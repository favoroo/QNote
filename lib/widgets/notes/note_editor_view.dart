import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/core/utils/delta_markdown.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;

class NoteEditorView extends ConsumerStatefulWidget {
  final Note note;

  const NoteEditorView({required this.note, super.key});

  @override
  ConsumerState<NoteEditorView> createState() => _NoteEditorViewState();
}

class _HistoryItem {
  final String text;
  final TextSelection selection;
  _HistoryItem(this.text, this.selection);
}

class _NoteEditorViewState extends ConsumerState<NoteEditorView> {
  late MarkdownTextEditingController _contentController;
  late TextEditingController _titleController;
  final FocusNode _editorFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ImageRepository _imageRepo = ImageRepository();
  final ImagePicker _imagePicker = ImagePicker();

  // History system for plain text undo/redo
  final List<_HistoryItem> _undoList = [];
  final List<_HistoryItem> _redoList = [];
  bool _isHistoryAction = false;

  // Auto-save and exit guard variables
  Timer? _autoSaveTimer;
  bool _isSaving = false;
  String _lastSavedTitle = '';
  String _lastSavedContent = '';

  // Photo synchronization and tracking
  late List<String> _photos;
  late List<String> _newlyUploadedPaths;
  late List<String> _removedPaths;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _contentController = MarkdownTextEditingController(
      context: context,
      text: _initContentString(),
    );
    
    // Seed the initial saved state to prevent redundant saves
    _lastSavedTitle = widget.note.title;
    _lastSavedContent = _contentController.text;

    // Parse initial photos from markdown content
    _photos = _extractImagesFromContent(_contentController.text);
    _newlyUploadedPaths = [];
    _removedPaths = [];

    // Listen to changes in both title and content for auto-saving
    _titleController.addListener(_onTitleChanged);
    _contentController.addListener(_onControllerChanged);

    // Initial state seed
    _undoList.add(_HistoryItem(_contentController.text, _contentController.selection));
  }

  String _initContentString() {
    final content = widget.note.content;
    if (content.isNotEmpty) {
      try {
        final deltaJson = jsonDecode(content);
        if (deltaJson is List) {
          final doc = Document.fromJson(deltaJson);
          return deltaToMarkdown(doc.toDelta());
        }
      } catch (_) {}
    }
    return content;
  }

  void _onTitleChanged() {
    _triggerAutoSave();
  }

  void _onControllerChanged() {
    if (_isHistoryAction) return;

    final currentText = _contentController.text;
    final currentSelection = _contentController.selection;

    if (_undoList.isEmpty || _undoList.last.text != currentText) {
      if (_undoList.length > 50) {
        _undoList.removeAt(0);
      }
      _undoList.add(_HistoryItem(currentText, currentSelection));
      _redoList.clear();
    }
    
    // Bidirectional sync: extract images from the text when edited
    _syncPhotosFromContent();
    
    _triggerAutoSave();
  }

  void _syncPhotosFromContent() {
    final currentContent = _contentController.text;
    final inlineImages = _extractImagesFromContent(currentContent);
    
    if (!listEquals(_photos, inlineImages)) {
      setState(() {
        _photos = inlineImages;
      });
    }
  }

  void _triggerAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        _saveNote();
      }
    });
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _titleController.removeListener(_onTitleChanged);
    _contentController.removeListener(_onControllerChanged);
    _contentController.dispose();
    _titleController.dispose();
    _editorFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _undo() {
    if (_undoList.length < 2) return;
    _isHistoryAction = true;

    // Pop current state and push to redo
    final currentState = _undoList.removeLast();
    _redoList.add(currentState);

    // Load previous state
    final prevState = _undoList.last;
    _contentController.value = TextEditingValue(
      text: prevState.text,
      selection: prevState.selection,
    );
    _isHistoryAction = false;
    if (mounted) setState(() {});
  }

  void _redo() {
    if (_redoList.isEmpty) return;
    _isHistoryAction = true;

    final nextState = _redoList.removeLast();
    _undoList.add(nextState);

    _contentController.value = TextEditingValue(
      text: nextState.text,
      selection: nextState.selection,
    );
    _isHistoryAction = false;
    if (mounted) setState(() {});
  }

  List<String> _extractImagesFromContent(String content) {
    final List<String> images = [];
    final regExp = RegExp(r'!\[.*?\]\((.*?)\)');
    final matches = regExp.allMatches(content);
    for (final match in matches) {
      final path = match.group(1);
      if (path != null && path.isNotEmpty) {
        images.add(path);
      }
    }
    return images;
  }

  Future<void> _saveNote() async {
    final currentTitle = _titleController.text.isEmpty ? '无标题' : _titleController.text;
    final currentContent = _contentController.text;

    // If nothing changed since the last save, skip the database update entirely
    if (currentTitle == _lastSavedTitle && currentContent == _lastSavedContent) {
      return;
    }

    _lastSavedTitle = currentTitle;
    _lastSavedContent = currentContent;

    // Parse and synchronize inline images with the Note model
    final inlineImages = _extractImagesFromContent(currentContent);

    final updated = widget.note.copyWith(
      title: currentTitle,
      content: currentContent,
      images: inlineImages,
      updatedAt: DateTime.now(),
    );
    
    await ref.read(noteListProvider.notifier).updateNote(updated);
  }

  Future<void> _handleBack() async {
    if (_isSaving) return;
    if (mounted) {
      setState(() {
        _isSaving = true;
      });
    }

    _autoSaveTimer?.cancel(); // Cancel any pending auto-save before final manual exit save

    try {
      // Clean up physically removed files from disk
      for (final path in _removedPaths) {
        try {
          await _imageRepo.deleteImage(path);
        } catch (_) {}
      }
      _removedPaths.clear();
      _newlyUploadedPaths.clear();

      await _saveNote();
    } catch (e) {
      debugPrint('Error saving note on back: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _copyMarkdown() {
    Clipboard.setData(ClipboardData(text: _contentController.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制 Markdown'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _pickImageFromGallery() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 80,
    );
    if (image == null) return;

    String savedPath;
    if (kIsWeb) {
      final bytes = await image.readAsBytes();
      final base64Str = base64Encode(bytes);
      final ext = image.path.contains('.png') ? 'png' : 'jpeg';
      savedPath = 'data:image/$ext;base64,$base64Str';
    } else {
      final file = File(image.path);
      savedPath = await _imageRepo.saveImage(file, subfolder: 'note');
    }

    if (mounted) {
      setState(() {
        _newlyUploadedPaths.add(savedPath);
      });
      _insertMarkdownAtCursor('![image]($savedPath)');
    }
  }

  Future<void> _pickImageFromCamera() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 80,
    );
    if (image == null) return;

    String savedPath;
    if (kIsWeb) {
      final bytes = await image.readAsBytes();
      final base64Str = base64Encode(bytes);
      final ext = image.path.contains('.png') ? 'png' : 'jpeg';
      savedPath = 'data:image/$ext;base64,$base64Str';
    } else {
      final file = File(image.path);
      savedPath = await _imageRepo.saveImage(file, subfolder: 'note');
    }

    if (mounted) {
      setState(() {
        _newlyUploadedPaths.add(savedPath);
      });
      _insertMarkdownAtCursor('![image]($savedPath)');
    }
  }

  void _removePhoto(int index) {
    final path = _photos[index];
    
    // Remove from disk if it was newly uploaded in this session
    if (_newlyUploadedPaths.contains(path)) {
      _newlyUploadedPaths.remove(path);
      try {
        _imageRepo.deleteImage(path);
      } catch (_) {}
    } else {
      _removedPaths.add(path);
    }

    setState(() {
      _photos.removeAt(index);
      
      // Also remove the inline markdown from the content editor text!
      final text = _contentController.text;
      final escapedPath = RegExp.escape(path);
      final regExp = RegExp('!\\\[.*?\\\]\\\\($escapedPath\\\\)\\\\n*');
      final newText = text.replaceAll(regExp, '');
      
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: 0),
      );
    });
    
    _triggerAutoSave();
  }

  void _previewPhoto(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          body: Center(
            child: InteractiveViewer(
              child: UnifiedImage(
                imagePath: _photos[index],
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _insertMarkdownAtCursor(String markup) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final index = selection.baseOffset >= 0 ? selection.baseOffset : text.length;

    // Smart newline wrapping for block level elements
    final isBlock = markup.startsWith('![image]') || markup == '---';
    String finalMarkup = markup;

    if (isBlock) {
      final prefix = (index == 0 || text[index - 1] == '\n') ? '' : '\n';
      String suffix = '\n';
      if (markup.startsWith('![')) {
        // Automatically add a blank line below the image for convenient subsequent text editing!
        suffix = '\n\n';
      } else {
        suffix = (index == text.length || text[index] == '\n') ? '' : '\n';
      }
      finalMarkup = '$prefix$markup$suffix';
    }

    final newText = text.replaceRange(index, index, finalMarkup);
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: index + finalMarkup.length),
    );
  }

  void _toggleBlockPrefix(String prefix) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    if (selection.baseOffset < 0) return;

    int start = selection.baseOffset;
    while (start > 0 && text[start - 1] != '\n') {
      start--;
    }
    int end = selection.baseOffset;
    while (end < text.length && text[end] != '\n') {
      end++;
    }

    final lineText = text.substring(start, end);
    String newLineText;

    if (lineText.startsWith(prefix)) {
      newLineText = lineText.substring(prefix.length);
    } else {
      var cleanLine = lineText;
      if (prefix.trim().startsWith('#')) {
        while (cleanLine.startsWith('#')) {
          cleanLine = cleanLine.substring(1);
        }
        if (cleanLine.startsWith(' ')) {
          cleanLine = cleanLine.substring(1);
        }
      }
      newLineText = '$prefix$cleanLine';
    }

    final newText = text.replaceRange(start, end, newLineText);
    final diff = newLineText.length - lineText.length;

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.baseOffset + diff),
    );
  }

  void _toggleInlineStyle(String marker) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    if (selection.baseOffset < 0) return;

    if (selection.start == selection.end) {
      final newText = text.replaceRange(selection.start, selection.end, '$marker$marker');
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: selection.start + marker.length),
      );
      return;
    }

    final selectedText = text.substring(selection.start, selection.end);
    String newSelectedText;

    if (selectedText.startsWith(marker) && selectedText.endsWith(marker)) {
      newSelectedText = selectedText.substring(marker.length, selectedText.length - marker.length);
    } else {
      newSelectedText = '$marker$selectedText$marker';
    }

    final newText = text.replaceRange(selection.start, selection.end, newSelectedText);
    final diff = newSelectedText.length - selectedText.length;

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: selection.start,
        extentOffset: selection.end + diff,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          await _handleBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          title: TextField(
            controller: _titleController,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: '无标题',
              filled: false,
              fillColor: Colors.transparent,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: _copyMarkdown,
              tooltip: '复制 Markdown',
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_photos.isNotEmpty) ...[
                      _buildPhotosSection(theme, colorScheme),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _contentController,
                      focusNode: _editorFocusNode,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        height: 1.6,
                        letterSpacing: 0.3,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        hintText: '在此输入内容...',
                        filled: false,
                        fillColor: Colors.transparent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _buildToolbar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotosSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '插入的图片 (${_photos.length})',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final path = _photos[index];
              return GestureDetector(
                onTap: () => _previewPhoto(index),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: UnifiedImage(
                          imagePath: path,
                          width: 96,
                          height: 96,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: GestureDetector(
                        onTap: () => _removePhoto(index),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: colorScheme.error.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Divider(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          thickness: 1,
        ),
      ],
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                children: [
                  _ToolbarButton(
                    icon: Icons.undo,
                    onPressed: _undo,
                    enabled: _undoList.length >= 2,
                  ),
                  _ToolbarButton(
                    icon: Icons.redo,
                    onPressed: _redo,
                    enabled: _redoList.isNotEmpty,
                  ),
                  _ToolbarButton(
                    icon: Icons.title,
                    onPressed: () => _toggleBlockPrefix('# '),
                  ),
                  _ToolbarButton(
                    icon: Icons.format_bold,
                    onPressed: () => _toggleInlineStyle('**'),
                  ),
                  _ToolbarButton(
                    icon: Icons.format_italic,
                    onPressed: () => _toggleInlineStyle('*'),
                  ),
                  _ToolbarButton(
                    icon: Icons.strikethrough_s,
                    onPressed: () => _toggleInlineStyle('~~'),
                  ),
                  _ToolbarButton(
                    icon: Icons.format_quote,
                    onPressed: () => _toggleBlockPrefix('> '),
                  ),
                  _ToolbarButton(
                    icon: Icons.image_outlined,
                    onPressed: _pickImageFromGallery,
                  ),
                  _ToolbarButton(
                    icon: Icons.camera_alt_outlined,
                    onPressed: _pickImageFromCamera,
                  ),
                  _ToolbarButton(
                    icon: Icons.format_list_bulleted,
                    onPressed: () => _toggleBlockPrefix('- '),
                  ),
                  _ToolbarButton(
                    icon: Icons.format_list_numbered,
                    onPressed: () => _toggleBlockPrefix('1. '),
                  ),
                  _ToolbarButton(
                    icon: Icons.code,
                    onPressed: () => _toggleInlineStyle('`'),
                  ),
                  _ToolbarButton(
                    icon: Icons.horizontal_rule,
                    onPressed: () => _insertMarkdownAtCursor('---'),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: VerticalDivider(
                      width: 1,
                      indent: 8,
                      endIndent: 8,
                      color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                    ),
                  ),
                  _ToolbarButton(
                    icon: Icons.keyboard_hide,
                    onPressed: () {
                      _editorFocusNode.unfocus();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

  const _ToolbarButton({
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        icon: Icon(icon),
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        style: IconButton.styleFrom(
          foregroundColor: enabled ? theme.colorScheme.onSurface : theme.colorScheme.outlineVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

class MarkdownTextEditingController extends TextEditingController {
  final BuildContext context;

  MarkdownTextEditingController({required this.context, super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final selection = this.selection;
    final cursorOffset = selection.baseOffset;
    final activeLineIndex = _getActiveLineIndex(text, cursorOffset);

    final lines = text.split('\n');
    final List<TextSpan> children = [];
    final baseStyle = style ?? const TextStyle();

    for (int i = 0; i < lines.length; i++) {
      final lineText = lines[i];
      final isActive = (i == activeLineIndex);

      final lineSpan = _styleLine(lineText, isActive, context, baseStyle);
      children.add(lineSpan);

      if (i < lines.length - 1) {
        children.add(const TextSpan(text: '\n'));
      }
    }

    return TextSpan(style: baseStyle, children: children);
  }

  int _getActiveLineIndex(String text, int selectionOffset) {
    if (selectionOffset < 0) return -1;
    int currentOffset = 0;
    final lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final lineLength = lines[i].length + 1; // +1 for the '\n'
      if (selectionOffset >= currentOffset && selectionOffset <= currentOffset + lines[i].length) {
        return i;
      }
      currentOffset += lineLength;
    }
    return lines.length - 1;
  }

  TextSpan _styleLine(String lineText, bool isActive, BuildContext context, TextStyle baseStyle) {
    final theme = Theme.of(context);
    if (isActive) {
      return _parseActiveLine(lineText, baseStyle, theme);
    } else {
      return _parsePreviewLine(lineText, baseStyle, theme);
    }
  }

  TextSpan _parseActiveLine(String lineText, TextStyle baseStyle, ThemeData theme) {
    // 1. Image Block - Render as a clean, monospace text link so it can be edited/deleted easily
    final imageMatch = RegExp(r'^!\[(.*?)\]\((.*?)\)$').firstMatch(lineText.trim());
    if (imageMatch != null) {
      final path = imageMatch.group(2) ?? '';
      return TextSpan(
        children: [
          TextSpan(
            text: '🖼️ ![图片]',
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: '($path)',
            style: baseStyle.copyWith(
              color: theme.colorScheme.outline,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        ],
      );
    }

    // 2. Horizontal Rule
    if (lineText.trim() == '---' || lineText.trim() == '***') {
      return TextSpan(
        text: lineText,
        style: baseStyle.copyWith(
          color: theme.colorScheme.primary.withValues(alpha: 0.6),
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      );
    }

    // 3. Headings
    if (lineText.startsWith('# ')) {
      final cleanText = lineText.substring(2);
      final headerStyle = baseStyle.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      );
      return TextSpan(
        children: [
          TextSpan(text: '# ', style: baseStyle.copyWith(color: theme.colorScheme.primary.withValues(alpha: 0.6), fontSize: 22, fontWeight: FontWeight.bold)),
          _parseInlineStylesActive(cleanText, headerStyle, theme),
        ],
      );
    }
    if (lineText.startsWith('## ')) {
      final cleanText = lineText.substring(3);
      final headerStyle = baseStyle.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      );
      return TextSpan(
        children: [
          TextSpan(text: '## ', style: baseStyle.copyWith(color: theme.colorScheme.primary.withValues(alpha: 0.6), fontSize: 18, fontWeight: FontWeight.bold)),
          _parseInlineStylesActive(cleanText, headerStyle, theme),
        ],
      );
    }
    if (lineText.startsWith('### ')) {
      final cleanText = lineText.substring(4);
      final headerStyle = baseStyle.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      );
      return TextSpan(
        children: [
          TextSpan(text: '### ', style: baseStyle.copyWith(color: theme.colorScheme.primary.withValues(alpha: 0.6), fontSize: 16, fontWeight: FontWeight.bold)),
          _parseInlineStylesActive(cleanText, headerStyle, theme),
        ],
      );
    }

    // 4. Blockquote
    if (lineText.startsWith('> ')) {
      final cleanText = lineText.substring(2);
      final quoteStyle = baseStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
      );
      return TextSpan(
        children: [
          TextSpan(text: '> ', style: baseStyle.copyWith(color: theme.colorScheme.primary.withValues(alpha: 0.6), fontWeight: FontWeight.bold)),
          _parseInlineStylesActive(cleanText, quoteStyle, theme),
        ],
      );
    }

    // 5. List items
    if (lineText.startsWith('- ') || lineText.startsWith('* ')) {
      final cleanText = lineText.substring(2);
      final symbol = lineText.substring(0, 2);
      return TextSpan(
        children: [
          TextSpan(text: symbol, style: baseStyle.copyWith(color: theme.colorScheme.primary.withValues(alpha: 0.6), fontWeight: FontWeight.bold)),
          _parseInlineStylesActive(cleanText, baseStyle, theme),
        ],
      );
    }

    // 6. Numbered list items
    final numberMatch = RegExp(r'^(\d+)\.\s(.*)$').firstMatch(lineText);
    if (numberMatch != null) {
      final number = numberMatch.group(1);
      final cleanText = numberMatch.group(2) ?? '';
      return TextSpan(
        children: [
          TextSpan(
            text: '$number. ',
            style: baseStyle.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
          ),
          _parseInlineStylesActive(cleanText, baseStyle, theme),
        ],
      );
    }

    // 7. General Paragraph Line
    return _parseInlineStylesActive(lineText, baseStyle, theme);
  }

  TextSpan _parseInlineStylesActive(String text, TextStyle baseStyle, ThemeData theme) {
    final List<TextSpan> spans = [];
    int index = 0;
    final symbolStyle = baseStyle.copyWith(
      color: theme.colorScheme.primary.withValues(alpha: 0.5),
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.none,
    );

    while (index < text.length) {
      // Bold `**`
      if (text.startsWith('**', index)) {
        final end = text.indexOf('**', index + 2);
        if (end != -1) {
          spans.add(TextSpan(text: '**', style: symbolStyle));
          final innerText = text.substring(index + 2, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(fontWeight: FontWeight.bold),
          ));
          spans.add(TextSpan(text: '**', style: symbolStyle));
          index = end + 2;
          continue;
        }
      }

      // Italic `*`
      if (text.startsWith('*', index)) {
        final end = text.indexOf('*', index + 1);
        if (end != -1) {
          spans.add(TextSpan(text: '*', style: symbolStyle));
          final innerText = text.substring(index + 1, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ));
          spans.add(TextSpan(text: '*', style: symbolStyle));
          index = end + 1;
          continue;
        }
      }

      // Monospace code `` ` ``
      if (text.startsWith('`', index)) {
        final end = text.indexOf('`', index + 1);
        if (end != -1) {
          spans.add(TextSpan(text: '`', style: symbolStyle));
          final innerText = text.substring(index + 1, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              color: theme.colorScheme.primary,
            ),
          ));
          spans.add(TextSpan(text: '`', style: symbolStyle));
          index = end + 1;
          continue;
        }
      }

      // Strikethrough `~~`
      if (text.startsWith('~~', index)) {
        final end = text.indexOf('~~', index + 2);
        if (end != -1) {
          spans.add(TextSpan(text: '~~', style: symbolStyle));
          final innerText = text.substring(index + 2, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
          ));
          spans.add(TextSpan(text: '~~', style: symbolStyle));
          index = end + 2;
          continue;
        }
      }

      // Default
      spans.add(TextSpan(text: text[index].toString(), style: baseStyle));
      index++;
    }

    return TextSpan(children: spans);
  }

  TextSpan _parsePreviewLine(String lineText, TextStyle baseStyle, ThemeData theme) {
    final trimmed = lineText.trim();

    // 1. Image Block - Render as a beautiful, clean monospace text link inside the editor to prevent floating layout bugs
    final imageMatch = RegExp(r'^!\[(.*?)\]\((.*?)\)$').firstMatch(trimmed);
    if (imageMatch != null) {
      final path = imageMatch.group(2) ?? '';
      return TextSpan(
        children: [
          TextSpan(
            text: '🖼️ [图片] ',
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: path.split('/').last,
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary.withValues(alpha: 0.8),
              decoration: TextDecoration.underline,
              fontFamily: 'monospace',
            ),
          ),
        ],
      );
    }

    // 2. Horizontal Rule
    if (trimmed == '---' || trimmed == '***') {
      final remainingText = lineText.substring(1);
      return TextSpan(
        children: [
          WidgetSpan(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              height: 1.5,
              color: theme.colorScheme.outlineVariant.withOpacity(0.5),
            ),
          ),
          TextSpan(
            text: remainingText,
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent, height: 0),
          ),
        ],
      );
    }

    // 3. Headings
    if (lineText.startsWith('# ')) {
      final cleanText = lineText.substring(2);
      final headerStyle = baseStyle.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      );
      return TextSpan(
        children: [
          TextSpan(text: '# ', style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent)),
          _parseInlineStyles(cleanText, headerStyle, theme),
        ],
      );
    }
    if (lineText.startsWith('## ')) {
      final cleanText = lineText.substring(3);
      final headerStyle = baseStyle.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      );
      return TextSpan(
        children: [
          TextSpan(text: '## ', style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent)),
          _parseInlineStyles(cleanText, headerStyle, theme),
        ],
      );
    }
    if (lineText.startsWith('### ')) {
      final cleanText = lineText.substring(4);
      final headerStyle = baseStyle.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      );
      return TextSpan(
        children: [
          TextSpan(text: '### ', style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent)),
          _parseInlineStyles(cleanText, headerStyle, theme),
        ],
      );
    }

    // 4. Blockquote
    if (lineText.startsWith('> ')) {
      final cleanText = lineText.substring(2);
      final quoteStyle = baseStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurfaceVariant.withOpacity(0.85),
      );
      return TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              width: 4,
              height: 16,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          TextSpan(text: ' ', style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent)),
          _parseInlineStyles(cleanText, quoteStyle, theme),
        ],
      );
    }

    // 5. List items
    if (lineText.startsWith('- ') || lineText.startsWith('* ')) {
      final cleanText = lineText.substring(2);
      return TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.only(right: 8, left: 4),
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          TextSpan(text: ' ', style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent)),
          _parseInlineStyles(cleanText, baseStyle, theme),
        ],
      );
    }

    // 6. Numbered list items
    final numberMatch = RegExp(r'^(\d+)\.\s(.*)$').firstMatch(lineText);
    if (numberMatch != null) {
      final number = numberMatch.group(1);
      final cleanText = numberMatch.group(2) ?? '';
      return TextSpan(
        children: [
          TextSpan(
            text: '$number. ',
            style: baseStyle.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          _parseInlineStyles(cleanText, baseStyle, theme),
        ],
      );
    }

    // 7. General Paragraph Line
    return _parseInlineStyles(lineText, baseStyle, theme);
  }

  TextSpan _parseInlineStyles(String text, TextStyle baseStyle, ThemeData theme) {
    final List<TextSpan> spans = [];
    int index = 0;

    while (index < text.length) {
      // Bold `**`
      if (text.startsWith('**', index)) {
        final end = text.indexOf('**', index + 2);
        if (end != -1) {
          spans.add(TextSpan(
            text: '**',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          final innerText = text.substring(index + 2, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(fontWeight: FontWeight.bold),
          ));
          spans.add(TextSpan(
            text: '**',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          index = end + 2;
          continue;
        }
      }

      // Italic `*`
      if (text.startsWith('*', index)) {
        final end = text.indexOf('*', index + 1);
        if (end != -1) {
          spans.add(TextSpan(
            text: '*',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          final innerText = text.substring(index + 1, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ));
          spans.add(TextSpan(
            text: '*',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          index = end + 1;
          continue;
        }
      }

      // Monospace code `` ` ``
      if (text.startsWith('`', index)) {
        final end = text.indexOf('`', index + 1);
        if (end != -1) {
          spans.add(TextSpan(
            text: '`',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          final innerText = text.substring(index + 1, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              color: theme.colorScheme.primary,
            ),
          ));
          spans.add(TextSpan(
            text: '`',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          index = end + 1;
          continue;
        }
      }

      // Strikethrough `~~`
      if (text.startsWith('~~', index)) {
        final end = text.indexOf('~~', index + 2);
        if (end != -1) {
          spans.add(TextSpan(
            text: '~~',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          final innerText = text.substring(index + 2, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
          ));
          spans.add(TextSpan(
            text: '~~',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          index = end + 2;
          continue;
        }
      }

      // Default
      spans.add(TextSpan(text: text[index].toString(), style: baseStyle));
      index++;
    }

    return TextSpan(children: spans);
  }
}

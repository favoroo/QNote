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

// ---------------------------------------------------------------------------
// Segment model
// ---------------------------------------------------------------------------
abstract class _Segment {}

class _TextSegment extends _Segment {
  final TextEditingController controller;
  final FocusNode focusNode;
  _TextSegment({String text = ''})
      : controller = TextEditingController(text: text),
        focusNode = FocusNode();
  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

class _ImageSegment extends _Segment {
  final String path;
  _ImageSegment(this.path);
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------
class NoteEditorView extends ConsumerStatefulWidget {
  final Note note;
  const NoteEditorView({required this.note, super.key});

  @override
  ConsumerState<NoteEditorView> createState() => _NoteEditorViewState();
}

class _NoteEditorViewState extends ConsumerState<NoteEditorView> {
  late TextEditingController _titleController;
  final ScrollController _scrollController = ScrollController();
  final ImageRepository _imageRepo = ImageRepository();
  final ImagePicker _imagePicker = ImagePicker();

  final List<_Segment> _segments = [];

  // Track which text segment is currently focused
  int _focusedSegmentIndex = 0;

  // Auto-save
  Timer? _autoSaveTimer;
  bool _isSaving = false;
  String _lastSavedTitle = '';
  String _lastSavedContent = '';

  // Newly uploaded paths for cleanup on discard
  final List<String> _newlyUploadedPaths = [];
  final List<String> _removedPaths = [];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;

    final rawContent = _initContentString();
    _lastSavedContent = rawContent;
    _parseContentIntoSegments(rawContent);

    _titleController.addListener(_triggerAutoSave);
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

  /// Parse a markdown string into alternating text/image segments.
  void _parseContentIntoSegments(String content) {
    _segments.clear();
    // Split on image lines: lines matching ^![...](...)$
    final imageReg = RegExp(r'^!\[.*?\]\((.*?)\)$', multiLine: true);
    int lastEnd = 0;

    for (final match in imageReg.allMatches(content)) {
      // Text before image
      final textBefore = content.substring(lastEnd, match.start);
      final cleanText = textBefore.trimRight();
      _addTextSegment(cleanText.isEmpty ? '' : cleanText);

      // Image segment
      final path = match.group(1) ?? '';
      _segments.add(_ImageSegment(path));

      lastEnd = match.end;
      // Skip a leading newline after image tag
      if (lastEnd < content.length && content[lastEnd] == '\n') lastEnd++;
    }

    // Remaining text
    final remaining = content.substring(lastEnd).trimLeft();
    _addTextSegment(remaining);

    // Ensure at least one text segment
    if (_segments.isEmpty) _addTextSegment('');
    // Ensure last segment is always a text segment for typing
    if (_segments.last is _ImageSegment) _addTextSegment('');

    _attachListeners();
  }

  void _addTextSegment(String text) {
    final seg = _TextSegment(text: text);
    _segments.add(seg);
  }

  void _attachListeners() {
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (seg is _TextSegment) {
        seg.controller.addListener(_triggerAutoSave);
        // Update focus index silently — NO setState, to avoid rebuild disrupting focus/keyboard.
        seg.focusNode.addListener(() {
          if (seg.focusNode.hasFocus) {
            _focusedSegmentIndex = i;
          }
        });
      }
    }
  }

  /// Serialize all segments back to markdown.
  String _serializeToMarkdown() {
    final buf = StringBuffer();
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (seg is _TextSegment) {
        final text = seg.controller.text;
        if (text.isNotEmpty) {
          buf.write(text);
          if (i < _segments.length - 1) buf.write('\n');
        }
      } else if (seg is _ImageSegment) {
        buf.write('![image](${seg.path})\n');
      }
    }
    return buf.toString();
  }

  List<String> _extractImages() {
    return _segments.whereType<_ImageSegment>().map((s) => s.path).toList();
  }

  void _triggerAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _saveNote();
    });
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.isEmpty ? '无标题' : _titleController.text;
    final content = _serializeToMarkdown();
    if (title == _lastSavedTitle && content == _lastSavedContent) return;
    _lastSavedTitle = title;
    _lastSavedContent = content;

    final updated = widget.note.copyWith(
      title: title,
      content: content,
      images: _extractImages(),
      updatedAt: DateTime.now(),
    );
    await ref.read(noteListProvider.notifier).updateNote(updated);
  }

  Future<void> _handleBack() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    _autoSaveTimer?.cancel();
    try {
      for (final path in _removedPaths) {
        try { await _imageRepo.deleteImage(path); } catch (_) {}
      }
      await _saveNote();
    } catch (e) {
      debugPrint('Error saving note: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _titleController.dispose();
    _scrollController.dispose();
    for (final seg in _segments) {
      if (seg is _TextSegment) seg.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Image insertion
  // ---------------------------------------------------------------------------
  Future<void> _pickImage(ImageSource source) async {
    final image = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 80,
    );
    if (image == null) return;

    String savedPath;
    if (kIsWeb) {
      final bytes = await image.readAsBytes();
      final base64Str = base64Encode(bytes);
      final ext = image.path.toLowerCase().contains('.png') ? 'png' : 'jpeg';
      savedPath = 'data:image/$ext;base64,$base64Str';
    } else {
      final file = File(image.path);
      savedPath = await _imageRepo.saveImage(file, subfolder: 'note');
    }

    _newlyUploadedPaths.add(savedPath);
    _insertImageAtFocusedSegment(savedPath);
  }

  void _insertImageAtFocusedSegment(String path) {
    // Find the currently focused text segment dynamically
    int targetIndex = -1;
    for (int i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      if (s is _TextSegment && s.focusNode.hasFocus) {
        targetIndex = i;
        break;
      }
    }
    // Fallback: use last known focused index
    if (targetIndex < 0) targetIndex = _focusedSegmentIndex;
    // Fallback: use last text segment
    if (targetIndex < 0 || targetIndex >= _segments.length || _segments[targetIndex] is! _TextSegment) {
      for (int i = _segments.length - 1; i >= 0; i--) {
        if (_segments[i] is _TextSegment) { targetIndex = i; break; }
      }
    }
    if (targetIndex < 0) return;

    final seg = _segments[targetIndex] as _TextSegment;
    final cursor = seg.controller.selection.baseOffset;
    final text = seg.controller.text;
    final splitAt = cursor >= 0 ? cursor : text.length;

    final textBefore = text.substring(0, splitAt);
    final textAfter = text.substring(splitAt);

    final before = _TextSegment(text: textBefore);
    final imgSeg = _ImageSegment(path);
    final after = _TextSegment(text: textAfter);

    // Dispose old segment and attach listeners to new ones before setState
    seg.dispose();
    before.controller.addListener(_triggerAutoSave);
    after.controller.addListener(_triggerAutoSave);
    final afterIdx = targetIndex + 2;
    before.focusNode.addListener(() {
      if (before.focusNode.hasFocus) _focusedSegmentIndex = targetIndex;
    });
    after.focusNode.addListener(() {
      if (after.focusNode.hasFocus) _focusedSegmentIndex = afterIdx;
    });

    setState(() {
      _segments.replaceRange(targetIndex, targetIndex + 1, [before, imgSeg, after]);
      _focusedSegmentIndex = afterIdx;
    });

    // Focus the text field after the image
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (afterIdx < _segments.length && _segments[afterIdx] is _TextSegment) {
        (_segments[afterIdx] as _TextSegment).focusNode.requestFocus();
      }
      _triggerAutoSave();
    });
  }

  void _removeImage(int segmentIndex) {
    if (_segments[segmentIndex] is! _ImageSegment) return;
    final img = _segments[segmentIndex] as _ImageSegment;

    if (_newlyUploadedPaths.contains(img.path)) {
      _newlyUploadedPaths.remove(img.path);
      try { _imageRepo.deleteImage(img.path); } catch (_) {}
    } else {
      _removedPaths.add(img.path);
    }

    setState(() {
      // Merge adjacent text segments around the removed image
      final prevIdx = segmentIndex - 1;
      final nextIdx = segmentIndex + 1;
      String mergedText = '';

      if (prevIdx >= 0 && _segments[prevIdx] is _TextSegment) {
        mergedText += (_segments[prevIdx] as _TextSegment).controller.text.trimRight();
        (_segments[prevIdx] as _TextSegment).dispose();
      }
      if (nextIdx < _segments.length && _segments[nextIdx] is _TextSegment) {
        final nextText = (_segments[nextIdx] as _TextSegment).controller.text.trimLeft();
        if (mergedText.isNotEmpty && nextText.isNotEmpty) mergedText += '\n';
        mergedText += nextText;
        (_segments[nextIdx] as _TextSegment).dispose();
      }

      final merged = _TextSegment(text: mergedText);

      final start = (prevIdx >= 0 && _segments[prevIdx] is _TextSegment) ? prevIdx : segmentIndex;
      final end = (nextIdx < _segments.length && _segments[nextIdx] is _TextSegment) ? nextIdx : segmentIndex;
      _segments.replaceRange(start, end + 1, [merged]);
      _attachListeners();
    });
    _triggerAutoSave();
  }

  void _previewImage(String path) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: Center(
          child: InteractiveViewer(
            child: UnifiedImage(imagePath: path, fit: BoxFit.contain),
          ),
        ),
      ),
    ));
  }

  void _copyMarkdown() {
    Clipboard.setData(ClipboardData(text: _serializeToMarkdown()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制 Markdown'), duration: Duration(seconds: 1)),
    );
  }

  // ---------------------------------------------------------------------------
  // Toolbar actions on focused segment
  // ---------------------------------------------------------------------------
  _TextSegment? get _focusedTextSeg {
    for (final seg in _segments) {
      if (seg is _TextSegment && seg.focusNode.hasFocus) return seg;
    }
    if (_focusedSegmentIndex < _segments.length &&
        _segments[_focusedSegmentIndex] is _TextSegment) {
      return _segments[_focusedSegmentIndex] as _TextSegment;
    }
    return null;
  }

  void _toggleBlockPrefix(String prefix) {
    final seg = _focusedTextSeg;
    if (seg == null) return;
    final ctrl = seg.controller;
    final text = ctrl.text;
    final sel = ctrl.selection;
    if (sel.baseOffset < 0) return;

    int start = sel.baseOffset;
    while (start > 0 && text[start - 1] != '\n') { start--; }
    int end = sel.baseOffset;
    while (end < text.length && text[end] != '\n') { end++; }

    final lineText = text.substring(start, end);
    final newLine = lineText.startsWith(prefix)
        ? lineText.substring(prefix.length)
        : '$prefix${lineText.replaceFirst(RegExp(r'^#+\s?'), '')}';

    final newText = text.replaceRange(start, end, newLine);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: sel.baseOffset + (newLine.length - lineText.length)),
    );
  }

  void _insertBlock(String markup) {
    final seg = _focusedTextSeg;
    if (seg == null) return;
    final ctrl = seg.controller;
    final text = ctrl.text;
    final idx = ctrl.selection.baseOffset >= 0 ? ctrl.selection.baseOffset : text.length;
    final prefix = (idx == 0 || text[idx - 1] == '\n') ? '' : '\n';
    final suffix = (idx == text.length || text[idx] == '\n') ? '' : '\n';
    final insert = '$prefix$markup$suffix';
    final newText = text.replaceRange(idx, idx, insert);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: idx + insert.length),
    );
  }

  void _toggleInlineStyle(String marker) {
    final seg = _focusedTextSeg;
    if (seg == null) return;
    final ctrl = seg.controller;
    final text = ctrl.text;
    final sel = ctrl.selection;
    if (sel.baseOffset < 0) return;

    if (sel.start == sel.end) {
      final newText = text.replaceRange(sel.start, sel.end, '$marker$marker');
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + marker.length),
      );
      return;
    }

    final selected = text.substring(sel.start, sel.end);
    final newSelected = (selected.startsWith(marker) && selected.endsWith(marker))
        ? selected.substring(marker.length, selected.length - marker.length)
        : '$marker$selected$marker';
    final newText = text.replaceRange(sel.start, sel.end, newSelected);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: sel.start, extentOffset: sel.start + newSelected.length),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          title: TextField(
            controller: _titleController,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: '无标题',
              filled: false,
            ),
          ),
          actions: [
            IconButton(icon: const Icon(Icons.copy), onPressed: _copyMarkdown, tooltip: '复制 Markdown'),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _buildSegmentWidgets(theme),
                ),
              ),
            ),
            _buildToolbar(theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSegmentWidgets(ThemeData theme) {
    final widgets = <Widget>[];
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (seg is _TextSegment) {
        widgets.add(_buildTextSegment(seg, theme));
      } else if (seg is _ImageSegment) {
        widgets.add(_buildImageSegment(seg, i, theme));
      }
    }
    return widgets;
  }

  Widget _buildTextSegment(_TextSegment seg, ThemeData theme) {
    return TextField(
      controller: seg.controller,
      focusNode: seg.focusNode,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      style: theme.textTheme.bodyLarge?.copyWith(height: 1.6, letterSpacing: 0.3),
      decoration: const InputDecoration(
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
        enabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        hintText: '',
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 4),
      ),
    );
  }

  Widget _buildImageSegment(_ImageSegment seg, int index, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => _previewImage(seg.path),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: UnifiedImage(
                  imagePath: seg.path,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => _removeImage(index),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            children: [
              _ToolbarButton(icon: Icons.title, onPressed: () => _toggleBlockPrefix('# ')),
              _ToolbarButton(icon: Icons.format_bold, onPressed: () => _toggleInlineStyle('**')),
              _ToolbarButton(icon: Icons.format_italic, onPressed: () => _toggleInlineStyle('*')),
              _ToolbarButton(icon: Icons.strikethrough_s, onPressed: () => _toggleInlineStyle('~~')),
              _ToolbarButton(icon: Icons.format_quote, onPressed: () => _toggleBlockPrefix('> ')),
              _ToolbarButton(icon: Icons.image_outlined, onPressed: () => _pickImage(ImageSource.gallery)),
              _ToolbarButton(icon: Icons.camera_alt_outlined, onPressed: () => _pickImage(ImageSource.camera)),
              _ToolbarButton(icon: Icons.format_list_bulleted, onPressed: () => _toggleBlockPrefix('- ')),
              _ToolbarButton(icon: Icons.format_list_numbered, onPressed: () => _toggleBlockPrefix('1. ')),
              _ToolbarButton(icon: Icons.code, onPressed: () => _toggleInlineStyle('`')),
              _ToolbarButton(icon: Icons.horizontal_rule, onPressed: () => _insertBlock('---')),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: VerticalDivider(
                  width: 1, indent: 8, endIndent: 8,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              _ToolbarButton(
                icon: Icons.keyboard_hide,
                onPressed: () => _focusedTextSeg?.focusNode.unfocus(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbar button
// ---------------------------------------------------------------------------
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _ToolbarButton({required this.icon, required this.onPressed});

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
          foregroundColor: theme.colorScheme.onSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
      ),
    );
  }
}

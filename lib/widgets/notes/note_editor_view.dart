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
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/core/utils/link_preview_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;

// ---------------------------------------------------------------------------
// Segment model
// ---------------------------------------------------------------------------
abstract class _Segment {}

class _TextSegment extends _Segment {
  final MarkdownTextEditingController controller;
  final FocusNode focusNode;
  bool listenersAttached = false;
  _TextSegment({required BuildContext context, String text = ''})
      : focusNode = FocusNode(),
        controller = MarkdownTextEditingController(context: context, text: text) {
    controller.focusNode = focusNode;
    focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    controller.refresh();
  }

  void dispose() {
    focusNode.removeListener(_onFocusChanged);
    controller.dispose();
    focusNode.dispose();
  }
}

class _ImageSegment extends _Segment {
  final String path;
  _ImageSegment(this.path);
}

class _LinkSegment extends _Segment {
  final String url;
  final String? title;
  _LinkSegment({required this.url, this.title});
}

// ---------------------------------------------------------------------------
// History states for undo/redo
// ---------------------------------------------------------------------------
abstract class _SegmentState {}

class _TextSegmentState extends _SegmentState {
  final String text;
  _TextSegmentState(this.text);
}

class _ImageSegmentState extends _SegmentState {
  final String path;
  _ImageSegmentState(this.path);
}

class _LinkSegmentState extends _SegmentState {
  final String url;
  final String? title;
  _LinkSegmentState(this.url, this.title);
}

class _EditorHistoryState {
  final List<_SegmentState> segments;
  final int focusedSegmentIndex;
  final TextSelection? selection;

  _EditorHistoryState({
    required this.segments,
    required this.focusedSegmentIndex,
    this.selection,
  });
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

  // Link Previews Cache & State
  final Map<String, LinkMetadata> _fetchedMetadata = {};
  final Set<String> _loadingUrls = {};
  final Set<String> _dismissedUrls = {};

  // History system for undo/redo
  final List<_EditorHistoryState> _undoList = [];
  final List<_EditorHistoryState> _redoList = [];
  bool _isHistoryAction = false;
  Timer? _historyTimer;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;

    final rawContent = _initContentString();
    _lastSavedContent = rawContent;
    _parseContentIntoSegments(rawContent);

    _titleController.addListener(_triggerAutoSave);
    
    // Seed initial history state
    _undoList.add(_captureHistoryState());
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
      if (cleanText.isEmpty) {
        _addTextSegment('');
      } else {
        _addTextAndLinkSegments(cleanText);
      }

      // Image segment
      final path = match.group(1) ?? '';
      _segments.add(_ImageSegment(path));

      lastEnd = match.end;
      // Skip a leading newline after image tag
      if (lastEnd < content.length && content[lastEnd] == '\n') lastEnd++;
    }

    // Remaining text
    final remaining = content.substring(lastEnd).trimLeft();
    if (remaining.isEmpty) {
      _addTextSegment('');
    } else {
      _addTextAndLinkSegments(remaining);
    }

    // Ensure at least one text segment
    if (_segments.isEmpty) _addTextSegment('');
    // Ensure last segment is always a text segment for typing
    if (_segments.last is _ImageSegment || _segments.last is _LinkSegment) _addTextSegment('');

    _attachListeners();
  }

  void _addTextSegment(String text) {
    final seg = _TextSegment(context: context, text: text);
    _segments.add(seg);
  }

  void _addTextAndLinkSegments(String text) {
    final pattern = RegExp(
      r'\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)|(https?:\/\/[^\s\(\)\[\]\{\}<>"\u4e00-\u9fa5]+)',
    );

    int lastEnd = 0;
    for (final match in pattern.allMatches(text)) {
      final textBefore = text.substring(lastEnd, match.start);
      if (textBefore.isNotEmpty) {
        _addTextSegment(textBefore);
      }

      if (match.group(1) != null) {
        final title = match.group(1)!;
        final url = match.group(2)!;
        _segments.add(_LinkSegment(url: url, title: title));
      } else {
        String url = match.group(3)!;
        final trailingPunct = RegExp(r'[\.\,\?\!\:\;]+$');
        final punctMatch = trailingPunct.firstMatch(url);
        String punct = '';
        if (punctMatch != null) {
          punct = punctMatch.group(0)!;
          url = url.substring(0, url.length - punct.length);
        }
        
        _segments.add(_LinkSegment(url: url));
        
        if (punct.isNotEmpty) {
          _addTextSegment(punct);
        }
      }

      lastEnd = match.end;
    }

    final remaining = text.substring(lastEnd);
    if (remaining.isNotEmpty) {
      _addTextSegment(remaining);
    }
  }

  void _attachListeners() {
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (seg is _TextSegment && !seg.listenersAttached) {
        seg.listenersAttached = true;
        seg.controller.addListener(_triggerAutoSave);
        seg.controller.addListener(() => _handleTextChanges(seg));
        seg.controller.addListener(() => _onTextSegmentChanged(seg));
        
        seg.focusNode.addListener(() {
          if (seg.focusNode.hasFocus) {
            final currentIndex = _segments.indexOf(seg);
            if (currentIndex >= 0) {
              _focusedSegmentIndex = currentIndex;
            }
          } else {
            // Check if we should split URL lines when segment loses focus
            final currentIndex = _segments.indexOf(seg);
            if (currentIndex >= 0) {
              _splitUrlsInSegment(currentIndex);
            }
          }
        });

        seg.focusNode.onKeyEvent = (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.backspace) {
            final currentIndex = _segments.indexOf(seg);
            if (seg.controller.text.isEmpty && currentIndex > 0) {
              _mergeSegmentWithPrevious(currentIndex);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        };
      }
    }
  }

  void _handleTextChanges(_TextSegment seg) {
    final index = _segments.indexOf(seg);
    if (index < 0) return;
    final text = seg.controller.text;
    if (text.contains('\n')) {
      _splitUrlsInSegment(index);
    }
  }

  void _splitUrlsInSegment(int index) {
    if (index < 0 || index >= _segments.length) return;
    final seg = _segments[index];
    if (seg is! _TextSegment) return;

    final text = seg.controller.text;
    final pattern = RegExp(
      r'\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)|(https?:\/\/[^\s\(\)\[\]\{\}<>"\u4e00-\u9fa5]+)',
    );

    final matches = pattern.allMatches(text);
    if (matches.isEmpty) return;

    _historyTimer?.cancel();
    _saveHistoryState();

    final List<_Segment> newSegments = [];
    int lastEnd = 0;
    int lastLinkIdxInNew = -1;

    for (final match in matches) {
      final textBefore = text.substring(lastEnd, match.start);
      if (textBefore.isNotEmpty) {
        newSegments.add(_TextSegment(context: context, text: textBefore));
      }

      if (match.group(1) != null) {
        final title = match.group(1)!;
        final url = match.group(2)!;
        newSegments.add(_LinkSegment(url: url, title: title));
      } else {
        String url = match.group(3)!;
        final trailingPunct = RegExp(r'[\.\,\?\!\:\;]+$');
        final punctMatch = trailingPunct.firstMatch(url);
        String punct = '';
        if (punctMatch != null) {
          punct = punctMatch.group(0)!;
          url = url.substring(0, url.length - punct.length);
        }
        
        newSegments.add(_LinkSegment(url: url));
        
        if (punct.isNotEmpty) {
          newSegments.add(_TextSegment(context: context, text: punct));
        }
      }
      lastLinkIdxInNew = newSegments.length - 1;
      lastEnd = match.end;
    }

    final remaining = text.substring(lastEnd);
    if (remaining.isNotEmpty) {
      newSegments.add(_TextSegment(context: context, text: remaining));
    }

    if (newSegments.isEmpty) {
      newSegments.add(_TextSegment(context: context, text: ''));
    }

    // Ensure last segment is always a text segment for typing if it's a link
    if (newSegments.last is _LinkSegment) {
      newSegments.add(_TextSegment(context: context, text: ''));
    }

    // Dispose old segment
    seg.dispose();

    setState(() {
      _segments.replaceRange(index, index + 1, newSegments);
    });

    _attachListeners();

    // Trigger metadata fetch
    for (final s in newSegments) {
      if (s is _LinkSegment) {
        _fetchMetadataForUrl(s.url);
      }
    }

    // Focus the next text segment
    int focusTargetIdx = -1;
    if (lastLinkIdxInNew != -1) {
      final absoluteLastLinkIdx = index + lastLinkIdxInNew;
      for (int i = absoluteLastLinkIdx + 1; i < _segments.length; i++) {
        if (_segments[i] is _TextSegment) {
          focusTargetIdx = i;
          break;
        }
      }
    }

    if (focusTargetIdx != -1) {
      _focusedSegmentIndex = focusTargetIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (focusTargetIdx < _segments.length && _segments[focusTargetIdx] is _TextSegment) {
          (_segments[focusTargetIdx] as _TextSegment).focusNode.requestFocus();
        }
        _saveHistoryState();
      });
    } else {
      _saveHistoryState();
    }

    _triggerAutoSave();
  }

  void _mergeSegmentWithPrevious(int index) {
    if (index <= 0 || index >= _segments.length) return;
    final current = _segments[index] as _TextSegment;
    final prev = _segments[index - 1];

    if (prev is _TextSegment) {
      final prevText = prev.controller.text;
      final mergedText = prevText.endsWith('\n') ? '$prevText${current.controller.text}' : '$prevText\n${current.controller.text}';
      
      _historyTimer?.cancel();
      _saveHistoryState();

      current.dispose();
      prev.dispose();

      final merged = _TextSegment(context: context, text: mergedText);
      merged.listenersAttached = false;

      setState(() {
        _segments.replaceRange(index - 1, index + 1, [merged]);
        _focusedSegmentIndex = index - 1;
      });

      _attachListeners();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        merged.focusNode.requestFocus();
        merged.controller.selection = TextSelection.collapsed(offset: prevText.length);
        _saveHistoryState();
        _triggerAutoSave();
      });
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
      } else if (seg is _LinkSegment) {
        if (seg.title != null && seg.title!.isNotEmpty) {
          buf.write('[${seg.title}](${seg.url})\n');
        } else {
          buf.write('${seg.url}\n');
        }
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
    _historyTimer?.cancel();
    _titleController.dispose();
    _scrollController.dispose();
    for (final seg in _segments) {
      if (seg is _TextSegment) seg.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // History Undo/Redo logic
  // ---------------------------------------------------------------------------
  _EditorHistoryState _captureHistoryState() {
    final states = _segments.map((seg) {
      if (seg is _TextSegment) {
        return _TextSegmentState(seg.controller.text);
      } else if (seg is _ImageSegment) {
        return _ImageSegmentState(seg.path);
      } else if (seg is _LinkSegment) {
        return _LinkSegmentState(seg.url, seg.title);
      } else {
        throw Exception('Unknown segment type');
      }
    }).toList();

    TextSelection? selection;
    if (_focusedSegmentIndex >= 0 && _focusedSegmentIndex < _segments.length) {
      final focusedSeg = _segments[_focusedSegmentIndex];
      if (focusedSeg is _TextSegment) {
        selection = focusedSeg.controller.selection;
      }
    }

    return _EditorHistoryState(
      segments: states,
      focusedSegmentIndex: _focusedSegmentIndex,
      selection: selection,
    );
  }

  void _restoreHistoryState(_EditorHistoryState state) {
    // 1. Dispose existing segments
    for (final seg in _segments) {
      if (seg is _TextSegment) {
        seg.dispose();
      }
    }
    _segments.clear();

    // 2. Re-create segments
    for (final segState in state.segments) {
      if (segState is _TextSegmentState) {
        final seg = _TextSegment(context: context, text: segState.text);
        _segments.add(seg);
      } else if (segState is _ImageSegmentState) {
        _segments.add(_ImageSegment(segState.path));
      } else if (segState is _LinkSegmentState) {
        _segments.add(_LinkSegment(url: segState.url, title: segState.title));
      }
    }

    // Ensure at least one text segment
    if (_segments.isEmpty) _addTextSegment('');
    // Ensure last segment is always a text segment for typing
    if (_segments.last is _ImageSegment || _segments.last is _LinkSegment) _addTextSegment('');

    // 3. Attach listeners
    _attachListeners();

    // 4. Restore focus and selection
    _focusedSegmentIndex = state.focusedSegmentIndex;
    if (_focusedSegmentIndex >= _segments.length) {
      _focusedSegmentIndex = _segments.length - 1;
    }

    final focusedSeg = _segments[_focusedSegmentIndex];
    if (focusedSeg is _TextSegment) {
      focusedSeg.focusNode.requestFocus();
      if (state.selection != null) {
        focusedSeg.controller.selection = state.selection!;
      }
    }
  }

  bool _areStatesEqual(_EditorHistoryState a, _EditorHistoryState b) {
    if (a.segments.length != b.segments.length) return false;
    for (int i = 0; i < a.segments.length; i++) {
      final sa = a.segments[i];
      final sb = b.segments[i];
      if (sa is _TextSegmentState && sb is _TextSegmentState) {
        if (sa.text != sb.text) return false;
      } else if (sa is _ImageSegmentState && sb is _ImageSegmentState) {
        if (sa.path != sb.path) return false;
      } else if (sa is _LinkSegmentState && sb is _LinkSegmentState) {
        if (sa.url != sb.url || sa.title != sb.title) return false;
      } else {
        return false;
      }
    }
    return true;
  }

  void _saveHistoryState() {
    if (_isHistoryAction) return;

    final newState = _captureHistoryState();

    // Check if the content is actually different from the last history item to avoid duplicates
    if (_undoList.isNotEmpty) {
      final lastState = _undoList.last;
      if (_areStatesEqual(lastState, newState)) {
        return;
      }
    }

    if (_undoList.length >= 50) {
      _undoList.removeAt(0);
    }
    _undoList.add(newState);
    _redoList.clear();

    if (mounted) setState(() {});
  }

  void _onTextSegmentChanged(_TextSegment seg) {
    if (_isHistoryAction) return;

    final text = seg.controller.text;

    // If the text ends with space or newline, save immediately to make a clean boundary
    if (text.endsWith(' ') || text.endsWith('\n')) {
      _historyTimer?.cancel();
      _saveHistoryState();
    } else {
      // Debounce saving the typing state
      _historyTimer?.cancel();
      _historyTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) {
          _saveHistoryState();
        }
      });
    }
  }

  void _undo() {
    _historyTimer?.cancel();
    _saveHistoryState();

    if (_undoList.length < 2) return;
    _isHistoryAction = true;

    // Pop current state and push to redo
    final currentState = _undoList.removeLast();
    _redoList.add(currentState);

    // Load previous state
    final prevState = _undoList.last;
    _restoreHistoryState(prevState);

    _isHistoryAction = false;
    if (mounted) setState(() {});
  }

  void _redo() {
    _historyTimer?.cancel();
    if (_redoList.isEmpty) return;
    _isHistoryAction = true;

    final nextState = _redoList.removeLast();
    _undoList.add(nextState);

    _restoreHistoryState(nextState);

    _isHistoryAction = false;
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Image insertion
  // ---------------------------------------------------------------------------
  Future<void> _pickImage(ImageSource source) async {
    final XFile? image;
    if (source == ImageSource.camera) {
      image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 80,
      );
    } else {
      image = await GalleryHelper.pickSingleImage(context);
    }
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

    _historyTimer?.cancel();
    _saveHistoryState();

    final seg = _segments[targetIndex] as _TextSegment;
    final cursor = seg.controller.selection.baseOffset;
    final text = seg.controller.text;
    final splitAt = cursor >= 0 ? cursor : text.length;

    final textBefore = text.substring(0, splitAt);
    final textAfter = text.substring(splitAt);

    final before = _TextSegment(context: context, text: textBefore);
    final imgSeg = _ImageSegment(path);
    final after = _TextSegment(context: context, text: textAfter);

    seg.dispose();
    final afterIdx = targetIndex + 2;

    setState(() {
      _segments.replaceRange(targetIndex, targetIndex + 1, [before, imgSeg, after]);
      _focusedSegmentIndex = afterIdx;
    });

    _attachListeners();

    // Focus the text field after the image
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (afterIdx < _segments.length && _segments[afterIdx] is _TextSegment) {
        (_segments[afterIdx] as _TextSegment).focusNode.requestFocus();
      }
      _saveHistoryState();
      _triggerAutoSave();
    });
  }

  void _removeImage(int segmentIndex) {
    if (_segments[segmentIndex] is! _ImageSegment) return;
    final img = _segments[segmentIndex] as _ImageSegment;

    _historyTimer?.cancel();
    _saveHistoryState();

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

      final merged = _TextSegment(context: context, text: mergedText);

      final start = (prevIdx >= 0 && _segments[prevIdx] is _TextSegment) ? prevIdx : segmentIndex;
      final end = (nextIdx < _segments.length && _segments[nextIdx] is _TextSegment) ? nextIdx : segmentIndex;
      _segments.replaceRange(start, end + 1, [merged]);
      _attachListeners();
    });
    _saveHistoryState();
    _triggerAutoSave();
  }

  void _showInsertLinkDialog() {
    final urlController = TextEditingController();
    final titleController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('插入链接', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '链接地址 (URL)',
                  hintText: 'https://example.com',
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: '链接标题 (可选)',
                  hintText: '输入显示标题',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final url = urlController.text.trim();
                if (url.isNotEmpty) {
                  // Ensure URL has protocol
                  String formattedUrl = url;
                  if (!url.startsWith('http://') && !url.startsWith('https://')) {
                    formattedUrl = 'https://$url';
                  }
                  final title = titleController.text.trim();
                  _insertLinkAtFocusedSegment(formattedUrl, title: title.isEmpty ? null : title);
                }
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showEditLinkDialog(int index) {
    if (index < 0 || index >= _segments.length) return;
    final seg = _segments[index];
    if (seg is! _LinkSegment) return;

    final urlController = TextEditingController(text: seg.url);
    final titleController = TextEditingController(text: seg.title ?? '');
    
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('编辑链接', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '链接地址 (URL)',
                  hintText: 'https://example.com',
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: '链接标题 (可选)',
                  hintText: '输入显示标题',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final url = urlController.text.trim();
                if (url.isNotEmpty) {
                  // Ensure URL has protocol
                  String formattedUrl = url;
                  if (!url.startsWith('http://') && !url.startsWith('https://')) {
                    formattedUrl = 'https://$url';
                  }
                  final title = titleController.text.trim();
                  
                  _historyTimer?.cancel();
                  _saveHistoryState();

                  setState(() {
                    _segments[index] = _LinkSegment(
                      url: formattedUrl,
                      title: title.isEmpty ? null : title,
                    );
                    if (formattedUrl != seg.url) {
                      _dismissedUrls.remove(formattedUrl);
                    }
                  });
                  
                  if (formattedUrl != seg.url) {
                    _fetchMetadataForUrl(formattedUrl);
                  }
                  _saveHistoryState();
                }
                Navigator.pop(context);
                _triggerAutoSave();
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  void _insertLinkAtFocusedSegment(String url, {String? title}) {
    int targetIndex = -1;
    for (int i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      if (s is _TextSegment && s.focusNode.hasFocus) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) targetIndex = _focusedSegmentIndex;
    if (targetIndex < 0 || targetIndex >= _segments.length || _segments[targetIndex] is! _TextSegment) {
      for (int i = _segments.length - 1; i >= 0; i--) {
        if (_segments[i] is _TextSegment) { targetIndex = i; break; }
      }
    }
    if (targetIndex < 0) return;

    _historyTimer?.cancel();
    _saveHistoryState();

    final seg = _segments[targetIndex] as _TextSegment;
    final cursor = seg.controller.selection.baseOffset;
    final text = seg.controller.text;
    final splitAt = cursor >= 0 ? cursor : text.length;

    final textBefore = text.substring(0, splitAt);
    final textAfter = text.substring(splitAt);

    final before = _TextSegment(context: context, text: textBefore);
    final linkSeg = _LinkSegment(url: url, title: title);
    final after = _TextSegment(context: context, text: textAfter);

    seg.dispose();
    final afterIdx = targetIndex + 2;

    _fetchMetadataForUrl(url);

    setState(() {
      _segments.replaceRange(targetIndex, targetIndex + 1, [before, linkSeg, after]);
      _focusedSegmentIndex = afterIdx;
    });

    _attachListeners();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (afterIdx < _segments.length && _segments[afterIdx] is _TextSegment) {
        (_segments[afterIdx] as _TextSegment).focusNode.requestFocus();
      }
      _saveHistoryState();
      _triggerAutoSave();
    });
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
    Toast.success(context, '已复制', duration: const Duration(seconds: 1));
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
    _historyTimer?.cancel();
    _saveHistoryState();

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
    _isHistoryAction = true;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: sel.baseOffset + (newLine.length - lineText.length)),
    );
    _isHistoryAction = false;
    _saveHistoryState();
    _triggerAutoSave();
  }

  void _insertBlock(String markup) {
    _historyTimer?.cancel();
    _saveHistoryState();

    final seg = _focusedTextSeg;
    if (seg == null) return;
    final ctrl = seg.controller;
    final text = ctrl.text;
    final idx = ctrl.selection.baseOffset >= 0 ? ctrl.selection.baseOffset : text.length;
    final prefix = (idx == 0 || text[idx - 1] == '\n') ? '' : '\n';
    final suffix = (idx == text.length || text[idx] == '\n') ? '' : '\n';
    final insert = '$prefix$markup$suffix';
    final newText = text.replaceRange(idx, idx, insert);
    _isHistoryAction = true;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: idx + insert.length),
    );
    _isHistoryAction = false;
    _saveHistoryState();
    _triggerAutoSave();
  }

  void _toggleInlineStyle(String marker) {
    _historyTimer?.cancel();
    _saveHistoryState();

    final seg = _focusedTextSeg;
    if (seg == null) return;
    final ctrl = seg.controller;
    final text = ctrl.text;
    final sel = ctrl.selection;
    if (sel.baseOffset < 0) return;

    if (sel.start == sel.end) {
      final newText = text.replaceRange(sel.start, sel.end, '$marker$marker');
      _isHistoryAction = true;
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + marker.length),
      );
      _isHistoryAction = false;
      _saveHistoryState();
      _triggerAutoSave();
      return;
    }

    final selected = text.substring(sel.start, sel.end);
    final newSelected = (selected.startsWith(marker) && selected.endsWith(marker))
        ? selected.substring(marker.length, selected.length - marker.length)
        : '$marker$selected$marker';
    final newText = text.replaceRange(sel.start, sel.end, newSelected);
    _isHistoryAction = true;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: sel.start, extentOffset: sel.start + newSelected.length),
    );
    _isHistoryAction = false;
    _saveHistoryState();
    _triggerAutoSave();
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
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_segments.isNotEmpty) {
                    for (int i = _segments.length - 1; i >= 0; i--) {
                      final seg = _segments[i];
                      if (seg is _TextSegment) {
                        seg.focusNode.requestFocus();
                        final text = seg.controller.text;
                        if (text.isNotEmpty && !text.endsWith('\n')) {
                          seg.controller.value = TextEditingValue(
                            text: '$text\n',
                            selection: TextSelection.collapsed(offset: text.length + 1),
                          );
                        } else {
                          seg.controller.selection = TextSelection.collapsed(offset: text.length);
                        }
                        break;
                      }
                    }
                  }
                },
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildSegmentWidgets(theme),
                  ),
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
      } else if (seg is _LinkSegment) {
        widgets.add(_buildLinkSegment(seg, i, theme));
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

  Widget _buildLinkSegment(_LinkSegment seg, int index, ThemeData theme) {
    final url = seg.url;

    // Trigger metadata fetch if needed
    if (!_fetchedMetadata.containsKey(url) && !_loadingUrls.contains(url) && !_dismissedUrls.contains(url)) {
      _fetchMetadataForUrl(url);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: Text(
              seg.title ?? url,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                height: 1.6,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (_fetchedMetadata.containsKey(url)) ...[
            _buildLinkPreviewCard(_fetchedMetadata[url]!, context, () => _showEditLinkDialog(index), () => _removeLinkSegment(index)),
          ] else if (_loadingUrls.contains(url)) ...[
            _buildLinkPreviewPlaceholder(url, theme, () => _removeLinkSegment(index)),
          ] else ...[
            _buildDefaultLinkPreviewCard(url, () => _showEditLinkDialog(index), () => _removeLinkSegment(index)),
          ],
        ],
      ),
    );
  }

  Widget _buildDefaultLinkPreviewCard(String url, VoidCallback onEdit, VoidCallback onDelete) {
    final theme = Theme.of(context);
    final domain = Uri.tryParse(url)?.host ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: InkWell(
                onTap: () {
                  final uri = Uri.tryParse(url);
                  if (uri != null) {
                    launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.link, color: theme.colorScheme.primary, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          if (domain.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              domain,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.edit, size: 16),
              onPressed: onEdit,
              tooltip: '编辑链接',
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: onDelete,
              tooltip: '删除链接',
            ),
          ],
        ),
      ),
    );
  }

  void _removeLinkSegment(int index) {
    if (index < 0 || index >= _segments.length || _segments[index] is! _LinkSegment) return;
    
    _historyTimer?.cancel();
    _saveHistoryState();

    setState(() {
      final prevIdx = index - 1;
      final nextIdx = index + 1;
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

      final merged = _TextSegment(context: context, text: mergedText);

      final start = (prevIdx >= 0 && _segments[prevIdx] is _TextSegment) ? prevIdx : index;
      final end = (nextIdx < _segments.length && _segments[nextIdx] is _TextSegment) ? nextIdx : index;
      _segments.replaceRange(start, end + 1, [merged]);
      _attachListeners();
    });
    _saveHistoryState();
    _triggerAutoSave();
  }



  Future<void> _fetchMetadataForUrl(String url) async {
    if (_loadingUrls.contains(url)) return;
    _loadingUrls.add(url);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
    
    final metadata = await LinkPreviewHelper.getMetadata(url);
    _loadingUrls.remove(url);
    if (metadata != null) {
      _fetchedMetadata[url] = metadata;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Widget _buildLinkPreviewPlaceholder(String url, ThemeData theme, VoidCallback onDelete) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '正在获取链接预览: $url',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: onDelete,
            tooltip: '删除链接',
          ),
        ],
      ),
    );
  }

  Widget _buildLinkPreviewCard(LinkMetadata meta, BuildContext context, VoidCallback onEdit, VoidCallback onDismiss) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: InkWell(
                onTap: () {
                  final uri = Uri.tryParse(meta.url);
                  if (uri != null) {
                    launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    if (meta.imageUrl != null && meta.imageUrl!.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 50,
                          height: 50,
                          child: Image.network(
                            meta.imageUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: theme.colorScheme.secondaryContainer,
                                child: Icon(Icons.link, color: theme.colorScheme.primary, size: 24),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ] else ...[
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.link, color: theme.colorScheme.primary, size: 24),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            meta.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            meta.domain,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.edit, size: 16),
              onPressed: onEdit,
              tooltip: '编辑链接',
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: onDismiss,
              tooltip: '删除链接',
            ),
          ],
        ),
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
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
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
              _ToolbarButton(icon: Icons.link, onPressed: _showInsertLinkDialog),
              _ToolbarButton(icon: Icons.format_quote, onPressed: () => _toggleBlockPrefix('> ')),
              _ToolbarButton(icon: Icons.image_outlined, onPressed: () => _pickImage(ImageSource.gallery)),
              _ToolbarButton(icon: Icons.camera_alt_outlined, onPressed: () => _pickImage(ImageSource.camera)),
              _ToolbarButton(icon: Icons.format_list_bulleted, onPressed: () => _toggleBlockPrefix('- ')),
              _ToolbarButton(icon: Icons.format_list_numbered, onPressed: () => _toggleBlockPrefix('1. ')),
              _ToolbarButton(icon: Icons.strikethrough_s, onPressed: () => _toggleInlineStyle('~~')),
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
                icon: Icons.undo,
                onPressed: _undoList.length >= 2 ? _undo : null,
              ),
              _ToolbarButton(
                icon: Icons.redo,
                onPressed: _redoList.isNotEmpty ? _redo : null,
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
  final VoidCallback? onPressed;

  const _ToolbarButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = onPressed != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        icon: Icon(icon),
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        style: IconButton.styleFrom(
          foregroundColor: isEnabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown rendering controller
// ---------------------------------------------------------------------------
class MarkdownTextEditingController extends TextEditingController {
  final BuildContext context;
  FocusNode? focusNode;

  MarkdownTextEditingController({required this.context, this.focusNode, super.text});

  void refresh() {
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final selection = this.selection;
    final cursorOffset = (focusNode == null || focusNode!.hasFocus) ? selection.baseOffset : -1;
    final activeLineIndex = _getActiveLineIndex(text, cursorOffset);

    final lines = text.split('\n');
    final List<TextSpan> children = [];
    final baseStyle = style ?? const TextStyle();

    // Pre-calculate code block lines
    final inCodeBlock = List<bool>.filled(lines.length, false);
    final isCodeBlockDelimiter = List<bool>.filled(lines.length, false);
    bool currentlyInCodeBlock = false;
    for (int i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.startsWith('```')) {
        currentlyInCodeBlock = !currentlyInCodeBlock;
        isCodeBlockDelimiter[i] = true;
      } else {
        inCodeBlock[i] = currentlyInCodeBlock;
      }
    }

    for (int i = 0; i < lines.length; i++) {
      final lineText = lines[i];
      final isActive = (i == activeLineIndex);

      TextSpan lineSpan;
      if (isCodeBlockDelimiter[i]) {
        lineSpan = _styleCodeBlockDelimiter(lineText, isActive, context, baseStyle);
      } else if (inCodeBlock[i]) {
        lineSpan = _styleCodeBlockLine(lineText, isActive, context, baseStyle);
      } else {
        lineSpan = _styleLine(lineText, isActive, context, baseStyle);
      }
      children.add(lineSpan);

      if (i < lines.length - 1) {
        children.add(const TextSpan(text: '\n'));
      }
    }

    return TextSpan(style: baseStyle, children: children);
  }

  TextSpan _styleCodeBlockDelimiter(String lineText, bool isActive, BuildContext context, TextStyle baseStyle) {
    final theme = Theme.of(context);
    if (isActive) {
      return TextSpan(
        text: lineText,
        style: baseStyle.copyWith(
          fontFamily: 'monospace',
          fontSize: 14,
          color: theme.colorScheme.primary.withValues(alpha: 0.7),
          fontWeight: FontWeight.bold,
        ),
      );
    } else {
      return TextSpan(
        text: lineText,
        style: baseStyle.copyWith(
          fontFamily: 'monospace',
          fontSize: 12,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
      );
    }
  }

  TextSpan _styleCodeBlockLine(String lineText, bool isActive, BuildContext context, TextStyle baseStyle) {
    final theme = Theme.of(context);
    final style = baseStyle.copyWith(
      fontFamily: 'monospace',
      fontSize: 14,
      color: theme.colorScheme.onSurfaceVariant,
      backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
    );
    return TextSpan(text: lineText, style: style);
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
          TextSpan(
              text: '# ',
              style: baseStyle.copyWith(
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
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
          TextSpan(
              text: '## ',
              style: baseStyle.copyWith(
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
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
          TextSpan(
              text: '### ',
              style: baseStyle.copyWith(
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
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
          TextSpan(
              text: '> ',
              style: baseStyle.copyWith(
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  fontWeight: FontWeight.bold)),
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
          TextSpan(
              text: symbol,
              style: baseStyle.copyWith(
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  fontWeight: FontWeight.bold)),
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

    final StringBuffer textBuffer = StringBuffer();

    void flushBuffer() {
      if (textBuffer.isNotEmpty) {
        spans.add(TextSpan(text: textBuffer.toString(), style: baseStyle));
        textBuffer.clear();
      }
    }

    final mdLinkReg = RegExp(r'^\[([^\]]+)\]\((https?:\/\/[^\)]+)\)');
    final urlReg = RegExp(r'^https?:\/\/[^\s\(\)\[\]\{\}<>"\u4e00-\u9fa5]+');

    while (index < text.length) {
      final remaining = text.substring(index);

      // Markdown link `[text](url)`
      if (text.startsWith('[', index)) {
        final match = mdLinkReg.firstMatch(remaining);
        if (match != null && match.start == 0) {
          flushBuffer();
          final linkText = match.group(1)!;
          final linkUrl = match.group(2)!;
          
          spans.add(TextSpan(text: '[', style: symbolStyle));
          spans.add(TextSpan(
            text: linkText,
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ));
          spans.add(TextSpan(text: ']', style: symbolStyle));
          spans.add(TextSpan(text: '(', style: symbolStyle));
          spans.add(TextSpan(
            text: linkUrl,
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary.withValues(alpha: 0.7),
              fontFamily: 'monospace',
              fontSize: 13,
              decoration: TextDecoration.underline,
            ),
          ));
          spans.add(TextSpan(text: ')', style: symbolStyle));
          
          index += match.end;
          continue;
        }
      }

      // Plain URL
      if (text.startsWith('http://', index) || text.startsWith('https://', index)) {
        final match = urlReg.firstMatch(remaining);
        if (match != null && match.start == 0) {
          flushBuffer();
          String url = match.group(0)!;
          final trailingPunct = RegExp(r'[\.\,\?\!\:\;]+$');
          final punctMatch = trailingPunct.firstMatch(url);
          String punct = '';
          if (punctMatch != null) {
            punct = punctMatch.group(0)!;
            url = url.substring(0, url.length - punct.length);
          }

          spans.add(TextSpan(
            text: url,
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ));
          if (punct.isNotEmpty) {
            spans.add(TextSpan(text: punct, style: baseStyle));
          }
          index += match.group(0)!.length;
          continue;
        }
      }

      // Bold `**`
      if (text.startsWith('**', index)) {
        final end = text.indexOf('**', index + 2);
        if (end != -1) {
          flushBuffer();
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
          flushBuffer();
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
          flushBuffer();
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
          flushBuffer();
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
      textBuffer.write(text[index]);
      index++;
    }

    flushBuffer();
    return TextSpan(children: spans);
  }

  TextSpan _parsePreviewLine(String lineText, TextStyle baseStyle, ThemeData theme) {
    final trimmed = lineText.trim();

    // 1. Image Block - Render as a beautiful, clean monospace text link inside the editor to prevent floating layout
    // bugs
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
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
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
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
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
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
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

    final StringBuffer textBuffer = StringBuffer();

    void flushBuffer() {
      if (textBuffer.isNotEmpty) {
        spans.add(TextSpan(text: textBuffer.toString(), style: baseStyle));
        textBuffer.clear();
      }
    }

    final mdLinkReg = RegExp(r'^\[([^\]]+)\]\((https?:\/\/[^\)]+)\)');
    final urlReg = RegExp(r'^https?:\/\/[^\s\(\)\[\]\{\}<>"\u4e00-\u9fa5]+');

    while (index < text.length) {
      final remaining = text.substring(index);

      // Markdown link `[text](url)`
      if (text.startsWith('[', index)) {
        final match = mdLinkReg.firstMatch(remaining);
        if (match != null && match.start == 0) {
          flushBuffer();
          final linkText = match.group(1)!;
          final linkUrl = match.group(2)!;
          
          spans.add(TextSpan(
            text: '[',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          spans.add(TextSpan(
            text: linkText,
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ));
          spans.add(TextSpan(
            text: ']',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          spans.add(TextSpan(
            text: '(',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          spans.add(TextSpan(
            text: linkUrl,
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          spans.add(TextSpan(
            text: ')',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          
          index += match.end;
          continue;
        }
      }

      // Plain URL
      if (text.startsWith('http://', index) || text.startsWith('https://', index)) {
        final match = urlReg.firstMatch(remaining);
        if (match != null && match.start == 0) {
          flushBuffer();
          String url = match.group(0)!;
          final trailingPunct = RegExp(r'[\.\,\?\!\:\;]+$');
          final punctMatch = trailingPunct.firstMatch(url);
          String punct = '';
          if (punctMatch != null) {
            punct = punctMatch.group(0)!;
            url = url.substring(0, url.length - punct.length);
          }

          spans.add(TextSpan(
            text: url,
            style: baseStyle.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ));
          if (punct.isNotEmpty) {
            spans.add(TextSpan(text: punct, style: baseStyle));
          }
          index += match.group(0)!.length;
          continue;
        }
      }

      // Bold `**`
      if (text.startsWith('**', index)) {
        final end = text.indexOf('**', index + 2);
        if (end != -1) {
          flushBuffer();
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
          flushBuffer();
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
          flushBuffer();
          spans.add(TextSpan(
            text: '`',
            style: baseStyle.copyWith(fontSize: 0, color: Colors.transparent),
          ));
          final innerText = text.substring(index + 1, end);
          spans.add(TextSpan(
            text: innerText,
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
          flushBuffer();
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
      textBuffer.write(text[index]);
      index++;
    }

    flushBuffer();
    return TextSpan(children: spans);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qnote_flutter/config/defaults.dart' show defaultSystemPrompts;
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/utils/delta_markdown.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/core/utils/note_file_type.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/widgets/notes/html_preview/html_preview_view.dart';
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
  /// 等宽源码模式：不解析 Markdown 行内语法（html/svg/json/code 笔记使用）
  final bool plainCode;
  _TextSegment({
    required BuildContext context,
    String text = '',
    this.plainCode = false,
  })  : focusNode = FocusNode(),
        controller = MarkdownTextEditingController(
          context: context,
          text: text,
          plainCode: plainCode,
        ) {
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
  // 记录历史快照时刻的文件级状态，用于 undo/redo 时回滚图片删除副作用
  final List<String> removedPaths;
  final List<String> newlyUploadedPaths;

  _EditorHistoryState({
    required this.segments,
    required this.focusedSegmentIndex,
    this.selection,
    required this.removedPaths,
    required this.newlyUploadedPaths,
  });
}


// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------
/// 解码笔记内容：兼容旧 Quill delta JSON，统一转为 Markdown 纯文本
/// （编辑器与笔记列表的「给小Q」整篇引用共用）
String decodeNoteContent(String content) {
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

  // 渲染预览模式：HTML/SVG 笔记默认开启，AppBar 可切换回源码编辑
  bool _previewMode = false;

  /// 按标题后缀实时识别的文件类型（标题改名时跟随变化）
  NoteFileType get _fileType =>
      NoteFileTypeHelper.fromTitle(_titleController.text);

  /// 是否按源码类内容处理：等宽字体、不做 Markdown 行内渲染与 URL 自动拆分
  bool get _isCodeLikeFile => NoteFileTypeHelper.isCodeLike(_fileType);

  /// 当前是否处于渲染预览状态（仅 html/svg 生效，json/code 始终为源码模式）
  bool get _isPreviewActive => _previewMode && !_isCodeLikeFile;

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

  bool _isToolbarExpanded = false;

  // 笔记图片长按 AI 提取：正在提取的图片段索引，null 表示未在提取
  int? _extractingImageIndex;
  // 笔记图片长按 AI 提取：用于取消进行中的请求
  CancelToken? _extractCancelToken;
  // 长按图片弹出的操作菜单 Overlay
  OverlayEntry? _imageActionMenuOverlay;

  // 全局悬浮小Q联动：页面上下文注册与任务期间自动保存抑制
  late final QPageContext _qContext;
  ProviderContainer? _qContainer;
  bool _qSuppressAutoSave = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;

    final rawContent = _initContentString();
    _lastSavedContent = rawContent;
    _parseContentIntoSegments(rawContent);

    // HTML/SVG 笔记默认进入渲染预览模式，源码可通过 AppBar 一键切换
    final initialType = NoteFileTypeHelper.fromTitle(widget.note.title);
    _previewMode =
        initialType == NoteFileType.html || initialType == NoteFileType.svg;

    _titleController.addListener(_triggerAutoSave);

    // Seed initial history state
    _undoList.add(_captureHistoryState());

    // 注册悬浮小Q页面上下文与编辑器联动钩子：任务开始暂停自动保存，
    // 任务结束后若用户未手动编辑则从仓库重读，避免编辑器旧内容覆盖小Q的修改
    _qContext = QPageContext(
      type: QContextType.noteDetail,
      targetId: widget.note.id,
      targetTitle: widget.note.title,
      signature: 'note:${widget.note.id}',
      displayLabel: '笔记《${widget.note.title}》',
    );
    ref.read(floatingQProvider.notifier).pushOverlayContext(_qContext);
    QTargetBridge.instance.register(
      _qContext.signature,
      QTargetHooks(
        fingerprint: () =>
            '${_titleController.text}\u0000${_serializeToMarkdown()}',
        reload: _reloadFromRepository,
        onTaskStart: () => _qSuppressAutoSave = true,
        onTaskEnd: () => _qSuppressAutoSave = false,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // dispose 中 ref 不可靠，提前捕获容器供注销悬浮小Q上下文使用
    _qContainer ??= ProviderScope.containerOf(context, listen: false);
  }

  String _initContentString() => decodeNoteContent(widget.note.content);

  /// Parse a markdown string into alternating text/image segments.
  void _parseContentIntoSegments(String content) {
    _segments.clear();
    // 代码类内容（html/svg/json/code）整体作为单个等宽文本段：
    // 不解析图片/链接语法，避免 HTML 标签、URL 被误拆成链接卡片
    if (_isCodeLikeFile) {
      _segments.add(_TextSegment(context: context, text: content, plainCode: true));
      _attachListeners();
      return;
    }
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
    final seg = _TextSegment(context: context, text: text, plainCode: _isCodeLikeFile);
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
    // 源码类内容中的 URL 是网页源码的一部分，禁止自动拆分为链接卡片
    if (_isCodeLikeFile) return;
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

      final merged = _TextSegment(
        context: context,
        text: mergedText,
        plainCode: _isCodeLikeFile,
      );
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
    // 悬浮小Q任务进行中或程序化刷新时暂停自动保存，避免编辑器旧内容覆盖小Q的工作区修改
    if (_qSuppressAutoSave) return;
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

  /// 悬浮小Q任务结束后从仓库重读最新内容刷新编辑器
  /// （桥接仅在用户任务期间未手动编辑时调用，用户编辑过的版本不会被覆盖）
  Future<void> _reloadFromRepository() async {
    if (!mounted) return;
    final fresh = await NoteRepository().getById(widget.note.id);
    if (!mounted) return;
    if (fresh == null) {
      Toast.info(context, '这篇笔记已被小Q删除');
      return;
    }
    // 抑制监听器：程序化刷新不触发自动保存
    _qSuppressAutoSave = true;
    _titleController.text = fresh.title;
    _lastSavedTitle = fresh.title.isEmpty ? '无标题' : fresh.title;

    final rawContent = decodeNoteContent(fresh.content);
    for (final seg in _segments) {
      if (seg is _TextSegment) seg.dispose();
    }
    _segments.clear();
    _parseContentIntoSegments(rawContent);
    _focusedSegmentIndex = 0;
    _lastSavedContent = _serializeToMarkdown();
    // 重建撤销历史基线，避免撤销栈跨越小Q修改点产生错乱
    _undoList.clear();
    _redoList.clear();
    _undoList.add(_captureHistoryState());
    _qSuppressAutoSave = false;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // 注销悬浮小Q上下文与编辑器联动钩子
    QTargetBridge.instance.unregister(_qContext.signature);
    _qContainer
        ?.read(floatingQProvider.notifier)
        .popOverlayContext(_qContext);
    _hideHeadingMenu();
    _hideImageActionMenu();
    _autoSaveTimer?.cancel();
    _historyTimer?.cancel();
    _extractCancelToken?.cancel('editor disposed');
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
      // 捕获文件级状态的副本，防止后续 mutate 影响历史快照
      removedPaths: List<String>.from(_removedPaths),
      newlyUploadedPaths: List<String>.from(_newlyUploadedPaths),
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
        final seg = _TextSegment(
          context: context,
          text: segState.text,
          plainCode: _isCodeLikeFile,
        );
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

    // 5. 恢复文件级状态（覆盖式），保证 undo/redo 时图片删除副作用同步回滚
    _removedPaths
      ..clear()
      ..addAll(state.removedPaths);
    _newlyUploadedPaths
      ..clear()
      ..addAll(state.newlyUploadedPaths);
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
    // 文件级状态不同也视为不同状态，避免 undo/redo 中途的删除副作用被误判为重复
    if (!_stringListEquals(a.removedPaths, b.removedPaths)) return false;
    if (!_stringListEquals(a.newlyUploadedPaths, b.newlyUploadedPaths)) return false;
    return true;
  }

  /// 简单的 `List<String>` 相等比较，避免引入新依赖
  bool _stringListEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
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
    }
    // 统一延迟删除：不再立即物理删文件，由 _handleBack 退出时按 _removedPaths 处理
    // 这样 undo/redo 可通过历史栈快照正确回滚文件级状态
    _removedPaths.add(img.path);

    setState(() {
      // 检查图片下方的文本段是否为 AI 提取的引用块（以 > 图： 开头），如果是则一并删除
      final nextIdx = segmentIndex + 1;
      final hasNextExtract = nextIdx < _segments.length &&
          _segments[nextIdx] is _TextSegment &&
          (_segments[nextIdx] as _TextSegment).controller.text.startsWith('> 图：');

      // Merge adjacent text segments around the removed image (and its extracted text)
      final prevIdx = segmentIndex - 1;
      String mergedText = '';

      if (prevIdx >= 0 && _segments[prevIdx] is _TextSegment) {
        mergedText += (_segments[prevIdx] as _TextSegment).controller.text.trimRight();
        (_segments[prevIdx] as _TextSegment).dispose();
      }

      // 如果有 AI 提取的引用块，仅删除该图片提取的内容，保留同段落内下方的其他内容
      String remainingExtractText = '';
      if (hasNextExtract) {
        final text = (_segments[nextIdx] as _TextSegment).controller.text;
        final doubleNewlineIdx = text.indexOf('\n\n');
        if (doubleNewlineIdx != -1) {
          remainingExtractText = text.substring(doubleNewlineIdx + 2).trim();
        } else {
          final newlineIdx = text.indexOf('\n');
          if (newlineIdx != -1) {
            remainingExtractText = text.substring(newlineIdx + 1).trim();
          }
        }
      }

      if (remainingExtractText.isNotEmpty) {
        if (mergedText.isNotEmpty) mergedText += '\n\n';
        mergedText += remainingExtractText;
      }

      // 再下一个文本段（跳过 AI 提取引用块后）
      final afterExtractIdx = hasNextExtract ? nextIdx + 1 : nextIdx;
      if (afterExtractIdx < _segments.length && _segments[afterExtractIdx] is _TextSegment) {
        final afterText = (_segments[afterExtractIdx] as _TextSegment).controller.text.trimLeft();
        if (mergedText.isNotEmpty && afterText.isNotEmpty) {
          mergedText += (mergedText.endsWith('\n') ? '' : '\n') + afterText;
        } else {
          mergedText += afterText;
        }
        (_segments[afterExtractIdx] as _TextSegment).dispose();
      }

      // 如果有 AI 提取引用块，也要 dispose
      if (hasNextExtract) {
        (_segments[nextIdx] as _TextSegment).dispose();
      }

      final merged = _TextSegment(
        context: context,
        text: mergedText,
        plainCode: _isCodeLikeFile,
      );

      final start = (prevIdx >= 0 && _segments[prevIdx] is _TextSegment) ? prevIdx : segmentIndex;
      final end = (afterExtractIdx < _segments.length && _segments[afterExtractIdx] is _TextSegment)
          ? afterExtractIdx
          : (hasNextExtract ? nextIdx : segmentIndex);
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
    final images = _segments
        .whereType<_ImageSegment>()
        .map((seg) => seg.path)
        .toList();
    final initialIndex = images.indexOf(path);
    final fallbackIndex = initialIndex >= 0 ? initialIndex : 0;

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullScreenImageGallery(
        images: images.isNotEmpty ? images : [path],
        initialIndex: fallbackIndex,
      ),
    ));
  }

  void _copyMarkdown() {
    Clipboard.setData(ClipboardData(text: _serializeToMarkdown()));
    Toast.success(context, '已复制', duration: const Duration(seconds: 1));
  }

  /// JSON 笔记一键格式化：美化缩进便于阅读与编辑
  void _formatJson() {
    final seg = _focusedTextSeg;
    if (seg == null || seg.controller.text.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(seg.controller.text);
      const encoder = JsonEncoder.withIndent('  ');
      final pretty = encoder.convert(decoded);
      _historyTimer?.cancel();
      _saveHistoryState();
      seg.controller.value = TextEditingValue(
        text: pretty,
        selection: TextSelection.collapsed(offset: pretty.length),
      );
      Toast.success(context, '已格式化', duration: const Duration(seconds: 1));
    } on FormatException catch (e) {
      Toast.error(context, 'JSON 格式错误：${e.message}');
    } catch (_) {
      Toast.error(context, 'JSON 解析失败');
    }
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
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '无标题',
                filled: false,
              ),
            ),
          actions: [
            // JSON 笔记：一键格式化缩进
            if (_fileType == NoteFileType.json)
              IconButton(
                icon: const Icon(Icons.data_object),
                onPressed: _formatJson,
                tooltip: '格式化 JSON',
              ),
            // HTML/SVG 笔记：渲染预览与源码编辑切换
            if (_fileType == NoteFileType.html || _fileType == NoteFileType.svg)
              IconButton(
                icon: Icon(_isPreviewActive ? Icons.code : Icons.visibility_outlined),
                onPressed: () => setState(() => _previewMode = !_previewMode),
                tooltip: _isPreviewActive ? '查看源码' : '渲染预览',
              ),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: _copyMarkdown,
              tooltip: _isCodeLikeFile ? '复制源码' : '复制 Markdown',
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _isPreviewActive
                  ? _buildPreviewBody(theme)
                  : _buildEditorBody(theme),
            ),
            // 渲染预览模式下隐藏编辑工具栏
            if (!_isPreviewActive) _buildToolbar(theme),
          ],
        ),
      ),
    );
  }

  /// 源码编辑主体（原有分段编辑视图）
  Widget _buildEditorBody(ThemeData theme) {
    return GestureDetector(
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
    );
  }

  /// 渲染预览主体：html 走 WebView/iframe 真实渲染，svg 走矢量渲染
  Widget _buildPreviewBody(ThemeData theme) {
    final source = _serializeToMarkdown();
    if (source.trim().isEmpty) {
      return Center(
        child: Text(
          '暂无内容，点击右上角切换到源码编辑',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_fileType == NoteFileType.svg) {
      return SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SvgPicture.string(
            source,
            fit: BoxFit.contain,
            // 无宽高声明的 SVG 以可用宽度等比展示
            width: double.infinity,
          ),
        ),
      );
    }
    return HtmlPreviewView(htmlContent: source);
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
      // 源码类笔记（html/svg/json/code）使用等宽字体，结构更易读
      style: seg.plainCode
          ? theme.textTheme.bodyMedium?.copyWith(height: 1.6, fontFamily: 'monospace')
          : theme.textTheme.bodyLarge?.copyWith(height: 1.6, letterSpacing: 0.3),
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
      // 保留默认菜单项（剪切/复制/粘贴/全选等），末尾追加「给小Q」：
      // 把选中文本连同位置引用给悬浮小Q（移动端与 Web 均为 Flutter 自绘菜单）
      contextMenuBuilder: (context, editableTextState) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editableTextState.contextMenuAnchors,
          buttonItems: [
            ...editableTextState.contextMenuButtonItems,
            ContextMenuButtonItem(
              label: '给小Q',
              onPressed: () => _sendSelectionToQ(seg),
            ),
          ],
        );
      },
    );
  }

  /// 「给小Q」：把正文选中文本连同近似行号引用给悬浮小Q，
  /// 便于用户让小Q修改这段指定文本或针对它提问
  void _sendSelectionToQ(_TextSegment seg) {
    final sel = seg.controller.selection;
    final text = seg.controller.text;
    if (!sel.isValid || sel.isCollapsed) return;
    final quoted = text.substring(sel.start, sel.end).trim();
    if (quoted.isEmpty) return;

    final line = _estimateSelectionLine(seg, sel.start);
    // 收起键盘与选择菜单，把焦点让给小Q面板输入框（选中文本已在上面捕获）
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(floatingQProvider.notifier).openWithQuote(QTextQuote(
          source: QQuoteSource.note,
          sourceId: widget.note.id,
          sourceTitle:
              _titleController.text.isEmpty ? '无标题' : _titleController.text,
          quotedText: quoted,
          locationDesc: '第 $line 行附近',
        ));
  }

  /// 估算选区起点在整篇序列化 Markdown 中的行号（与 [_serializeToMarkdown]
  /// 的拼接逻辑一致：前序段按序列化输出累计换行，再加段内选区前换行数），
  /// 仅作为给小Q的定位提示，非精确文件行号
  int _estimateSelectionLine(_TextSegment seg, int offsetInSeg) {
    int newlines = 0;
    for (final s in _segments) {
      if (identical(s, seg)) break;
      if (s is _ImageSegment || s is _LinkSegment) {
        // 图片/链接段序列化时固定占一行且以 \n 结尾
        newlines++;
      } else if (s is _TextSegment && s.controller.text.isNotEmpty) {
        // 文本段自身换行数 + 段后分隔符（末段除外，估算多算一次无碍）
        newlines += '\n'.allMatches(s.controller.text).length + 1;
      }
    }
    newlines += '\n'.allMatches(seg.controller.text.substring(0, offsetInSeg)).length;
    return newlines + 1;
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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

      final merged = _TextSegment(
        context: context,
        text: mergedText,
        plainCode: _isCodeLikeFile,
      );

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
    final isExtracting = _extractingImageIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Stack(
        children: [
          Builder(
            builder: (imgContext) => GestureDetector(
              onTap: () => _previewImage(seg.path),
              onLongPress: () => _showImageActionMenu(seg, index, anchorContext: imgContext),
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
          // AI 提取中遮罩
          if (isExtracting)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          '正在提取图片内容...',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按图片时弹出操作菜单（AI 提取 / 预览 / 删除）。
  /// 复用 [_showHeadingMenu] 的 OverlayEntry 模式，避免 GlobalKey 生命周期问题。
  void _showImageActionMenu(_ImageSegment seg, int index, {BuildContext? anchorContext}) {
    if (_extractingImageIndex != null) return; // 提取中不弹菜单
    _hideImageActionMenu();

    final BuildContext ctx = anchorContext ?? context;
    final RenderBox? button = ctx.findRenderObject() as RenderBox?;
    if (button == null) return;
    final RenderBox overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
    final Offset position = button.localToGlobal(Offset.zero, ancestor: overlay);
    final screenSize = MediaQuery.of(ctx).size;

    const menuWidth = 200.0;
    const itemHeight = 48.0;
    const menuHeight = itemHeight * 3 + 16;

    // 智能选择上方/下方弹出
    final showAbove = position.dy + button.size.height + menuHeight > screenSize.height - 16;
    double top;
    if (showAbove) {
      top = position.dy - menuHeight;
      if (top < 16) top = 16;
    } else {
      top = position.dy + button.size.height + 4;
    }
    double left = position.dx;
    if (left + menuWidth > screenSize.width - 16) {
      left = screenSize.width - menuWidth - 16;
    }
    if (left < 16) left = 16;

    _imageActionMenuOverlay = OverlayEntry(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hideImageActionMenu,
              child: const SizedBox.expand(),
            ),
            Positioned(
              left: left,
              top: top,
              child: Material(
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
                color: colorScheme.surface,
                child: Container(
                  width: menuWidth,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildImageMenuItem(
                        icon: Icons.auto_awesome,
                        label: 'AI 提取图片内容',
                        color: colorScheme.primary,
                        onTap: () {
                          _hideImageActionMenu();
                          _extractImageContent(index);
                        },
                      ),
                      _buildImageMenuItem(
                        icon: Icons.visibility_outlined,
                        label: '预览图片',
                        color: colorScheme.onSurface,
                        onTap: () {
                          _hideImageActionMenu();
                          _previewImage(seg.path);
                        },
                      ),
                      _buildImageMenuItem(
                        icon: Icons.delete_outline,
                        label: '删除图片',
                        color: colorScheme.error,
                        onTap: () {
                          _hideImageActionMenu();
                          _removeImage(index);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(ctx).insert(_imageActionMenuOverlay!);
  }

  void _hideImageActionMenu() {
    _imageActionMenuOverlay?.remove();
    _imageActionMenuOverlay = null;
  }

  Widget _buildImageMenuItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 调用 AI 模型提取图片内容，并把结果以引用块形式追加到图片下方。
  Future<void> _extractImageContent(int index) async {
    if (_extractingImageIndex != null) return; // 已有提取在进行
    if (index < 0 || index >= _segments.length || _segments[index] is! _ImageSegment) {
      return;
    }
    final imgSeg = _segments[index] as _ImageSegment;

    // 1. 获取 AI 配置（支持免费模型）
    final AiConfig aiConfig;
    try {
      aiConfig = await AiRoleService.instance.getEffectiveConfigForRole('timelineOptimization');
    } catch (e) {
      if (mounted) Toast.warning(context, 'AI 模型配置失败，请检查设置');
      return;
    }

    // 2. 进入 loading 状态
    _extractCancelToken = CancelToken();
    setState(() => _extractingImageIndex = index);
    if (mounted) Toast.info(context, '正在提取图片内容...');

    try {
      // 3. 图片转 base64
      final imageBase64 = await _imageRepo.getBase64Image(imgSeg.path);
      if (imageBase64.isEmpty) {
        if (mounted) Toast.error(context, '图片文件不存在');
        return;
      }
      final mimeType = ImageRepository.getMimeType(imgSeg.path);

      // 4. 配置 AI 服务并调用
      final aiService = ref.read(aiServiceProvider);
      final roleSettings = await AiRoleService.instance.getSettingsForRole('timelineOptimization');
      aiService.updateConfig(aiConfig, temperature: roleSettings.temperature, maxTokens: roleSettings.maxTokens);
      final systemPrompt = defaultSystemPrompts['note_image_analysis'] ?? '';
      final result = await aiService.chatWithImage(
        imageBase64: imageBase64,
        mimeType: mimeType,
        userText: '提取图片中的相关内容',
        systemPrompt: systemPrompt,
        cancelToken: _extractCancelToken,
      );

      final trimmed = result.trim();
      if (trimmed.isEmpty) {
        if (mounted) Toast.warning(context, '未识别到内容');
        return;
      }

      // 5. 把文本追加到图片下方的文本段
      _appendTextBelowImage(index, trimmed);
      if (mounted) Toast.success(context, '已提取并追加到图片下方');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        if (mounted) Toast.info(context, '已停止提取');
      } else if (e.type == DioExceptionType.connectionError) {
        if (mounted) Toast.error(context, '网络连接失败，请检查网络或API配置');
      } else if (e.response?.statusCode == 401) {
        if (mounted) Toast.error(context, 'API密钥无效，请检查AI配置');
      } else {
        if (mounted) Toast.error(context, '提取失败：${e.message ?? '网络错误'}');
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        '笔记图片内容提取失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      if (mounted) Toast.error(context, '提取失败');
    } finally {
      if (mounted) setState(() => _extractingImageIndex = null);
      _extractCancelToken = null;
    }
  }

  /// 把提取到的文本以 Markdown 引用块形式追加到指定图片段下方。
  ///
  /// 若图片下方已是文本段，则在开头插入（保留原有内容）；否则新建一个文本段。
  /// 引用块格式 `> 图：xxx` 便于分享笔记时被识别为图片描述。
  void _appendTextBelowImage(int imageIndex, String extractedText) {
    _historyTimer?.cancel();
    _saveHistoryState();

    final wrapped = extractedText.trim().isEmpty ? '' : '> 图：${extractedText.trim()}';

    setState(() {
      final nextIdx = imageIndex + 1;
      if (nextIdx < _segments.length && _segments[nextIdx] is _TextSegment) {
        // 已有文本段：合并为新的文本段（避免旧 selection 越界）
        final seg = _segments[nextIdx] as _TextSegment;
        final original = seg.controller.text;
        final combined = original.isEmpty ? wrapped : '$wrapped\n\n$original';
        seg.dispose();
        _segments[nextIdx] = _TextSegment(context: context, text: combined);
        _attachListeners();
      } else {
        // 无文本段：插入新文本段
        if (wrapped.isNotEmpty) {
          final newSeg = _TextSegment(context: context, text: wrapped);
          _segments.insert(nextIdx, newSeg);
          _attachListeners();
        }
      }
    });

    _saveHistoryState();
    _triggerAutoSave();
  }

  OverlayEntry? _headingMenuOverlay;

  void _showHeadingMenu(BuildContext context) {
    if (_headingMenuOverlay != null) return;
    
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final Offset position = button.localToGlobal(Offset.zero, ancestor: overlay);

    _headingMenuOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hideHeadingMenu,
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.transparent,
              ),
            ),
            Positioned(
              left: position.dx - 20,
              bottom: overlay.size.height - position.dy + 10,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPopupMenuItem('H1 一级标题', '# ', context),
                      _buildPopupMenuItem('H2 二级标题', '## ', context),
                      _buildPopupMenuItem('H3 三级标题', '### ', context),
                      _buildPopupMenuItem('H4 四级标题', '#### ', context),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_headingMenuOverlay!);
  }

  void _hideHeadingMenu() {
    _headingMenuOverlay?.remove();
    _headingMenuOverlay = null;
  }

  Widget _buildPopupMenuItem(String text, String prefix, BuildContext context) {
    return InkWell(
      onTap: () {
        _hideHeadingMenu();
        _toggleBlockPrefix(prefix);
      },
      child: Container(
        width: 140,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isToolbarExpanded)
              Container(
                height: 38,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                ),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
                  children: [
                    _ToolbarButton(icon: Icons.strikethrough_s, onPressed: () => _toggleInlineStyle('~~')),
                    _ToolbarButton(icon: Icons.format_list_numbered, onPressed: () => _toggleBlockPrefix('1. ')),
                    _ToolbarButton(icon: Icons.format_quote, onPressed: () => _toggleBlockPrefix('> ')),
                    _ToolbarButton(icon: Icons.link, onPressed: _showInsertLinkDialog),
                    _ToolbarButton(icon: Icons.camera_alt_outlined, onPressed: () => _pickImage(ImageSource.camera)),
                    _ToolbarButton(icon: Icons.code, onPressed: () => _toggleInlineStyle('`')),
                    _ToolbarButton(icon: Icons.horizontal_rule, onPressed: () => _insertBlock('---')),
                  ],
                ),
              ),
            SizedBox(
              height: 38,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ToolbarButton(
                    icon: Icons.undo,
                    onPressed: _undoList.length >= 2 ? _undo : null,
                  ),
                  _ToolbarButton(
                    icon: Icons.redo,
                    onPressed: _redoList.isNotEmpty ? _redo : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: VerticalDivider(
                      width: 1, indent: 8, endIndent: 8,
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  Builder(
                    builder: (context) => _ToolbarButton(
                      icon: Icons.title, 
                      onPressed: () => _toggleBlockPrefix('# '),
                      onLongPress: () => _showHeadingMenu(context),
                    ),
                  ),
                  _ToolbarButton(icon: Icons.format_bold, onPressed: () => _toggleInlineStyle('**')),
                  _ToolbarButton(icon: Icons.format_italic, onPressed: () => _toggleInlineStyle('*')),
                  _ToolbarButton(icon: Icons.format_list_bulleted, onPressed: () => _toggleBlockPrefix('- ')),
                  _ToolbarButton(icon: Icons.image_outlined, onPressed: () => _pickImage(ImageSource.gallery)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: VerticalDivider(
                      width: 1, indent: 8, endIndent: 8,
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  _ToolbarButton(
                    icon: _isToolbarExpanded ? Icons.keyboard_arrow_down : Icons.more_horiz,
                    onPressed: () {
                      setState(() {
                        _isToolbarExpanded = !_isToolbarExpanded;
                      });
                    },
                  ),
                  _ToolbarButton(
                    icon: Icons.keyboard_hide,
                    onPressed: () => _focusedTextSeg?.focusNode.unfocus(),
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

// ---------------------------------------------------------------------------
// Toolbar button
// ---------------------------------------------------------------------------
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  const _ToolbarButton({required this.icon, this.onPressed, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = onPressed != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 18,
              color: isEnabled
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
            ),
          ),
        ),
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
  /// 为 true 时跳过 Markdown 行内渲染，按纯文本输出（代码类笔记使用）
  final bool plainCode;

  MarkdownTextEditingController({
    required this.context,
    this.focusNode,
    super.text,
    this.plainCode = false,
  });

  void refresh() {
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // 源码模式：整体纯文本输出，HTML/JSON 等内容不做任何 Markdown 解析
    if (plainCode) {
      return TextSpan(text: text, style: style);
    }
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

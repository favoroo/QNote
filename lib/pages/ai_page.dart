import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/widgets/ai/agent_turn_limit_actions.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';
import 'package:qnote_flutter/widgets/common/streaming_elapsed_text.dart';
import 'package:qnote_flutter/widgets/common/thought_tail_scroll_view.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/agent/services/q_text_quote.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/widgets/ai/q_input_command_panels.dart';
import 'package:qnote_flutter/widgets/ai/quick_prompt_dialog.dart';
import 'package:qnote_flutter/widgets/q_text_selection_toolbar.dart';

class AiPage extends ConsumerStatefulWidget {
  const AiPage({super.key});

  @override
  ConsumerState<AiPage> createState() => _AiPageState();
}

/// 会话流的可视展示包装项，携带该项在原始 session.messages 中的实际下标（供撤回/重试使用）
class _ChatDisplayEntry {
  final ChatMessage message;
  final int? stateIndex;

  const _ChatDisplayEntry(this.message, [this.stateIndex]);
}

class _AiPageState extends ConsumerState<AiPage> {
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  double _lastBottomInset = 0.0;

  bool _isTyping = false;
  bool _isBatchMode = false;
  List<String> _selectedSessionIds = [];
  String? _activeModelId;

  // 待发送的对话引用文本（用户通过消息框选「给小Q」或点击悬浮球挂起）
  String? _quotedChatText;
  // 当前在聊天区域划选高亮的纯文本
  String? _currentSelectedText;

  // 豆包式附件状态（图片、分享给AI的日记、笔记与待办）
  final List<String> _attachedImages = [];
  final List<String> _attachedJournalIds = [];
  final List<String> _attachedNoteIds = [];
  final List<String> _attachedTodoIds = [];
  final Map<String, String> _journalTitles = {};
  final Map<String, String> _noteTitles = {};
  final Map<String, String> _todoTitles = {};

  // 输入增强状态：斜杠命令 / @ 引用浮层（非 null 即展示对应面板）
  String? _slashQuery;
  String? _atQuery;
  List<Map<String, String>> _slashSkills = [];
  Map<String, SkillUsageStat> _usageStats = {};

  @override
  void initState() {
    super.initState();
    _inputFocusNode.addListener(_onInputFocusChanged);
    _inputController.addListener(_onInputChanged);
    WorkspaceEventBus.instance.addListener(_onSkillsChanged);
    _loadSlashSkills();
    _initActiveModelId();
    _registerTargetBridge();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(currentChatProvider.notifier).initLastSession();
      _scrollToBottom();
    });
  }

  /// 注册到悬浮小Q桥接：小Q主对话界面内点击悬浮球时，捕获当前框选文本并引用到输入框
  void _registerTargetBridge() {
    QTargetBridge.instance.register(
      'page:/ai',
      QTargetHooks(
        quoteSelection: () {
          final text = _currentSelectedText?.trim();
          if (text == null || text.isEmpty) return null;
          return QTextQuote(
            source: QQuoteSource.chat,
            sourceId: '',
            sourceTitle: '对话内容',
            quotedText: text,
          );
        },
        onApplyQuote: (quote) {
          _applyQuote(quote.quotedText);
        },
        onFocusInput: () {
          _inputFocusNode.requestFocus();
        },
      ),
    );
  }

  /// 将选中的文本作为引用挂载到下方输入框上方
  void _applyQuote(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _quotedChatText = trimmed;
    });
    _inputFocusNode.requestFocus();
    HapticFeedback.lightImpact();
  }

  /// 小Q经 VFS 写入 /skills/ 时刷新斜杠命令候选（会话中新建的技能立即可用）
  void _onSkillsChanged(WorkspaceChangeEvent event) {
    if (event.path.startsWith('/skills/')) {
      _loadSlashSkills();
    }
  }

  Future<void> _loadSlashSkills() async {
    await SkillRegistry.instance.ensureLoaded();
    if (!mounted) return;
    final stats = await SkillUsageTracker.instance.getStats();
    if (!mounted) return;
    setState(() {
      _slashSkills = SkillRegistry.instance.listSkills();
      _usageStats = stats;
    });
  }

  /// 输入变化时检测光标处是否有激活的斜杠命令或 @ 引用命令词
  void _onInputChanged() {
    final text = _inputController.text;
    final selection = _inputController.selection;
    if (!selection.isValid || selection.baseOffset < 0) {
      _updateOverlays(null, null);
      return;
    }
    final caret = selection.baseOffset.clamp(0, text.length);
    final before = text.substring(0, caret);

    // 触发符必须位于行首或紧跟空白，且命令词内不含空白（长度上限防误触发）
    String? slashQuery;
    final slashIdx = before.lastIndexOf('/');
    if (slashIdx >= 0) {
      final token = before.substring(slashIdx + 1);
      final atBoundary =
          slashIdx == 0 || RegExp(r'\s').hasMatch(before[slashIdx - 1]);
      if (atBoundary && !RegExp(r'\s').hasMatch(token) && token.length <= 40) {
        slashQuery = token;
      }
    }

    String? atQuery;
    final atIdx = before.lastIndexOf('@');
    if (atIdx >= 0) {
      final token = before.substring(atIdx + 1);
      final atBoundary =
          atIdx == 0 || RegExp(r'\s').hasMatch(before[atIdx - 1]);
      if (atBoundary && !RegExp(r'\s').hasMatch(token) && token.length <= 20) {
        atQuery = token;
      }
    }

    // 同时最多展示一个面板：光标更近的触发符优先
    if (slashQuery != null && atQuery != null) {
      if (atIdx > slashIdx) {
        slashQuery = null;
      } else {
        atQuery = null;
      }
    }
    _updateOverlays(slashQuery, atQuery);
  }

  void _updateOverlays(String? slash, String? at) {
    if (_slashQuery == slash && _atQuery == at) return;
    setState(() {
      _slashQuery = slash;
      _atQuery = at;
    });
  }

  /// 斜杠命令面板当前候选：按命令词过滤技能清单并附使用次数
  List<Map<String, String?>> get _slashCandidates {
    final query = _slashQuery?.toLowerCase() ?? '';
    return [
      for (final skill in _slashSkills)
        if (query.isEmpty ||
            (skill['name'] ?? '').toLowerCase().contains(query) ||
            (skill['description'] ?? '').toLowerCase().contains(query))
          {
            'name': skill['name'] ?? '',
            'description': skill['description'] ?? '',
            'usageCount': '${_usageStats[skill['name']]?.count ?? 0}',
          },
    ];
  }

  /// 选中斜杠命令候选：把命令词替换为完整技能名并追加空格
  void _applySlashSelection(String skillName) {
    HapticFeedback.lightImpact();
    _replaceActiveToken('/', '/$skillName ');
    _updateOverlays(null, null);
    _inputFocusNode.requestFocus();
  }

  /// 选中 @ 引用类别：移除 @ 命令词并打开对应的多选弹窗
  void _applyAtSelection(AtReferenceKind kind) {
    HapticFeedback.lightImpact();
    _replaceActiveToken('@', '');
    _updateOverlays(null, null);
    switch (kind) {
      case AtReferenceKind.note:
        _pickNotes();
      case AtReferenceKind.todo:
        _pickTodos();
      case AtReferenceKind.journal:
        _pickJournals();
    }
  }

  /// 将光标前正在输入的触发符命令词替换为 [replacement]
  void _replaceActiveToken(String trigger, String replacement) {
    final text = _inputController.text;
    final selection = _inputController.selection;
    final caret = selection.isValid && selection.baseOffset >= 0
        ? selection.baseOffset.clamp(0, text.length)
        : text.length;
    final before = text.substring(0, caret);
    final idx = before.lastIndexOf(trigger);
    if (idx < 0) return;
    _inputController.value = TextEditingValue(
      text: text.replaceRange(idx, caret, replacement),
      selection: TextSelection.collapsed(offset: idx + replacement.length),
    );
  }

  void _onInputFocusChanged() {
    if (_inputFocusNode.hasFocus) {
      // 输入框聚焦时立即触发滚动，并等待软键盘弹起动画完成后再次校准到底部
      _scrollToBottom();
      Future.delayed(const Duration(milliseconds: 260), () {
        if (mounted && _inputFocusNode.hasFocus) {
          _scrollToBottom();
        }
      });
    }
  }

  Future<void> _initActiveModelId() async {
    final roles = await ref.read(aiRolesProvider.future);
    if (roles != null && roles.assistantUseFreeModel) {
      final freeId = roles.assistantFreeModelId ?? 'gemini-3.5-flash-lite';
      if (mounted) setState(() => _activeModelId = 'free:$freeId');
      return;
    }
    try {
      final config = await AiRoleService.instance.getEffectiveConfigForRole(
        'assistant',
      );
      if (mounted) {
        setState(() => _activeModelId = config.id);
      }
    } catch (_) {
      if (roles?.assistant != null) {
        if (mounted) setState(() => _activeModelId = roles!.assistant);
      } else {
        final config = await ref.read(defaultAiConfigProvider.future);
        if (config != null && mounted) {
          setState(() => _activeModelId = config.id);
        }
      }
    }
  }

  @override
  void dispose() {
    QTargetBridge.instance.unregister('page:/ai');
    AgentInteractionService.instance.cancelPending('离开AI页面');
    WorkspaceEventBus.instance.removeListener(_onSkillsChanged);
    _inputController.removeListener(_onInputChanged);
    _inputFocusNode.removeListener(_onInputFocusChanged);
    _inputFocusNode.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        if (immediate) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        } else {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: AppDurations.medium,
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  void _scrollToBottomIfNeeded() {
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      // 当键盘弹起时，允许更大容差，避免流式内容被误判为历史回看而阻断滚动
      final tolerance = _lastBottomInset > 0 ? 300.0 : 150.0;
      final isNearBottom = pos.maxScrollExtent - pos.pixels < tolerance;
      if (isNearBottom || pos.pixels == 0) {
        _scrollToBottom(immediate: true);
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    final quoteToSend = _quotedChatText;
    final hasQuote = quoteToSend != null && quoteToSend.isNotEmpty;
    final hasImages = _attachedImages.isNotEmpty;
    final hasNotes = _attachedNoteIds.isNotEmpty;
    final hasTodos = _attachedTodoIds.isNotEmpty;
    final hasJournals = _attachedJournalIds.isNotEmpty;

    if (text.isEmpty &&
        !hasQuote &&
        !hasImages &&
        !hasNotes &&
        !hasTodos &&
        !hasJournals) {
      return;
    }
    if (_isTyping) {
      return;
    }
    // 当前会话已有任务在后台生成（如切走后再切回）：拦截发送，避免同会话并发两轮任务
    final activeId = ref.read(currentChatProvider)?.id;
    if (activeId != null &&
        ref.read(agentRunningSessionsProvider).contains(activeId)) {
      Toast.warning(context, '小Q正在处理当前对话，请等待完成或先中止');
      return;
    }

    // 斜杠命令解析：消息以「/技能名」开头时显式激活该技能（手册由 Provider 注入上下文）
    final skillName = _parseSlashCommand(text);

    final quotePrefix = hasQuote ? '【引用对话】：\n"""\n$quoteToSend\n"""\n\n' : '';
    final content = text.isNotEmpty
        ? '$quotePrefix$text'
        : (hasQuote
              ? '请分析我引用的这段对话内容：\n$quoteToSend'
              : (hasImages ? '请结合图片进行分析' : '请结合我分享的内容进行分析'));

    final imagesToSend = hasImages ? List<String>.from(_attachedImages) : null;
    final notesToSend = hasNotes ? List<String>.from(_attachedNoteIds) : null;
    final todosToSend = hasTodos ? List<String>.from(_attachedTodoIds) : null;
    final journalsToSend = hasJournals
        ? List<String>.from(_attachedJournalIds)
        : null;

    HapticFeedback.lightImpact();
    _inputController.clear();
    setState(() {
      _attachedImages.clear();
      _attachedNoteIds.clear();
      _attachedTodoIds.clear();
      _attachedJournalIds.clear();
      _quotedChatText = null;
    });
    FocusScope.of(context).unfocus();
    setState(() => _isTyping = true);
    _scrollToBottom();
    // 延迟一帧在软键盘开始收起时再次校准滚动，确保占位气泡第一时间露出
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom(immediate: true);
    });

    try {
      if (ref.read(currentChatProvider) == null) {
        final session = await ref
            .read(chatSessionListProvider.notifier)
            .createSession();
        ref.read(currentChatProvider.notifier).setSession(session);
      }

      await ref
          .read(currentChatProvider.notifier)
          .sendMessage(
            content,
            images: imagesToSend,
            noteIds: notesToSend,
            todoIds: todosToSend,
            journalIds: journalsToSend,
            skillName: skillName,
          );
    } catch (e) {
      debugPrint('发送消息失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isTyping = false);
        _scrollToBottom();
      }
    }
  }

  /// 解析消息开头的斜杠命令词，返回对应技能主名；未命中返回 null
  String? _parseSlashCommand(String text) {
    final match = RegExp(r'^/([^\s/]+)(?:\s+|$)').firstMatch(text);
    if (match == null) return null;
    return SkillRegistry.instance.resolveSkillName(match.group(1)!);
  }

  /// 中止小Q当前生成与工具执行
  void _stopGenerating() {
    HapticFeedback.mediumImpact();
    ref.read(currentChatProvider.notifier).cancelCurrentAgent('用户主动中止操作');
    AgentInteractionService.instance.cancelPending('用户主动中止操作');
  }

  // ==========================================
  // 用户消息长按操作：再次编辑 / 撤回本轮对话 / 复制
  // ==========================================

  /// 长按用户消息弹出的操作菜单；[stateIndex] 为该消息在会话态中的真实下标
  void _showUserMessageActions(int stateIndex, ChatMessage message) {
    if (_isTyping ||
        ref.read(aiStreamingMessageProvider) != null ||
        ref.read(aiStreamingStatusProvider) != null) {
      Toast.warning(context, '小Q正在生成中，请等待完成后再操作');
      return;
    }

    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.edit_note_rounded, size: 22),
                  title: const Text('再次编辑', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '回退到本轮对话发起前，内容填回输入框重新生成',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmRollback(stateIndex, refill: true);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.undo_rounded,
                    size: 22,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    '撤回本轮对话',
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  subtitle: const Text(
                    '回退到本轮对话发起前，并撤销本轮对数据的修改',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmRollback(stateIndex, refill: false);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded, size: 20),
                  title: const Text('复制', style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Clipboard.setData(ClipboardData(text: message.content));
                    Toast.success(context, '已复制');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 撤回前的二次确认（破坏性操作：删除该轮起的消息并恢复数据修改，不可恢复）
  Future<void> _confirmRollback(int stateIndex, {required bool refill}) async {
    final session = ref.read(currentChatProvider);
    final messages = session?.messages ?? const <ChatMessage>[];
    if (stateIndex < 0 || stateIndex >= messages.length) return;

    final removedCount = messages.length - stateIndex;
    int changeCount = 0;
    for (final m in messages.skip(stateIndex).where((m) => m.role == 'user')) {
      changeCount += WorkspaceUndoEntry.decodeList(m.undoLog).length;
    }

    final description = StringBuffer('将删除该轮起的 $removedCount 条消息');
    if (changeCount > 0) {
      description.write('，并撤销本轮及之后的 $changeCount 处数据修改');
    }
    description.write('。此操作不可恢复。');

    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(refill ? '再次编辑并回退？' : '撤回本轮对话？'),
        content: Text(description.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(refill ? '编辑并回退' : '撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _executeRollback(stateIndex, refill: refill);
  }

  /// 执行撤回；[refill] 为 true 时把被撤回的用户消息内容与图片回填输入区（再次编辑）
  Future<void> _executeRollback(int stateIndex, {required bool refill}) async {
    final message = refill
        ? ref.read(currentChatProvider)?.messages[stateIndex]
        : null;

    // 复用生成中状态禁用输入区，防止撤回期间发送新消息
    setState(() => _isTyping = true);
    try {
      final result = await ref
          .read(currentChatProvider.notifier)
          .rollbackToMessage(stateIndex);
      if (!mounted) return;
      if (result == null) {
        Toast.error(context, '当前状态无法撤回');
        return;
      }
      final (restored, failed) = result;
      if (failed > 0) {
        Toast.warning(context, '已回退对话，但 $failed 处数据恢复失败，详情请查看日志');
      } else if (restored > 0) {
        Toast.success(context, '已回退对话并恢复 $restored 处数据修改');
      } else {
        Toast.success(context, '已回退对话');
      }
      if (refill && message != null) {
        _refillInputFromMessage(message);
      }
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _isTyping = false);
    }
  }

  // ==========================================
  // 失败气泡长按操作：重试本轮对话 / 复制错误详情
  // ==========================================

  /// 长按失败气泡弹出的操作菜单；[stateIndex] 为该消息在会话态中的真实下标。
  /// 仅当失败气泡是会话最后一条时提供重试，避免回退误删其后已发生的新对话。
  void _showErrorAssistantActions(int stateIndex, ChatMessage message) {
    if (_isTyping ||
        ref.read(aiStreamingMessageProvider) != null ||
        ref.read(aiStreamingStatusProvider) != null) {
      Toast.warning(context, '小Q正在生成中，请等待完成后再操作');
      return;
    }

    final messages =
        ref.read(currentChatProvider)?.messages ?? const <ChatMessage>[];
    final canRetry = stateIndex == messages.length - 1;

    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                if (canRetry)
                  ListTile(
                    leading: const Icon(Icons.refresh_rounded, size: 22),
                    title: const Text('重试本轮对话', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      '回退本轮并撤销期间产生的数据修改，然后重新发送上一条提问',
                      style: TextStyle(fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _retryFailedTurn(stateIndex);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded, size: 20),
                  title: const Text('复制错误详情', style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Clipboard.setData(ClipboardData(text: message.content));
                    Toast.success(context, '已复制');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 重试失败本轮：先回退到本轮用户消息之前（恢复期间已产生的数据修改），
  /// 再按原文本/图片/附件引用重新发送。附件引用来自发送时持久化的 uiDetails。
  Future<void> _retryFailedTurn(int errorIndex) async {
    final messages =
        ref.read(currentChatProvider)?.messages ?? const <ChatMessage>[];
    if (errorIndex <= 0 || errorIndex >= messages.length) return;

    // 定位本轮用户消息（失败气泡之前最近的一条 user 消息）
    int? userIndex;
    for (var i = errorIndex - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        userIndex = i;
        break;
      }
    }
    if (userIndex == null) return;
    final userMessage = messages[userIndex];

    // 该轮（含其后轮次）记录过数据修改时需二次确认：重试前的回退会撤销这些修改
    int changeCount = 0;
    for (final m in messages.skip(userIndex).where((m) => m.role == 'user')) {
      changeCount += WorkspaceUndoEntry.decodeList(m.undoLog).length;
    }
    if (changeCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('重试本轮对话？'),
          content: Text('本轮已产生 $changeCount 处数据修改，重试前会先撤销这些修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    // 解析发送时持久化的附件引用（旧消息或纯文本/图片提问则视为无引用）
    final attachments = userMessage.uiDetails?['attachments'];
    final attachmentMap = attachments is Map ? attachments : null;
    List<String>? readIds(String key) {
      final raw = attachmentMap?[key];
      if (raw is List && raw.isNotEmpty) {
        return raw.map((e) => e.toString()).toList();
      }
      return null;
    }

    // 复用生成中状态禁用输入区，防止回退与重发期间插入新消息
    setState(() => _isTyping = true);
    _scrollToBottom();
    try {
      final result = await ref
          .read(currentChatProvider.notifier)
          .rollbackToMessage(userIndex);
      if (!mounted) return;
      if (result == null) {
        Toast.error(context, '当前状态无法重试');
        return;
      }
      await ref
          .read(currentChatProvider.notifier)
          .sendMessage(
            userMessage.content,
            images: userMessage.images,
            noteIds: readIds('notes'),
            todoIds: readIds('todos'),
            journalIds: readIds('journals'),
            skillName: _parseSlashCommand(userMessage.content),
          );
    } finally {
      if (mounted) {
        setState(() => _isTyping = false);
        _scrollToBottom();
      }
    }
  }

  /// 「再次编辑」：把被撤回的用户消息文本与图片回填到输入区（引用的日记/笔记/待办
  /// 未持久化到消息上，无法回填，需重新选择）
  void _refillInputFromMessage(ChatMessage message) {
    setState(() {
      _inputController.text = message.content;
      _attachedImages
        ..clear()
        ..addAll(message.images ?? const []);
      _attachedJournalIds.clear();
      _attachedNoteIds.clear();
      _attachedTodoIds.clear();
    });
    _inputFocusNode.requestFocus();
  }

  Future<void> _pickFromCamera() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 80,
      );
      if (image != null && mounted) {
        setState(() {
          _attachedImages.add(image.path);
        });
      }
    } catch (e) {
      debugPrint('拍照失败: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final images = await GalleryHelper.pickMultiImages(context, maxAssets: 9);
      if (images.isNotEmpty && mounted) {
        setState(() {
          for (final img in images) {
            if (!_attachedImages.contains(img.path)) {
              _attachedImages.add(img.path);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('相册选图失败: $e');
    }
  }

  Future<void> _pickJournals() async {
    final journals = await JournalService.instance.getAllJournals();
    if (!mounted) return;
    if (journals.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无已写日记，可在时间线左下角撰写日记')));
      return;
    }
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiJournalSelectorDialog(
        journals: journals,
        initialSelected: _attachedJournalIds,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedJournalIds.clear();
        _attachedJournalIds.addAll(result);
        for (final j in journals) {
          _journalTitles[j.id] = '${j.title} 日记';
        }
      });
    }
  }

  Future<void> _pickNotes() async {
    final notes = await NoteRepository().getAll();
    if (!mounted) return;
    // 排除日记笔记，保持普通笔记专属
    final validNotes = notes
        .where((n) => !n.isDeleted && !JournalService.isJournalNote(n.id))
        .toList();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiNoteSelectorDialog(
        notes: validNotes,
        initialSelected: _attachedNoteIds,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedNoteIds.clear();
        _attachedNoteIds.addAll(result);
        for (final n in validNotes) {
          _noteTitles[n.id] = n.title.isNotEmpty ? n.title : '无标题笔记';
        }
      });
    }
  }

  Future<void> _pickTodos() async {
    final todos = await TodoRepository().getAll();
    if (!mounted) return;
    final validTodos = todos.where((t) => !t.isDeleted).toList();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiTodoSelectorDialog(
        todos: validTodos,
        initialSelected: _attachedTodoIds,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedTodoIds.clear();
        _attachedTodoIds.addAll(result);
        for (final t in validTodos) {
          _todoTitles[t.id] = t.title.isNotEmpty ? t.title : '无标题待办';
        }
      });
    }
  }

  void _showAttachmentMenu(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildAttachmentOption(
                        icon: Icons.camera_alt_rounded,
                        label: '相机',
                        iconColor: const Color(0xFF3F51B5),
                        bgColor: const Color(
                          0xFF3F51B5,
                        ).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickFromCamera();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.photo_library_rounded,
                        label: '相册',
                        iconColor: const Color(0xFF009688),
                        bgColor: const Color(
                          0xFF009688,
                        ).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickFromGallery();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.auto_stories_rounded,
                        label: '日记',
                        iconColor: const Color(0xFFE91E63),
                        bgColor: const Color(
                          0xFFE91E63,
                        ).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickJournals();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.description_rounded,
                        label: '笔记',
                        iconColor: const Color(0xFFFF9800),
                        bgColor: const Color(
                          0xFFFF9800,
                        ).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickNotes();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.check_circle_outline_rounded,
                        label: '待办',
                        iconColor: const Color(0xFF4CAF50),
                        bgColor: const Color(
                          0xFF4CAF50,
                        ).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickTodos();
                        },
                        theme: theme,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color iconColor,
    required Color bgColor,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openModelSelector() async {
    // 弹窗与 AiRoles 写入逻辑在共享组件中（悬浮小Q面板长按发送按钮也走此入口）
    final selected = await showAssistantModelSelector(context, ref);
    if (selected == null) return;
    setState(() => _activeModelId = selected.id);
  }

  @override
  Widget build(BuildContext context) {
    final currentChat = ref.watch(currentChatProvider);
    final aiConfigsAsync = ref.watch(aiConfigListProvider);
    final theme = Theme.of(context);

    // 监听 aiRolesProvider，保证小Q界面与设置页角色绑定实时同步
    ref.listen<AsyncValue<AiRoles?>>(aiRolesProvider, (prev, next) {
      if (next is AsyncData<AiRoles?>) {
        final roles = next.value;
        if (roles != null) {
          String? newActiveId;
          if (roles.assistantUseFreeModel) {
            final freeId =
                roles.assistantFreeModelId ?? 'gemini-3.5-flash-lite';
            newActiveId = 'free:$freeId';
          } else if (roles.assistant != null) {
            newActiveId = roles.assistant;
          }
          if (newActiveId != null && newActiveId != _activeModelId) {
            setState(() => _activeModelId = newActiveId);
          }
        }
      }
    });

    // Listen to aiConfigsAsync to ensure _activeModelId is always valid
    ref.listen<AsyncValue<List<AiConfig>>>(aiConfigListProvider, (prev, next) {
      if (next is AsyncData<List<AiConfig>>) {
        final configs = next.value;
        // 如果当前是内置免费模型，不受自定义模型列表增删影响
        if (_activeModelId != null && _activeModelId!.startsWith('free:')) {
          return;
        }
        if (configs.isNotEmpty) {
          // If current active ID is not in the list, or null, pick the first or default
          final currentValid = configs.any((c) => c.id == _activeModelId);
          if (!currentValid) {
            final defaultCfg =
                configs.where((c) => c.isDefault).firstOrNull ?? configs.first;
            setState(() => _activeModelId = defaultCfg.id);
          }
        } else {
          setState(() => _activeModelId = 'free:gemini-3.5-flash-lite');
        }
      }
    });

    ref.listen(currentChatProvider, (prev, next) {
      _scrollToBottom();
      // 会话切换时重置打字点/停止按钮状态：流式气泡已随会话卸载，
      // 旧会话的等待指示不能残留到新会话。
      // prev == null 是发送时自动创建会话的场景，属于本次发送自己的会话，不重置
      if (prev != null && next?.id != prev.id && _isTyping && mounted) {
        setState(() => _isTyping = false);
      }
    });
    ref.listen(aiStreamingMessageProvider, (prev, next) {
      if (next != null) {
        _scrollToBottomIfNeeded();
      }
    });
    ref.listen(aiStreamingStatusProvider, (prev, next) {
      if (next != null) {
        _scrollToBottomIfNeeded();
      }
    });
    // 监听实时思考过程更新：思考卡长高时自动贴底，防止被底部输入栏遮挡
    ref.listen(aiStreamingThoughtProvider, (prev, next) {
      if (next != null && next.isNotEmpty) {
        _scrollToBottomIfNeeded();
      }
    });

    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    if (bottomInset != _lastBottomInset) {
      // 软键盘高度变化（弹起避让或收拢恢复），在下一帧重新校准贴底
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToBottomIfNeeded();
        }
      });
    }
    _lastBottomInset = bottomInset;

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('小Q'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '新建对话',
            onPressed: () async {
              // 先收起键盘，避免新会话打开后键盘自动弹出
              FocusManager.instance.primaryFocus?.unfocus();
              final session = await ref
                  .read(chatSessionListProvider.notifier)
                  .createSession();
              ref.read(currentChatProvider.notifier).setSession(session);
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              // 先取消输入框焦点，防止关闭抽屉后键盘自动弹出
              FocusManager.instance.primaryFocus?.unfocus();
              _scaffoldKey.currentState?.openEndDrawer();
            },
          ),
        ],
      ),
      // 历史抽屉的 sessionsAsync 与 currentChat.id 订阅下沉，避免顶层 rebuild 连带
      endDrawer: Consumer(
        builder: (context, ref, _) {
          final sessionsAsync = ref.watch(chatSessionListProvider);
          final activeId = ref.watch(currentChatProvider.select((c) => c?.id));
          return _buildHistoryDrawer(sessionsAsync, activeId, theme);
        },
      ),
      body: Column(
        children: [
          Expanded(child: _buildChatArea(currentChat, theme)),
          _buildInputArea(aiConfigsAsync, theme),
        ],
      ),
    );
  }

  /// 判断一条消息是否需要在会话流中渲染。
  ///
  /// Agent 在每轮发起工具调用前，都会生成一条「正文为空、仅承载 tool_calls」的 assistant
  /// 消息以维持上下文协议完整。这类消息属于内部中转，不应出现在聊天记录里，
  /// 否则会被渲染成一个永远不会消失的加载气泡。
  bool _isVisibleMessage(ChatMessage message) {
    if (message.role == 'user') return true;
    if (message.content.trim().isNotEmpty) return true;
    if (message.role == 'tool') return true;
    if (message.uiDetails != null) return true;
    // 如果 assistant 正文为空且带有 toolCalls（说明是发起工具调用的中间状态帧），不作为独立顶级气泡展示
    if (message.role == 'assistant' &&
        message.toolCalls != null &&
        message.toolCalls!.isNotEmpty) {
      return false;
    }
    if (message.thought != null && message.thought!.trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  Widget _buildChatArea(ChatSession? currentChat, ThemeData theme) {
    final stateMessages = currentChat?.messages ?? const <ChatMessage>[];

    // 将消息归一为可视展示项，连续的工具执行结果（≥2项）自动聚合成折叠链
    final displayEntries = <_ChatDisplayEntry>[];
    int i = 0;
    while (i < stateMessages.length) {
      final msg = stateMessages[i];
      if (!_isVisibleMessage(msg)) {
        i++;
        continue;
      }

      // 判断是否可作为工具链聚合（ask_user 需保持独立交互卡片）
      if (msg.role == 'tool' && msg.toolName != 'ask_user') {
        final toolGroup = <ChatMessage>[msg];
        var j = i + 1;
        while (j < stateMessages.length) {
          final nextMsg = stateMessages[j];
          if (!_isVisibleMessage(nextMsg)) {
            j++;
            continue;
          }
          if (nextMsg.role == 'tool' && nextMsg.toolName != 'ask_user') {
            toolGroup.add(nextMsg);
            j++;
          } else {
            break;
          }
        }

        if (toolGroup.length >= 2) {
          final groupMsg = ChatMessage(
            role: 'tool_group',
            content: '',
            timestamp: toolGroup.first.timestamp,
            uiDetails: {'messages': toolGroup},
          );
          displayEntries.add(_ChatDisplayEntry(groupMsg));
          i = j;
          continue;
        } else {
          displayEntries.add(_ChatDisplayEntry(msg, i));
          i++;
          continue;
        }
      }

      displayEntries.add(_ChatDisplayEntry(msg, i));
      i++;
    }

    // If messages are empty, virtualize the assistant's greeting bubble so it's shown.
    final displayItems = displayEntries.isEmpty
        ? [
            _ChatDisplayEntry(
              ChatMessage(
                role: 'assistant',
                content:
                    defaultSystemPrompts['assistant_greeting'] ?? '嗨，你好',
                timestamp: DateTime.now(),
              ),
            ),
          ]
        : displayEntries;

    final hasStreaming =
        ref.watch(
          aiStreamingMessageProvider.select((value) => value != null),
        ) ||
        ref.watch(aiStreamingStatusProvider.select((value) => value != null));
    final showTyping =
        _isTyping &&
        !hasStreaming &&
        displayItems.isNotEmpty &&
        displayItems.last.message.role == 'user';
    final showStreaming = hasStreaming;

    final totalCount =
        displayItems.length + (showTyping ? 1 : 0) + (showStreaming ? 1 : 0);

    bool isUserMsg(ChatMessage m) => m.role == 'user';

    return SelectionArea(
      // 追踪聊天区域当前的框选文本，供悬浮球点击与「给小Q」工具栏引用
      onSelectionChanged: (selection) {
        _currentSelectedText = selection?.plainText;
      },
      contextMenuBuilder: (context, selectableRegionState) {
        final selectedText = _currentSelectedText?.trim();
        final hasSelection = selectedText != null && selectedText.isNotEmpty;
        return QTextSelectionToolbar(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: [
            ...selectableRegionState.contextMenuButtonItems.where(
              (item) => item.type != ContextMenuButtonType.custom,
            ),
            if (hasSelection)
              ContextMenuButtonItem(
                label: '给小Q',
                onPressed: () {
                  selectableRegionState.hideToolbar();
                  _applyQuote(selectedText);
                },
              ),
          ],
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          // 点击聊天区域空白背景收起软键盘
          _inputFocusNode.unfocus();
        },
        child: ListView.builder(
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          itemCount: totalCount,
          itemBuilder: (context, index) {
            // 隔离每条消息的重绘，流式输出时只重绘最后一条
            if (index < displayItems.length) {
              final entry = displayItems[index];
              final currentMsg = entry.message;
              final currentIsUser = isUserMsg(currentMsg);

              // 1. 判断是否是同组的第一条消息（若前一条也是同一方且时间相近，则不重复显示头像）
              var isFirstInGroup = true;
              if (index > 0) {
                final prevMsg = displayItems[index - 1].message;
                final prevIsUser = isUserMsg(prevMsg);
                if (prevIsUser == currentIsUser) {
                  final prevTime = prevMsg.timestamp;
                  final currTime = currentMsg.timestamp;
                  if (prevTime == null ||
                      currTime == null ||
                      currTime.difference(prevTime).abs().inMinutes < 5) {
                    isFirstInGroup = false;
                  }
                }
              }

              // 2. 判断是否是同组的最后一条消息（若后面还有同方连续消息/流式输出，则收缩底部间距）
              var isLastInGroup = true;
              if (index < displayItems.length - 1) {
                final nextMsg = displayItems[index + 1].message;
                final nextIsUser = isUserMsg(nextMsg);
                if (nextIsUser == currentIsUser) {
                  final nextTime = nextMsg.timestamp;
                  final currTime = currentMsg.timestamp;
                  if (nextTime == null ||
                      currTime == null ||
                      nextTime.difference(currTime).abs().inMinutes < 5) {
                    isLastInGroup = false;
                  }
                }
              } else {
                // 当前是已存列表的最后一条，如果紧接着有 typing 或 streaming，且小Q是发送方，则不是最后一条
                if (!currentIsUser && (showTyping || showStreaming)) {
                  isLastInGroup = false;
                }
              }

              final bubble = ChatBubble(
                message: currentMsg,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                actionsEnabled: !hasStreaming,
                onContinue: () => ref
                    .read(currentChatProvider.notifier)
                    .continueAfterTurnLimit(),
                onPause: () => ref
                    .read(currentChatProvider.notifier)
                    .pauseAfterTurnLimit(),
              );
              // 用户消息长按弹出操作菜单（撤回本轮 / 再次编辑 / 复制）；
              // 失败气泡长按弹出重试菜单（重试本轮 / 复制错误详情）
              return RepaintBoundary(
                child: currentIsUser && entry.stateIndex != null
                    ? GestureDetector(
                        onLongPress: () => _showUserMessageActions(
                          entry.stateIndex!,
                          currentMsg,
                        ),
                        child: bubble,
                      )
                    : !currentIsUser &&
                          currentMsg.isError == true &&
                          entry.stateIndex != null
                    ? GestureDetector(
                        onLongPress: () => _showErrorAssistantActions(
                          entry.stateIndex!,
                          currentMsg,
                        ),
                        child: bubble,
                      )
                    : bubble,
              );
            }

            if (showTyping && index == displayItems.length) {
              // 如果上一条已经是小Q回复，打字指示器隐藏头像并紧凑排列
              final prevIsAssistant =
                  displayItems.isNotEmpty &&
                  !isUserMsg(displayItems.last.message);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TypingBubble(
                  isFirstInGroup: !prevIsAssistant,
                  isLastInGroup: !showStreaming,
                ),
              );
            }

            // 流式气泡（含思考中状态卡）：底部增加留白，确保不紧贴输入栏
            final lastMsg = displayItems.isNotEmpty
                ? displayItems.last.message
                : null;
            final prevIsAssistant = lastMsg != null && !isUserMsg(lastMsg);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _StreamingBubble(
                isFirstInGroup: !prevIsAssistant && !showTyping,
                isLastInGroup: true,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInputArea(
    AsyncValue<List<AiConfig>> aiConfigsAsync,
    ThemeData theme,
  ) {
    final hasAttachments =
        _attachedImages.isNotEmpty ||
        _attachedJournalIds.isNotEmpty ||
        _attachedNoteIds.isNotEmpty ||
        _attachedTodoIds.isNotEmpty;

    // 当前会话是否有进行中的小Q任务：切换会话后据此恢复停止按钮归属、
    // 防止往正在生成的会话并发发送第二条消息
    final activeId = ref.watch(currentChatProvider.select((c) => c?.id));
    final isSessionBusy = ref.watch(
      agentRunningSessionsProvider.select(
        (s) => activeId != null && s.contains(activeId),
      ),
    );
    final busy = _isTyping || isSessionBusy;

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 0. 输入增强浮层：斜杠命令 / @ 引用（位于附件挂载条之上）
              if (_slashQuery != null) ...[
                SlashCommandPanel(
                  skills: _slashCandidates,
                  query: _slashQuery!,
                  onSelected: _applySlashSelection,
                ),
                const SizedBox(height: 6),
              ],
              if (_atQuery != null) ...[
                AtReferencePanel(onSelected: _applyAtSelection),
                const SizedBox(height: 6),
              ],

              // 0.5 框选对话引用卡片（框选「给小Q」或点击悬浮球挂起）
              if (_quotedChatText != null) ...[
                _buildQuotePreviewCard(theme),
                const SizedBox(height: 6),
              ],

              // 1. 豆包式附件挂载条（图片缩略图、分享的笔记、分享的待办）
              if (hasAttachments) ...[
                _buildAttachmentBar(theme),
                const SizedBox(height: 6),
              ],

              // 1.5 输入栏上方功能行：左侧常用提示词，右侧模型选择按钮
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    // 常用提示词按钮（点击弹出列表，选中即覆盖输入框）
                    GestureDetector(
                      onTap: () => showQuickPromptDialog(context, ref, (text) {
                        _inputController.text = text;
                        _inputController.selection = TextSelection.fromPosition(
                          TextPosition(offset: text.length),
                        );
                        _inputFocusNode.requestFocus();
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 15,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '常用提示词',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // 模型选择按钮（与长按发送按钮共用同一弹窗入口）
                    Flexible(
                      child: GestureDetector(
                        onTap: _openModelSelector,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.smart_toy_outlined,
                                size: 15,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  // 按钮上仅展示裸模型名，不带「内置」前缀
                                  (assistantModelDisplayName(
                                            _activeModelId,
                                            aiConfigsAsync.valueOrNull ??
                                                const <AiConfig>[],
                                          ) ??
                                          '选择模型')
                                      .replaceFirst(
                                        RegExp('^内置\\s*'),
                                        '',
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 2. 底部输入栏与操作按钮
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 附件/分享加号按钮（类似豆包）
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, right: 6),
                    child: InkWell(
                      onTap: () => _showAttachmentMenu(context, theme),
                      borderRadius: BorderRadius.circular(22),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.add_rounded,
                          size: 26,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _buildInputField(theme)),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _inputController,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      final canSend = (hasText || hasAttachments) && !busy;

                      // 小Q工作过程中：发送按钮变为中断/停止按钮，
                      // 外层环绕极简细线 LoadingRing 缺口圆环旋转动画，中央为精致圆角停止方块
                      if (busy) {
                        final isDark = theme.brightness == Brightness.dark;
                        final primary = theme.colorScheme.primary;
                        return Tooltip(
                          message: '点击中止小Q当前操作',
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                HapticFeedback.lightImpact();
                                _stopGenerating();
                              },
                              borderRadius: BorderRadius.circular(22),
                              child: Ink(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: primary.withValues(
                                    alpha: isDark ? 0.14 : 0.08,
                                  ),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: primary.withValues(
                                      alpha: isDark ? 0.22 : 0.14,
                                    ),
                                    width: 0.8,
                                  ),
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    LoadingRing(
                                      size: 32,
                                      strokeWidth: 1.3,
                                      color: primary,
                                    ),
                                    Container(
                                      width: 9.5,
                                      height: 9.5,
                                      decoration: BoxDecoration(
                                        color: primary,
                                        borderRadius: BorderRadius.circular(
                                          2.0,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      // 小Q空闲时：标准发送按钮（长按切换模型）
                      return GestureDetector(
                        onTap: canSend ? _sendMessage : null,
                        onLongPress: () {
                          HapticFeedback.mediumImpact();
                          _openModelSelector();
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: canSend
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              Icons.send_rounded,
                              size: 22,
                              color: canSend
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 引用卡片：展示框选「给小Q」或点击悬浮球引用的对话片段
  Widget _buildQuotePreviewCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.format_quote_rounded,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '引用对话：$_quotedChatText',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => setState(() => _quotedChatText = null),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentBar(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 64),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 已选图片缩略图
            ..._attachedImages.map((imgPath) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: UnifiedImage(
                          imagePath: imgPath,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedImages.remove(imgPath);
                          });
                        },
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),

            // 已选分享日记
            ..._attachedJournalIds.map((jId) {
              final title = _journalTitles[jId] ?? '日记';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.auto_stories_outlined,
                        size: 14,
                        color: Color(0xFFE91E63),
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedJournalIds.remove(jId);
                          });
                        },
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 已选分享笔记
            ..._attachedNoteIds.map((noteId) {
              final title = _noteTitles[noteId] ?? '笔记';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedNoteIds.remove(noteId);
                          });
                        },
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 已选分享待办
            ..._attachedTodoIds.map((todoId) {
              final title = _todoTitles[todoId] ?? '待办';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_box_outlined,
                        size: 14,
                        color: theme.colorScheme.secondary,
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedTodoIds.remove(todoId);
                          });
                        },
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 继续添加小卡片按钮
            InkWell(
              onTap: () => _showAttachmentMenu(context, theme),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.4,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 2),
                    Text(
                      '添加',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 物理键盘 Enter 拦截：无 Shift 即发送，Shift+Enter 放行默认换行。
  /// 软键盘行为由 textInputAction:newline 交给 IME（移动端发送一律点按钮）；
  /// 返回 handled 后 engine 不再把 Enter 送入文本输入通道，避免发送与换行叠加
  KeyEventResult _handleEnterKey(FocusNode node, KeyEvent event) {
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _sendMessage();
    return KeyEventResult.handled;
  }

  Widget _buildInputField(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 120),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Focus(
            onKeyEvent: _handleEnterKey,
            child: TextField(
              controller: _inputController,
              focusNode: _inputFocusNode,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                filled: false,
                hintText: '输入问题',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: EdgeInsets.only(
                  left: 16,
                  top: 10,
                  bottom: 10,
                  right: 42,
                ),
              ),
              // 软键盘回车键为「换行」，发送一律点右侧按钮；
              // 桌面/Web 物理回车在 _handleEnterKey 拦截发送，Shift+Enter 换行
              textInputAction: TextInputAction.newline,
            ),
          ),
          Positioned(
            right: 6,
            bottom: 4,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _inputController,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _inputController.clear();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withValues(
                            alpha: 0.85,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.error.withValues(
                                alpha: 0.25,
                              ),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryDrawer(
    AsyncValue<List<ChatSession>> sessionsAsync,
    String? activeId,
    ThemeData theme,
  ) {
    return Drawer(
      child: sessionsAsync.when(
        data: (sessions) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '对话历史',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (sessions.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.grid_view,
                              size: 18,
                              color: _isBatchMode
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            onPressed: () {
                              setState(() {
                                _isBatchMode = !_isBatchMode;
                                if (!_isBatchMode) _selectedSessionIds = [];
                              });
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: !_isBatchMode
                    ? SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新建对话'),
                          onPressed: () async {
                            final session = await ref
                                .read(chatSessionListProvider.notifier)
                                .createSession();
                            ref
                                .read(currentChatProvider.notifier)
                                .setSession(session);
                            if (!mounted) return;
                            Navigator.pop(context);
                          },
                        ),
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                setState(() {
                                  _selectedSessionIds =
                                      _selectedSessionIds.length ==
                                          sessions.length
                                      ? []
                                      : sessions.map((s) => s.id).toList();
                                });
                              },
                              child: Text(
                                _selectedSessionIds.length == sessions.length
                                    ? '取消全选'
                                    : '全选',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                              ),
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('确认'),
                                    content: const Text('确定要清空所有对话吗？'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('确定'),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok == true) {
                                  for (final s in sessions) {
                                    await ref
                                        .read(chatSessionListProvider.notifier)
                                        .deleteSession(s.id);
                                  }
                                  ref
                                      .read(currentChatProvider.notifier)
                                      .setSession(null);
                                  setState(() {
                                    _isBatchMode = false;
                                    _selectedSessionIds = [];
                                  });
                                }
                              },
                              child: const Text('清空全部'),
                            ),
                          ),
                        ],
                      ),
              ),
              const Divider(height: 1),
              Expanded(
                child: sessions.isEmpty
                    ? const EmptyStateWidget(
                        icon: Icons.chat_bubble_outline,
                        message: '暂无对话',
                      )
                    : ListView.builder(
                        itemCount: sessions.length,
                        itemBuilder: (ctx, i) => _buildSessionTile(
                          sessions[i],
                          sessions[i].id == activeId,
                          theme,
                        ),
                      ),
              ),
              if (_isBatchMode && _selectedSessionIds.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text('删除已选 (${_selectedSessionIds.length})'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                      ),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('确认'),
                            content: Text(
                              '确定要删除选中的 ${_selectedSessionIds.length} 个对话吗？',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('确定'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          for (final id in _selectedSessionIds) {
                            await ref
                                .read(chatSessionListProvider.notifier)
                                .deleteSession(id);
                          }
                          final currentId = ref.read(currentChatProvider)?.id;
                          if (currentId != null &&
                              _selectedSessionIds.contains(currentId)) {
                            ref
                                .read(currentChatProvider.notifier)
                                .setSession(null);
                          }
                          setState(() {
                            _selectedSessionIds = [];
                            _isBatchMode = false;
                          });
                        }
                      },
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Widget _buildSessionTile(
    ChatSession session,
    bool isActive,
    ThemeData theme,
  ) {
    final isSelected = _selectedSessionIds.contains(session.id);
    // 该会话的小Q任务是否正在生成：列表项转圈 + 「生成中」副标题提示
    final isRunning = ref.watch(
      agentRunningSessionsProvider.select((s) => s.contains(session.id)),
    );
    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: theme.colorScheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('确认'),
                content: const Text('确定要删除这个对话吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) {
        ref.read(chatSessionListProvider.notifier).deleteSession(session.id);
        if (ref.read(currentChatProvider)?.id == session.id) {
          ref.read(currentChatProvider.notifier).setSession(null);
        }
      },
      child: ListTile(
        leading: _isBatchMode
            ? Checkbox(
                value: isSelected,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedSessionIds = [
                        ..._selectedSessionIds,
                        session.id,
                      ];
                    } else {
                      _selectedSessionIds = _selectedSessionIds
                          .where((id) => id != session.id)
                          .toList();
                    }
                  });
                },
              )
            : isRunning
            ? LoadingRing(
                size: 16,
                strokeWidth: 1.8,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              )
            : Icon(
                Icons.chat_bubble_outline,
                size: 16,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: isActive ? theme.colorScheme.primary : null,
          ),
        ),
        subtitle: Text(
          isRunning && !_isBatchMode
              ? '小Q生成中…'
              : DateFormat('MM/dd HH:mm').format(session.updatedAt),
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: !_isBatchMode
            ? IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: () async {
                  await ref
                      .read(chatSessionListProvider.notifier)
                      .deleteSession(session.id);
                  if (ref.read(currentChatProvider)?.id == session.id) {
                    ref.read(currentChatProvider.notifier).setSession(null);
                  }
                },
              )
            : null,
        selected: isActive && !_isBatchMode,
        onTap: () {
          if (_isBatchMode) {
            setState(() {
              if (isSelected) {
                _selectedSessionIds = _selectedSessionIds
                    .where((id) => id != session.id)
                    .toList();
              } else {
                _selectedSessionIds = [..._selectedSessionIds, session.id];
              }
            });
          } else {
            ref.read(currentChatProvider.notifier).setSession(session);
            Navigator.pop(context);
          }
        },
      ),
    );
  }
}

class _StreamingBubble extends ConsumerWidget {
  final bool isFirstInGroup;
  final bool isLastInGroup;

  const _StreamingBubble({
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamingContent = ref.watch(aiStreamingMessageProvider);
    // 正文与阶段性状态互斥展示：优先正文；正文未到时展示状态行（思考中/准备中…）
    final hasContent =
        streamingContent != null && streamingContent.trim().isNotEmpty;
    final statusText = hasContent ? null : ref.watch(aiStreamingStatusProvider);
    // 正文流式输出时本身在持续增长，无需已用时计时
    final statusStartedAt = hasContent
        ? null
        : ref.watch(aiStreamingStartedAtProvider);
    return ChatBubble(
      message: ChatMessage(
        role: 'assistant',
        content: streamingContent ?? '',
        timestamp: DateTime.now(),
      ),
      statusText: statusText,
      statusStartedAt: statusStartedAt,
      isFirstInGroup: isFirstInGroup,
      isLastInGroup: isLastInGroup,
    );
  }
}

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  /// 流式占位的阶段性状态文案（非 null 即占位模式），与正文互斥展示
  final String? statusText;

  /// 本轮任务的开始时间，状态行尾部显示「已用时」递增计数
  final DateTime? statusStartedAt;
  final bool isFirstInGroup;
  final bool isLastInGroup;

  /// 步数上限消息的操作回调（非 null 且待处理时在气泡下方渲染「继续/暂停」按钮）
  final VoidCallback? onContinue;
  final VoidCallback? onPause;

  /// 按钮是否可点（Agent 执行中禁用，防止并发任务）
  final bool actionsEnabled;

  const ChatBubble({
    required this.message,
    this.statusText,
    this.statusStartedAt,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.onContinue,
    this.onPause,
    this.actionsEnabled = false,
  });

  /// 是否为待处理的步数上限消息（渲染「继续/暂停」按钮）
  bool get _isTurnLimitPending =>
      message.uiDetails?['type'] == 'turn_limit' &&
      message.uiDetails?['handled'] != true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    // 实例字段的空安全提升不跨闭包生效，局部变量化供下方 builder 内使用
    final statusText = this.statusText;

    // 该消息是否还有可渲染的主体（正文 / 思考过程 / 工具卡片）
    final hasRenderableBody =
        message.content.trim().isNotEmpty ||
        (message.thought?.trim().isNotEmpty ?? false) ||
        message.role == 'tool' ||
        message.role == 'tool_group' ||
        message.uiDetails != null;

    // 正文为空的助手消息属于工具调用中转（列表层已过滤），这里再兜一层；
    // 只有流式占位气泡（statusText 阶段）才允许退化成「正在输入」动画。
    if (!isUser && statusText == null && !hasRenderableBody) {
      return const SizedBox.shrink();
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AppDurations.medium,
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 20),
            child: child,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // Avatar and sender name header - 仅当同组第一条消息时显示，同一回复多条消息避免重复显示头像
          if (isFirstInGroup)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isUser) ...[
                    const QAvatar(size: 24, withBackground: true),
                    const SizedBox(width: 6),
                    Text(
                      '小Q',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ] else ...[
                    Text(
                      'You',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          // Bubble container
          Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: isUser ? null : double.infinity,
              margin: EdgeInsets.only(bottom: isLastInGroup ? 16 : 4),
              padding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: isUser ? 10 : 12,
              ),
              constraints: BoxConstraints(
                maxWidth: isUser
                    ? MediaQuery.of(context).size.width * 0.82
                    : double.infinity,
              ),
              decoration: BoxDecoration(
                color: isUser
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: isUser
                      ? const Radius.circular(16)
                      : const Radius.circular(4),
                  bottomRight: isUser
                      ? const Radius.circular(4)
                      : const Radius.circular(16),
                ),
                border: isUser
                    ? null
                    : Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                        width: 1,
                      ),
                boxShadow: isUser
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: isUser
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.images != null &&
                            message.images!.isNotEmpty)
                          _buildImagesGrid(context, message.images!),
                        if (message.content.isNotEmpty)
                          Text(
                            message.content,
                            style: TextStyle(
                              color: theme.colorScheme.onPrimary,
                              fontSize: 14,
                            ),
                          ),
                      ],
                    )
                  : statusText != null
                  ? // 阶段性状态行：弱化色文案 + 逐点渐显的动态省略号，替代原先文本下方的闪烁光标；
                    // 下方挂实时思考区（模型返回 reasoning_content 时滚动展示思考过程）
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Flexible(
                                child: Text(
                                  statusText,
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontSize: 14,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                              // 思考中采用形变无限符号动画，流动生命力替代三个跳动圆点
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  right: 6,
                                ),
                                child: MorphingInfinity(
                                  size: 21,
                                  strokeWidth: 1.5,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              // 已用时递增计数：长任务期间传达"仍在推进，没有卡住"
                              Padding(
                                padding: const EdgeInsets.only(left: 2),
                                child: StreamingElapsedText(
                                  startedAt: statusStartedAt,
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const _LiveThoughtView(),
                      ],
                    )
                  : !hasRenderableBody
                  ? const MorphingInfinity()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 思考过程展示（若有，折叠在单行流水中滚动展示，点击可展开完整内容）
                        if (message.thought != null &&
                            message.thought!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _ThoughtProcessView(
                              thought: message.thought!.trim(),
                            ),
                          ),

                        // 连续工具聚合卡片或单工具执行反馈卡片
                        if (message.role == 'tool_group')
                          ToolChainGroupWidget(
                            toolMessages:
                                (message.uiDetails?['messages']
                                        as List<ChatMessage>?) ??
                                    const [],
                            theme: theme,
                          )
                        else if (message.role == 'tool')
                          buildToolFeedback(context, message, theme)
                        else ...[
                          MarkdownBody(
                            data: message.content,
                            selectable: false,
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 14,
                                height: 1.5,
                              ),
                              h1: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                height: 1.6,
                              ),
                              h2: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                height: 1.5,
                              ),
                              h3: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                height: 1.4,
                              ),
                              code: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                color: theme.colorScheme.primary,
                                backgroundColor: Colors.transparent,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              blockquoteDecoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLow,
                                border: Border(
                                  left: BorderSide(
                                    color: theme.colorScheme.primary,
                                    width: 4,
                                  ),
                                ),
                                borderRadius: const BorderRadius.horizontal(
                                  right: Radius.circular(6),
                                ),
                              ),
                              blockquotePadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              listBullet: TextStyle(
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
          // 步数上限提示：待处理时在气泡下方渲染「继续/暂停」按钮
          if (!isUser && _isTurnLimitPending)
            AgentTurnLimitActions(
              onContinue: onContinue,
              onPause: onPause,
              enabled: actionsEnabled,
            ),
        ],
      ),
    );
  }

  /// 构建工具调用执行反馈与小Q确认交互卡片
  static Widget buildToolFeedback(
    BuildContext context,
    ChatMessage message,
    ThemeData theme,
  ) {
    final uiDetails = message.uiDetails;
    final isAskUser =
        message.toolName == 'ask_user' || uiDetails?['type'] == 'ask_user';

    if (isAskUser) {
      final question = uiDetails?['question'] as String? ?? message.content;
      final status = uiDetails?['status'] as String?;
      final choice = uiDetails?['choice'] as String?;
      final isConfirmed = status == 'confirmed';
      final isCancelled = status == 'cancelled';

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCancelled
                ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5)
                : theme.colorScheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.help_outline_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '小Q确认交互',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const Spacer(),
                if (isConfirmed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check, size: 12, color: Colors.green),
                        const SizedBox(width: 4),
                        Text(
                          choice != null ? '已选择: $choice' : '已确认',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (isCancelled)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.3,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.close,
                          size: 12,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '已取消',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            MarkdownBody(
              data: question,
              selectable: false,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // generate_image 生图完成：气泡内直接大图预览，附模型与提示词摘要
    if (message.toolName == 'generate_image' && message.isError != true) {
      final paths =
          (uiDetails?['paths'] as List?)?.whereType<String>().toList() ??
          const [];
      final model = uiDetails?['model'] as String? ?? '';
      final prompt = uiDetails?['prompt'] as String? ?? '';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  model.isEmpty ? '生图完成' : '生图完成 · $model',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...paths.map(
              (path) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: () => _showFullImageDialog(context, path),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: UnifiedImage(imagePath: path, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
            ),
            if (prompt.isNotEmpty)
              Text(
                prompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      );
    }

    // view_image 成功时图片已注入模型上下文，气泡里显示缩略图与路径摘要；失败走通用错误卡片
    if (message.toolName == 'view_image' && message.isError != true) {
      final path = uiDetails?['path'] as String? ?? '';
      final sizeKB = uiDetails?['sizeKB'];
      final sizeHint = sizeKB is int && sizeKB > 0 ? '（约 $sizeKB KB）' : '';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: path.isEmpty
                  ? null
                  : () => _showFullImageDialog(context, path),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: UnifiedImage(imagePath: path, fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '已查看图片 $path$sizeHint',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // skill 工具加载手册过长，只显示调用的技能名与章节胶囊，支持点击查看完整手册，不占主消息流空间
    if (message.toolName == 'skill') {
      final isError = message.isError == true;
      final name = uiDetails?['name'] as String? ?? '';
      final section = uiDetails?['section'] as String?;
      final rawSkills = uiDetails?['skills'];
      final skillsList = rawSkills is List
          ? rawSkills.map((e) => e.toString()).toList()
          : null;

      if (isError) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.error.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 14,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message.content.trim().isNotEmpty
                      ? message.content.trim()
                      : '调用技能失败',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      // 查看所有可用技能列表时的紧凑条
      if (skillsList != null) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome,
                size: 14,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已查看可用技能列表 (共 ${skillsList.length} 个)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
              if (message.content.trim().isNotEmpty) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _showSkillHandbookDialog(
                    context,
                    '可用技能列表',
                    message.content,
                  ),
                  child: Text(
                    '查看',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      }

      final skillTitle = name.isEmpty ? '技能手册' : name;
      final sectionHint =
          (section != null && section.trim().isNotEmpty) ? ' · $section' : '';

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 14,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '已调用技能手册 · $skillTitle$sectionHint',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (message.content.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _showSkillHandbookDialog(
                  context,
                  skillTitle,
                  message.content,
                ),
                child: Text(
                  '查看',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // read_file 返回的文件正文过长，气泡里只显示路径摘要与预览按钮，错误时展示错误卡片
    if (message.toolName == 'read_file') {
      final isError = message.isError == true;
      final path = uiDetails?['path'] as String? ?? '';
      if (isError) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.error.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 14,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message.content.trim().isNotEmpty
                      ? message.content.trim()
                      : (path.isNotEmpty ? '读取文件失败: $path' : '读取文件失败'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      final displayPath = path.isNotEmpty ? path : '文件';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 14,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '已读取文件 $displayPath',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
            if (message.content.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _showFilePreviewDialog(
                  context,
                  displayPath,
                  message.content,
                ),
                child: Text(
                  '预览',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // list_dir 目录遍历结果折叠展示，防止几十条条目拉长屏幕
    if (message.toolName == 'list_dir') {
      return _DirectoryFeedbackWidget(message: message, theme: theme);
    }

    // grep 全局检索结果折叠展示
    if (message.toolName == 'grep') {
      return _GrepFeedbackWidget(message: message, theme: theme);
    }

    // fetch_url 返回的网页正文过长，气泡里只显示标题摘要，点击可打开原网页
    if (message.toolName == 'fetch_url') {
      final url = uiDetails?['url'] as String? ?? '';
      final title = (uiDetails?['title'] as String? ?? '').trim();
      final hasError = message.isError == true;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasError ? Icons.link_off : Icons.language,
              size: 14,
              color: hasError
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title.isEmpty ? '已读取网页 $url' : '已读取网页：$title',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
            // 点击卡片用系统浏览器打开原网页，方便用户核对来源
            if (!hasError && url.isNotEmpty)
              GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                ),
                child: Icon(
                  Icons.open_in_new,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      );
    }

    final isError = message.isError == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isError
                ? theme.colorScheme.errorContainer.withValues(alpha: 0.4)
                : theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                size: 14,
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                AgentToolLabels.resultLabel(
                  message.toolName ?? '',
                  message.uiDetails,
                ),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: MarkdownBody(
              data: message.content,
              selectable: false,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 14,
                  height: 1.5,
                ),
                h1: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  height: 1.6,
                ),
                h2: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  height: 1.5,
                ),
                h3: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                ),
                code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: theme.colorScheme.primary,
                  backgroundColor: Colors.transparent,
                ),
                codeblockDecoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
                blockquoteDecoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  border: Border(
                    left: BorderSide(color: theme.colorScheme.primary, width: 4),
                  ),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(6),
                  ),
                ),
                blockquotePadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                listBullet: TextStyle(color: theme.colorScheme.onSurface),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImagesGrid(BuildContext context, List<String> images) {
    if (images.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: () => _showFullImageDialog(context, images.first),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
              child: UnifiedImage(imagePath: images.first, fit: BoxFit.cover),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: images.map((imgPath) {
          return GestureDetector(
            onTap: () => _showFullImageDialog(context, imgPath),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 68,
                height: 68,
                child: UnifiedImage(imagePath: imgPath, fit: BoxFit.cover),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  static void _showFullImageDialog(BuildContext context, String imagePath) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              child: Center(
                child: UnifiedImage(imagePath: imagePath, fit: BoxFit.contain),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 技能手册查看弹窗：避免大段 Markdown 技能说明直接在主对话流刷屏
  static void _showSkillHandbookDialog(
    BuildContext context,
    String skillName,
    String content,
  ) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '技能手册 · $skillName',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const Divider(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: MarkdownBody(
                      data: content,
                      selectable: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 文件内容预览弹窗：点击「预览」按钮按需查看，避免正文长篇大论挤占对话空间
  static void _showFilePreviewDialog(
    BuildContext context,
    String filePath,
    String content,
  ) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '文件预览 · $filePath',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const Divider(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: theme.colorScheme.onSurface,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 目录列表折叠反馈组件：条目较多时默认折叠，显示前 3 项与总计，支持平滑展开和内滚动
class _DirectoryFeedbackWidget extends StatefulWidget {
  final ChatMessage message;
  final ThemeData theme;

  const _DirectoryFeedbackWidget({
    required this.message,
    required this.theme,
  });

  @override
  State<_DirectoryFeedbackWidget> createState() =>
      _DirectoryFeedbackWidgetState();
}

class _DirectoryFeedbackWidgetState extends State<_DirectoryFeedbackWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final message = widget.message;
    final isError = message.isError == true;
    final uiDetails = message.uiDetails;
    final path = uiDetails?['path'] as String? ?? '';
    final rawItems = uiDetails?['items'];
    final items = rawItems is List
        ? rawItems.map((e) => e.toString()).toList()
        : null;

    if (isError) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message.content.trim().isNotEmpty
                    ? message.content.trim()
                    : '查看目录失败',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final totalCount = items?.length ??
        message.content
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .length;
    final displayList = items ??
        message.content
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();

    final pathHint = path.isNotEmpty ? path : '/';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部胶囊：目录路径 + 条目总数 + 展开/收起按钮
          InkWell(
            onTap: totalCount == 0
                ? null
                : () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_open_outlined,
                    size: 15,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      totalCount == 0
                          ? '已查看目录 $pathHint (空目录)'
                          : '已查看目录 $pathHint (共 $totalCount 项)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  if (totalCount > 0) ...[
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _isExpanded ? 0.5 : 0,
                      duration: AppDurations.normal,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 展开内容区：当条目数较多时提供带滚动的列表
          if (_isExpanded && displayList.isNotEmpty) ...[
            const Divider(height: 1),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: displayList.map((item) {
                    final isDir = item.endsWith('/');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Icon(
                            isDir
                                ? Icons.folder_outlined
                                : Icons.insert_drive_file_outlined,
                            size: 13,
                            color: theme.colorScheme.primary.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 全局 grep 检索折叠反馈组件：命中条目过多时折叠
class _GrepFeedbackWidget extends StatefulWidget {
  final ChatMessage message;
  final ThemeData theme;

  const _GrepFeedbackWidget({
    required this.message,
    required this.theme,
  });

  @override
  State<_GrepFeedbackWidget> createState() => _GrepFeedbackWidgetState();
}

class _GrepFeedbackWidgetState extends State<_GrepFeedbackWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final message = widget.message;
    final isError = message.isError == true;
    final uiDetails = message.uiDetails;
    final query = uiDetails?['query'] as String? ?? '';
    final total = uiDetails?['total'] as int? ?? 0;

    if (isError) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message.content.trim().isNotEmpty
                    ? message.content.trim()
                    : '搜索失败',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final queryHint = query.isNotEmpty ? '「$query」' : '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: total == 0
                ? null
                : () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search_rounded,
                    size: 15,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      total == 0
                          ? '搜索笔记 $queryHint (未找到匹配)'
                          : '搜索笔记 $queryHint (共 $total 条匹配)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  if (total > 0) ...[
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _isExpanded ? 0.5 : 0,
                      duration: AppDurations.normal,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_isExpanded && message.content.trim().isNotEmpty) ...[
            const Divider(height: 1),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(10),
              child: SingleChildScrollView(
                child: MarkdownBody(
                  data: message.content,
                  selectable: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 连续工具调用链（多步操作）聚合折叠组件：
/// 当 Agent 连续执行多项工具操作（如连续 read_file、list_dir 等）时，
/// 聚合成一个「执行步骤」折叠面板，折叠态只占一行，展开后呈现紧凑步骤清单。
class ToolChainGroupWidget extends StatefulWidget {
  final List<ChatMessage> toolMessages;
  final ThemeData theme;

  const ToolChainGroupWidget({
    required this.toolMessages,
    required this.theme,
  });

  @override
  State<ToolChainGroupWidget> createState() => _ToolChainGroupWidgetState();
}

class _ToolChainGroupWidgetState extends State<ToolChainGroupWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final messages = widget.toolMessages;
    final totalCount = messages.length;
    final hasError = messages.any((m) => m.isError == true);

    // 统计工具类型分布，如「读取文件 3 个、查看目录 1 次」
    final countsByType = <String, int>{};
    for (final m in messages) {
      final name = m.toolName ?? '操作';
      countsByType[name] = (countsByType[name] ?? 0) + 1;
    }

    final summarySegments = <String>[];
    countsByType.forEach((toolName, count) {
      final label = AgentToolLabels.resultLabel(toolName);
      summarySegments.add('$label $count 项');
    });
    final summaryText = summarySegments.join('、');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: hasError
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.18)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasError
              ? theme.colorScheme.error.withValues(alpha: 0.3)
              : theme.colorScheme.primary.withValues(alpha: 0.22),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部总览条：点击展开/折叠全部步骤
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    hasError ? Icons.error_outline : Icons.task_alt_rounded,
                    size: 15,
                    color: hasError
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已连续完成 $totalCount 步操作 · $summaryText',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: hasError
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: AppDurations.normal,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开状态：逐条紧凑渲染每一个工具的专属反馈卡
          if (_isExpanded) ...[
            const Divider(height: 1),
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < messages.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 8, right: 6),
                              child: Container(
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.12,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: ChatBubble.buildToolFeedback(
                                context,
                                messages[i],
                                theme,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  final bool isFirstInGroup;
  final bool isLastInGroup;

  const _TypingBubble({this.isFirstInGroup = true, this.isLastInGroup = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isFirstInGroup)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const QAvatar(size: 24, withBackground: true),
                const SizedBox(width: 6),
                Text(
                  '小Q',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: EdgeInsets.only(bottom: isLastInGroup ? 16 : 4),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: MorphingInfinity(
              size: 26,
              strokeWidth: 1.6,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 思考过程展示：折叠态呈现简洁的「思考过程」标签胶囊（不滚动文字），点击平滑展开查看完整思考富文本
class _ThoughtProcessView extends StatefulWidget {
  final String thought;

  const _ThoughtProcessView({required this.thought});

  @override
  State<_ThoughtProcessView> createState() => _ThoughtProcessViewState();
}

class _ThoughtProcessViewState extends State<_ThoughtProcessView> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedSize(
      duration: AppDurations.medium,
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.18),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部单行胶囊栏：静态标签 + 展开箭头（不再滚动显示思考文字）
                  Row(
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        size: 15,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '思考过程',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const Spacer(),
                      AnimatedRotation(
                        turns: _isExpanded ? 0.5 : 0,
                        duration: AppDurations.normal,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  // 展开态：完整富文本思考过程（支持长文本内部滚动）
                  if (_isExpanded) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 220),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          widget.thought,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.55,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.9,
                            ),
                            fontStyle: FontStyle.italic,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「思考中」状态卡内的实时思考区：模型思考增量（reasoning_content）限高滚动展示，
/// 视觉沿用 [_ThoughtProcessView] 的胶囊语言，滚动与贴底跟随由 [ThoughtTailScrollView] 承担
class _LiveThoughtView extends ConsumerWidget {
  const _LiveThoughtView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thought = ref.watch(aiStreamingThoughtProvider);
    if (thought == null || thought.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: AppDurations.fast,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.18),
            ),
          ),
          child: ThoughtTailScrollView(
            text: thought.trim(),
            maxHeight: 96,
            textStyle: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ),
    );
  }
}

class _MultiNoteSelectorDialog extends StatefulWidget {
  final List<Note> notes;
  final List<String> initialSelected;
  const _MultiNoteSelectorDialog({
    required this.notes,
    required this.initialSelected,
  });

  @override
  State<_MultiNoteSelectorDialog> createState() =>
      _MultiNoteSelectorDialogState();
}

class _MultiNoteSelectorDialogState extends State<_MultiNoteSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected =
        _selected.length == widget.notes.length && widget.notes.isNotEmpty;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('选择笔记'),
          if (widget.notes.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selected.clear();
                  } else {
                    _selected = widget.notes.map((n) => n.id).toList();
                  }
                });
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(
                isAllSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.notes.isEmpty
            ? const Center(child: Text('暂无笔记'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.notes.length,
                itemBuilder: (ctx, i) {
                  final note = widget.notes[i];
                  final isSelected = _selected.contains(note.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      DateFormat('MM/dd HH:mm').format(note.updatedAt),
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(note.id);
                        } else {
                          _selected.remove(note.id);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: Text('确定 (${_selected.length})'),
        ),
      ],
    );
  }
}

class _MultiTodoSelectorDialog extends StatefulWidget {
  final List<Todo> todos;
  final List<String> initialSelected;
  const _MultiTodoSelectorDialog({
    required this.todos,
    required this.initialSelected,
  });

  @override
  State<_MultiTodoSelectorDialog> createState() =>
      _MultiTodoSelectorDialogState();
}

class _MultiTodoSelectorDialogState extends State<_MultiTodoSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected =
        _selected.length == widget.todos.length && widget.todos.isNotEmpty;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('选择待办'),
          if (widget.todos.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selected.clear();
                  } else {
                    _selected = widget.todos.map((t) => t.id).toList();
                  }
                });
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(
                isAllSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.todos.isEmpty
            ? const Center(child: Text('暂无待办'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.todos.length,
                itemBuilder: (ctx, i) {
                  final todo = widget.todos[i];
                  final isSelected = _selected.contains(todo.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Text(
                      todo.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        decoration: todo.isCompleted
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      todo.isCompleted ? '已完成' : '未完成',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(todo.id);
                        } else {
                          _selected.remove(todo.id);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _MultiJournalSelectorDialog extends StatefulWidget {
  final List<Note> journals;
  final List<String> initialSelected;
  const _MultiJournalSelectorDialog({
    required this.journals,
    required this.initialSelected,
  });

  @override
  State<_MultiJournalSelectorDialog> createState() =>
      _MultiJournalSelectorDialogState();
}

class _MultiJournalSelectorDialogState
    extends State<_MultiJournalSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected =
        _selected.length == widget.journals.length &&
        widget.journals.isNotEmpty;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('选择日记'),
          if (widget.journals.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selected.clear();
                  } else {
                    _selected = widget.journals.map((j) => j.id).toList();
                  }
                });
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(
                isAllSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.journals.isEmpty
            ? const Center(child: Text('暂无日记'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.journals.length,
                itemBuilder: (ctx, i) {
                  final journal = widget.journals[i];
                  final isSelected = _selected.contains(journal.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Row(
                      children: [
                        const Icon(
                          Icons.auto_stories_outlined,
                          size: 16,
                          color: Color(0xFFE91E63),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${journal.title} 日记',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        journal.content.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(journal.id);
                        } else {
                          _selected.remove(journal.id);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: Text('确定 (${_selected.length})'),
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/utils/chat_reedit.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/widgets/ai/agent_turn_limit_actions.dart';
import 'package:qnote_flutter/widgets/ai/assistant_model_sheet.dart';
import 'package:qnote_flutter/widgets/ai/auto_read_toggle_button.dart';
import 'package:qnote_flutter/widgets/ai/bubble_action_bar.dart';
import 'package:qnote_flutter/widgets/ai/chat_history_drawer.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/ai/user_bubble_reedit_tap.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';
import 'package:qnote_flutter/widgets/common/streaming_elapsed_text.dart';
import 'package:qnote_flutter/widgets/common/thinking_process_view.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/agent/services/q_text_quote.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/utils/chat_image_dedupe.dart';
import 'package:qnote_flutter/widgets/ai/q_input_command_panels.dart';
import 'package:qnote_flutter/widgets/ai/quick_prompt_dialog.dart';
import 'package:qnote_flutter/widgets/chat/chat_image_view.dart';
import 'package:qnote_flutter/widgets/q_text_selection_toolbar.dart';

part 'ai_chat_bubble.dart';
part 'ai_tool_feedback.dart';
part 'ai_selector_dialogs.dart';

class AiPage extends ConsumerStatefulWidget {
  const AiPage({super.key});

  @override
  ConsumerState<AiPage> createState() => _AiPageState();
}

class _AiPageState extends ConsumerState<AiPage> {
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  double _lastBottomInset = 0.0;
  // 键盘动画中间帧的贴底校准定时器（见 build 内 inset 监听）
  Timer? _insetScrollDebounce;

  bool _isTyping = false;
  AiModelRef? _activeModelId;

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

  // 再次编辑态：被点中的那条提问在会话态里的下标，null 表示不在编辑态。
  // 进入编辑态只回填输入框，撤回（删除该轮并撤销数据修改）推迟到点发送才做。
  int? _reeditIndex;

  // 进入编辑态时的消息对象引用：ChatMessage 无主键，只能靠 identical 认人，
  // 防止会话被重载或后面又冒出新提问后，仍按老下标撤回错的那一轮
  ChatMessage? _reeditAnchor;

  // 回填瞬间的输入区快照：据此区分「原样回填没动过」与「用户自己新写的草稿」
  ReeditDraft? _reeditDraftSnapshot;

  // 回填与撤回共用的忙窗口：期间不得再触发第二次进入或发送
  bool _reeditBusy = false;

  // 会话消息派生结果缓存：时间线、生图去重键、可再次编辑下标都是 O(消息数) 的纯计算，
  // 流式输出/键盘 inset 等会让页面频繁重建，只要消息列表引用没换就直接复用，
  // 避免每次重建都把整段历史重扫一遍。provider 增删消息都会生成新 List，
  // 因此用 identical 比较列表引用即可判定内容是否变化。
  List<ChatMessage>? _cacheSource;
  List<ChatTimelineEntry>? _cachedTimeline;
  Set<String>? _cachedImageKeys;
  // null 既可能是「还没算」也可能是「算出来就是 null」，有效性统一由 _cacheSource 判定
  int? _cachedReeditIndex;

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
    // 用户资料默认懒加载（仅在个人信息页打开时加载），聊天页需要主动拉一次才能显示头像/昵称
    Future.microtask(() => ref.read(userProfileNotifierProvider.notifier).load());
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
          return QTextQuote(source: QQuoteSource.chat, sourceId: '', sourceTitle: '对话内容', quotedText: text);
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
    // 输入框被清空（点了它自带的清除 X）就顺带退出编辑态：不留一个谁也看不见、
    // 却会在下次发送时撤回对话的挂起状态
    if (_reeditIndex != null && !_reeditBusy && _currentDraft().isEmpty) {
      _exitReeditMode();
    }
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
      final atBoundary = slashIdx == 0 || RegExp(r'\s').hasMatch(before[slashIdx - 1]);
      if (atBoundary && !RegExp(r'\s').hasMatch(token) && token.length <= 40) {
        slashQuery = token;
      }
    }

    String? atQuery;
    final atIdx = before.lastIndexOf('@');
    if (atIdx >= 0) {
      final token = before.substring(atIdx + 1);
      final atBoundary = atIdx == 0 || RegExp(r'\s').hasMatch(before[atIdx - 1]);
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
    final providers = await ref.read(aiProviderListProvider.future);
    final groups = await ref.read(aiRouteGroupListProvider.future);
    final bound = roles?.assistant;
    if (bound != null && isBindingUsable(bound, providers, groups)) {
      if (mounted) setState(() => _activeModelId = bound);
      return;
    }
    final provider =
        providers.where((p) => p.isDefault && p.isUsable).firstOrNull ?? providers.where((p) => p.isUsable).firstOrNull;
    final model = provider?.firstModel;
    if (model != null && mounted) {
      setState(() => _activeModelId = AiModelRef(providerId: provider!.id, modelName: model.id));
    }
  }

  /// 顶部胶囊指向的绑定若已失效（厂商/模型/路由组被删），回落到默认厂商首个模型
  void _syncActiveBindingIfStale(List<AiProvider> providers, List<AiRouteGroup> groups) {
    final current = _activeModelId;
    if (isBindingUsable(current, providers, groups)) return;
    final provider =
        providers.where((p) => p.isDefault && p.isUsable).firstOrNull ?? providers.where((p) => p.isUsable).firstOrNull;
    final model = provider?.firstModel;
    setState(() {
      _activeModelId = model == null ? null : AiModelRef(providerId: provider!.id, modelName: model.id);
    });
  }

  @override
  void dispose() {
    _insetScrollDebounce?.cancel();
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
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      if (immediate) {
        _scrollController.jumpTo(target);
      } else {
        AppMotion.animateScrollTo(_scrollController, target, context: context);
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

    if (text.isEmpty && !hasQuote && !hasImages && !hasNotes && !hasTodos && !hasJournals) {
      return;
    }
    if (_isTyping || _reeditBusy) {
      return;
    }
    // 未配置模型：先弹引导，不发消息、也不写入会话
    if (!await AiRoleService.instance.hasUsableConfigForRole('assistant')) {
      if (mounted) await showNoModelConfiguredDialog(context, scene: '小Q 对话');
      return;
    }
    if (!mounted) return;
    // 当前会话已有任务在后台生成（如切走后再切回）：拦截发送，避免同会话并发两轮任务
    final activeId = ref.read(currentChatProvider)?.id;
    if (activeId != null && ref.read(agentRunningSessionsProvider).contains(activeId)) {
      Toast.warning(context, '小Q正在处理对话，稍候或先中止');
      return;
    }

    // 斜杠命令解析：消息以「/技能名」开头时显式激活该技能（手册由 Provider 注入上下文）
    final skillName = _parseSlashCommand(text);

    final quotePrefix = hasQuote ? '【引用对话】：\n"""\n$quoteToSend\n"""\n\n' : '';
    final content = text.isNotEmpty
        ? '$quotePrefix$text'
        : (hasQuote ? '请分析我引用的这段对话内容：\n$quoteToSend' : (hasImages ? '请结合图片进行分析' : '请结合我分享的内容进行分析'));

    final imagesToSend = hasImages ? List<String>.from(_attachedImages) : null;
    final notesToSend = hasNotes ? List<String>.from(_attachedNoteIds) : null;
    final todosToSend = hasTodos ? List<String>.from(_attachedTodoIds) : null;
    final journalsToSend = hasJournals ? List<String>.from(_attachedJournalIds) : null;

    // 编辑态下点发送才是撤回时机：确认与回退全部发生在清空输入框之前，
    // 任何一步没过（用户取消、回退被拒）就原样退回，改过的字一个字都不会丢
    if (_reeditIndex != null) {
      if (!await _consumeReeditBeforeSend()) return;
      if (!mounted) return;
    }

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
        final session = await ref.read(chatSessionListProvider.notifier).createSession();
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
  // 最后一条用户提问：点击直达再次编辑
  // ==========================================

  /// 点击我最后发的那条提问：把提问完整填回输入框进入编辑态，**对话一字不动**。
  ///
  /// 撤回（删除该轮并撤销本轮数据修改）推迟到用户点发送时才做：点击本身不该是破坏性
  /// 操作，点开看一眼又改主意是常态。生成中仍要拒——那会儿列表正在长，回填的内容与
  /// 下标都会对不上。
  Future<void> _beginReedit(int stateIndex) async {
    if (_reeditBusy) return;
    if (_isTyping || ref.read(aiStreamingMessageProvider) != null || ref.read(aiStreamingStatusProvider) != null) {
      Toast.warning(context, '小Q正在生成，请稍候');
      return;
    }
    if (_draftBlocksReedit()) {
      Toast.warning(context, '输入框有草稿，清空或发送后再改');
      return;
    }

    final messages = ref.read(currentChatProvider)?.messages ?? const <ChatMessage>[];
    if (stateIndex < 0 || stateIndex >= messages.length || messages[stateIndex].role != 'user') {
      return;
    }
    final message = messages[stateIndex];
    // 已经在这条上且没动过：再点一次什么都不做，别把光标和附件条折腾一遍
    if (_reeditIndex == stateIndex && identical(_reeditAnchor, message)) return;

    await _enterReeditMode(message, stateIndex);
  }

  /// 进入编辑态：先置锚点，再把提问原样填回输入区。
  ///
  /// 不套 `_isTyping`：那个标志会把发送按钮换成停止按钮，回填的一瞬按钮乱跳；
  /// 重入由 `_reeditBusy` 挡。快照要等回填落地后再取，才知道「原样」长什么样。
  Future<void> _enterReeditMode(ChatMessage message, int index) async {
    _reeditBusy = true;
    setState(() {
      _reeditIndex = index;
      _reeditAnchor = message;
      _reeditDraftSnapshot = null;
    });
    try {
      await _refillInputFromMessage(message);
      if (!mounted) return;
      setState(() => _reeditDraftSnapshot = _currentDraft());
    } finally {
      _reeditBusy = false;
    }
  }

  /// 读出输入区当前这份待发送内容的形态。
  ReeditDraft _currentDraft() => ReeditDraft(
    text: _inputController.text,
    images: List.of(_attachedImages),
    noteIds: List.of(_attachedNoteIds),
    todoIds: List.of(_attachedTodoIds),
    journalIds: List.of(_attachedJournalIds),
    hasQuote: _quotedChatText != null && _quotedChatText!.isNotEmpty,
  );

  /// 输入框里是否躺着一份「不是本次回填」的草稿。
  ///
  /// 回填本身就会让输入框非空，若仍按「非空即拒」处理，第二次点气泡就永远点不动；
  /// 因此只拒用户自己写过的那份。
  bool _draftBlocksReedit() {
    final draft = _currentDraft();
    if (draft.isEmpty) return false;
    final snapshot = _reeditDraftSnapshot;
    return snapshot == null || !draft.matches(snapshot);
  }

  /// 发送前消费编辑态：走到这一步才真正撤回被编辑的那一轮。
  ///
  /// 返回 false 表示调用方必须原样保留输入框（用户取消、回退被拒）。
  /// 锚点已失效时不撤回、也不拦发送：编辑态当场退出，这条降级成一条普通新提问，
  /// 失败方向是「多一条」而不是「少一条」。
  Future<bool> _consumeReeditBeforeSend() async {
    final index = _reeditIndex;
    final anchor = _reeditAnchor;
    if (index == null || anchor == null) return true;

    final messages = ref.read(currentChatProvider)?.messages ?? const <ChatMessage>[];
    if (!isReeditAnchorValid(messages: messages, index: index, anchor: anchor) ||
        reeditableUserIndex(messages) != index) {
      _exitReeditMode();
      Toast.warning(context, '原提问已不在末轮，将作为新提问发送');
      return true;
    }

    // 只有真的要撤销数据修改时才拦一次确认，纯文字问答直接放行
    final changeCount = countTurnUndoChanges(messages, fromUserIndex: index);
    if (changeCount > 0) {
      final confirmed = await AppMotion.showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('撤回提问？'),
          content: Text('本轮有 $changeCount 处数据修改，发送前会先撤销。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialogCtx, true), child: const Text('撤回并发送')),
          ],
        ),
      );
      if (confirmed != true) return false;
    }
    if (!mounted) return false;

    // 复用生成中状态禁用输入区，防止回退与随后发送之间插入新消息
    _reeditBusy = true;
    setState(() => _isTyping = true);
    try {
      final result = await ref.read(currentChatProvider.notifier).rollbackToMessage(index);
      if (!mounted) return false;
      if (result == null) {
        Toast.error(context, '无法重新编辑');
        return false;
      }
      // 回退后该下标已越界，必须当场消费掉编辑态，否则后续路径会按错下标再撤一次
      _exitReeditMode();
      final (restored, failed) = result;
      if (failed > 0) {
        Toast.warning(context, '已回退对话，$failed 处数据恢复失败，详见日志');
      } else if (restored > 0) {
        Toast.success(context, '已回退对话，恢复 $restored 处数据');
      }
      return true;
    } finally {
      _reeditBusy = false;
      if (mounted) setState(() => _isTyping = false);
    }
  }

  /// 退出编辑态：挂起的撤回归口随之作废，输入框里的草稿原样留着（降级成普通草稿）。
  ///
  /// 幂等——`_onInputChanged`、发送链路与会话切换三处都会调它。
  void _exitReeditMode() {
    if (_reeditIndex == null) return;
    setState(() {
      _reeditIndex = null;
      _reeditAnchor = null;
      _reeditDraftSnapshot = null;
    });
  }

  /// 会话流变化后校验编辑态是否还成立：切了会话、或那条提问已被换掉/已不在末轮，
  /// 就退出编辑态，输入框里的草稿留着不动（降级成一条普通草稿）。
  ///
  /// 编辑态与撤回下标是绑死的一对，放着不管，下一次发送就会按错下标删对话。
  void _invalidateReeditIfNeeded(ChatSession? session) {
    final index = _reeditIndex;
    final anchor = _reeditAnchor;
    if (index == null || anchor == null || _reeditBusy) return;
    final messages = session?.messages ?? const <ChatMessage>[];
    if (!isReeditAnchorValid(messages: messages, index: index, anchor: anchor) ||
        reeditableUserIndex(messages) != index) {
      _exitReeditMode();
    }
  }

  // ==========================================
  // 失败气泡长按操作：重试本轮对话 / 复制错误详情
  // ==========================================

  /// 长按失败气泡弹出的操作菜单；[stateIndex] 为该消息在会话态中的真实下标。
  /// 仅当失败气泡是会话最后一条时提供重试，避免回退误删其后已发生的新对话。
  void _showErrorAssistantActions(int stateIndex, ChatMessage message) {
    if (_isTyping || ref.read(aiStreamingMessageProvider) != null || ref.read(aiStreamingStatusProvider) != null) {
      Toast.warning(context, '小Q正在生成，请稍候');
      return;
    }

    final messages = ref.read(currentChatProvider)?.messages ?? const <ChatMessage>[];
    final canRetry = stateIndex == messages.length - 1;

    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                if (canRetry)
                  ListTile(
                    leading: const Icon(Icons.refresh_rounded, size: 22),
                    title: const Text('重试本轮对话', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('回退本轮并撤销数据修改，再重新发送上一条', style: TextStyle(fontSize: 12)),
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
    final messages = ref.read(currentChatProvider)?.messages ?? const <ChatMessage>[];
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
    final changeCount = countTurnUndoChanges(messages, fromUserIndex: userIndex);
    if (changeCount > 0) {
      final confirmed = await AppMotion.showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('重试本轮对话？'),
          content: Text('本轮有 $changeCount 处数据修改，重试前会先撤销。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialogCtx, true), child: const Text('重试')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    // 引用附件的 id 与「再次编辑」回填共用同一份解析，落库格式因此只有一个读取口
    final refs = ChatAttachmentRefs.fromMessage(userMessage);

    // 复用生成中状态禁用输入区，防止回退与重发期间插入新消息
    setState(() => _isTyping = true);
    _scrollToBottom();
    try {
      final result = await ref.read(currentChatProvider.notifier).rollbackToMessage(userIndex);
      if (!mounted) return;
      if (result == null) {
        Toast.error(context, '无法重试');
        return;
      }
      await ref
          .read(currentChatProvider.notifier)
          .sendMessage(
            userMessage.content,
            images: userMessage.images,
            noteIds: refs.noteIds,
            todoIds: refs.todoIds,
            journalIds: refs.journalIds,
            skillName: _parseSlashCommand(userMessage.content),
          );
    } finally {
      if (mounted) {
        setState(() => _isTyping = false);
        _scrollToBottom();
      }
    }
  }

  /// 把被回退的提问完整填回输入区：正文、图片、日记/笔记/待办引用一并还原。
  ///
  /// 标题必须按 id 回查：附件条的标题缓存只在打开选择弹窗时填充、不落库，冷启动后是空的，
  /// 不补标题 chip 就只剩「日记/笔记/待办」这类类型名，用户无从确认拿回来的是哪几条。
  Future<void> _refillInputFromMessage(ChatMessage message) async {
    final refs = ChatAttachmentRefs.fromMessage(message);
    final titles = await resolveAttachmentTitles(refs);
    if (!mounted) return;

    final text = message.content;
    setState(() {
      _journalTitles.addAll(titles.journals);
      _noteTitles.addAll(titles.notes);
      _todoTitles.addAll(titles.todos);
      _attachedJournalIds
        ..clear()
        ..addAll(refs.journalIds ?? const []);
      _attachedNoteIds
        ..clear()
        ..addAll(refs.noteIds ?? const []);
      _attachedTodoIds
        ..clear()
        ..addAll(refs.todoIds ?? const []);
      _attachedImages
        ..clear()
        ..addAll(message.images ?? const []);
      // 引用文本整段留在正文里原样回填，不反解析回 _quotedChatText：反解析要靠文案模板
      // 匹配，_sendMessage 的措辞一改就静默丢内容，整段回填才与用户当初发的逐字一致
      _quotedChatText = null;
      // 一次性写 value：连带把光标钉在文末，避免 .text 赋值保留旧 selection 造成瞬时越界
      _inputController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
    // 程序化写入同样会走 _onInputChanged，原文以「/技能名」「@类别」结尾时会误拉面板；
    // 回填不是敲键，这里显式收起，下一次真实输入仍会重算
    _updateOverlays(null, null);
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

  /// 「给小Q」：把聊天里的图片挂到本页输入框附件条，供用户就这张图继续追问。
  ///
  /// 用户已在小Q 主页，因此不跳转悬浮面板，直接复用本页的 `_attachedImages` 发送链路。
  void _attachImageToInput(String path) {
    if (path.trim().isEmpty) {
      return;
    }
    HapticFeedback.lightImpact();
    if (!_attachedImages.contains(path)) {
      setState(() {
        _attachedImages.add(path);
      });
    }
    _inputFocusNode.requestFocus();
    Toast.info(context, '已添加到输入框');
  }

  Future<void> _pickJournals() async {
    final journals = await JournalService.instance.getAllJournals();
    if (!mounted) return;
    if (journals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('暂无日记，可在时间线左下角撰写')));
      return;
    }
    final result = await AppMotion.showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiJournalSelectorDialog(journals: journals, initialSelected: _attachedJournalIds),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedJournalIds.clear();
        _attachedJournalIds.addAll(result);
        for (final j in journals) {
          _journalTitles[j.id] = journalChipTitle(j);
        }
      });
    }
  }

  Future<void> _pickNotes() async {
    final notes = await NoteRepository().getAll();
    if (!mounted) return;
    // 排除日记笔记，保持普通笔记专属
    final validNotes = notes.where((n) => !n.isDeleted && !JournalService.isJournalNote(n.id)).toList();
    final result = await AppMotion.showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiNoteSelectorDialog(notes: validNotes, initialSelected: _attachedNoteIds),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedNoteIds.clear();
        _attachedNoteIds.addAll(result);
        for (final n in validNotes) {
          _noteTitles[n.id] = noteChipTitle(n);
        }
      });
    }
  }

  Future<void> _pickTodos() async {
    final todos = await TodoRepository().getAll();
    if (!mounted) return;
    final validTodos = todos.where((t) => !t.isDeleted).toList();
    final result = await AppMotion.showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiTodoSelectorDialog(todos: validTodos, initialSelected: _attachedTodoIds),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedTodoIds.clear();
        _attachedTodoIds.addAll(result);
        for (final t in validTodos) {
          _todoTitles[t.id] = todoChipTitle(t);
        }
      });
    }
  }

  void _showAttachmentMenu(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
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
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 附件入口铺实心彩底，前景自动取黑/白；淡彩底配同色图标在荧光黄绿下看不清
          AppIconBadge(
            icon: icon,
            size: 56,
            iconSize: 28,
            backgroundColor: iconColor,
            borderRadius: BorderRadius.circular(16),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface),
          ),
        ],
      ),
    );
  }

  Future<void> _openModelSelector() async {
    // 弹窗与 AiRoles 写入逻辑在共享组件中（悬浮小Q面板长按发送按钮也走此入口）
    final selected = await showAssistantModelSelector(context, ref);
    if (selected == null) return;
    setState(() => _activeModelId = selected.ref);
  }

  @override
  Widget build(BuildContext context) {
    final currentChat = ref.watch(currentChatProvider);
    final providersAsync = ref.watch(aiProviderListProvider);
    final routeGroupsAsync = ref.watch(aiRouteGroupListProvider);
    final theme = Theme.of(context);

    // 监听 aiRolesProvider，保证小Q界面与设置页角色绑定实时同步
    ref.listen<AsyncValue<AiRoles?>>(aiRolesProvider, (prev, next) {
      final bound = next.valueOrNull?.assistant;
      if (bound != null && bound != _activeModelId) {
        setState(() => _activeModelId = bound);
      }
    });

    // 厂商/模型/路由组增删改后，校正顶部胶囊指向的绑定；失效时回落到默认厂商首个模型
    ref.listen<AsyncValue<List<AiProvider>>>(aiProviderListProvider, (prev, next) {
      final providers = next.valueOrNull;
      if (providers == null) return;
      _syncActiveBindingIfStale(providers, routeGroupsAsync.valueOrNull ?? const <AiRouteGroup>[]);
    });
    ref.listen<AsyncValue<List<AiRouteGroup>>>(aiRouteGroupListProvider, (prev, next) {
      final groups = next.valueOrNull;
      if (groups == null) return;
      _syncActiveBindingIfStale(providersAsync.valueOrNull ?? const <AiProvider>[], groups);
    });

    ref.listen(currentChatProvider, (prev, next) {
      _scrollToBottom();
      // 会话切换时重置打字点/停止按钮状态：流式气泡已随会话卸载，
      // 旧会话的等待指示不能残留到新会话。
      // prev == null 是发送时自动创建会话的场景，属于本次发送自己的会话，不重置
      if (prev != null && next?.id != prev.id && _isTyping && mounted) {
        setState(() => _isTyping = false);
      }
      // 会话被换掉或那条提问已不在末轮：编辑态随之作废，否则下一次发送会按错下标撤回
      _invalidateReeditIfNeeded(next);
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
      final switched = (bottomInset == 0) != (_lastBottomInset == 0);
      // 键盘弹出/收起瞬间立即校准贴底；动画中间帧不逐帧滚动，
      // 改用短 debounce 在动画结束后兜底校准一次，避免每帧滚动布局
      _insetScrollDebounce?.cancel();
      if (switched) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToBottomIfNeeded();
          }
        });
      } else {
        _insetScrollDebounce = Timer(const Duration(milliseconds: 80), () {
          if (mounted) {
            _scrollToBottomIfNeeded();
          }
        });
      }
    }
    _lastBottomInset = bottomInset;

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.menu), onPressed: () => rootScaffoldKey.currentState?.openDrawer()),
        title: const Text('小Q'),
        actions: [
          // 自动朗读开关：与语音设置页同一真源，随手切换不必跳设置
          const AutoReadToggleButton(iconSize: 22),
          IconButton(
            // 圆角气泡+加号造型，线条比 add_comment 更圆润
            icon: const Icon(Icons.maps_ugc_outlined),
            tooltip: '新建对话',
            onPressed: () async {
              // 先收起键盘，避免新会话打开后键盘自动弹出
              FocusManager.instance.primaryFocus?.unfocus();
              final previous = ref.read(currentChatProvider);
              final session = await ref.read(chatSessionListProvider.notifier).createSession();
              ref.read(currentChatProvider.notifier).setSession(session);
              // 本来就停在空白新对话上时，界面点了不会有任何变化，用 Toast 明确回应
              if (context.mounted && (previous == null || isBlankNewChatSession(previous))) {
                Toast.info(context, '已是新对话');
              }
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
          return ChatHistoryDrawer(sessionsAsync: sessionsAsync, activeId: activeId);
        },
      ),
      body: Column(
        children: [
          Expanded(child: _buildChatArea(currentChat, theme)),
          _buildInputArea(providersAsync, routeGroupsAsync, theme),
        ],
      ),
    );
  }

  Widget _buildChatArea(ChatSession? currentChat, ThemeData theme) {
    final stateMessages = currentChat?.messages ?? const <ChatMessage>[];

    // 三个派生结果一起重算：都以 stateMessages 为唯一输入，命中缓存时整组复用。
    // 缓存键刻意不含 hasStreaming——流式开始/结束不改变历史消息，
    // 不应因此击穿缓存重扫全部消息。
    if (!identical(stateMessages, _cacheSource)) {
      _cacheSource = stateMessages;
      // 生图卡片已展示过的图片键：assistant 正文里模型回显的同一张 `![image](<路径>)`
      // 据此跳过渲染，避免一张生成图在会话流里出现两次
      _cachedImageKeys = collectGeneratedImageKeys(stateMessages);
      // 消息归一抽在纯函数里（思考步骤独立成行 + 连续工具聚合成折叠链），
      // 便于在没有数据库和 UI 的环境下锁定顺序、可见性与撤回下标
      _cachedTimeline = buildChatTimelineEntries(stateMessages);
      _cachedReeditIndex = reeditableUserIndex(stateMessages);
    }
    final generatedImageKeys = _cachedImageKeys!;
    final timeline = _cachedTimeline!;
    final displayItems = timeline.isEmpty
        ? [
            // 空会话：虚拟一条小Q问候语，避免首屏空白
            ChatTimelineEntry(
              ChatMessage(
                role: 'assistant',
                content: defaultSystemPrompts['assistant_greeting'] ?? '嗨，我是小Q —— 记待办、写笔记、打卡时间线、看统计，说一句就行',
                timestamp: DateTime.now(),
              ),
            ),
          ]
        : timeline;

    final hasStreaming =
        ref.watch(aiStreamingMessageProvider.select((value) => value != null)) ||
        ref.watch(aiStreamingStatusProvider.select((value) => value != null));
    final showTyping =
        _isTyping && !hasStreaming && displayItems.isNotEmpty && displayItems.last.message.role == 'user';
    final showStreaming = hasStreaming;

    // 「再次编辑」入口只挂在我最后发的那条提问上：更早的轮次回退会连带撤销其后
    // 所有真实数据修改，误触代价不可接受
    final reeditIndex = _cachedReeditIndex;

    final totalCount = displayItems.length + (showTyping ? 1 : 0) + (showStreaming ? 1 : 0);

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
            ...selectableRegionState.contextMenuButtonItems.where((item) => item.type != ContextMenuButtonType.custom),
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
                  if (prevTime == null || currTime == null || currTime.difference(prevTime).abs().inMinutes < 5) {
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
                  if (nextTime == null || currTime == null || nextTime.difference(currTime).abs().inMinutes < 5) {
                    isLastInGroup = false;
                  }
                }
              } else {
                // 当前是已存列表的最后一条，如果紧接着有 typing 或 streaming，且小Q是发送方，则不是最后一条
                if (!currentIsUser && (showTyping || showStreaming)) {
                  isLastInGroup = false;
                }
              }

              // 重新生成只对会话最后一条回复开放：更早的轮次重发会连带撤销
              // 其后所有轮次的数据修改，误触代价太高
              final canRegenerate =
                  !currentIsUser &&
                  !hasStreaming &&
                  entry.stateIndex != null &&
                  entry.stateIndex == stateMessages.length - 1;

              final bubble = ChatBubble(
                message: currentMsg,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                actionsEnabled: !hasStreaming,
                generatedImageKeys: generatedImageKeys,
                onSendToQ: _attachImageToInput,
                onRegenerate: canRegenerate ? () => _retryFailedTurn(entry.stateIndex!) : null,
                // 回退与重发期间置灰，避免连点触发两轮
                regenerateEnabled: !_isTyping,
                onContinue: () => ref.read(currentChatProvider.notifier).continueAfterTurnLimit(),
                onPause: () => ref.read(currentChatProvider.notifier).pauseAfterTurnLimit(),
              );
              // 我最后发的那条提问：点一下把提问填回输入框慢慢改，撤回留到点发送时；
              // 失败气泡仍走长按弹重试菜单
              final canReedit = currentIsUser && reeditIndex != null && entry.stateIndex == reeditIndex;
              return RepaintBoundary(
                child: canReedit
                    ? UserBubbleReeditTap(
                        enabled: !_isTyping && !hasStreaming,
                        active: _reeditIndex == entry.stateIndex,
                        onTap: () => _beginReedit(entry.stateIndex!),
                        child: bubble,
                      )
                    : !currentIsUser && currentMsg.isError == true && entry.stateIndex != null
                    ? GestureDetector(
                        onLongPress: () => _showErrorAssistantActions(entry.stateIndex!, currentMsg),
                        child: bubble,
                      )
                    : bubble,
              );
            }

            if (showTyping && index == displayItems.length) {
              // 如果上一条已经是小Q回复，打字指示器隐藏头像并紧凑排列
              final prevIsAssistant = displayItems.isNotEmpty && !isUserMsg(displayItems.last.message);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TypingBubble(isFirstInGroup: !prevIsAssistant, isLastInGroup: !showStreaming),
              );
            }

            // 流式气泡（含思考中状态卡）：底部增加留白，确保不紧贴输入栏
            final lastMsg = displayItems.isNotEmpty ? displayItems.last.message : null;
            final prevIsAssistant = lastMsg != null && !isUserMsg(lastMsg);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _StreamingBubble(
                isFirstInGroup: !prevIsAssistant && !showTyping,
                isLastInGroup: true,
                generatedImageKeys: generatedImageKeys,
                onSendToQ: _attachImageToInput,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInputArea(
    AsyncValue<List<AiProvider>> providersAsync,
    AsyncValue<List<AiRouteGroup>> routeGroupsAsync,
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
      agentRunningSessionsProvider.select((s) => activeId != null && s.contains(activeId)),
    );
    final busy = _isTyping || isSessionBusy;

    // 模型胶囊尾部的思考强度档位：模型选择面板里一并调整，这里只做展示
    final reasoningTargets = reasoningTargetsOf(
      _activeModelId,
      providersAsync.valueOrNull ?? const <AiProvider>[],
      routeGroupsAsync.valueOrNull ?? const <AiRouteGroup>[],
    );
    final effortState = reasoningEffortStateOf(reasoningTargets);
    final effortLabel = effortState == null
        ? null
        : effortState.mixed
        ? '混合'
        : effortState.capability.labelFor(effortState.effort);

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 0~1. 输入区附加内容：斜杠命令 / @ 引用 / 引用卡 / 附件条。
              // 统一包一层高度过渡：出现时把输入框平滑顶起，消失时也不留空洞。
              AnimatedSize(
                duration: AppMotion.duration(context, AppDurations.normal),
                curve: AppCurves.emphasizedSpatial,
                alignment: Alignment.bottomCenter,
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
                    if (_quotedChatText != null) ...[_buildQuotePreviewCard(theme), const SizedBox(height: 6)],

                    // 1. 豆包式附件挂载条（图片缩略图、分享的笔记、分享的待办）
                    if (hasAttachments) ...[_buildAttachmentBar(theme), const SizedBox(height: 6)],
                  ],
                ),
              ),

              // 1.5 输入栏上方功能行：左侧常用提示词，右侧模型胶囊（含思考强度档位）
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    // 常用提示词（点击弹出列表，选中即覆盖输入框）
                    _InputPill(
                      icon: Icons.bolt_rounded,
                      label: '常用提示词',
                      onTap: () => showQuickPromptDialog(context, ref, (text) {
                        _inputController.text = text;
                        _inputController.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
                        _inputFocusNode.requestFocus();
                      }),
                    ),
                    const SizedBox(width: 8),
                    // 右侧控制区：模型胶囊（带当前思考强度档位）。
                    // 模型只显示模型名（厂商名对「当前用哪个模型」没有增量信息，
                    // 且会把胶囊撑得很长）；思考强度在模型选择面板里一并调整。
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: _InputPill(
                                icon: Icons.memory_rounded,
                                label: aiBindingShortName(
                                  _activeModelId,
                                  providersAsync.valueOrNull ?? const <AiProvider>[],
                                  routeGroupsAsync.valueOrNull ?? const <AiRouteGroup>[],
                                ),
                                suffix: effortLabel,
                                trailing: Icons.expand_more_rounded,
                                onTap: _openModelSelector,
                              ),
                            ),
                          ],
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
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.add_rounded, size: 26, color: theme.colorScheme.onSurfaceVariant),
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
                      final Widget button;
                      if (busy) {
                        final isDark = theme.brightness == Brightness.dark;
                        final primary = theme.colorScheme.primary;
                        button = Tooltip(
                          message: '中止小Q当前操作',
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
                                  color: primary.withValues(alpha: isDark ? 0.14 : 0.08),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: primary.withValues(alpha: isDark ? 0.22 : 0.14),
                                    width: 0.8,
                                  ),
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    LoadingRing(size: 32, strokeWidth: 1.3, color: primary),
                                    Container(
                                      width: 9.5,
                                      height: 9.5,
                                      decoration: BoxDecoration(
                                        color: primary,
                                        borderRadius: BorderRadius.circular(2.0),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      } else {
                        // 小Q空闲时：标准发送按钮（长按切换模型）
                        button = PressableScale(
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
                                  : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Icon(
                                Icons.send_rounded,
                                size: 22,
                                color: canSend
                                    ? theme.colorScheme.onPrimary
                                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                        );
                      }
                      // 发送/停止两套按钮交叉淡化 + 轻微缩放，避免整钮硬闪
                      return AppMotion.switcher(
                        context: context,
                        child: KeyedSubtree(key: ValueKey(busy ? 'send_stop' : 'send_idle'), child: button),
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
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.format_quote_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '引用：$_quotedChatText',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => setState(() => _quotedChatText = null),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentBar(ThemeData theme) {
    return Container(
      // 外层 Column 默认 crossAxisAlignment.center，而横向滚动条会收缩到内容宽度，
      // 不撑满就会让附件整体看起来悬在中间；这里强制占满后由内部 Row 左对齐
      width: double.infinity,
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
                        child: UnifiedImage(imagePath: imgPath, fit: BoxFit.cover),
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
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 12, color: Colors.white),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.auto_stories_outlined, size: 14, color: Color(0xFFE91E63)),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedJournalIds.remove(jId);
                          });
                        },
                        child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.description_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedNoteIds.remove(noteId);
                          });
                        },
                        child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.checklist_rounded, size: 14, color: theme.colorScheme.secondary),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedTodoIds.remove(todoId);
                          });
                        },
                        child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
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
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 2),
                    Text('添加', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
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
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
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
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6), width: 1),
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
                contentPadding: EdgeInsets.only(left: 16, top: 10, bottom: 10, right: 42),
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
                          color: theme.colorScheme.error.withValues(alpha: 0.85),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.error.withValues(alpha: 0.25),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Center(child: Icon(Icons.close, size: 12, color: Colors.white)),
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
}

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/engine/agent_cancellation_token.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/agent/services/q_text_quote.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/agent_support.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';

// 引用模型本体在 core 层（QTargetBridge 桥接钩子需要该类型），
// 这里 re-export 保持既有 import 路径兼容
export 'package:qnote_flutter/core/agent/services/q_text_quote.dart'
    show QQuoteSource, QTextQuote;

// ==========================================
// 全局悬浮小Q快捷入口
//
// 与 AI 主页面会话完全隔离的轻量任务入口：
// - 页面上下文（QPageContext）让小Q知道当前界面与目标文件；
// - 会话按上下文签名隔离：签名变化（切页/返回）即丢失历史，重新开始；
// - 任务过程悬浮球播放动画，结束后可在面板横幅中随时撤回本次会话的全部修改
//   （撤回横幅常驻不消失，直到撤回执行；期间发起新任务则跨任务累加）；
// - 消息为纯内存态，不落库、不污染 AI 主页面的会话历史。
// ==========================================

/// 全局模态弹层计数（Dialog/BottomSheet 打开时悬浮球自动隐藏）
final floatingQModalCount = ValueNotifier<int>(0);

/// 模态路由观察者：挂在 GoRouter 的 observers（root Navigator）上，统计 PopupRoute。
///
/// 自愈设计：除 didPush/didPop/didRemove/didReplace 对称增删外，还给每个入集路由挂
/// 动画状态监听——弹层动画回到 dismissed 即代表它已关闭，若因事件丢失仍残留在集合中
/// 则强制剔除并重算，杜绝计数泄漏导致悬浮球永久隐藏。
class FloatingQModalRouteObserver extends NavigatorObserver {
  /// 当前打开中的 PopupRoute 集合（以路由对象为键，天然去重）。
  /// 用 PopupRoute 类型而非 Route 基类：animation getter 定义在 TransitionRoute 上
  final Set<PopupRoute> _openPopups = {};

  @override
  void didPush(Route route, Route? previousRoute) => _track(route);

  @override
  void didPop(Route route, Route? previousRoute) => _untrack(route);

  @override
  void didRemove(Route route, Route? previousRoute) => _untrack(route);

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _untrack(oldRoute);
    _track(newRoute);
  }

  /// 登记弹层路由并挂动画状态监听（自愈信号源）
  void _track(Route? route) {
    if (route is! PopupRoute || _openPopups.contains(route)) return;
    _openPopups.add(route);
    route.animation?.addStatusListener(_onRouteAnimationStatus);
    _sync();
  }

  void _untrack(Route? route) {
    if (route is! PopupRoute || !_openPopups.contains(route)) return;
    route.animation?.removeStatusListener(_onRouteAnimationStatus);
    _openPopups.remove(route);
    _sync();
  }

  /// 弹层动画回到 dismissed 意味着它已经关闭：无论 didPop/didRemove 是否被
  /// 漏掉都强制剔除（防止计数泄漏导致悬浮球永久隐藏）
  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    final stale = _openPopups
        .where((r) =>
            r.animation == null ||
            r.animation!.status == AnimationStatus.dismissed)
        .toList();
    if (stale.isEmpty) return;
    for (final route in stale) {
      route.animation?.removeStatusListener(_onRouteAnimationStatus);
      _openPopups.remove(route);
    }
    _sync();
  }

  void _sync() {
    if (kDebugMode) {
      debugPrint('[FloatingQ] modal count = ${_openPopups.length}');
    }
    floatingQModalCount.value = _openPopups.length;
  }
}

/// 悬浮小Q的工作阶段
enum FloatingQPhase {
  /// 待机：无任务进行、无待撤回变更
  idle,

  /// 任务执行中（悬浮球播放动画，面板可查看进度并可中断）
  working,

  /// 撤回就绪：任务（或中断）结束后可随时在面板中撤回，
  /// 直到撤回执行；期间发起新任务则待撤回变更跨任务累加
  countdown,
}

/// 悬浮小Q状态
class FloatingQState {
  /// 路由推导的基础上下文
  final QPageContext? baseContext;

  /// 编辑页覆盖栈（后进先出，栈顶即当前编辑页）
  final List<QPageContext> overlayStack;

  /// 工作阶段
  final FloatingQPhase phase;

  /// 快捷对话面板是否展开
  final bool panelOpen;

  /// 当前会话绑定的上下文签名（null 表示尚无会话）
  final String? contextSignature;

  /// 会话绑定时的上下文展示文案（面板徽章）
  final String? contextLabel;

  /// 本会话消息（纯内存，不落库）
  final List<ChatMessage> messages;

  /// 流式阶段状态文案（小Q思考中/执行操作等），与 [streamingText] 互斥
  final String? statusText;

  /// 流式正文缓冲
  final String? streamingText;

  /// 待撤回的变更处数
  final int pendingUndoCount;

  /// 是否正在执行撤回（防重入）
  final bool isUndoing;

  /// 「给小Q」挂起的待发送引用（面板展示为引用卡片，发送时一次性消费）
  final QTextQuote? pendingQuote;

  const FloatingQState({
    this.baseContext,
    this.overlayStack = const [],
    this.phase = FloatingQPhase.idle,
    this.panelOpen = false,
    this.contextSignature,
    this.contextLabel,
    this.messages = const [],
    this.statusText,
    this.streamingText,
    this.pendingUndoCount = 0,
    this.isUndoing = false,
    this.pendingQuote,
  });

  /// 生效上下文：编辑页覆盖栈顶优先，否则取基础上下文
  QPageContext? get effectiveContext =>
      overlayStack.isNotEmpty ? overlayStack.last : baseContext;

  FloatingQState copyWith({
    QPageContext? baseContext,
    List<QPageContext>? overlayStack,
    FloatingQPhase? phase,
    bool? panelOpen,
    String? contextSignature,
    String? contextLabel,
    List<ChatMessage>? messages,
    String? statusText,
    String? streamingText,
    int? pendingUndoCount,
    bool? isUndoing,
    QTextQuote? pendingQuote,
    bool clearSignature = false,
    bool clearStatusText = false,
    bool clearStreamingText = false,
    bool clearQuote = false,
  }) {
    return FloatingQState(
      baseContext: baseContext ?? this.baseContext,
      overlayStack: overlayStack ?? this.overlayStack,
      phase: phase ?? this.phase,
      panelOpen: panelOpen ?? this.panelOpen,
      contextSignature:
          clearSignature ? null : (contextSignature ?? this.contextSignature),
      contextLabel: clearSignature ? null : (contextLabel ?? this.contextLabel),
      messages: messages ?? this.messages,
      statusText:
          clearStatusText ? null : (statusText ?? this.statusText),
      streamingText:
          clearStreamingText ? null : (streamingText ?? this.streamingText),
      pendingUndoCount: pendingUndoCount ?? this.pendingUndoCount,
      isUndoing: isUndoing ?? this.isUndoing,
      pendingQuote: clearQuote ? null : (pendingQuote ?? this.pendingQuote),
    );
  }
}

final floatingQProvider =
    NotifierProvider<FloatingQNotifier, FloatingQState>(
  FloatingQNotifier.new,
);

class FloatingQNotifier extends Notifier<FloatingQState> {
  AgentCancellationToken? _currentToken;

  /// 本次会话累积的待撤回变更（跨多轮累加，撤回语义 = 撤销本会话小Q的全部修改）
  final List<WorkspaceUndoEntry> _pendingUndo = [];

  /// 运行中任务的会话消息现场（事件流写入，结束时同步到 state）
  List<ChatMessage> _sessionMessages = const [];

  /// 任务运行期间上下文是否被切换（切换即丢弃历史）
  bool _contextSwitchedDuringRun = false;

  final StringBuffer _streamBuffer = StringBuffer();
  Timer? _flushTimer;

  @override
  FloatingQState build() {
    ref.onDispose(() {
      _flushTimer?.cancel();
    });
    return const FloatingQState();
  }

  // ==========================================
  // 上下文注册（路由监听与编辑页压栈/出栈）
  // ==========================================

  /// 更新基础上下文（由路由 location 监听器调用）
  void setBaseContext(QPageContext context) {
    state = state.copyWith(baseContext: context);
    _applyEffectiveContext();
  }

  /// 编辑页压栈（initState 调用）
  void pushOverlayContext(QPageContext context) {
    state = state.copyWith(overlayStack: [...state.overlayStack, context]);
    _applyEffectiveContext();
  }

  /// 编辑页出栈（dispose 调用，按值匹配移除最后压入的同类上下文）
  void popOverlayContext(QPageContext context) {
    final stack = [...state.overlayStack];
    final idx = stack.lastIndexWhere((c) => c == context);
    if (idx >= 0) stack.removeAt(idx);
    state = state.copyWith(overlayStack: stack);
    _applyEffectiveContext();
  }

  /// 生效上下文签名变化时处理会话隔离：
  /// 空闲 → 立即清空历史（切页/返回即丢失，含"切走再回来"）；
  /// 工作中 → 任务继续跑完（撤回能力全局保留），但历史立即丢弃
  void _applyEffectiveContext() {
    final effective = state.effectiveContext;
    final signature = effective?.signature;
    if (signature == state.contextSignature) return;

    if (state.phase == FloatingQPhase.working) {
      _contextSwitchedDuringRun = true;
    }
    state = state.copyWith(
      contextSignature: signature,
      contextLabel: effective?.displayLabel,
      messages: const [],
      // 生效上下文为空（无基础上下文且无编辑页）时显式清空会话签名
      clearSignature: signature == null,
      // 挂起引用与来源页面绑定，会话随签名切换即作废
      clearQuote: true,
    );
  }

  // ==========================================
  // 面板与会话操作
  // ==========================================

  void openPanel() => state = state.copyWith(panelOpen: true);

  void closePanel() => state = state.copyWith(panelOpen: false);

  /// 「给小Q」引用入口：挂起引用并展开面板。
  ///
  /// 小Q工作中同样允许挂起（send 在 working 期是 no-op，引用保留待发），
  /// 引用在发送时一次性消费，期间可在面板引用卡片上移除
  void openWithQuote(QTextQuote quote) =>
      state = state.copyWith(pendingQuote: quote, panelOpen: true);

  /// 移除挂起的引用（引用卡片 × 按钮）
  void clearPendingQuote() => state = state.copyWith(clearQuote: true);

  /// 手动开启新对话（清空历史；进行中的任务与待撤回变更不受影响）
  void newConversation() {
    if (state.phase == FloatingQPhase.working) return;
    state = state.copyWith(
      messages: const [],
      clearSignature: true,
      clearStatusText: true,
      clearStreamingText: true,
      // 挂起引用属于旧会话上下文，随会话重置一并清空
      clearQuote: true,
    );
    _sessionMessages = const [];
  }

  // ==========================================
  // 发送 / 中断 / 撤回
  // ==========================================

  /// 发送指令：上下文签名变化即自动开新会话；连续对话携带本会话历史
  Future<void> send(String content) async {
    final text = content.trim();
    if (text.isEmpty || state.phase == FloatingQPhase.working) return;

    final ctx = state.effectiveContext;
    final signature = ctx?.signature ?? 'page:none';

    // 撤回就绪期发起新任务：保留并继续累加旧修改，撤回语义仍为
    // "撤销本会话小Q的全部修改"（逆序恢复天然按时间倒序覆盖多次任务）
    final isNewConversation = signature != state.contextSignature;
    final userMessage = ChatMessage(
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );

    // 「给小Q」引用一次性消费：随本次任务注入动态上下文（引用卡片同步移除）
    final quote = state.pendingQuote;

    state = state.copyWith(
      phase: FloatingQPhase.working,
      contextSignature: signature,
      contextLabel: ctx?.displayLabel,
      messages: isNewConversation ? [userMessage] : [...state.messages, userMessage],
      statusText: '小Q准备中',
      clearStreamingText: true,
      clearQuote: true,
    );
    _sessionMessages = List.of(state.messages);
    _contextSwitchedDuringRun = false;

    // 通知目标编辑页任务开始（暂停自动保存）并记录编辑器指纹
    QTargetBridge.instance.notifyTaskStart(ctx?.signature);

    await _runAgentTask(ctx, signature, quote: quote);
  }

  /// 中断当前任务（已执行的部分修改同样进入撤回就绪状态）
  void stop() {
    _currentToken?.cancel('用户主动中止操作');
    AgentInteractionService.instance.cancelPending('用户主动中止操作');
  }

  /// 将最近一条步数上限消息标记为已处理（隐藏「继续/暂停」按钮）
  void _markTurnLimitHandled() {
    final messages = List<ChatMessage>.from(_sessionMessages);
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].uiDetails?['type'] == 'turn_limit') {
        messages[i] = messages[i].copyWith(
          uiDetails: {...?messages[i].uiDetails, 'handled': true},
        );
        _sessionMessages = messages;
        state = state.copyWith(messages: List.of(messages));
        return;
      }
    }
  }

  /// 点击「继续」：以「继续」指令重启 Agent 循环接着执行未完成的任务
  Future<void> continueTask() async {
    if (state.phase == FloatingQPhase.working) return;
    _markTurnLimitHandled();
    await send('继续');
  }

  /// 点击「暂停」：仅隐藏按钮，已完成的工作保留，任务就此结束
  void pauseTask() {
    if (state.phase == FloatingQPhase.working) return;
    _markTurnLimitHandled();
  }

  /// 撤回本会话小Q的全部修改，返回 (恢复成功处数, 失败处数)；不可撤回时返回 null
  Future<(int restored, int failed)?> undo() async {
    if (state.phase != FloatingQPhase.countdown ||
        state.isUndoing ||
        _pendingUndo.isEmpty) {
      return null;
    }
    state = state.copyWith(isUndoing: true);
    try {
      final entries = List.of(_pendingUndo);
      final result = await restoreWorkspaceUndoEntries(ref, entries);
      // 逐路径联动刷新已由恢复器完成，这里兜底全量刷新并重载打开中的编辑页
      refreshAllBusinessData(ref);
      await QTargetBridge.instance.reloadAll();
      _pendingUndo.clear();
      _sessionMessages = const [];
      state = state.copyWith(
        phase: FloatingQPhase.idle,
        messages: const [],
        clearSignature: true,
        pendingUndoCount: 0,
        isUndoing: false,
      );
      return result;
    } catch (e) {
      LoggerService.instance.logAI(
        '悬浮小Q撤回失败: $e',
        level: LogLevel.error,
      );
      state = state.copyWith(isUndoing: false);
      return null;
    }
  }

  // ==========================================
  // Agent 任务管线（与 AI 主会话同源的引擎与联动，独立轻量事件消费）
  // ==========================================

  Future<void> _runAgentTask(
    QPageContext? ctx,
    String signature, {
    QTextQuote? quote,
  }) async {
    final token = AgentCancellationToken();
    _currentToken = token;
    _streamBuffer.clear();
    final recorderHandle = VirtualWorkspaceService.instance.startRecording();

    try {
      // 页面上下文说明块：告诉小Q当前界面与目标文件（无目标页面则省略）；
      // 「给小Q」引用说明块：告诉小Q用户引用了哪段内容、位于哪个文件
      final pageBlock = await ctx?.toPromptBlock();
      final quoteBlock = quote == null ? null : await _quotePromptBlock(quote);
      final dynamicContext = await buildBaseDynamicContext(
        extraSections: [
          if (pageBlock != null) pageBlock,
          if (quoteBlock != null) quoteBlock,
        ],
      );

      final aiService = ref.read(aiServiceProvider);
      final roleSettings = await AiRoleService.instance.getSettingsForRole(
        'assistant',
      );
      final assistantConfig = await AiRoleService.instance
          .getEffectiveConfigForRole('assistant');
      aiService.updateConfig(
        assistantConfig,
        temperature: roleSettings.temperature,
        maxTokens: roleSettings.maxTokens,
      );

      final dispatcher = AgentToolRegistry.createDefaultDispatcher();
      final agentLoop = AgentLoop(
        aiService: aiService,
        dispatcher: dispatcher,
        maxTurns: 20,
        afterToolCall: (call, result) async {
          // 按 VFS 路径前缀联动刷新对应业务数据
          refreshWorkspaceSideEffects(
            ref,
            call.arguments['path'] as String? ?? '',
          );
        },
      );

      ChatMessage? finalResponse;
      await for (final event in agentLoop.run(
        conversationHistory: List.of(_sessionMessages),
        systemPrompt: QSystemPrompt.prompt,
        dynamicContext: dynamicContext,
        cancellationToken: token,
      )) {
        switch (event.type) {
          case AgentEventType.agentStart:
            _setStatus('小Q准备中');
            break;
          case AgentEventType.turnStart:
            _streamBuffer.clear();
            // 首轮不展示步数，避免"第 1 步"这类无信息量文案
            _setStatus((event.turn ?? 0) > 1
                ? '小Q思考中 · 第 ${event.turn} 步'
                : '小Q思考中');
            break;
          case AgentEventType.contentDelta:
            if (event.text != null) {
              _streamBuffer.write(event.text!);
              _scheduleFlush();
            }
            break;
          case AgentEventType.thoughtUpdate:
            if (event.text != null && event.text!.isNotEmpty) {
              _setStatus('💭 ${event.text}');
            }
            break;
          case AgentEventType.toolExecuting:
            final toolName = event.toolCall?.name ?? '';
            final extraProgress = event.text != null ? '（${event.text}）' : '';
            _setStatus(
              '${AgentToolLabels.progressLabel(toolName, event.toolCall?.arguments)}$extraProgress',
            );
            break;
          case AgentEventType.toolCompleted:
          case AgentEventType.assistantMessage:
            if (event.message != null) {
              _appendSessionMessage(event.message!, signature);
            }
            break;
          case AgentEventType.finished:
            finalResponse = event.message;
            break;
          case AgentEventType.agentEnd:
          case AgentEventType.turnEnd:
            break;
          case AgentEventType.error:
            throw Exception(event.error ?? 'Agent 执行异常');
        }
      }

      if (finalResponse != null) {
        // 避免重复追加相同内容的最终答复
        final isDup = _sessionMessages.isNotEmpty &&
            _sessionMessages.last.role == 'assistant' &&
            _sessionMessages.last.content.trim() ==
                finalResponse.content.trim();
        if (!isDup) _appendSessionMessage(finalResponse, signature);
      }
      if (token.isCancelled && _sessionMessages.isNotEmpty) {
        final last = _sessionMessages.last;
        if (last.role != 'assistant' || !last.content.contains('中止')) {
          _appendSessionMessage(
            ChatMessage(
              role: 'assistant',
              content: '(已中止，未完成的指令可以重新发送)',
              timestamp: DateTime.now(),
            ),
            signature,
          );
        }
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        '悬浮小Q任务执行失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      _appendSessionMessage(
        ChatMessage(
          role: 'assistant',
          content: '抱歉，执行出错了：$e',
          timestamp: DateTime.now(),
        ),
        signature,
      );
    } finally {
      _flushTimer?.cancel();
      _flushTimer = null;
      _currentToken = null;
      final undoEntries =
          VirtualWorkspaceService.instance.stopRecording(recorderHandle);

      // 任务结束：目标编辑页指纹未变则重载刷新 UI（保留用户手动编辑的版本）
      await QTargetBridge.instance.notifyTaskEnd(ctx?.signature);

      // 会话已因切页重置：历史丢弃，消息不再回到界面（撤回能力仍全局保留）
      if (_contextSwitchedDuringRun) {
        _sessionMessages = const [];
      }

      // 本轮任务的修改并入待撤回集合（跨任务累加，撤回 = 撤销本会话全部修改）
      _pendingUndo.addAll(undoEntries);

      if (_pendingUndo.isNotEmpty) {
        // 存在待撤回变更即进入撤回就绪：横幅常驻面板、不再自动过期，
        // 直到用户执行撤回；本轮无新修改但此前仍有待撤回变更时同样保持就绪
        state = state.copyWith(
          phase: FloatingQPhase.countdown,
          pendingUndoCount: _pendingUndo.length,
          messages: List.of(_sessionMessages),
          clearStatusText: true,
          clearStreamingText: true,
        );
      } else {
        state = state.copyWith(
          phase: FloatingQPhase.idle,
          messages: List.of(_sessionMessages),
          clearStatusText: true,
          clearStreamingText: true,
        );
      }
    }
  }

  /// 组装「给小Q」引用说明块：告诉小Q用户引用了哪条内容、位于哪个虚拟工作区
  /// 文件，让小Q无需猜测即可 read_file 定位。返回 null 表示无法解析来源
  Future<String?> _quotePromptBlock(QTextQuote quote) async {
    final workspace = VirtualWorkspaceService.instance;
    final sourceLabel = switch (quote.source) {
      QQuoteSource.note => '笔记',
      QQuoteSource.diary => '时间线记录',
      QQuoteSource.journal => '每日日记',
      QQuoteSource.todo => '待办',
    };

    // 按来源类型解析 VFS 规范路径与 id 提示（与 undo 录制的归一化键一致）
    String? path;
    String idHint;
    switch (quote.source) {
      case QQuoteSource.note:
        path = await workspace.resolveNotePath(quote.sourceId);
        idHint = '笔记 id: ${quote.sourceId}';
      case QQuoteSource.diary:
        // 记录内嵌在天文件中，修改时必须保留 <!-- id: ... --> 标记
        path = await workspace.resolveTimelineDayPath(quote.sourceId);
        idHint =
            '记录 id: ${quote.sourceId}（记录以 <!-- id: ... --> 标记内嵌在天文件中，修改单条记录时保留其标记）';
      case QQuoteSource.journal:
        final date = DateTime.tryParse(quote.sourceId);
        if (date == null) return null;
        path = workspace.journalPathForDate(date);
        idHint = '日期: ${quote.sourceId}';
      case QQuoteSource.todo:
        path = await workspace.resolveTodoPath(quote.sourceId);
        idHint = '待办 id: ${quote.sourceId}（文件头部为 YAML frontmatter，修改时保留其中的 id 字段）';
    }

    // 引用过长时截断：引用文本主要用于定位，完整内容以 read_file 实际读取为准
    var text = quote.quotedText.trim();
    if (text.isEmpty) text = '（用户未附加摘录，请直接根据来源定位完整内容）';
    if (text.length > 2000) text = '${text.substring(0, 2000)}…（引用过长已截断）';

    return [
      '用户引用的内容（用户通过「给小Q」主动引用，接下来的指令通常针对这段内容提问或要求修改）',
      '来源：$sourceLabel《${quote.sourceTitle}》（$idHint${path == null ? '' : '，虚拟工作区文件: $path'}）',
      if (quote.locationDesc != null)
        '位置：${quote.locationDesc}（按引用时的内容估算，可能与文件当前实际内容有细微出入）',
      '引用文本：',
      '"""',
      text,
      '"""',
      '请先 read_file 上述文件定位该内容（以文件实际内容为准），需要修改时用 edit_file 精确替换；若指令与引用内容无关则按通用指令处理',
    ].join('\n');
  }

  /// 追加会话消息：会话已因切页重置时不再回写界面
  void _appendSessionMessage(ChatMessage message, String runSignature) {
    _sessionMessages = [..._sessionMessages, message];
    if (!_contextSwitchedDuringRun && state.contextSignature == runSignature) {
      state = state.copyWith(messages: List.of(_sessionMessages));
    }
  }

  void _setStatus(String text) {
    _flushTimer?.cancel();
    _flushTimer = null;
    state = state.copyWith(statusText: text, clearStreamingText: true);
  }

  /// 以约 60ms 的节奏批量刷新流式文本到面板（与 AI 主会话相同的节流策略）
  void _scheduleFlush() {
    if (_flushTimer != null && _flushTimer!.isActive) return;
    _flushTimer = Timer(const Duration(milliseconds: 60), () {
      state = state.copyWith(
        streamingText: _streamBuffer.toString(),
        clearStatusText: true,
      );
    });
  }
}

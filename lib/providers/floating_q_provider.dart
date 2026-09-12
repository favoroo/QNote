import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/engine/agent_cancellation_token.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/agent_support.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';

// ==========================================
// 全局悬浮小Q快捷入口
//
// 与 AI 主页面会话完全隔离的轻量任务入口：
// - 页面上下文（QPageContext）让小Q知道当前界面与目标文件；
// - 会话按上下文签名隔离：签名变化（切页/返回）即丢失历史，重新开始；
// - 任务过程悬浮球播放动画，结束后 5 秒倒计时可一键撤回本次会话的全部修改；
// - 消息为纯内存态，不落库、不污染 AI 主页面的会话历史。
// ==========================================

/// 全局模态弹层计数（Dialog/BottomSheet 打开时悬浮球自动隐藏）
final floatingQModalCount = ValueNotifier<int>(0);

/// 模态路由观察者：挂在 GoRouter 的 observers 上，统计 PopupRoute（对话框/底部弹层）
class FloatingQModalRouteObserver extends NavigatorObserver {
  static int _count = 0;

  void _bump(Route? route, int delta) {
    if (route is! PopupRoute) return;
    _count = (_count + delta).clamp(0, 1 << 30);
    floatingQModalCount.value = _count;
  }

  @override
  void didPush(Route route, Route? previousRoute) => _bump(route, 1);

  @override
  void didPop(Route route, Route? previousRoute) => _bump(route, -1);

  @override
  void didRemove(Route route, Route? previousRoute) => _bump(route, -1);
}

/// 悬浮小Q的工作阶段
enum FloatingQPhase {
  /// 待机：无任务进行、无待撤回变更
  idle,

  /// 任务执行中（悬浮球播放动画，面板可查看进度并可中断）
  working,

  /// 撤回倒计时：任务（或中断）结束后 5 秒内可一键撤回
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

  /// 撤回倒计时截止时间（null 表示不在倒计时）
  final DateTime? countdownEndsAt;

  /// 待撤回的变更处数
  final int pendingUndoCount;

  /// 是否正在执行撤回（防重入）
  final bool isUndoing;

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
    this.countdownEndsAt,
    this.pendingUndoCount = 0,
    this.isUndoing = false,
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
    DateTime? countdownEndsAt,
    int? pendingUndoCount,
    bool? isUndoing,
    bool clearSignature = false,
    bool clearStatusText = false,
    bool clearStreamingText = false,
    bool clearCountdownEndsAt = false,
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
      countdownEndsAt: clearCountdownEndsAt
          ? null
          : (countdownEndsAt ?? this.countdownEndsAt),
      pendingUndoCount: pendingUndoCount ?? this.pendingUndoCount,
      isUndoing: isUndoing ?? this.isUndoing,
    );
  }
}

final floatingQProvider =
    NotifierProvider<FloatingQNotifier, FloatingQState>(
  FloatingQNotifier.new,
);

class FloatingQNotifier extends Notifier<FloatingQState> {
  /// 撤回倒计时窗口
  static const _undoWindow = Duration(seconds: 5);

  AgentCancellationToken? _currentToken;

  /// 本次会话累积的待撤回变更（跨多轮累加，撤回语义 = 撤销本会话小Q的全部修改）
  final List<WorkspaceUndoEntry> _pendingUndo = [];

  /// 运行中任务的会话消息现场（事件流写入，结束时同步到 state）
  List<ChatMessage> _sessionMessages = const [];

  /// 任务运行期间上下文是否被切换（切换即丢弃历史）
  bool _contextSwitchedDuringRun = false;

  final StringBuffer _streamBuffer = StringBuffer();
  Timer? _countdownTimer;
  Timer? _flushTimer;

  @override
  FloatingQState build() {
    ref.onDispose(() {
      _countdownTimer?.cancel();
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
    );
  }

  // ==========================================
  // 面板与会话操作
  // ==========================================

  void openPanel() => state = state.copyWith(panelOpen: true);

  void closePanel() => state = state.copyWith(panelOpen: false);

  /// 手动开启新对话（清空历史；进行中的任务与撤回窗口不受影响）
  void newConversation() {
    if (state.phase == FloatingQPhase.working) return;
    state = state.copyWith(
      messages: const [],
      clearSignature: true,
      clearStatusText: true,
      clearStreamingText: true,
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

    // 撤回倒计时期间发起新任务：放弃未撤回的旧修改（新任务基于新结果）
    if (state.phase == FloatingQPhase.countdown) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
      _pendingUndo.clear();
    }

    final isNewConversation = signature != state.contextSignature;
    final userMessage = ChatMessage(
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      phase: FloatingQPhase.working,
      contextSignature: signature,
      contextLabel: ctx?.displayLabel,
      messages: isNewConversation ? [userMessage] : [...state.messages, userMessage],
      statusText: '小Q准备中',
      clearStreamingText: true,
      clearCountdownEndsAt: true,
      pendingUndoCount: 0,
    );
    _sessionMessages = List.of(state.messages);
    _contextSwitchedDuringRun = false;

    // 通知目标编辑页任务开始（暂停自动保存）并记录编辑器指纹
    QTargetBridge.instance.notifyTaskStart(ctx?.signature);

    await _runAgentTask(ctx, signature);
  }

  /// 中断当前任务（已执行的部分修改同样进入撤回倒计时）
  void stop() {
    _currentToken?.cancel('用户主动中止操作');
    AgentInteractionService.instance.cancelPending('用户主动中止操作');
  }

  /// 撤回本会话小Q的全部修改，返回 (恢复成功处数, 失败处数)；不可撤回时返回 null
  Future<(int restored, int failed)?> undo() async {
    if (state.phase != FloatingQPhase.countdown ||
        state.isUndoing ||
        _pendingUndo.isEmpty) {
      return null;
    }
    state = state.copyWith(isUndoing: true);
    _countdownTimer?.cancel();
    _countdownTimer = null;
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
        clearCountdownEndsAt: true,
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
    String signature,
  ) async {
    final token = AgentCancellationToken();
    _currentToken = token;
    _streamBuffer.clear();
    final recorderHandle = VirtualWorkspaceService.instance.startRecording();

    try {
      // 页面上下文说明块：告诉小Q当前界面与目标文件（无目标页面则省略）
      final pageBlock = await ctx?.toPromptBlock();
      final dynamicContext = await buildBaseDynamicContext(
        extraSections: [if (pageBlock != null) pageBlock],
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
        maxTurns: 8,
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
            final extraProgress = event.text != null ? ' (${event.text})' : '';
            _setStatus('小Q正在执行操作: [$toolName]$extraProgress');
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

      if (undoEntries.isNotEmpty) {
        _pendingUndo.addAll(undoEntries);
        state = state.copyWith(
          phase: FloatingQPhase.countdown,
          countdownEndsAt: DateTime.now().add(_undoWindow),
          pendingUndoCount: _pendingUndo.length,
          messages: List.of(_sessionMessages),
          clearStatusText: true,
          clearStreamingText: true,
        );
        _startCountdownTimer();
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

  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer(_undoWindow, _expireCountdown);
  }

  /// 倒计时自然结束：放弃撤回机会，回到待机
  void _expireCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (state.phase != FloatingQPhase.countdown) return;
    _pendingUndo.clear();
    state = state.copyWith(
      phase: FloatingQPhase.idle,
      clearCountdownEndsAt: true,
      pendingUndoCount: 0,
    );
  }
}

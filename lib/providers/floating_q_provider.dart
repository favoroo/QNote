import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/engine/agent_cancellation_token.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';
import 'package:qnote_flutter/core/agent/services/agent_tool_config.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/agent/services/q_text_quote.dart';
import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/ai/ai_error_explainer.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/raccoon_account_router.dart';
import 'package:qnote_flutter/core/ai/vision_capability_probe.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/tts/streaming_speech_session.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/agent_support.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';

// 引用模型本体在 core 层（QTargetBridge 桥接钩子需要该类型），
// 这里 re-export 保持既有 import 路径兼容
export 'package:qnote_flutter/core/agent/services/q_text_quote.dart' show QQuoteSource, QTextQuote;

// ==========================================
// 全局悬浮小Q快捷入口
//
// 与 AI 主页面会话完全隔离的轻量任务入口：
// - 页面上下文（QPageContext）让小Q知道当前界面与目标文件；
// - 临时会话按上下文签名留存：最小化成气泡、切页暂存、回到原页面恢复，
//   点右上角 × 才彻底丢弃；退出 App 即全部清空；
// - 任务结束后可在面板横幅中随时撤回本次会话的全部修改
//   （撤回横幅常驻不消失，直到撤回执行；期间发起新任务则跨任务累加）；
// - 消息为纯内存态，不落库、不污染 AI 主页面的会话历史；
//   只有「展开全页面」时才把当前临时会话提升为正式 ChatSession。
// ==========================================

/// 全局模态弹层计数（Dialog/BottomSheet 打开时悬浮层自动隐藏）
final floatingQModalCount = ValueNotifier<int>(0);

/// 模态路由观察者：挂在 GoRouter 的 observers（root Navigator）上，统计 PopupRoute。
///
/// 自愈设计：除 didPush/didPop/didRemove/didReplace 对称增删外，还给每个入集路由挂
/// 动画状态监听——弹层动画回到 dismissed 即代表它已关闭，若因事件丢失仍残留在集合中
/// 则强制剔除并重算，杜绝计数泄漏导致悬浮层永久隐藏。
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
  /// 漏掉都强制剔除（防止计数泄漏导致悬浮层永久隐藏）
  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    final stale = _openPopups
        .where((r) => r.animation == null || r.animation!.status == AnimationStatus.dismissed)
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

  /// 任务执行中（气泡播放动画，面板可查看进度并可中断）
  working,

  /// 撤回就绪：任务（或中断）结束后可随时在面板中撤回，
  /// 直到撤回执行；期间发起新任务则待撤回变更跨任务累加
  countdown,
}

/// 悬浮小Q的显示形态。
///
/// 三者是同一套容器的不同尺寸：弹窗 ↔ 气泡之间做容器变形，
/// [hidden] 表示当前页面没有临时会话（什么都不渲染）。
enum FloatingQPanelMode {
  /// 没有临时会话：弹窗和气泡都不显示
  hidden,

  /// 最小化为可拖动圆形气泡（会话仍存活）
  bubble,

  /// 居中弹窗展开
  panel,
}

/// 一个页面的临时会话快照。
///
/// 切页时把当前会话整体 park 到这里，回到同一页面再恢复；纯内存态，
/// 退出 App 即消失。最多保留 [FloatingQNotifier._kMaxParkedSessions] 个页面。
class _FloatingQSessionSnapshot {
  _FloatingQSessionSnapshot({
    required this.signature,
    required this.contextLabel,
    required this.messages,
    required this.pendingQuote,
    required this.attachedImages,
    required this.draftText,
    required this.minimized,
    required this.unreadReply,
    required this.pendingUndo,
    required this.phase,
    required this.updatedAt,
  });

  final String signature;
  final String? contextLabel;
  List<ChatMessage> messages;
  QTextQuote? pendingQuote;
  List<String> attachedImages;
  String draftText;
  bool minimized;
  bool unreadReply;
  List<WorkspaceUndoEntry> pendingUndo;
  FloatingQPhase phase;
  DateTime updatedAt;
}

/// 悬浮小Q状态
class FloatingQState {
  /// 路由推导的基础上下文
  final QPageContext? baseContext;

  /// 编辑页覆盖栈（后进先出，栈顶即当前编辑页）
  final List<QPageContext> overlayStack;

  /// 工作阶段
  final FloatingQPhase phase;

  /// 当前显示形态（隐藏 / 气泡 / 弹窗）
  final FloatingQPanelMode panelMode;

  /// 当前会话绑定的上下文签名（null 表示尚无会话）
  final String? contextSignature;

  /// 会话绑定时的上下文展示文案（面板徽章）
  final String? contextLabel;

  /// 本会话消息（纯内存，不落库）
  final List<ChatMessage> messages;

  /// 流式阶段状态文案（小Q思考中/执行操作等），与 [streamingText] 互斥
  final String? statusText;

  /// 「思考中」期间模型实时下发的思考过程文本，展示在状态行下方的
  /// 限高滚动区；模型不返回思考内容时保持 null（面板与现状一致）
  final String? streamingThought;

  /// 流式正文缓冲
  final String? streamingText;

  /// 本轮任务的开始时间（发送指令时记录，结束清理），供状态行显示已用时
  final DateTime? streamingStartedAt;

  /// 待撤回的变更处数
  final int pendingUndoCount;

  /// 是否正在执行撤回（防重入）
  final bool isUndoing;

  /// 「给小Q」挂起的待发送引用（面板展示为引用卡片，发送时一次性消费）
  final QTextQuote? pendingQuote;

  /// 面板是否处于外部分享模式（第三方分享文字/划词/分享图片唤起）：
  /// true 时头部不显示页面位置徽章，发送时也不注入页面上下文
  final bool externalShareMode;

  /// 待挂载的分享图片（外部分享图片唤起时传入，面板读取后转入附件区）
  final List<String>? pendingImages;

  /// 面板附件图片（本地路径），随下一轮发送一次性携带给小Q
  final List<String> attachedImages;

  /// 悬浮面板弹出的锚点对齐方式（默认底边居中 Alignment.bottomCenter）
  final Alignment anchorAlignment;

  /// 输入框草稿：面板卸载后仍随会话留存，重新打开/切回页面时回填
  final String draftText;

  /// 最小化期间是否收到了新的完成回复（气泡右上角小圆点）
  final bool unreadReply;

  /// 气泡左上角全局坐标（会话级共享；null 表示尚未放置，用默认右下角）
  final Offset? bubblePosition;

  /// 是否有任务正在执行（全局唯一，跨页面阻止并发发送）
  final bool runActive;

  const FloatingQState({
    this.baseContext,
    this.overlayStack = const [],
    this.phase = FloatingQPhase.idle,
    this.panelMode = FloatingQPanelMode.hidden,
    this.contextSignature,
    this.contextLabel,
    this.messages = const [],
    this.statusText,
    this.streamingThought,
    this.streamingText,
    this.streamingStartedAt,
    this.pendingUndoCount = 0,
    this.isUndoing = false,
    this.pendingQuote,
    this.externalShareMode = false,
    this.pendingImages,
    this.attachedImages = const [],
    this.anchorAlignment = Alignment.bottomCenter,
    this.draftText = '',
    this.unreadReply = false,
    this.bubblePosition,
    this.runActive = false,
  });

  /// 生效上下文：编辑页覆盖栈顶优先，否则取基础上下文
  QPageContext? get effectiveContext => overlayStack.isNotEmpty ? overlayStack.last : baseContext;

  /// 弹窗是否展开（兼容旧调用点）
  bool get panelOpen => panelMode == FloatingQPanelMode.panel;

  /// 是否已最小化成气泡
  bool get minimized => panelMode == FloatingQPanelMode.bubble;

  /// 当前页面是否还有值得留存的临时会话
  bool get hasSession =>
      messages.isNotEmpty ||
      draftText.isNotEmpty ||
      pendingQuote != null ||
      attachedImages.isNotEmpty ||
      pendingUndoCount > 0 ||
      panelMode != FloatingQPanelMode.hidden;

  FloatingQState copyWith({
    QPageContext? baseContext,
    List<QPageContext>? overlayStack,
    FloatingQPhase? phase,
    FloatingQPanelMode? panelMode,
    String? contextSignature,
    String? contextLabel,
    List<ChatMessage>? messages,
    String? statusText,
    String? streamingThought,
    String? streamingText,
    DateTime? streamingStartedAt,
    int? pendingUndoCount,
    bool? isUndoing,
    QTextQuote? pendingQuote,
    bool? externalShareMode,
    List<String>? pendingImages,
    List<String>? attachedImages,
    Alignment? anchorAlignment,
    String? draftText,
    bool? unreadReply,
    Offset? bubblePosition,
    bool? runActive,
    bool clearSignature = false,
    bool clearStatusText = false,
    bool clearStreamingThought = false,
    bool clearStreamingText = false,
    bool clearStreamingStartedAt = false,
    bool clearQuote = false,
    bool clearPendingImages = false,
    bool clearAttachedImages = false,
    bool clearBubblePosition = false,
  }) {
    return FloatingQState(
      baseContext: baseContext ?? this.baseContext,
      overlayStack: overlayStack ?? this.overlayStack,
      phase: phase ?? this.phase,
      panelMode: panelMode ?? this.panelMode,
      contextSignature: clearSignature ? null : (contextSignature ?? this.contextSignature),
      contextLabel: clearSignature ? null : (contextLabel ?? this.contextLabel),
      messages: messages ?? this.messages,
      statusText: clearStatusText ? null : (statusText ?? this.statusText),
      streamingThought: clearStreamingThought ? null : (streamingThought ?? this.streamingThought),
      streamingText: clearStreamingText ? null : (streamingText ?? this.streamingText),
      streamingStartedAt: clearStreamingStartedAt ? null : (streamingStartedAt ?? this.streamingStartedAt),
      pendingUndoCount: pendingUndoCount ?? this.pendingUndoCount,
      isUndoing: isUndoing ?? this.isUndoing,
      pendingQuote: clearQuote ? null : (pendingQuote ?? this.pendingQuote),
      externalShareMode: externalShareMode ?? this.externalShareMode,
      pendingImages: clearPendingImages ? null : (pendingImages ?? this.pendingImages),
      attachedImages: clearAttachedImages ? const [] : (attachedImages ?? this.attachedImages),
      anchorAlignment: anchorAlignment ?? this.anchorAlignment,
      draftText: draftText ?? this.draftText,
      unreadReply: unreadReply ?? this.unreadReply,
      bubblePosition: clearBubblePosition ? null : (bubblePosition ?? this.bubblePosition),
      runActive: runActive ?? this.runActive,
    );
  }
}

final floatingQProvider = NotifierProvider<FloatingQNotifier, FloatingQState>(FloatingQNotifier.new);

class FloatingQNotifier extends Notifier<FloatingQState> {
  /// 每个页面最多保留的临时会话数（LRU 淘汰）
  static const int _kMaxParkedSessions = 5;

  AgentCancellationToken? _currentToken;

  /// 本次会话累积的待撤回变更（跨多轮累加，撤回语义 = 撤销本会话小Q的全部修改）
  List<WorkspaceUndoEntry> _pendingUndo = [];

  /// 运行中任务的会话消息现场（事件流写入，结束时同步到 state）
  List<ChatMessage> _sessionMessages = const [];

  /// 任务运行期间是否已切离所属会话（切走后不再朗读、不再把流式内容写进新页面）
  bool _contextSwitchedDuringRun = false;

  final StringBuffer _streamBuffer = StringBuffer();
  // 「思考中」期间的模型思考增量缓冲，与正文共用同一个节流 flush 定时器
  final StringBuffer _thoughtBuffer = StringBuffer();
  Timer? _flushTimer;

  /// 分段朗读驱动：随正文增量逐段开口，一轮任务一个实例
  StreamingSpeechSession? _speech;

  /// 按页面签名暂存的临时会话（切页留存，退出 App 清空）
  final Map<String, _FloatingQSessionSnapshot> _parkedSessions = {};

  /// 当前运行中的任务属于哪个会话（同一时刻最多一个）
  String? _runSignature;

  /// 当前运行中任务的展示态，切回所属页面时恢复
  DateTime? _runStartedAt;
  String? _runStatus;

  /// 是否有任务在跑（跨页面阻止并发发送）
  bool _runActive = false;

  /// 面板被 × 彻底关闭后，正在收尾的异步任务不再回写任何状态
  bool _discardRun = false;

  /// 最近一次全局点按位置（容器变形的起点）
  Offset? _lastPointerDown;
  DateTime? _lastPointerDownAt;

  @override
  FloatingQState build() {
    ref.onDispose(() {
      _flushTimer?.cancel();
    });
    return const FloatingQState();
  }

  // ==========================================
  // 触发点与上下文注册
  // ==========================================

  /// 记录全局点按位置，供打开弹窗时从手指/按钮位置展开
  void recordPointerDown(Offset position) {
    _lastPointerDown = position;
    _lastPointerDownAt = DateTime.now();
  }

  /// 最近 1.2 秒内的点按位置；过期或没有点按时返回 null（走默认底部锚点）
  Offset? get lastPointerDown {
    final position = _lastPointerDown;
    final at = _lastPointerDownAt;
    if (position == null || at == null) return null;
    if (DateTime.now().difference(at) > const Duration(milliseconds: 1200)) return null;
    return position;
  }

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

  /// 生效上下文签名变化时切换临时会话：
  /// 旧会话（含消息、引用、附件、草稿、待撤回变更）park 起来，
  /// 新页面若有暂存会话则恢复成气泡，否则隐藏；不再直接清空历史。
  void _applyEffectiveContext() {
    final effective = state.effectiveContext;
    _switchToSession(effective?.signature, label: effective?.displayLabel, external: false);
  }

  /// 切换到指定签名的临时会话。
  ///
  /// [external] 为 true 时使用独立的 `external:share` 会话，不与页面会话互串。
  void _switchToSession(String? signature, {String? label, required bool external}) {
    final sameSignature = signature == state.contextSignature && external == state.externalShareMode;
    if (sameSignature) {
      if (label != null && label != state.contextLabel) {
        state = state.copyWith(contextLabel: label);
      }
      return;
    }

    // 运行中的任务属于旧会话：切走后不再朗读，也不再往新页面写流式内容
    if (_runActive && state.contextSignature == _runSignature) {
      _contextSwitchedDuringRun = true;
    }
    _parkActiveSession();

    final restored = signature == null ? null : _parkedSessions.remove(signature);
    _pendingUndo = restored?.pendingUndo ?? <WorkspaceUndoEntry>[];
    final isRunSession = _runActive && signature != null && signature == _runSignature;
    final restoredPhase = restored?.phase ?? FloatingQPhase.idle;
    final phase = isRunSession
        ? FloatingQPhase.working
        : (restoredPhase == FloatingQPhase.working ? FloatingQPhase.idle : restoredPhase);

    state = FloatingQState(
      baseContext: state.baseContext,
      overlayStack: state.overlayStack,
      phase: phase,
      panelMode: restored == null
          ? FloatingQPanelMode.hidden
          : (restored.minimized ? FloatingQPanelMode.bubble : FloatingQPanelMode.hidden),
      contextSignature: signature,
      contextLabel: label ?? restored?.contextLabel,
      messages: restored?.messages ?? const [],
      statusText: isRunSession ? _runStatus : null,
      streamingThought: isRunSession && _thoughtBuffer.isNotEmpty ? _thoughtBuffer.toString() : null,
      streamingText: isRunSession && _streamBuffer.isNotEmpty ? _streamBuffer.toString() : null,
      streamingStartedAt: isRunSession ? _runStartedAt : null,
      pendingUndoCount: _pendingUndo.length,
      pendingQuote: restored?.pendingQuote,
      externalShareMode: external,
      attachedImages: restored?.attachedImages ?? const [],
      draftText: restored?.draftText ?? '',
      unreadReply: restored?.unreadReply ?? false,
      bubblePosition: state.bubblePosition,
      anchorAlignment: state.anchorAlignment,
      runActive: _runActive,
    );
    _sessionMessages = List.of(state.messages);
  }

  /// 把当前会话整体暂存起来（切页/离开编辑器时调用）。
  ///
  /// 暂存态统一标记为「最小化」：回来时显示气泡而不是突然弹出对话框。
  void _parkActiveSession() {
    final signature = state.contextSignature;
    if (signature == null) return;
    final hasContent =
        state.messages.isNotEmpty ||
        state.draftText.isNotEmpty ||
        state.pendingQuote != null ||
        state.attachedImages.isNotEmpty ||
        state.pendingUndoCount > 0;
    if (!hasContent) {
      _parkedSessions.remove(signature);
      return;
    }
    _parkedSessions[signature] = _FloatingQSessionSnapshot(
      signature: signature,
      contextLabel: state.contextLabel,
      messages: List.of(state.messages),
      pendingQuote: state.pendingQuote,
      attachedImages: List.of(state.attachedImages),
      draftText: state.draftText,
      minimized: true,
      unreadReply: state.unreadReply,
      pendingUndo: List.of(_pendingUndo),
      phase: state.phase,
      updatedAt: DateTime.now(),
    );
    _pendingUndo = [];
    _evictParkedSessions();
  }

  /// 超出上限时按最后活跃时间淘汰最旧的页面，运行中的会话始终保留
  void _evictParkedSessions() {
    while (_parkedSessions.length > _kMaxParkedSessions) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _parkedSessions.entries) {
        if (entry.key == _runSignature) continue;
        if (oldestAt == null || entry.value.updatedAt.isBefore(oldestAt)) {
          oldestKey = entry.key;
          oldestAt = entry.value.updatedAt;
        }
      }
      if (oldestKey == null) break;
      _parkedSessions.remove(oldestKey);
    }
  }

  // ==========================================
  // 面板与会话操作
  // ==========================================

  /// 手动点开面板：回到页面上下文模式（外部分享模式仅在分享唤起时生效）
  void openPanel({Alignment anchorAlignment = Alignment.bottomCenter}) {
    final effective = state.effectiveContext;
    _switchToSession(effective?.signature, label: effective?.displayLabel, external: false);
    state = state.copyWith(
      panelMode: FloatingQPanelMode.panel,
      externalShareMode: false,
      anchorAlignment: anchorAlignment,
      unreadReply: false,
    );
  }

  /// 收起面板：最小化成气泡（无内容时直接隐藏）。
  ///
  /// 名称保留给旧调用点；「彻底关闭」走 [dismissActiveSession]。
  void closePanel() => minimizePanel();

  /// 最小化成气泡；当前页面没有值得留存的内容时直接隐藏
  void minimizePanel() {
    if (state.panelMode != FloatingQPanelMode.panel) return;
    final hasContent =
        state.messages.isNotEmpty ||
        state.draftText.isNotEmpty ||
        state.pendingQuote != null ||
        state.attachedImages.isNotEmpty ||
        state.pendingUndoCount > 0;
    state = state.copyWith(panelMode: hasContent ? FloatingQPanelMode.bubble : FloatingQPanelMode.hidden);
  }

  /// 彻底关闭当前页面的临时会话（× 按钮确认后调用）。
  ///
  /// 正在执行的任务会中止，且不再回写任何消息；待撤回变更一并丢弃。
  void dismissActiveSession() {
    _discardRun = true;
    _currentToken?.cancel('对话已关闭');
    AgentInteractionService.instance.cancelPending('对话已关闭');
    _speech?.onAbort();
    _pendingUndo = [];
    _sessionMessages = const [];
    final signature = state.contextSignature;
    if (signature != null) {
      _parkedSessions.remove(signature);
    }
    state = state.copyWith(
      panelMode: FloatingQPanelMode.hidden,
      messages: const [],
      clearQuote: true,
      clearAttachedImages: true,
      draftText: '',
      pendingUndoCount: 0,
      clearStatusText: true,
      clearStreamingText: true,
      clearStreamingThought: true,
      clearStreamingStartedAt: true,
      unreadReply: false,
    );
  }

  /// 「给小Q」引用入口：挂起引用并展开面板。
  ///
  /// 小Q工作中同样允许挂起（send 在 working 期是 no-op，引用保留待发），
  /// 引用在发送时一次性消费，期间可在面板引用卡片上移除。
  /// 外部内容（第三方分享/划词）唤起时进入外部模式：不展示也不注入页面位置
  void openWithQuote(QTextQuote quote, {Alignment anchorAlignment = Alignment.bottomCenter}) {
    final isExternal = quote.source == QQuoteSource.external;
    final effective = state.effectiveContext;
    _switchToSession(
      isExternal ? 'external:share' : effective?.signature,
      label: isExternal ? '系统分享' : effective?.displayLabel,
      external: isExternal,
    );
    state = state.copyWith(
      pendingQuote: quote,
      panelMode: FloatingQPanelMode.panel,
      externalShareMode: isExternal,
      anchorAlignment: anchorAlignment,
      unreadReply: false,
    );
  }

  /// 移除挂起的引用（引用卡片 × 按钮）
  void clearPendingQuote() => state = state.copyWith(clearQuote: true);

  /// 外部分享图片入口：挂起待挂载图片并展开面板（同样进入外部模式）
  void openWithImages(List<String> paths) {
    if (paths.isEmpty) return;
    _switchToSession('external:share', label: '系统分享', external: true);
    state = state.copyWith(
      pendingImages: List.of(paths),
      panelMode: FloatingQPanelMode.panel,
      externalShareMode: true,
      unreadReply: false,
    );
  }

  /// 面板消费挂起的分享图片：转入附件区展示，随下一轮发送一次性携带。
  /// 按路径对已有附件去重，防御推送+拉取双投递导致同一张图显示两次
  void consumePendingImages() {
    final pending = state.pendingImages;
    if (pending == null || pending.isEmpty) return;
    final existing = state.attachedImages.toSet();
    final added = pending.where((p) => !existing.contains(p)).toList();
    state = state.copyWith(attachedImages: [...state.attachedImages, ...added], clearPendingImages: true);
  }

  /// 「给小Q」：把面板里看到的图片直接挂到当前附件区，供就这张图继续追问。
  ///
  /// 与 [openWithImages] 的区别：后者是系统外部分享入口，会切到外部分享模式；
  /// 这里只是面板内的一次追加，不改变会话模式。
  void addAttachedImage(String path) {
    if (path.trim().isEmpty) {
      return;
    }
    if (state.attachedImages.contains(path)) {
      return;
    }
    state = state.copyWith(attachedImages: [...state.attachedImages, path]);
  }

  /// 移除一张附件图片（缩略图 × 按钮）
  void removeAttachedImage(String path) {
    state = state.copyWith(attachedImages: state.attachedImages.where((p) => p != path).toList());
  }

  /// 输入框草稿同步：面板卸载后仍能恢复未发送内容
  void updateDraft(String text) {
    if (state.draftText == text) return;
    state = state.copyWith(draftText: text);
  }

  /// 记录气泡最终位置（拖动结束后调用；纯内存，重启 App 回到默认右下角）
  void setBubblePosition(Offset position) {
    if (state.bubblePosition == position) return;
    state = state.copyWith(bubblePosition: position);
  }

  /// 手动开启新对话（清空历史；进行中的任务与待撤回变更不受影响）
  void newConversation() {
    if (state.runActive) return;
    _pendingUndo = [];
    _sessionMessages = const [];
    state = state.copyWith(
      messages: const [],
      clearStatusText: true,
      clearStreamingText: true,
      clearStreamingThought: true,
      clearStreamingStartedAt: true,
      // 挂起引用与附件图片属于旧会话上下文，随会话重置一并清空
      clearQuote: true,
      clearAttachedImages: true,
      draftText: '',
      pendingUndoCount: 0,
      unreadReply: false,
      phase: FloatingQPhase.idle,
    );
  }

  // ==========================================
  // 发送 / 中断 / 撤回
  // ==========================================

  /// 发送指令：上下文签名变化即自动切到对应会话；连续对话携带本会话历史。
  /// 支持仅附件图片、无文字的发送（自动补引导语）；发送时取走全部附件图片
  Future<void> send(String content) async {
    final text = content.trim();
    final images = List<String>.of(state.attachedImages);
    if ((text.isEmpty && images.isEmpty) || state.runActive) {
      return;
    }

    // 外部分享模式：独立会话签名（不与页面会话互串），不读取页面上下文
    final isExternal = state.externalShareMode;
    final ctx = isExternal ? null : state.effectiveContext;
    final signature = isExternal ? 'external:share' : (ctx?.signature ?? 'page:none');
    _switchToSession(signature, label: ctx?.displayLabel, external: isExternal);

    // 撤回就绪期发起新任务：保留并继续累加旧修改，撤回语义仍为
    // "撤销本会话小Q的全部修改"（逆序恢复天然按时间倒序覆盖多次任务）
    final userMessage = ChatMessage(
      role: 'user',
      content: text.isEmpty && images.isNotEmpty ? '请结合图片进行分析' : text,
      images: images.isEmpty ? null : images,
      timestamp: DateTime.now(),
    );

    // 「给小Q」引用一次性消费：随本次任务注入动态上下文（引用卡片同步移除）
    final quote = state.pendingQuote;

    state = state.copyWith(
      phase: FloatingQPhase.working,
      runActive: true,
      contextSignature: signature,
      contextLabel: ctx?.displayLabel ?? state.contextLabel,
      messages: [...state.messages, userMessage],
      statusText: '小Q准备中',
      streamingStartedAt: DateTime.now(),
      clearStreamingText: true,
      clearStreamingThought: true,
      clearQuote: true,
      clearAttachedImages: true,
      draftText: '',
      unreadReply: false,
    );
    _sessionMessages = List.of(state.messages);
    _runSignature = signature;
    _runStartedAt = state.streamingStartedAt;
    _runStatus = state.statusText;
    _runActive = true;
    _discardRun = false;
    _contextSwitchedDuringRun = false;

    // 通知目标编辑页任务开始（暂停自动保存）并记录编辑器指纹
    QTargetBridge.instance.notifyTaskStart(ctx?.signature);

    await _runAgentTask(ctx, signature, quote: quote);
  }

  /// 中断当前任务（已执行的部分修改同样进入撤回就绪状态）
  void stop() {
    _currentToken?.cancel('用户主动中止操作');
    AgentInteractionService.instance.cancelPending('用户主动中止操作');
    // 中止同时收声：只停 Agent 会让界面安静下来、语音却继续念完
    _speech?.onAbort();
  }

  /// 将最近一条步数上限消息标记为已处理（隐藏「继续/暂停」按钮）
  void _markTurnLimitHandled() {
    if (_discardRun) return;
    final messages = List<ChatMessage>.from(_sessionMessages);
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].uiDetails?['type'] == 'turn_limit') {
        messages[i] = messages[i].copyWith(uiDetails: {...?messages[i].uiDetails, 'handled': true});
        _sessionMessages = messages;
        state = state.copyWith(messages: List.of(messages));
        return;
      }
    }
  }

  /// 点击「继续」：以「继续」指令重启 Agent 循环接着执行未完成的任务
  Future<void> continueTask() async {
    if (state.runActive) return;
    _markTurnLimitHandled();
    await send('继续');
  }

  /// 点击「暂停」：仅隐藏按钮，已完成的工作保留，任务就此结束
  void pauseTask() {
    if (state.runActive) return;
    _markTurnLimitHandled();
  }

  /// 撤回本会话小Q的全部修改，返回 (恢复成功处数, 失败处数)；不可撤回时返回 null
  Future<(int restored, int failed)?> undo() async {
    if (state.phase != FloatingQPhase.countdown || state.isUndoing || _pendingUndo.isEmpty) {
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
        pendingUndoCount: 0,
        isUndoing: false,
        unreadReply: false,
      );
      return result;
    } catch (e) {
      LoggerService.instance.logAI('悬浮小Q撤回失败: $e', level: LogLevel.error);
      state = state.copyWith(isUndoing: false);
      return null;
    }
  }

  /// 把当前临时对话提升为正式会话，供「展开全页面」继续聊。
  ///
  /// 返回 null 表示当前没有可迁移的内容（已清空临时会话）；
  /// 任务执行中不可迁移，由调用方提示。
  Future<ChatSession?> promoteActiveSession() async {
    if (state.runActive) return null;
    final messages = List<ChatMessage>.of(state.messages);
    final draft = state.draftText.trim();
    if (messages.isEmpty && draft.isEmpty) {
      dismissActiveSession();
      return null;
    }

    ChatMessage? firstUser;
    for (final message in messages) {
      if (message.role == 'user') {
        firstUser = message;
        break;
      }
    }
    var title = (firstUser?.content ?? draft).trim().replaceAll(RegExp(r'\s+'), ' ');
    if (title.isEmpty) title = '与小Q的对话';
    if (title.length > 20) title = '${title.substring(0, 20)}…';

    final now = DateTime.now();
    final session = ChatSession(
      id: const Uuid().v4(),
      title: title,
      messages: messages,
      createdAt: now,
      updatedAt: now,
    );
    await ConfigRepository.instance.insertChatSession(session);
    ref.read(chatSessionListProvider.notifier).upsertLocal(session);
    ref.read(currentChatProvider.notifier).setSession(session);
    dismissActiveSession();
    return session;
  }

  // ==========================================
  // Agent 任务管线（与 AI 主会话同源的引擎与联动，独立轻量事件消费）
  // ==========================================

  Future<void> _runAgentTask(QPageContext? ctx, String signature, {QTextQuote? quote}) async {
    final token = AgentCancellationToken();
    _currentToken = token;
    _streamBuffer.clear();
    _thoughtBuffer.clear();
    final speechSink = ref.read(ttsPlaybackProvider.notifier);
    // 新一轮任务发起即打断上一轮仍在进行的语音朗读
    unawaited(speechSink.stop());
    _speech = StreamingSpeechSession(
      sink: speechSink,
      // 现在就去取音色与语速：首段切出来时通常已就绪，不必为它多等一次读库
      settings: QVoiceConfig.instance.get(),
      keyPrefix: 'stream_floating_q',
    );
    final recorderHandle = VirtualWorkspaceService.instance.startRecording();

    try {
      // 读取当前激活个性（对话开始时取一次，本轮中途的修改下轮生效——对齐记忆的冻结快照语义）
      final personality = await QPersonalityService.instance.getActivePersonality();
      // 生效人格落一条日志，便于排查「改了性格没生效」到底是没读到还是读到了没听话
      LoggerService.instance.logAI(
        '小Q本轮生效个性: ${personality.id}（${personality.name}），'
        '人格提示词 ${personality.prompt.length} 字',
      );

      // 页面上下文说明块：告诉小Q当前界面与目标文件（无目标页面则省略）；
      // 「给小Q」引用说明块：告诉小Q用户引用了哪段内容、位于哪个文件
      final pageBlock = await ctx?.toPromptBlock();
      final quoteBlock = quote == null ? null : await _quotePromptBlock(quote);
      final dynamicContext = await buildBaseDynamicContext(
        personality: personality,
        extraSections: [?pageBlock, ?quoteBlock],
      );

      final aiService = ref.read(aiServiceProvider);
      final roleSettings = await AiRoleService.instance.getSettingsForRole('assistant');
      // 绑定路由组时按组策略选成员并把组内切换器交给 AgentLoop；本轮带图片时
      // 优先选支持识图的成员，避免把图片发给看不见画面的模型
      final runHasImages = _sessionMessages.any((m) => m.images?.isNotEmpty ?? false);
      final assistantResolution = await AiRoleService.instance.resolveForRole('assistant', preferVision: runHasImages);
      final assistantConfig = assistantResolution.config;
      // 当前模型能否看图：同时决定提示词措辞与本轮图片是否进上下文。
      // 能力未知时先自动实测一次并落盘，避免把新加的视觉模型误判为不支持
      final supportsVisionInput = await VisionCapabilityProbe.ensure(assistantConfig);
      aiService.updateConfig(assistantConfig, temperature: roleSettings.temperature, maxTokens: roleSettings.maxTokens);

      // 预加载用户技能缓存，保证本次会话系统提示词中的技能索引完整
      await SkillRegistry.instance.ensureLoaded();

      // 可选工具按用户配置裁剪：禁用的工具不注册，系统提示词对应准则段也不注入
      final disabledTools = await AgentToolConfig.instance.getDisabledTools();
      final dispatcher = AgentToolRegistry.createDefaultDispatcher(disabledTools: disabledTools);
      final agentLoop = AgentLoop(
        aiService: aiService,
        dispatcher: dispatcher,
        maxTurns: 60,
        // 当前模型看不了图时，本轮图片在发请求前就换成 describe_image 引导（与主聊天一致）
        supportsImageInput: supportsVisionInput,
        route: assistantResolution.route,
        // 账号型选号作用域：悬浮窗是一段独立对话，按会话固定账号；
        // turnKey 用消息数近似「本轮」，同一条消息内的工具循环不换号
        requestScope: AiRequestScope(sessionKey: 'floating', turnKey: 'floating:${_sessionMessages.length}'),
        // 整池限流时不报错、不静默：与主聊天一致，把排队秒数写到悬浮窗状态行
        onQuotaHold: (hold) => _setStatus('服务商限流 · ${hold.inSeconds}s 后重试'),
        afterToolCall: (call, result) async {
          // 按 VFS 路径前缀联动刷新对应业务数据
          refreshWorkspaceSideEffects(ref, call.arguments['path'] as String? ?? '');
        },
      );

      ChatMessage? finalResponse;
      await for (final event in agentLoop.run(
        conversationHistory: List.of(_sessionMessages),
        systemPrompt: QSystemPrompt.buildSystemPrompt(
          personalityPrompt: personality.prompt,
          personalityName: personality.name,
          enabledOptionalTools: AgentToolRegistry.optionalToolNames.difference(disabledTools),
          supportsVisionInput: supportsVisionInput,
        ),
        dynamicContext: dynamicContext,
        cancellationToken: token,
      )) {
        switch (event.type) {
          case AgentEventType.agentStart:
            _setStatus('小Q准备中');
            break;
          case AgentEventType.turnStart:
            _streamBuffer.clear();
            // 新一轮思考从零开始，与状态行「第 N 步」语义对齐
            _thoughtBuffer.clear();
            // 上一轮的正文会被状态行覆盖，朗读跟着作废，否则"念半截又从头念"
            _speech?.onTurnStart();
            if (!_discardRun && _runSignature == state.contextSignature) {
              state = state.copyWith(clearStreamingThought: true);
            }
            // 首轮不展示步数，避免"第 1 步"这类无信息量文案
            _setStatus((event.turn ?? 0) > 1 ? '小Q思考中 · 第 ${event.turn} 步' : '小Q思考中');
            break;
          case AgentEventType.contentDelta:
            if (event.text != null) {
              _streamBuffer.write(event.text);
              _scheduleFlush();
              // 切页后不再喂正文：与"历史留存但不跨页面朗读"保持同一语义
              if (!_contextSwitchedDuringRun) _speech?.onContentDelta(event.text!);
            }
            break;
          case AgentEventType.reasoningDelta:
            if (event.text != null) {
              _thoughtBuffer.write(event.text);
              _scheduleFlush();
            }
            break;
          case AgentEventType.thoughtUpdate:
            // 轮末完整思考文本直接落入思考区展示（含 <thought> 标签协议路径），
            // 不再作为瞬态状态行文案被下一事件覆盖
            final thoughtText = event.text;
            if (thoughtText != null && thoughtText.isNotEmpty) {
              _thoughtBuffer
                ..clear()
                ..write(thoughtText);
              if (!_discardRun && _runSignature == state.contextSignature) {
                state = state.copyWith(streamingThought: thoughtText);
              }
            }
            break;
          case AgentEventType.toolCalling:
            // 模型正在流式生成工具调用参数（大参数期间可达数十秒），
            // 提前展示目标文件等信息，避免状态行停留在「思考中」形似卡死
            final callingTool = event.toolCall;
            if (callingTool != null && callingTool.name.isNotEmpty) {
              _setStatus(AgentToolLabels.progressLabel(callingTool.name, callingTool.arguments));
            }
            break;
          case AgentEventType.toolExecuting:
            final toolName = event.toolCall?.name ?? '';
            final extraProgress = event.text != null ? '（${event.text}）' : '';
            _setStatus('${AgentToolLabels.progressLabel(toolName, event.toolCall?.arguments)}$extraProgress');
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
        final isDup =
            _sessionMessages.isNotEmpty &&
            _sessionMessages.last.role == 'assistant' &&
            _sessionMessages.last.content.trim() == finalResponse.content.trim();
        if (!isDup) _appendSessionMessage(finalResponse, signature);

        // 语音回复：与 AI 主页面共用「小Q语音 → 自动朗读回复」开关。
        // 正文流式期间已逐段开口，这里只补上未满门槛的最后一段并收尾。
        // 只在答复确实落到当前可见会话时朗读（切页/用户主动中止时沉默）
        if (!_contextSwitchedDuringRun &&
            !token.isCancelled &&
            state.contextSignature == signature &&
            finalResponse.content.trim().isNotEmpty) {
          _speech?.onFinish(TtsPlayer.messageKeyOf(finalResponse));
        }
      }
      if (token.isCancelled && _sessionMessages.isNotEmpty) {
        final last = _sessionMessages.last;
        if (last.role != 'assistant' || !last.content.contains('中止')) {
          _appendSessionMessage(
            ChatMessage(role: 'assistant', content: '(已中止，可重新发送)', timestamp: DateTime.now()),
            signature,
          );
        }
      }
    } catch (e, stackTrace) {
      // 报错路径下已开口的半句不再续播，避免错误提示和语音打架
      _speech?.onAbort();
      LoggerService.instance.logAI('悬浮小Q任务执行失败: $e', level: LogLevel.error, details: stackTrace.toString());
      _appendSessionMessage(
        ChatMessage(
          role: 'assistant',
          content: '执行失败\n\n${AiErrorExplainer.describe(e)}',
          timestamp: DateTime.now(),
          isError: true,
        ),
        signature,
      );
    } finally {
      _flushTimer?.cancel();
      _flushTimer = null;
      _currentToken = null;
      final undoEntries = VirtualWorkspaceService.instance.stopRecording(recorderHandle);

      // 任务结束：目标编辑页指纹未变则重载刷新 UI（保留用户手动编辑的版本）
      await QTargetBridge.instance.notifyTaskEnd(ctx?.signature);

      _runActive = false;
      if (_discardRun) {
        // 面板已被 × 彻底关闭：本次任务的结果和撤回入口一并丢弃
        _discardRun = false;
        state = state.copyWith(
          phase: FloatingQPhase.idle,
          runActive: false,
          clearStatusText: true,
          clearStreamingText: true,
          clearStreamingThought: true,
          clearStreamingStartedAt: true,
        );
      } else {
        final isRunSession = state.contextSignature == signature;
        if (isRunSession) {
          // 本轮任务的修改并入待撤回集合（跨任务累加，撤回 = 撤销本会话全部修改）
          _pendingUndo.addAll(undoEntries);
          final hasUndo = _pendingUndo.isNotEmpty;
          state = state.copyWith(
            phase: hasUndo ? FloatingQPhase.countdown : FloatingQPhase.idle,
            messages: List.of(_sessionMessages),
            pendingUndoCount: _pendingUndo.length,
            runActive: false,
            // 最小化期间完成：气泡上亮未读点；面板开着则直接看到回复
            unreadReply: state.panelMode == FloatingQPanelMode.bubble,
            clearStatusText: true,
            clearStreamingText: true,
            clearStreamingThought: true,
            clearStreamingStartedAt: true,
          );
        } else {
          // 任务所属页面已切走：结果写回暂存会话，回来时以未读气泡提示
          final snapshot = _parkedSessions[signature];
          if (snapshot != null) {
            snapshot.messages = List.of(_sessionMessages);
            snapshot.pendingUndo.addAll(undoEntries);
            snapshot.phase = snapshot.pendingUndo.isNotEmpty ? FloatingQPhase.countdown : FloatingQPhase.idle;
            snapshot.unreadReply = true;
            snapshot.updatedAt = DateTime.now();
          }
          state = state.copyWith(
            runActive: false,
            clearStatusText: true,
            clearStreamingText: true,
            clearStreamingThought: true,
            clearStreamingStartedAt: true,
          );
        }
      }
      _runSignature = null;
      _runStatus = null;
      _runStartedAt = null;
      _sessionMessages = const [];
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
      QQuoteSource.external => '外部内容',
      QQuoteSource.chat => '对话内容',
    };

    // 外部分享内容（第三方分享/划词）：没有应用内来源实体可定位，
    // 直接把文本注入上下文即可，不做 VFS 路径解析、不给 read_file 指引
    if (quote.source == QQuoteSource.external) {
      return buildExternalQuoteBlock(quote);
    }

    // 对话内容（从面板消息中引用）：同样无 VFS 来源实体，
    // 直接注入文本，但措辞与外部内容区分
    if (quote.source == QQuoteSource.chat) {
      return buildChatQuoteBlock(quote);
    }

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
        idHint = '记录 id: ${quote.sourceId}（记录以 <!-- id: ... --> 标记内嵌在天文件中，修改单条记录时保留其标记）';
      case QQuoteSource.journal:
        final date = DateTime.tryParse(quote.sourceId);
        if (date == null) return null;
        path = workspace.journalPathForDate(date);
        idHint = '日期: ${quote.sourceId}';
      case QQuoteSource.todo:
        path = await workspace.resolveTodoPath(quote.sourceId);
        idHint = '待办 id: ${quote.sourceId}（文件头部为 YAML frontmatter，修改时保留其中的 id 字段）';
      case QQuoteSource.external:
        // 外部内容已在方法开头提前返回，此处不可达
        return null;
      case QQuoteSource.chat:
        // 对话内容已在方法开头提前返回，此处不可达
        return null;
    }

    // 引用过长时截断：引用文本主要用于定位，完整内容以 read_file 实际读取为准
    var text = quote.quotedText.trim();
    if (text.isEmpty) text = '（用户未附加摘录，请直接根据来源定位完整内容）';
    if (text.length > 2000) text = '${text.substring(0, 2000)}…（引用过长已截断）';

    final isCursorLocation = quote.locationDesc?.contains('光标') == true;

    return [
      '用户引用的内容（用户通过「给小Q」主动引用，接下来的指令通常针对这段内容提问或要求修改）',
      '来源：$sourceLabel《${quote.sourceTitle}》（$idHint${path == null ? '' : '，虚拟工作区文件: $path'}）',
      if (quote.locationDesc != null) '位置：${quote.locationDesc}（按引用时的内容估算，可能与文件当前实际内容有细微出入）',
      '引用文本：',
      '"""',
      text,
      '"""',
      if (isCursorLocation)
        '注意：用户当前定位在光标处（引用文本中以【光标】标记具体插入位置），指令通常要求在此处续写、补全或插入内容。请先 read_file 定位该行与上下文，使用 edit_file 在光标位置处插入续写内容；若指令与续写无关则按常规要求处理'
      else
        '请先 read_file 上述文件定位该内容（以文件实际内容为准），需要修改时用 edit_file 精确替换；若指令与引用内容无关则按通用指令处理',
    ].join('\n');
  }

  @visibleForTesting
  Future<String?> quotePromptBlockForTest(QTextQuote quote) => _quotePromptBlock(quote);

  /// 组装外部分享内容的注入块：无应用内来源实体，直接注入文本本身，
  /// 并显式告知小Q不要尝试 read_file 定位。返回 null 表示无可注入内容
  @visibleForTesting
  static String? buildExternalQuoteBlock(QTextQuote quote) {
    var externalText = quote.quotedText.trim();
    if (externalText.isEmpty) return null;
    if (externalText.length > 2000) {
      externalText = '${externalText.substring(0, 2000)}…（内容过长已截断）';
    }
    return [
      '用户分享的外部内容（来自第三方应用，接下来的指令通常针对这段内容提问或要求处理）',
      '分享内容：',
      '"""',
      externalText,
      '"""',
      '上述内容无法在虚拟工作区中定位，不要尝试用 read_file 查找它，直接基于内容本身处理',
    ].join('\n');
  }

  /// 组装对话内容的注入块：引用来自面板内某条消息的片段，
  /// 无 VFS 来源实体，直接注入文本。返回 null 表示无可注入内容
  @visibleForTesting
  static String? buildChatQuoteBlock(QTextQuote quote) {
    var chatText = quote.quotedText.trim();
    if (chatText.isEmpty) return null;
    if (chatText.length > 2000) {
      chatText = '${chatText.substring(0, 2000)}…（内容过长已截断）';
    }
    return [
      '用户引用的对话内容（来自当前对话中某条消息的片段，接下来的指令通常针对这段内容提问或要求处理）',
      '引用内容：',
      '"""',
      chatText,
      '"""',
      '上述内容来自对话本身，不要尝试用 read_file 查找它，直接基于内容本身处理',
    ].join('\n');
  }

  /// 追加会话消息：只回写到任务所属的可见会话，切走的页面不串显
  void _appendSessionMessage(ChatMessage message, String runSignature) {
    _sessionMessages = [..._sessionMessages, message];
    if (_discardRun) return;
    if (!_contextSwitchedDuringRun && state.contextSignature == runSignature) {
      state = state.copyWith(messages: List.of(_sessionMessages));
    }
  }

  void _setStatus(String text) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_discardRun || _runSignature != state.contextSignature) return;
    _runStatus = text;
    state = state.copyWith(statusText: text, clearStreamingText: true);
  }

  /// 以约 60ms 的节奏批量刷新流式文本到面板（与 AI 主会话相同的节流策略），
  /// 正文与思考缓冲共用本定时器；正文已开始时思考区随状态行一并退场
  void _scheduleFlush() {
    if (_flushTimer != null && _flushTimer!.isActive) return;
    _flushTimer = Timer(const Duration(milliseconds: 60), () {
      if (_discardRun || _runSignature != state.contextSignature) return;
      final content = _streamBuffer.toString();
      if (content.isNotEmpty) {
        state = state.copyWith(streamingText: content, clearStatusText: true, clearStreamingThought: true);
      } else if (_thoughtBuffer.isNotEmpty) {
        state = state.copyWith(streamingThought: _thoughtBuffer.toString());
      }
    });
  }
}

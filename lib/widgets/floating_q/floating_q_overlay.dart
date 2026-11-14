import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/chat_image_dedupe.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/core/utils/q_bubble_layout.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/ai/agent_turn_limit_actions.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/ai/quick_prompt_dialog.dart';
import 'package:qnote_flutter/widgets/ai/workflow_process_view.dart';
import 'package:qnote_flutter/widgets/chat/chat_image_view.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';
import 'package:qnote_flutter/widgets/common/thinking_process_view.dart';
import 'package:qnote_flutter/widgets/q_text_selection_toolbar.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

part 'floating_q_bubble.dart';
part 'floating_q_panel.dart';

// ==========================================
// 悬浮小Q：居中弹窗 + 可拖动气泡
//
// 同一套容器在「触发点 / 气泡 / 弹窗」三种尺寸间变形：
// - 打开：从最近一次点按位置（或气泡 Rect）长成居中弹窗；
// - 最小化：弹窗缩成气泡，内容先淡出、幽灵气泡最后落位；
// - 关闭（×）：轻量缩放淡出，会话彻底丢弃。
//
// 弹窗挂在 MaterialApp.builder 的全局 Stack 上，覆盖所有路由页面。
// ==========================================

/// 打开变形：容器从触发点长到弹窗，走 M3 强调型空间曲线。
const Duration _kMorphOpenDuration = Duration(milliseconds: 460);

/// 最小化变形：比打开更快，不拖住用户继续编辑。
const Duration _kMorphCloseDuration = Duration(milliseconds: 320);

/// × 彻底关闭的缩放淡出。
const Duration _kDialogExitDuration = Duration(milliseconds: 220);

/// 气泡松手磁吸回边的时长。
const Duration _kBubbleSnapDuration = Duration(milliseconds: 220);

/// 弹窗圆角（与记录面板保持同一视觉语言）。
const double _kDialogRadius = 24;

/// 弹窗最大宽高：手机铺满左右 16 边距，桌面/平板不无限拉宽。
const double _kDialogMaxWidth = 560;
const double _kDialogMaxHeight = 640;
const double _kDialogMinHeight = 240;
const double _kDialogVerticalMargin = 24;

/// 键盘避让的过渡时长。
///
/// Android 上 `viewInsets` 往往是一次跳变或几段跳变，若布局直接跟每一帧
/// 重算，弹窗会在键盘落定的瞬间「咔」地缩一下。这里统一用一段短动效
/// 收放，和系统键盘弹起的时间大致同步，看起来是卡片跟着键盘一起让位。
const Duration _kKeyboardAvoidDuration = Duration(milliseconds: 220);

/// 气泡尺寸与贴边留白。
///
/// 尺寸与落点算法统一放在 `lib/core/utils/q_bubble_layout.dart`：那里把「避开
/// 导航栏 + 右下角悬浮按钮行」写成可单测的常量与纯函数，避免再次出现
/// 「气泡压住时间线智能提取按钮」这类只能靠真机发现的叠压问题。
const double _kBubbleSize = kQBubbleSize;

/// 默认气泡位置需越过底部导航栏与页面右下角的悬浮按钮行。
const double _kBubbleDefaultBottomGap = kQBubbleDefaultBottomGap;

/// 全局小Q快捷对话层。
///
/// 挂载于 MaterialApp.builder 的 Stack 上层，覆盖所有路由页面（含编辑器）。
/// 弹窗由底部导航栏中央按钮长按唤起，或由「给小Q」选区菜单、外部分享自动唤起。
/// 模态弹窗打开时淡出隐藏。
class FloatingQOverlay extends ConsumerStatefulWidget {
  const FloatingQOverlay({super.key});

  @override
  ConsumerState<FloatingQOverlay> createState() => _FloatingQOverlayState();
}

class _FloatingQOverlayState extends ConsumerState<FloatingQOverlay> with TickerProviderStateMixin {
  /// 量弹窗卡片最终 Rect 的 Key（容器变形目标）。
  final GlobalKey _surfaceKey = GlobalKey();

  late final AnimationController _morphController;
  late final CurvedAnimation _rectProgress;
  late final CurvedAnimation _scrimProgress;
  late final CurvedAnimation _ghostProgress;

  /// × 关闭时独立的退出控制器：变形动画此时可能停在 1。
  late final AnimationController _exitController;

  /// 正在播放「弹窗 → 气泡」的反向变形。
  bool _minimizing = false;

  /// 正在播放 × 的缩放淡出。
  bool _closing = false;

  /// 打开变形起点（点按位置或气泡 Rect），在动画开始时固定。
  Rect? _openOrigin;

  /// 内容窗口暂时量不到弹窗 Rect 时（首帧/收回后段）留一份上次值。
  Rect? _lastDialogRect;

  /// 拖动气泡期间的实时位置（松手后清空，交给 provider 的最终位置）。
  Offset? _liveBubblePosition;

  Size _lastSize = Size.zero;
  EdgeInsets _lastPadding = EdgeInsets.zero;
  double _lastKeyboardInset = 0;

  /// 最小化/关闭开始时锁定的键盘高度。
  ///
  /// 收起键盘要几百毫秒，这期间 `viewInsets` 会一路回落。若变形目标 Rect
  /// 仍跟着它变，卡片会在缩向气泡的同时突然拉长，视觉上就是「缩一半又弹回」。
  double _frozenKeyboardInset = 0;
  bool _reduceMotion = false;

  /// 路由变化导致的隐藏：直接落终态，不在新页面上方播放退场动画。
  bool _navigationHiding = false;

  GoRouter? _router;
  late final VoidCallback _routeListener;
  String _location = '';

  /// 面板内 SelectionArea 当前选中文本（供面板内「给小Q」工具栏引用）
  final _panelSelection = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _morphController = AnimationController(
      vsync: this,
      duration: _kMorphOpenDuration,
      reverseDuration: _kMorphCloseDuration,
    )..addStatusListener(_handleMorphStatus);
    _rectProgress = CurvedAnimation(
      parent: _morphController,
      curve: AppCurves.emphasizedSpatial,
      reverseCurve: AppCurves.exit,
    );
    _scrimProgress = CurvedAnimation(
      parent: _morphController,
      curve: const Interval(0, 0.45, curve: AppCurves.emphasized),
      reverseCurve: const Interval(0.25, 1, curve: AppCurves.exit),
    );
    _ghostProgress = CurvedAnimation(
      parent: _morphController,
      curve: const Interval(0, 0.25, curve: AppCurves.emphasized),
      reverseCurve: const Interval(0.55, 0.9, curve: AppCurves.emphasized),
    );
    _exitController = AnimationController(vsync: this, duration: _kDialogExitDuration)
      ..addStatusListener(_handleExitStatus);

    _router = ref.read(routerProvider);
    _location = _router!.routerDelegate.currentConfiguration.uri.toString();
    _routeListener = () {
      final uri = _router!.routerDelegate.currentConfiguration.uri.toString();
      if (uri == _location || !mounted) return;
      // 路由通知可能发生在 build 阶段（如 redirect），延后到帧末处理，
      // 避免 setState / 修改 Provider 在 build 期抛异常
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || uri == _location) return;
        // 页面已经切走：弹窗/气泡直接落终态，不要跨页面播放退场
        _navigationHiding = true;
        setState(() => _location = uri);
        // 路由变化同步基础上下文：签名变化驱动临时会话 park/restore；
        // 同时把新页面若有会话自动收成气泡（弹窗不跨页面跟随）
        ref.read(floatingQProvider.notifier)
          ..setBaseContext(QPageContext.fromLocation(uri))
          ..closePanel();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigationHiding = false;
        });
      });
    };
    _router!.routerDelegate.addListener(_routeListener);
    // 初始化基础页面上下文（编辑页覆盖上下文由各编辑页自行注册），同样延后到帧末
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(floatingQProvider.notifier).setBaseContext(QPageContext.fromLocation(_location));
    });
  }

  @override
  void dispose() {
    _panelSelection.dispose();
    _router?.routerDelegate.removeListener(_routeListener);
    _morphController.removeStatusListener(_handleMorphStatus);
    _exitController.removeStatusListener(_handleExitStatus);
    _morphController.dispose();
    _exitController.dispose();
    _rectProgress.dispose();
    _scrimProgress.dispose();
    _ghostProgress.dispose();
    super.dispose();
  }

  void _handleMorphStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !_minimizing) return;
    // 气泡落到目标位置：先补上默认位置，再切真实气泡，避免下一帧跳位
    _ensureBubblePosition();
    setState(() => _minimizing = false);
  }

  void _handleExitStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    setState(() => _closing = false);
    _exitController.reset();
  }

  /// 打开：从气泡（或最近点按位置）容器变形到居中弹窗。
  void _startOpen({required bool fromBubble}) {
    _minimizing = false;
    _closing = false;
    if (_reduceMotion) {
      _morphController.value = 1;
      return;
    }
    _openOrigin = fromBubble ? _bubbleRect(_lastSize, _lastPadding, _lastKeyboardInset) : _tapOriginRect();
    _morphController.forward(from: 0);
  }

  /// 最小化：弹窗反向缩成气泡（内容先收口，幽灵最后落位）。
  void _startMinimize() {
    if (_reduceMotion) {
      _morphController.value = 0;
      _ensureBubblePosition();
      setState(() => _minimizing = false);
      return;
    }
    // 调用方已收起焦点，键盘会随后回落；把当前高度锁住，
    // 收缩目标在整个变形过程中保持不变。
    _frozenKeyboardInset = _lastKeyboardInset;
    setState(() => _minimizing = true);
    _morphController.reverse();
  }

  /// × 彻底关闭：轻量缩放淡出，会话已由 provider 清空。
  void _startClose() {
    _minimizing = false;
    _frozenKeyboardInset = _lastKeyboardInset;
    if (_reduceMotion) {
      _morphController.value = 0;
      return;
    }
    setState(() => _closing = true);
    _exitController.forward(from: 0);
  }

  /// 最小化时若还没有气泡位置，落到默认右下角（导航栏上方）
  void _ensureBubblePosition() {
    if (ref.read(floatingQProvider).bubblePosition != null) return;
    final position = _defaultBubblePosition(_lastSize, _lastPadding, _lastKeyboardInset);
    ref
        .read(floatingQProvider.notifier)
        .setBubblePosition(_clampBubblePosition(position, _lastSize, _lastPadding, _lastKeyboardInset));
  }

  void _handleMinimize() {
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(floatingQProvider.notifier).minimizePanel();
  }

  void _handleBubbleTap() {
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(floatingQProvider.notifier).openPanel();
  }

  /// 撤回小Q本会话的全部修改并提示结果
  Future<void> _handleUndo() async {
    final result = await ref.read(floatingQProvider.notifier).undo();
    if (result == null || !mounted) return;
    final (restored, failed) = result;
    final toastContext = rootNavigatorKey.currentContext;
    if (toastContext == null || !toastContext.mounted) return;
    if (failed > 0) {
      Toast.warning(toastContext, '已撤回 $restored 处修改，$failed 处失败');
    } else {
      Toast.success(toastContext, '已撤回小Q的 $restored 处修改');
    }
  }

  /// × 关闭：执行中或还有可撤回修改时先二次确认，避免误关后无法撤回。
  Future<void> _handleClose() async {
    final state = ref.read(floatingQProvider);
    if (state.runActive || state.pendingUndoCount > 0) {
      final dialogContext = rootNavigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      final confirmed = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('结束本次对话？'),
          content: Text(state.runActive ? '小Q 正在处理任务，关闭会中止本次任务。' : '小Q 已修改 ${state.pendingUndoCount} 处内容，关闭后将无法在这里撤回。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('结束对话')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    ref.read(floatingQProvider.notifier).dismissActiveSession();
  }

  /// 展开全页面：把临时对话提升为正式会话，再进入 /ai 继续聊。
  Future<void> _handleExpand() async {
    final notifier = ref.read(floatingQProvider.notifier);
    if (ref.read(floatingQProvider).runActive) {
      Toast.info(context, '小Q正在处理任务，结束或中止后再展开');
      return;
    }
    try {
      await notifier.promoteActiveSession();
      if (!mounted) return;
      // 不能用 context.push：本浮层挂在 MaterialApp.builder 的 Stack 上，位于路由
      // Navigator 之外，context 里没有 GoRouter 的 InheritedWidget，会直接抛
      // 「No GoRouter found in context」。initState 已缓存 router 实例，走它。
      final router = _router;
      if (router == null) {
        Toast.error(context, '展开失败：导航未就绪，请重试');
        return;
      }
      router.push('/ai');
    } catch (e) {
      if (mounted) {
        Toast.error(context, '展开失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 精确订阅：流式期间 provider 以约 60ms 节奏刷新消息/流式文本，
    // 这里只关心形态与气泡状态，避免整条悬浮层被高频重建。
    final mode = ref.watch(floatingQProvider.select((s) => s.panelMode));
    final runActive = ref.watch(floatingQProvider.select((s) => s.runActive));
    final unread = ref.watch(floatingQProvider.select((s) => s.unreadReply));
    final bubblePosition = ref.watch(floatingQProvider.select((s) => s.bubblePosition));

    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    _lastSize = size;
    _lastPadding = padding;
    _lastKeyboardInset = keyboardInset;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    final layoutKeyboardInset = _resolveKeyboardInset(keyboardInset);

    ref.listen<FloatingQPanelMode>(floatingQProvider.select((s) => s.panelMode), (prev, next) {
      if (prev == next) return;
      if (_navigationHiding) {
        _morphController.value = next == FloatingQPanelMode.panel ? 1 : 0;
        _minimizing = false;
        _closing = false;
        return;
      }
      if (next == FloatingQPanelMode.panel) {
        _startOpen(fromBubble: prev == FloatingQPanelMode.bubble);
      } else if (next == FloatingQPanelMode.bubble) {
        _startMinimize();
      } else if (next == FloatingQPanelMode.hidden) {
        _startClose();
      }
    });

    // 弹窗页只依赖屏幕尺寸/安全区与会话签名，morph 期间这些都不变：在 build
    // 时构建一次，交给 AnimatedBuilder.child 复用。变形每帧只重建外壳
    // （Positioned/圆角/阴影/裁剪），不再每帧重建整块对话面板与消息列表。
    final showDialog = _closing || _minimizing || mode == FloatingQPanelMode.panel;
    final Widget? dialogPage = showDialog ? _buildDialogPage(size, padding, layoutKeyboardInset) : null;

    return ValueListenableBuilder<int>(
      valueListenable: floatingQModalCount,
      builder: (context, modalCount, _) {
        // 模态弹窗（对话框/底部弹层）打开时隐藏悬浮层。
        // 内容用 Offstage 隐藏而非整层 Opacity：既保留面板 Element/State
        // （输入框文本、滚动位置不丢），又不会对整屏叠加层做 saveLayer。
        final layerHidden = modalCount > 0;

        return IgnorePointer(
          ignoring: layerHidden,
          child: AnimatedBuilder(
            animation: Listenable.merge([_morphController, _exitController]),
            child: dialogPage,
            builder: (context, child) {
              final showBubble = mode == FloatingQPanelMode.bubble && !_minimizing && !_closing;
              return Stack(
                children: [
                  if (showDialog)
                    ..._buildDialogLayers(
                      size,
                      padding,
                      keyboardInset,
                      layoutKeyboardInset,
                      bubblePosition,
                      child!,
                      hidden: layerHidden,
                    ),
                  // 气泡根节点是 AnimatedPositioned，直接再包 Opacity/Offstage 会
                  // 在 Stack 与 Positioned 之间插入 RenderObject、破坏 ParentData；
                  // 它只有几十像素，模态遮挡时干脆不挂载（无需保留内部拖拽状态）。
                  if (showBubble && !layerHidden)
                    _FloatingQBubble(
                      key: const ValueKey('floating-q-bubble'),
                      position: _bubblePosition(size, padding, keyboardInset, bubblePosition),
                      working: runActive,
                      unread: unread,
                      onTap: _handleBubbleTap,
                      onDragUpdate: (position) {
                        final clamped = _clampBubblePosition(position, size, padding, keyboardInset);
                        setState(() => _liveBubblePosition = clamped);
                      },
                      onDragEnd: () {
                        final current =
                            _liveBubblePosition ?? _bubblePosition(size, padding, keyboardInset, bubblePosition);
                        final snapped = _snapBubble(current, size);
                        setState(() => _liveBubblePosition = null);
                        ref.read(floatingQProvider.notifier).setBubblePosition(snapped);
                      },
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // ==========================================
  // 变形层
  // ==========================================

  List<Widget> _buildDialogLayers(
    Size size,
    EdgeInsets padding,
    double keyboardInset,
    double layoutKeyboardInset,
    Offset? bubblePosition,
    Widget page, {
    required bool hidden,
  }) {
    if (_closing) {
      final fade = Curves.easeInCubic.transform(_exitController.value);
      final remaining = (1 - fade).clamp(0.0, 1.0);
      return [
        // 遮罩直接按纯色 alpha 淡出，仅内容窗做缩放 + 淡出，避免把全屏遮罩也拖进离屏 saveLayer
        _buildScrim(remaining, allowDismiss: false, hidden: hidden),
        Positioned.fill(
          child: Offstage(
            offstage: hidden,
            child: Opacity(
              opacity: remaining,
              child: Transform.scale(
                scale: 0.96 + 0.04 * remaining,
                child: Stack(
                  fit: StackFit.expand,
                  children: [_buildContentWindow(Offset.zero & size, 0, size, page, clip: false, interactive: false)],
                ),
              ),
            ),
          ),
        ),
      ];
    }

    // 打开动画结束：容器/幽灵撤掉，内容窗口铺满全屏并停止裁切。
    // 面板 widget 必须始终待在同一个带 Key 的窗口里 —— 直接把它挪到
    // Stack 的另一层会让 Element 重新挂载，输入框和焦点会被重置。
    final isSteady = !_minimizing && _morphController.value >= 1;
    if (isSteady) {
      return [
        _buildScrim(1, allowDismiss: true, hidden: hidden),
        _buildBody(hidden, [_buildContentWindow(Offset.zero & size, 0, size, page, clip: false)]),
      ];
    }

    final dialogRect = _readDialogRect() ?? _lastDialogRect ?? _fallbackDialogRect(size, padding, layoutKeyboardInset);
    _lastDialogRect = dialogRect;
    final bubbleRect = _bubbleRect(size, padding, keyboardInset, bubblePosition);
    final origin = _minimizing ? bubbleRect : (_openOrigin ?? dialogRect);
    final t = _rectProgress.value;
    final rect = Rect.lerp(origin, dialogRect, t)!;
    final radius = lerpDouble(_kBubbleSize / 2, _kDialogRadius, t)!;
    final scheme = Theme.of(context).colorScheme;
    final color = Color.lerp(scheme.primary, scheme.surface, t)!;
    final shadow = _lerpShadow(_bubbleShadow(scheme), _dialogShadow(scheme), t);
    final ghostOpacity = (1 - _ghostProgress.value).clamp(0.0, 1.0);
    final ghostRect = _minimizing ? bubbleRect : (_openOrigin ?? bubbleRect);

    return [
      _buildScrim(_scrimProgress.value, allowDismiss: !_minimizing && !_closing && t > 0.4, hidden: hidden),
      _buildBody(hidden, [
        _buildContainer(rect, radius, color, shadow),
        _buildContentWindow(rect, radius, size, page, interactive: !_minimizing && !_closing),
        if (ghostOpacity > 0.001)
          Positioned.fromRect(
            key: const ValueKey('floating-q-bubble-ghost'),
            rect: ghostRect,
            child: IgnorePointer(
              child: Opacity(
                opacity: ghostOpacity,
                child: _FloatingQBubbleVisual(working: ref.read(floatingQProvider).runActive, unread: false),
              ),
            ),
          ),
      ]),
    ];
  }

  /// 把变形主体（容器 + 内容窗口 + 幽灵气泡）收进同一层，供模态遮挡时整体隐藏。
  ///
  /// [Offstage] 只跳过绘制与命中测试，不卸载子树：面板 State 里的输入框文本、
  /// 消息滚动位置和选区都保留。相比给整块内容套 Opacity，它不会建立离屏层。
  Widget _buildBody(bool hidden, List<Widget> children) {
    return Positioned.fill(
      child: Offstage(
        offstage: hidden,
        child: Stack(children: children),
      ),
    );
  }

  /// 自绘遮罩。
  ///
  /// 变形路径把路由的 barrier 设成透明，遮罩跟着容器一起动；[allowDismiss]
  /// 为 false 时仍然吃掉点击（空回调），防止穿透到下面的页面。
  ///
  /// [hidden] 控制模态弹窗打开时的淡出：这里只插值纯色 alpha，不套 Opacity，
  /// 因此不会为整屏建立 saveLayer。
  Widget _buildScrim(double opacity, {required bool allowDismiss, bool hidden = false}) {
    final baseAlpha = 0.4 * opacity.clamp(0.0, 1.0).toDouble();
    return Positioned.fill(
      key: const ValueKey('floating-q-scrim'),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: hidden ? 0 : 1),
        duration: AppMotion.duration(context, AppDurations.normal),
        curve: AppCurves.emphasized,
        builder: (context, visible, _) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: allowDismiss ? _handleMinimize : () {},
            child: ColoredBox(color: Colors.black.withValues(alpha: baseAlpha * visible)),
          );
        },
      ),
    );
  }

  /// 变形容器的底色/圆角/阴影。
  Widget _buildContainer(Rect rect, double radius, Color color, BoxShadow shadow) {
    return Positioned.fromRect(
      key: const ValueKey('floating-q-morph-slot'),
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('floating-q-morph'),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius), boxShadow: [shadow]),
        ),
      ),
    );
  }

  /// 把整页弹窗内容裁进变形窗口。
  ///
  /// [OverflowBox] 让弹窗仍按最终全屏尺寸布局，[Transform.translate] 再把
  /// 整页平移回全屏原点——外层 Positioned 的偏移和这里的平移恰好抵消，所以
  /// 窗口怎么变都不会触发弹窗重新布局，量到的卡片 Rect 也始终是最终值。
  ///
  /// [page] 由外层 build 构建一次后跨帧复用，morph 每帧只更新这里的平移与裁剪。
  Widget _buildContentWindow(
    Rect rect,
    double radius,
    Size size,
    Widget page, {
    bool clip = true,
    bool interactive = true,
  }) {
    return Positioned.fromRect(
      key: const ValueKey('floating-q-window'),
      rect: rect,
      child: IgnorePointer(
        // 收回/关闭途中内容已经不可见，不能再让点击命中弹窗里的按钮。
        ignoring: !interactive,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          clipBehavior: clip ? Clip.antiAlias : Clip.none,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: Transform.translate(
              offset: -rect.topLeft,
              child: RepaintBoundary(child: page),
            ),
          ),
        ),
      ),
    );
  }

  /// 居中弹窗页面：按最终屏幕坐标布局，供变形窗口裁切/量取。
  ///
  /// 键盘高度不直接拿 `viewInsets` 硬算：外面套一层 [TweenAnimationBuilder]，
  /// 让卡片高度/位置在 [_kKeyboardAvoidDuration] 内平滑过渡。面板本体作为
  /// `child` 预先构建，动画期间只重新布局、不重建输入框与消息列表。
  Widget _buildDialogPage(Size size, EdgeInsets padding, double keyboardInset) {
    final dialogWidth = math.min(_kDialogMaxWidth, math.max(0.0, size.width - 32));
    // 会话切换时面板必须重挂载：输入草稿从 provider 回填，避免串到另一段对话
    final sessionKey = ref.watch(floatingQProvider.select((s) => (s.contextSignature, s.externalShareMode)));
    final panel = _FloatingQPanel(
      key: ValueKey('floating-q-panel-${sessionKey.$1 ?? 'none'}-${sessionKey.$2}'),
      surfaceKey: _surfaceKey,
      entrance: _morphController,
      panelSelection: _panelSelection,
      onUndo: _handleUndo,
      onMinimize: _handleMinimize,
      onClose: _handleClose,
      onExpand: _handleExpand,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: keyboardInset),
      duration: AppMotion.duration(context, _kKeyboardAvoidDuration),
      curve: AppCurves.emphasized,
      child: panel,
      builder: (context, animatedInset, child) {
        final bottomInset = math.max(padding.bottom, animatedInset);
        final availableHeight = math.max(
          _kDialogMinHeight,
          size.height - padding.top - _kDialogVerticalMargin * 2 - bottomInset,
        );
        final dialogHeight = math.min(_kDialogMaxHeight, availableHeight);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            padding.top + _kDialogVerticalMargin,
            16,
            bottomInset + _kDialogVerticalMargin,
          ),
          child: Center(
            child: SizedBox(width: dialogWidth, height: dialogHeight, child: child),
          ),
        );
      },
    );
  }

  /// 布局目标里使用的键盘高度。
  ///
  /// 最小化/关闭期间锁住开始那一刻的高度：收起键盘要几百毫秒，若目标 Rect
  /// 还跟着 `viewInsets` 一起回落，卡片会在缩向气泡的同时被拉长。
  /// 其余时候直接跟随 `viewInsets`（由 [_buildDialogPage] 内部平滑过渡）；
  /// 打开变形期间不会再有“输入框自身”的键盘弹出——焦点已推迟到变形结束，
  /// 此时若屏幕上有键盘，说明用户原本就在别的输入框里，按它让位反而正确。
  double _resolveKeyboardInset(double rawInset) {
    if (_minimizing || _closing) return _frozenKeyboardInset;
    return rawInset;
  }

  Rect? _readDialogRect() {
    final box = _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 首帧/收回后段量不到弹窗 Rect 时的兜底，必须和 [_buildDialogPage] 的布局一致。
  Rect _fallbackDialogRect(Size size, EdgeInsets padding, double keyboardInset) {
    final bottomInset = math.max(padding.bottom, keyboardInset);
    final availableHeight = math.max(
      _kDialogMinHeight,
      size.height - padding.top - _kDialogVerticalMargin * 2 - bottomInset,
    );
    final height = math.min(_kDialogMaxHeight, availableHeight);
    final width = math.min(_kDialogMaxWidth, math.max(0.0, size.width - 32));
    final top = padding.top + _kDialogVerticalMargin + (availableHeight - height) / 2;
    final left = (size.width - width) / 2;
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 打开变形的起点：优先最近一次点按位置（从手指/按钮处展开），
  /// 程序化唤起（外部分享等）没有点按时落到屏幕底部中央。
  Rect _tapOriginRect() {
    final tap = ref.read(floatingQProvider.notifier).lastPointerDown;
    if (tap != null) {
      return Rect.fromCenter(center: tap, width: _kBubbleSize, height: _kBubbleSize);
    }
    return Rect.fromCenter(
      center: Offset(_lastSize.width / 2, _lastSize.height - _kBubbleDefaultBottomGap),
      width: _kBubbleSize,
      height: _kBubbleSize,
    );
  }

  Rect _bubbleRect(Size size, EdgeInsets padding, double keyboardInset, [Offset? committed]) {
    return _bubblePosition(size, padding, keyboardInset, committed) & const Size(_kBubbleSize, _kBubbleSize);
  }

  Offset _bubblePosition(Size size, EdgeInsets padding, double keyboardInset, Offset? committed) {
    final base = _liveBubblePosition ?? committed ?? _defaultBubblePosition(size, padding, keyboardInset);
    return _clampBubblePosition(base, size, padding, keyboardInset);
  }

  Offset _defaultBubblePosition(Size size, EdgeInsets padding, double keyboardInset) {
    final bottomInset = math.max(padding.bottom, keyboardInset);
    return defaultQBubblePosition(size, bottomInset: bottomInset);
  }

  Offset _clampBubblePosition(Offset position, Size size, EdgeInsets padding, double keyboardInset) {
    final bottomInset = math.max(padding.bottom, keyboardInset);
    return clampQBubblePosition(position, size, topInset: padding.top, bottomInset: bottomInset);
  }

  Offset _snapBubble(Offset position, Size size) => snapQBubbleX(position, size);
}

BoxShadow _dialogShadow(ColorScheme scheme) {
  return BoxShadow(color: scheme.shadow.withValues(alpha: 0.16), blurRadius: 32, offset: const Offset(0, 12));
}

BoxShadow _bubbleShadow(ColorScheme scheme) {
  return BoxShadow(color: scheme.primary.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 6));
}

BoxShadow _lerpShadow(BoxShadow from, BoxShadow to, double t) {
  return BoxShadow(
    color: Color.lerp(from.color, to.color, t)!,
    offset: Offset.lerp(from.offset, to.offset, t)!,
    blurRadius: lerpDouble(from.blurRadius, to.blurRadius, t)!,
    spreadRadius: lerpDouble(from.spreadRadius, to.spreadRadius, t)!,
  );
}

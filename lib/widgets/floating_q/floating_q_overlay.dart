import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/ai/agent_turn_limit_actions.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';
import 'package:qnote_flutter/widgets/common/animated_ellipsis.dart';
import 'package:qnote_flutter/widgets/common/streaming_elapsed_text.dart';
import 'package:qnote_flutter/widgets/common/thought_tail_scroll_view.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

/// 全局悬浮小Q入口：悬浮球 + 快捷对话面板。
///
/// 挂载于 MaterialApp.builder 的 Stack 上层，覆盖所有路由页面（含编辑器）。
/// 隐藏规则：/ai 页（已有完整对话入口）、模态弹窗打开时。
/// 键盘弹起时不隐藏，改为整体上移钳制避让，保证悬浮层任何时刻可见可点。
class FloatingQOverlay extends ConsumerStatefulWidget {
  const FloatingQOverlay({super.key});

  @override
  ConsumerState<FloatingQOverlay> createState() => _FloatingQOverlayState();
}

enum _DockSide { left, right }

class _FloatingQOverlayState extends ConsumerState<FloatingQOverlay>
    with SingleTickerProviderStateMixin {
  /// 球直径与时间线页"智能提取"悬浮按钮（44×44）保持一致
  static const double _ballSize = 44;
  static const double _edgeMargin = 12;

  /// 默认位置的底部净空：底部导航栏(60) + 收起态日记输入条(约48) +
  /// 提取按钮(bottom 12 + 高 44) + 间距 12，球悬停在时间线输入栏上方，
  /// 与右侧提取按钮同一水平线
  static const double _ballBottomClearance = 176;

  /// 静置多长时间后自动向屏幕外侧半折叠（毫秒）
  static const int _dockIdleDelayMs = 2500;

  /// 悬浮球位置的持久化键（设备本地 UI 偏好，不进同步链路）
  static const String _prefsKeyDx = 'floating_q_ball_dx';
  static const String _prefsKeyDy = 'floating_q_ball_dy';

  GoRouter? _router;
  late final VoidCallback _routeListener;
  String _location = '';

  /// 悬浮球位置（相对屏幕左上角）；null 表示使用默认左下角位置。
  /// 拖拽结束后持久化到 SharedPreferences，重启后恢复用户上次摆放的位置
  Offset? _ballPosition;

  /// 贴边吸附动画控制器
  late final AnimationController _snapController;
  Animation<Offset>? _snapAnimation;

  /// 靠边半折叠（Docking）状态与停靠方向
  bool _isDocked = false;
  _DockSide _dockSide = _DockSide.left;
  bool _isDragging = false;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        if (_snapAnimation != null && mounted) {
          setState(() => _ballPosition = _snapAnimation!.value);
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _snapAnimation = null;
          _persistBallPosition();
          _scheduleDockTimer();
        }
      });

    _router = ref.read(routerProvider);
    _location = _router!.routerDelegate.currentConfiguration.uri.toString();
    _routeListener = () {
      final uri = _router!.routerDelegate.currentConfiguration.uri.toString();
      if (uri == _location || !mounted) return;
      // 路由通知可能发生在 build 阶段（如 redirect），延后到帧末处理，
      // 避免 setState / 修改 Provider 在 build 期抛异常
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || uri == _location) return;
        setState(() => _location = uri);
        // 路由变化同步基础上下文：签名变化即驱动会话重置（切页丢失历史）；
        // 同时收起面板（面板不跨页面跟随，缩短全屏点击层的存活时间）
        ref
            .read(floatingQProvider.notifier)
          ..setBaseContext(QPageContext.fromLocation(uri))
          ..closePanel();
      });
    };
    _router!.routerDelegate.addListener(_routeListener);
    // 初始化基础页面上下文（编辑页覆盖上下文由各编辑页自行注册），同样延后到帧末
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(floatingQProvider.notifier)
          .setBaseContext(QPageContext.fromLocation(_location));
    });
    // 恢复用户上次拖拽的球位置：读取完成前先按默认位置渲染，读到后钳制再赋值
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBallPosition());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _snapController.dispose();
    _router?.routerDelegate.removeListener(_routeListener);
    super.dispose();
  }

  Offset _defaultBallPosition(Size size) =>
      Offset(_edgeMargin, size.height - _ballSize - _ballBottomClearance);

  /// 唤醒展开：按下、拖动或点击时立即退出折叠态，重置空闲计时
  void _wakeUpFromDock() {
    _idleTimer?.cancel();
    if (_isDocked) {
      setState(() => _isDocked = false);
    }
  }

  /// 调度静置靠边半收折计时器
  void _scheduleDockTimer() {
    _idleTimer?.cancel();
    // 面板打开、小Q执行中、正在拖拽或吸附动画进行中时不收折
    final panelOpen = ref.read(floatingQProvider).panelOpen;
    final isWorking = ref.read(floatingQProvider).phase == FloatingQPhase.working;
    if (panelOpen || isWorking || _isDragging || _snapController.isAnimating) {
      return;
    }

    _idleTimer = Timer(const Duration(milliseconds: _dockIdleDelayMs), () {
      if (!mounted) return;
      final panelOpen = ref.read(floatingQProvider).panelOpen;
      final isWorking = ref.read(floatingQProvider).phase == FloatingQPhase.working;
      if (panelOpen || isWorking || _isDragging || _snapController.isAnimating) {
        return;
      }
      final size = MediaQuery.sizeOf(context);
      final pos = _ballPosition ?? _defaultBallPosition(size);
      final isAtLeft = pos.dx <= _edgeMargin + 4;
      final isAtRight = pos.dx >= size.width - _ballSize - _edgeMargin - 4;
      if (isAtLeft || isAtRight) {
        setState(() {
          _isDocked = true;
          _dockSide = isAtLeft ? _DockSide.left : _DockSide.right;
        });
      }
    });
  }

  /// 从 SharedPreferences 恢复球位置；按当前屏幕贴边吸附并钳制，
  /// 防止跨设备/旋转后存储值越界
  Future<void> _loadBallPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final dx = prefs.getDouble(_prefsKeyDx);
    final dy = prefs.getDouble(_prefsKeyDy);
    if (dx == null || dy == null || !mounted) return;
    final size = MediaQuery.sizeOf(context);
    final isLeft = (dx + _ballSize / 2) < size.width / 2;
    final snapDx = isLeft ? _edgeMargin : size.width - _ballSize - _edgeMargin;
    final clampedDy = dy.clamp(
      _edgeMargin,
      math.max(_edgeMargin, size.height - _ballSize - _edgeMargin).toDouble(),
    );
    setState(() {
      _ballPosition = Offset(snapDx, clampedDy);
      _dockSide = isLeft ? _DockSide.left : _DockSide.right;
    });
    _scheduleDockTimer();
  }

  /// 拖拽结束时持久化位置（松手才写，避免拖动过程高频 IO）
  Future<void> _persistBallPosition() async {
    final pos = _ballPosition;
    if (pos == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsKeyDx, pos.dx);
    await prefs.setDouble(_prefsKeyDy, pos.dy);
  }

  /// 悬浮球显示位置：拖动存储位置基础上，键盘弹起时整体上移钳制避让。
  /// 渲染期计算、不改存储值，键盘收起自动回位；inset 异常残留时球也始终可见可点
  Offset _displayBallPosition(Size size, double keyboardInset) {
    final base = _ballPosition ?? _defaultBallPosition(size);
    final maxTop = size.height - keyboardInset - _ballSize - _edgeMargin;
    return Offset(
      base.dx.clamp(
          _edgeMargin, math.max(_edgeMargin, size.width - _ballSize - _edgeMargin)),
      math.min(base.dy, math.max(_edgeMargin, maxTop).toDouble()),
    );
  }

  void _onDragStart() {
    _wakeUpFromDock();
    _isDragging = true;
    _snapController.stop();
  }

  void _onDragBall(Offset newTopLeft) {
    _wakeUpFromDock();
    final size = MediaQuery.sizeOf(context);
    final dx = newTopLeft.dx
        .clamp(_edgeMargin, size.width - _ballSize - _edgeMargin);
    final dy = newTopLeft.dy
        .clamp(_edgeMargin, size.height - _ballSize - _edgeMargin);
    setState(() => _ballPosition = Offset(dx, dy));
  }

  /// 拖拽松手：智能磁吸贴边动画，弹射到左侧或右侧边缘
  void _onDragEnd() {
    _isDragging = false;
    final size = MediaQuery.sizeOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final current = _ballPosition ?? _defaultBallPosition(size);
    final isLeft = (current.dx + _ballSize / 2) < (size.width / 2);
    final targetDx = isLeft ? _edgeMargin : size.width - _ballSize - _edgeMargin;

    final maxTop = size.height - keyboardInset - _ballSize - _edgeMargin;
    final targetDy = current.dy.clamp(
      _edgeMargin,
      math.max(_edgeMargin, maxTop).toDouble(),
    );
    final target = Offset(targetDx, targetDy);

    _dockSide = isLeft ? _DockSide.left : _DockSide.right;

    if ((current - target).distance < 1.0) {
      _ballPosition = target;
      _persistBallPosition();
      _scheduleDockTimer();
      return;
    }

    _snapAnimation = Tween<Offset>(
      begin: current,
      end: target,
    ).animate(CurvedAnimation(
      parent: _snapController,
      curve: Curves.easeOutBack,
    ));
    _snapController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    // 监听小Q任务状态与面板开关：执行工作或打开面板时立即唤醒展开，任务完成或面板关闭后重新倒计时收折
    ref.listen<FloatingQPhase>(
      floatingQProvider.select((s) => s.phase),
      (previous, next) {
        if (next == FloatingQPhase.working) {
          _wakeUpFromDock();
        } else {
          _scheduleDockTimer();
        }
      },
    );
    ref.listen<bool>(
      floatingQProvider.select((s) => s.panelOpen),
      (previous, next) {
        if (next) {
          _wakeUpFromDock();
        } else {
          _scheduleDockTimer();
        }
      },
    );

    // 精确订阅：流式期间 provider 以约 60ms 节奏刷新消息/流式文本，
    // 这里只关心面板开关与工作态，避免整条悬浮层（含面板输入框）被高频重建，
    // 否则 Web 端中文输入法组合态会被反复打断（删字复活、光标错乱）
    final panelOpen = ref.watch(floatingQProvider.select((s) => s.panelOpen));
    final isWorking = ref.watch(
        floatingQProvider.select((s) => s.phase == FloatingQPhase.working));
    final size = MediaQuery.sizeOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final isAiPage = _location.startsWith('/ai');

    return ValueListenableBuilder<int>(
      valueListenable: floatingQModalCount,
      builder: (context, modalCount, _) {
        // /ai 页有完整小Q对话；模态弹窗（对话框/底部弹层）打开时隐藏悬浮层。
        // 改用淡出+禁点而非整层卸载：隐藏/恢复获得淡入淡出过渡，
        // 面板开着时弹出补充提问框也不再丢失输入框文本；
        // 键盘弹起仍不隐藏，改为钳制上移，杜绝 inset 异常残留导致的"永久消失"
        final layerHidden = isAiPage || modalCount > 0;

        return IgnorePointer(
          ignoring: layerHidden,
          child: AnimatedOpacity(
            opacity: layerHidden ? 0 : 1,
            duration: AppDurations.normal,
            curve: Curves.easeOut,
            child: Stack(
              children: [
                // 面板打开时的全屏透明点击层：点面板外收起面板（任务继续后台执行）；
                // 常驻 + IgnorePointer 切换，避免面板收起动画期间瞬间失去点击遮挡
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !panelOpen,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          ref.read(floatingQProvider.notifier).closePanel(),
                    ),
                  ),
                ),
                // 对话面板：弹出时自底边向上生长淡入，收起时缩回淡出，
                // 动画结束才卸载（autofocus 输入框每次打开重新挂载，行为不变）
                Positioned(
                  left: _edgeMargin,
                  right: _edgeMargin,
                  // 钳制上限：即使 inset 异常残留，面板也不会被推出屏幕外
                  bottom: math.min(keyboardInset, size.height * 0.55) + 12,
                  child: AnimatedSwitcher(
                    duration: AppDurations.normal,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        // 以面板底边中心为锚点缩放：视觉上从球的位置向上展开
                        alignment: Alignment.bottomCenter,
                        scale: Tween<double>(begin: 0.88, end: 1)
                            .animate(animation),
                        child: child,
                      ),
                    ),
                    child: panelOpen
                        ? SizedBox(
                            // AnimatedSwitcher 内部 Stack 是松约束，
                            // 需显式撑满宽度，面板才能保持左右贴边
                            key: const ValueKey('panel'),
                            width: double.infinity,
                            child: _FloatingQPanel(onUndo: _handleUndo),
                          )
                        : const SizedBox.shrink(key: ValueKey('panel-hidden')),
                  ),
                ),
                // 悬浮球：面板打开时原地缩小淡出，面板收起后带轻微回弹归位
                Positioned(
                  left: _displayBallPosition(size, keyboardInset).dx,
                  top: _displayBallPosition(size, keyboardInset).dy,
                  child: AnimatedSwitcher(
                    duration: AppDurations.normal,
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.6, end: 1)
                            .animate(animation),
                        child: child,
                      ),
                    ),
                    child: panelOpen
                        ? const SizedBox.shrink(key: ValueKey('ball-hidden'))
                        : _FloatingBall(
                            key: const ValueKey('ball'),
                            size: _ballSize,
                            position: _displayBallPosition(size, keyboardInset),
                            isWorking: isWorking,
                            isDocked: _isDocked && !isWorking && !panelOpen,
                            dockSide: _dockSide,
                            onPointerDown: _wakeUpFromDock,
                            onDragStart: _onDragStart,
                            onTap: _handleBallTap,
                            onDragUpdate: _onDragBall,
                            onDragEnd: _onDragEnd,
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 悬浮球点按：当前编辑页正文处于框选状态时，把选中文本作为引用打开面板
  /// （等同选择菜单「给小Q」）；否则普通打开面板。
  /// 球体用原生 Listener 处理指针，点按不会打断编辑器焦点与选区，
  /// 捕获在点按回调内同步完成，不存在丢失窗口
  void _handleBallTap() {
    final notifier = ref.read(floatingQProvider.notifier);
    final signature = ref.read(floatingQProvider).effectiveContext?.signature;
    final quote = QTargetBridge.instance.captureQuote(signature);
    if (quote == null) {
      notifier.openPanel();
      return;
    }
    // 收起键盘与选择菜单，把焦点让给面板输入框（选中文本已在捕获时取得）
    FocusManager.instance.primaryFocus?.unfocus();
    notifier.openWithQuote(quote);
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
}

// ---------------------------------------------------------------------------
// 悬浮球
// ---------------------------------------------------------------------------
class _FloatingBall extends StatefulWidget {
  final double size;

  /// 当前显示位置（左上角，已含键盘避让钳制），作为拖动位移基准
  final Offset position;

  /// 任务执行中（显示工作动画球）
  final bool isWorking;

  /// 靠边半收折状态（静置时向屏幕外滑入约 60%，仅露出边缘弧形以防遮挡）
  final bool isDocked;

  /// 靠边停靠方向（左侧或右侧）
  final _DockSide dockSide;

  /// 指针按下时触发唤醒展开
  final VoidCallback onPointerDown;

  /// 开始拖动回调
  final VoidCallback onDragStart;

  final VoidCallback onTap;

  /// 拖动回调：新的球左上角位置（屏幕坐标，未钳制，由宿主钳制后存储）
  final ValueChanged<Offset> onDragUpdate;

  /// 拖动结束回调：松手或拖动中被打断时触发，宿主借此持久化位置并触发吸附动画
  final VoidCallback onDragEnd;

  const _FloatingBall({
    super.key,
    required this.size,
    required this.position,
    required this.isWorking,
    required this.isDocked,
    required this.dockSide,
    required this.onPointerDown,
    required this.onDragStart,
    required this.onTap,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_FloatingBall> createState() => _FloatingBallState();
}

/// 用原始 [Listener] 而非 GestureDetector 实现点击与拖动：
/// Listener 不参与手势竞技场，指针事件分发阶段必定到达本组件，
/// 即使某个手势识别器异常卡住竞技场，悬浮球也始终保持可点可拖
/// （修复"球看得见但点不动、拖不动，需重启才恢复"的问题）
class _FloatingBallState extends State<_FloatingBall> {
  /// 拖动判定阈值（逻辑像素）：位移超过该值视为拖动而非点击
  static const double _dragSlop = 8;

  /// 折叠时向屏幕外滑出的逻辑像素（44px 圆球滑出 26px，露出约 18px 弧形胶囊边）
  static const double _dockSlideOffset = 26;

  Offset? _pointerStart;
  Offset? _origin;
  bool _dragging = false;

  /// 按压态：驱动球体轻微缩放的按压反馈，松开或转入拖动即恢复
  bool _pressed = false;

  void _onPointerDown(PointerDownEvent event) {
    widget.onPointerDown();
    // 只跟踪首个按下的指针，多指触控时忽略后续指针
    _pointerStart ??= event.position;
    _origin ??= widget.position;
    _dragging = false;
    if (!_pressed) setState(() => _pressed = true);
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _pointerStart;
    final origin = _origin;
    if (start == null || origin == null) return;
    if (!_dragging && (event.position - start).distance > _dragSlop) {
      _dragging = true;
      widget.onDragStart();
      HapticFeedback.selectionClick();
    }
    if (_dragging) {
      // 拖动即脱离按压语义，球体恢复正常大小随指针移动
      if (_pressed) setState(() => _pressed = false);
      widget.onDragUpdate(origin + (event.position - start));
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final wasDragging = _dragging;
    _pointerStart = null;
    _origin = null;
    _dragging = false;
    if (_pressed) setState(() => _pressed = false);
    if (wasDragging) {
      widget.onDragEnd();
    } else {
      HapticFeedback.lightImpact();
      widget.onTap();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final wasDragging = _dragging;
    _pointerStart = null;
    _origin = null;
    _dragging = false;
    if (_pressed) setState(() => _pressed = false);
    // 拖动中被打断时位置已随 move 更新，同样触发结束吸附与持久化
    if (wasDragging) widget.onDragEnd();
  }

  @override
  Widget build(BuildContext context) {
    // 折叠时的水平平移比例（相对于球体尺寸）
    final slideX = widget.isDocked
        ? (widget.dockSide == _DockSide.left
            ? -_dockSlideOffset / widget.size
            : _dockSlideOffset / widget.size)
        : 0.0;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      // 撤回入口只保留在面板横幅中：悬浮球不再切换撤回倒计时形态，
      // 撤回就绪期点击球同样是弹出面板
      child: AnimatedSlide(
        offset: Offset(slideX, 0),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          // 静置半折叠时衰减不透明度至 0.42，阅读正文无干扰；触碰唤醒后立即恢复 1.0
          opacity: widget.isDocked ? 0.42 : 1.0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          child: AnimatedScale(
            // 按压反馈：球体轻微缩小，松开回弹
            scale: _pressed ? 0.92 : 1.0,
            duration: AppDurations.fast,
            curve: Curves.easeOut,
            child: AnimatedSwitcher(
              duration: AppDurations.normal,
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              // 工作态流光环会溢出球体边界，布局 Stack 需关闭裁剪
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  ...previousChildren,
                  ?currentChild,
                ],
              ),
              child: widget.isWorking
                  ? _WorkingBall(
                      key: const ValueKey('working'),
                      size: widget.size,
                    )
                  : _IdleBall(
                      key: const ValueKey('idle'),
                      size: widget.size,
                      isDocked: widget.isDocked,
                      dockSide: widget.dockSide,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 待机状态悬浮球：高质感双层微渐变 + 柔和立体光晕 + 边缘折叠小耳微弧
class _IdleBall extends StatelessWidget {
  final double size;
  final bool isDocked;
  final _DockSide dockSide;

  const _IdleBall({
    super.key,
    required this.size,
    required this.isDocked,
    required this.dockSide,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    // 轻柔浅淡高光与核心主色双层渐变，打破死板纯色
    final topHighlight =
        Color.lerp(primary, Colors.white, isDark ? 0.22 : 0.28)!;
    final bottomCore = primary;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [topHighlight, bottomCore],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.28 : 0.45),
          width: 1.2,
        ),
        boxShadow: [
          // 主题色微光晕
          BoxShadow(
            color: primary.withValues(alpha: isDark ? 0.35 : 0.25),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
          // 底层环境景深柔阴影
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            blurRadius: 6,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 中心机器人图标
          Icon(
            Icons.smart_toy_rounded,
            color: theme.colorScheme.onPrimary,
            size: 20,
          ),
          // 折叠态露出的侧边高光小耳朵指示微弧，保证在边缘也有极佳识别度与萌感
          if (isDocked)
            Positioned(
              left: dockSide == _DockSide.right ? 2 : null,
              right: dockSide == _DockSide.left ? 2 : null,
              child: Container(
                width: 3.5,
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 工作中悬浮球：AI 极光流光边框（双流星对称追逐） + 中心脉冲与三点跳动
class _WorkingBall extends StatefulWidget {
  final double size;

  const _WorkingBall({super.key, required this.size});

  @override
  State<_WorkingBall> createState() => _WorkingBallState();
}

class _WorkingBallState extends State<_WorkingBall>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // 外圈轻度脉冲光晕（1.0 ~ 1.25 倍），表达能量汇聚
        final ringScale = 1.0 + _pulse.value * 0.22;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Transform.scale(
              scale: ringScale,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary.withValues(
                      alpha: (isDark ? 0.30 : 0.20) * (1 - _pulse.value)),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: primary.withValues(alpha: isDark ? 0.40 : 0.30),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: AnimatedGradientBorder(
          isAnimating: true,
          borderRadius: widget.size / 2, // 22px 完美贴合圆形
          strokeWidth: 2.2,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primary.withValues(alpha: isDark ? 0.22 : 0.12),
            ),
            child: Center(
              child: AnimatedEllipsis(
                dotSize: 4.5,
                dotSpacing: 2.2,
                color: primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 快捷对话面板
// ---------------------------------------------------------------------------
class _FloatingQPanel extends ConsumerStatefulWidget {
  final Future<void> Function() onUndo;

  const _FloatingQPanel({required this.onUndo});

  @override
  ConsumerState<_FloatingQPanel> createState() => _FloatingQPanelState();
}

class _FloatingQPanelState extends ConsumerState<_FloatingQPanel> {
  static const double _panelMaxHeight = 380;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 精确订阅上下文徽章文案：流式刷新（约 60ms 一次）不重建面板外壳，
    // 输入行 TextField 因此保持稳定（Web 端中文 IME 组合态不被打断）
    final contextLabel = ref.watch(floatingQProvider.select(
        (s) => s.contextLabel ?? s.effectiveContext?.displayLabel ?? '当前页面'));
    // 外部分享场景：内容来自第三方应用，与当前页面无关，不展示位置徽章
    final externalShareMode =
        ref.watch(floatingQProvider.select((s) => s.externalShareMode));

    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _panelMaxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme, externalShareMode ? '小Q' : '小Q · $contextLabel'),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const Flexible(child: _PanelMessages()),
            // 撤回横幅自管显隐（内部按 phase 判定），常驻面板不自动消失
            _PanelUndoBanner(onUndo: widget.onUndo),
            // 「给小Q」引用卡片自管显隐（无挂起引用时不占位）
            const _PanelQuoteCard(),
            // 分享图片附件条自管显隐（无附件时不占位）
            const _PanelImageAttachments(),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const _PanelInputRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          Icon(Icons.smart_toy_rounded,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 手动开启新对话（会话按界面自动隔离，这里是主动重置）
          Tooltip(
            message: '开启新对话',
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () =>
                  ref.read(floatingQProvider.notifier).newConversation(),
            ),
          ),
          Tooltip(
            message: '收起',
            child: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () =>
                  ref.read(floatingQProvider.notifier).closePanel(),
            ),
          ),
        ],
      ),
    );
  }

  /// 撤回横幅：任务完成后常驻展示（见 [_PanelUndoBanner]）
}

/// 消息区：会话消息 + 流式占位（状态文案与流式正文互斥展示）。
///
/// 独立订阅 provider：流式期间（约 60ms 一次）只有本组件重建，
/// 面板外壳与输入行保持稳定，输入框 IME 组合态不被打断
class _PanelMessages extends ConsumerStatefulWidget {
  const _PanelMessages();

  @override
  ConsumerState<_PanelMessages> createState() => _PanelMessagesState();
}

class _PanelMessagesState extends ConsumerState<_PanelMessages> {
  final _listController = ScrollController();

  /// 是否自动贴底跟随；流式期间用户向上拖动查看历史后暂停，
  /// 拖回底部附近自动恢复（与 ThoughtTailScrollView 同一套约定）
  bool _follow = true;

  bool get _isNearBottom =>
      !_listController.hasClients ||
      _listController.position.maxScrollExtent - _listController.offset < 24;

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  /// 贴底仅在跟随态执行：jumpTo 会先终止当前滚动活动，流式期间每 60ms
  /// 一次的无条件贴底会持续打断用户拖拽，表现为回复时列表滑不动
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listController.hasClients) return;
      if (!force && !_follow) return;
      _listController.jumpTo(_listController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fq = ref.watch(floatingQProvider);

    // 消息流或流式状态变化（正文、状态文案、实时思考内容）时滚到底部：
    // 新消息落地是离散事件，强制恢复跟随并贴底；流式增量仅在跟随态贴底
    ref.listen<FloatingQState>(floatingQProvider, (prev, next) {
      final newMessage = prev?.messages.length != next.messages.length;
      if (newMessage ||
          prev?.streamingText != next.streamingText ||
          prev?.statusText != next.statusText ||
          prev?.streamingThought != next.streamingThought) {
        if (newMessage) _follow = true;
        _scrollToBottom(force: newMessage);
      }
    });

    final children = <Widget>[];

    for (final message in fq.messages) {
      // 生图结果直接以图片卡预览；其余工具中间消息不在快捷面板展示
      //（进行中的操作由状态行实时表达）
      if (message.role == 'tool') {
        final imageCard = _buildGeneratedImageCard(theme, message);
        if (imageCard != null) children.add(_buildEntrance(imageCard));
        continue;
      }
      // Agent 每轮发起工具调用前会生成「正文为空、仅承载 tool_calls」的 assistant
      // 中转消息（与 AI 主页面 _isVisibleMessage 过滤的是同一类消息），快捷面板
      // 不渲染思考胶囊，这类消息只会渲染成空白胶囊卡片，直接跳过
      if (message.content.trim().isEmpty) continue;
      children.add(_buildEntrance(_buildBubble(theme, message)));
      // 步数上限提示：待处理时在气泡下方渲染「继续/暂停」按钮
      if (message.role == 'assistant' &&
          message.uiDetails?['type'] == 'turn_limit' &&
          message.uiDetails?['handled'] != true) {
        children.add(
          AgentTurnLimitActions(
            enabled: fq.phase != FloatingQPhase.working,
            onContinue: () =>
                ref.read(floatingQProvider.notifier).continueTask(),
            onPause: () => ref.read(floatingQProvider.notifier).pauseTask(),
          ),
        );
      }
    }

    if (fq.statusText != null) {
      children.add(
        _buildEntrance(
          _buildStatusLine(theme, fq.statusText!, fq.streamingStartedAt),
        ),
      );
      // 思考中状态行下方挂实时思考尾随区（模型返回思考增量时才出现）
      final liveThought = fq.streamingThought;
      if (liveThought != null && liveThought.trim().isNotEmpty) {
        children.add(
          _buildEntrance(_buildThoughtTail(theme, liveThought.trim())),
        );
      }
    } else if (fq.streamingText != null && fq.streamingText!.isNotEmpty) {
      children.add(
        _buildEntrance(_buildAssistantBubble(theme, fq.streamingText!)),
      );
    }

    if (children.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Text(
          '让小Q处理当前页面的内容，例如"优化这篇笔记的表达"。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification &&
            notification.dragDetails != null) {
          _follow = false; // 用户主动拖动即暂停贴底跟随
        }
        if (_isNearBottom) _follow = true; // 拖回底部附近自动恢复
        return false;
      },
      child: ListView(
        controller: _listController,
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        children: children,
      ),
    );
  }

  /// 新内容入场微动画：淡入 + 轻微上移归位。
  ///
  /// tween 终值恒定，仅在气泡/状态行首次挂载时播放一次；流式期间约 60ms
  /// 一次的高频重建复用同一 Element，不会重复触发动画，也不产生持续重建
  Widget _buildEntrance(Widget child) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: AppDurations.fast,
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          // 位移只作用于绘制阶段，不影响布局，避免列表抖动
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// 生图工具结果卡：在快捷面板中直接预览生成的图片
  ///
  /// 仅渲染 generate_image 成功且带路径的结果，其余工具消息返回 null 由调用方跳过。
  Widget? _buildGeneratedImageCard(ThemeData theme, ChatMessage message) {
    if (message.toolName != 'generate_image' || message.isError == true) {
      return null;
    }
    final paths =
        (message.uiDetails?['paths'] as List?)?.whereType<String>().toList() ?? const [];
    if (paths.isEmpty) return null;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 48),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final path in paths)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: UnifiedImage(imagePath: path, fit: BoxFit.cover),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(ThemeData theme, ChatMessage message) {
    if (message.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(AppRadius.medium),
          ),
          child: Text(
            message.content,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onPrimary),
          ),
        ),
      );
    }
    return _buildAssistantBubble(theme, message.content);
  }

  Widget _buildAssistantBubble(ThemeData theme, String content) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: SelectableText(
          content,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }

  /// 等待态状态行：状态文案 + 动态省略号 + 已用时递增计数
  /// （遵循小Q等待态显示规范，不用闪烁光标）
  Widget _buildStatusLine(ThemeData theme, String statusText, DateTime? startedAt) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              statusText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const Padding(
            padding: EdgeInsets.only(bottom: 3),
            child: AnimatedEllipsis(),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 3),
            child: StreamingElapsedText(
              startedAt: startedAt,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 实时思考尾随区：裸文本不加容器（面板空间小，保持轻量），
  /// 限高 2 行自动贴底滚动，随思考增量流式更新
  Widget _buildThoughtTail(ThemeData theme, String thought) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ThoughtTailScrollView(
        text: thought,
        maxHeight: 40,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        textStyle: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
          fontStyle: FontStyle.italic,
          height: 1.4,
        ),
      ),
    );
  }
}

/// 撤回横幅：有待撤回变更时常驻展示，不再自动过期——
/// 直到撤回执行（phase 回 idle）或发起新任务（变更跨任务累加）
class _PanelUndoBanner extends ConsumerWidget {
  final Future<void> Function() onUndo;

  const _PanelUndoBanner({required this.onUndo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 记录按结构相等比较：仅撤回相关状态变化时才重建横幅
    final (showBanner, undoCount, isUndoing) = ref.watch(
      floatingQProvider.select(
        (s) => (
          s.phase == FloatingQPhase.countdown,
          s.pendingUndoCount,
          s.isUndoing,
        ),
      ),
    );
    // 高度展开/收合 + 淡入：横幅插入/移除不再硬切挤压消息区；
    // 空态保持等宽零高，宽度稳定后只做高度方向动画
    return AnimatedSize(
      duration: AppDurations.normal,
      curve: Curves.easeOut,
      child: AnimatedSwitcher(
        duration: AppDurations.fast,
        switchInCurve: Curves.easeOut,
        child: showBanner
            ? Container(
                key: const ValueKey('undo-banner'),
                width: double.infinity,
                color:
                    theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.history_rounded,
                        size: 16, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '可撤回小Q本次的 $undoCount 处修改',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: isUndoing ? null : onUndo,
                      child: isUndoing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('撤回'),
                    ),
                  ],
                ),
              )
            : const SizedBox(
                width: double.infinity, key: ValueKey('undo-empty')),
      ),
    );
  }
}

/// 引用卡片：展示用户通过「给小Q」挂起的引用内容（来源 + 位置 + 文本摘录），
/// 发送时随任务注入给小Q；× 可随时移除。null 时不渲染、不占位，
/// 且只精确订阅 pendingQuote，流式刷新不重建本卡片外的面板结构
class _PanelQuoteCard extends ConsumerWidget {
  const _PanelQuoteCard();

  IconData _sourceIcon(QQuoteSource source) => switch (source) {
        QQuoteSource.note => Icons.sticky_note_2_outlined,
        QQuoteSource.diary => Icons.schedule_rounded,
        QQuoteSource.journal => Icons.menu_book_outlined,
        QQuoteSource.todo => Icons.task_alt_outlined,
        QQuoteSource.external => Icons.share_outlined,
      };

  String _sourceLabel(QQuoteSource source) => switch (source) {
        QQuoteSource.note => '笔记',
        QQuoteSource.diary => '流水记录',
        QQuoteSource.journal => '每日日记',
        QQuoteSource.todo => '待办',
        QQuoteSource.external => '外部分享',
      };

  /// 标题行：日记来源为日期字符串不加书名号，其余《标题》+ 位置；
  /// 外部分享无实体标题，只展示来源标签
  String _titleLine(QTextQuote quote) {
    final label = _sourceLabel(quote.source);
    if (quote.source == QQuoteSource.external) return label;
    final title = quote.source == QQuoteSource.journal
        ? '$label ${quote.sourceTitle}'
        : '$label《${quote.sourceTitle}》';
    final location = quote.locationDesc;
    return location == null ? title : '$title · $location';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quote = ref.watch(floatingQProvider.select((s) => s.pendingQuote));
    if (quote == null) {
      return const SizedBox.shrink(key: ValueKey('quote-card-hidden'));
    }
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('quote-card'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_sourceIcon(quote.source),
                size: 16, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _titleLine(quote),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  quote.quotedText.isEmpty ? '（引用完整内容）' : quote.quotedText,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              tooltip: '移除引用',
              icon: const Icon(Icons.close_rounded),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () =>
                  ref.read(floatingQProvider.notifier).clearPendingQuote(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分享图片附件条：外部分享图片唤起时展示待发送缩略图，× 可移除，
/// 发送时随消息一次性携带。无附件时不占位；挂载与 pendingImages 变化
/// 两个时机消费挂起图片（面板未开时收到分享走前者，面板开着再分享走后者）
class _PanelImageAttachments extends ConsumerStatefulWidget {
  const _PanelImageAttachments();

  @override
  ConsumerState<_PanelImageAttachments> createState() =>
      _PanelImageAttachmentsState();
}

class _PanelImageAttachmentsState
    extends ConsumerState<_PanelImageAttachments> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _consumePending();
    });
  }

  void _consumePending() =>
      ref.read(floatingQProvider.notifier).consumePendingImages();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = ref.watch(floatingQProvider.select((s) => s.attachedImages));

    ref.listen<List<String>?>(
      floatingQProvider.select((s) => s.pendingImages),
      (prev, next) {
        if (next != null && next.isNotEmpty) _consumePending();
      },
    );

    if (images.isEmpty) {
      return const SizedBox.shrink(key: ValueKey('image-attachments-hidden'));
    }

    return Container(
      key: const ValueKey('image-attachments'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: images.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final path = images[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  child: UnifiedImage(
                    imagePath: path,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
                // 移除按钮叠在缩略图右上角内侧（外溢负偏移会被 ListView 裁剪）
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () => ref
                        .read(floatingQProvider.notifier)
                        .removeAttachedImage(path),
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 输入行：输入框 + 发送/停止按钮。
///
/// 输入控制器在本组件内持有，且只订阅"是否工作中"：
/// 流式刷新不重建 TextField，保证光标位置与 IME 组合态稳定
/// （修复"删除文字后再打字，刚删的字又出现"的 Web 端输入异常）
class _PanelInputRow extends ConsumerStatefulWidget {
  const _PanelInputRow();

  @override
  ConsumerState<_PanelInputRow> createState() => _PanelInputRowState();
}

class _PanelInputRowState extends ConsumerState<_PanelInputRow> {
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 物理键盘 Enter 拦截：无 Shift 即发送，Shift+Enter 放行默认换行。
  /// 软键盘行为由 textInputAction:newline 交给 IME（移动端发送一律点按钮）；
  /// 返回 handled 后 engine 不再把 Enter 送入文本输入通道，避免发送与换行叠加
  KeyEventResult _handleEnterKey(FocusNode node, KeyEvent event) {
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _handleSend();
    return KeyEventResult.handled;
  }

  Future<void> _handleSend() async {
    final fq = ref.read(floatingQProvider);
    final text = _inputController.text.trim();
    // 工作中由发送按钮转为停止按钮，键盘发送路径直接忽略（不清空已输入内容）
    if (fq.phase == FloatingQPhase.working) return;
    if (text.isEmpty && fq.attachedImages.isEmpty) return;
    HapticFeedback.lightImpact();
    _inputController.clear();
    // 发送后无需手动滚动：消息区的 listen 监听到消息数变化会自动滚到底部
    await ref.read(floatingQProvider.notifier).send(text);
  }

  void _handleStop() {
    HapticFeedback.mediumImpact();
    ref.read(floatingQProvider.notifier).stop();
  }

  /// 长按发送按钮切换小Q模型：与 AI 主页面共用同一 assistant 角色绑定，
  /// 切换为全局生效（主页面同步更新）
  Future<void> _handleModelSelect() async {
    HapticFeedback.mediumImpact();
    final selected = await showAssistantModelSelector(context, ref);
    if (selected == null || !mounted) return;
    Toast.success(context, '小Q模型已切换为 ${selected.name}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWorking = ref.watch(
        floatingQProvider.select((s) => s.phase == FloatingQPhase.working));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: _handleEnterKey,
              child: TextField(
                controller: _inputController,
                focusNode: _focusNode,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                // 软键盘回车键为「换行」，发送一律点右侧按钮；
                // 桌面/Web 物理回车在 _handleEnterKey 拦截发送，Shift+Enter 换行
                textInputAction: TextInputAction.newline,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: '告诉小Q要做什么…',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.5),
                  ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.medium),
                    borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.medium),
                    borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.medium),
                    borderSide:
                        BorderSide(color: theme.colorScheme.primary, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 小Q工作中：发送按钮变为中断/停止按钮（与 AI 主页面交互一致）；
          // 空闲态长按可切换模型（工作中为停止按钮，不响应长按）。
          // 工作期间外圈套主题色灵动流光描边（与悬浮球脉冲环同一「运行中」语义）
          AnimatedGradientBorder(
            isAnimating: isWorking,
            borderRadius: 20,
            strokeWidth: 2,
            child: IconButton.filled(
              onPressed: isWorking
                  ? () {
                      HapticFeedback.lightImpact();
                      _handleStop();
                    }
                  : _handleSend,
              onLongPress: isWorking ? null : _handleModelSelect,
              tooltip:
                  isWorking ? '点击中止小Q当前操作' : '发送（长按切换模型）',
              style: IconButton.styleFrom(
                // 告别突兀的深黑底色，工作态采用通透轻盈的主题色浅底，衬托主题色灵动流光
                backgroundColor: isWorking
                    ? theme.colorScheme.primary.withValues(
                        alpha: theme.brightness == Brightness.dark ? 0.20 : 0.12,
                      )
                    : theme.colorScheme.primary,
                foregroundColor:
                    isWorking ? theme.colorScheme.primary : theme.colorScheme.onPrimary,
              ),
              icon: isWorking
                  ? Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    )
                  : const Icon(
                      Icons.arrow_upward_rounded,
                      size: 22,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

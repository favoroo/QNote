part of 'diary_record_sheet.dart';
// 从主文件拆出的底部组件，保持同一 library 以便继续访问私有类型。

class _UndoCountdownPainter extends CustomPainter {
  final double progress;
  final Color color;

  _UndoCountdownPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 4) / 2;

    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    final sweepAngle = (1.0 - progress) * 2 * 3.141592653589793;
    if (sweepAngle > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -3.141592653589793 / 2,
        sweepAngle,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UndoCountdownPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// 卡片外框：居中、限宽、圆角与柔和投影。
///
/// 用 [Dialog] 而不是自绘遮罩，是为了直接拿到它的键盘避让：`Dialog` 会把
/// `viewInsets` 加到 insetPadding 上，键盘升起时整张卡片上移、可用高度变小，
/// 不再需要像底部面板时代那样手工算 `screenHeight - keyboard - safeArea`。
class _SheetSurface extends StatelessWidget {
  const _SheetSurface({this.surfaceKey, required this.child});

  /// 量卡片最终 Rect 用的 Key（容器变形）。
  final GlobalKey? surfaceKey;

  final Widget child;

  /// 桌面/平板上不铺成一整条，手机上 16 的左右边距刚好还能看见底下的时间线。
  static const double _maxWidth = 520;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        key: surfaceKey,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: _maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.16),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 面板内容的错峰入场：从同一个控制器上切一段窗口出来（尾部与下一段重叠）。
///
/// Fade/Slide 都是把 child 透传的过渡件，入场期间逐帧重建的只有这两个节点，
/// 区块内容本身不会跟着重建。动画对象在 State 里建好、dispose 释放 ——
/// 如果放在 build 里临时 new，会把状态监听一次次挂到控制器上（打字每次
/// setState 都加一份），既不干净也会拖慢长会话。
class _Reveal extends StatefulWidget {
  const _Reveal({
    required this.controller,
    required this.begin,
    required this.child,
  });

  final Animation<double> controller;
  final double begin;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> {
  late final CurvedAnimation _animation;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _animation = CurvedAnimation(
      parent: widget.controller,
      curve: Interval(
        widget.begin,
        math.min(1.0, widget.begin + 0.64),
        curve: Curves.easeOutCubic,
      ),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(_animation);
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// 记录卡片的路由。
///
/// 有按钮锚点时入场/退场是真正的容器变形（[buildTransitions] 里交给
/// [_RecordDialogTransition]），发送后还能从面板飞向新卡片；没有锚点时退回
/// 整卡缩放淡入，退场比入场更快，不拖住时间线。
///
/// [done] 在退场动画真正播完（或路由被销毁）时完成：页面要等到这一刻再把
/// 记录按钮放出来，否则按钮会在卡片还没缩回去时提前从底下冒出来。
class _RecordDialogRoute extends RawDialogRoute<void> {
  _RecordDialogRoute({
    required super.pageBuilder,
    required super.barrierLabel,
    required super.barrierColor,
    required this.reduceMotion,
    required this.useMorph,
    required this.theme,
    required this.surfaceKey,
    required this.originAnchor,
    required this.readAnchor,
  }) : super(
         barrierDismissible: true,
         transitionDuration: reduceMotion
             ? Duration.zero
             : (useMorph ? _kMorphEnterDuration : _kDialogEnterDuration),
       );

  /// 系统开启「减弱动效」时直接落终态。
  final bool reduceMotion;
  final bool useMorph;
  final ThemeData theme;
  final GlobalKey surfaceKey;
  final RecordFabAnchor? originAnchor;
  final RecordFabAnchor? Function()? readAnchor;

  final GlobalKey<_RecordDialogTransitionState> _transitionKey = GlobalKey();
  final Completer<void> _done = Completer<void>();

  /// 发送落位后改用更短的退场，让盖板尽快把卡片让出来。
  Duration? _landingExitDuration;

  Future<void> get done => _done.future;

  @override
  Duration get reverseTransitionDuration {
    if (reduceMotion) return Duration.zero;
    return _landingExitDuration ??
        (useMorph ? _kMorphExitDuration : _kDialogExitDuration);
  }

  /// 面板保存成功、并且页面量到了目标卡片时调用。
  bool startCardMorph(RecordCardMorphTarget target) {
    final state = _transitionKey.currentState;
    if (state == null) return false;
    return state.startCardMorph(target);
  }

  /// 盖板已经压在目标卡片上，接下来用短退场把盖板和遮罩一起淡掉。
  void prepareLandingExit() {
    _landingExitDuration = _kCardLandingExitDuration;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!useMorph) {
      return _DialogEntrance(animation: animation, child: child);
    }
    return _RecordDialogTransition(
      key: _transitionKey,
      animation: animation,
      route: this,
      child: child,
    );
  }

  @override
  TickerFuture didPush() {
    final future = super.didPush();
    animation?.addStatusListener(_handleAnimationStatus);
    return future;
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      _completeDone();
    }
  }

  void _completeDone() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void dispose() {
    animation?.removeStatusListener(_handleAnimationStatus);
    _completeDone();
    super.dispose();
  }
}

/// 按钮 ↔ 弹窗的容器变形，以及发送后「弹窗变卡片」的飞行落位。
///
/// 打开时容器从按钮 Rect 长到卡片 Rect；卡片的目标 Rect 每帧从 [Key] 上实时
/// 读取，所以键盘弹起、内容长高时容器会跟着走。窗口内用
/// `OverflowBox + Transform.translate` 把整页内容按最终坐标放进变形窗口，
/// 净偏移正好抵消，量到的始终是卡片的最终屏幕位置。
///
/// 发送时面板先淡成一张空白盖板，再飞到页面量好的卡片 Rect 上；落位瞬间
/// 页面揭开真实卡片，盖板和遮罩一起淡出。
class _RecordDialogTransition extends StatefulWidget {
  const _RecordDialogTransition({
    super.key,
    required this.animation,
    required this.route,
    required this.child,
  });

  final Animation<double> animation;
  final _RecordDialogRoute route;
  final Widget child;

  @override
  State<_RecordDialogTransition> createState() => _RecordDialogTransitionState();
}

class _RecordDialogTransitionState extends State<_RecordDialogTransition>
    with SingleTickerProviderStateMixin {
  /// 按钮 ↔ 卡片的 Rect/圆角/配色进度。
  late final CurvedAnimation _rectProgress;

  /// 遮罩淡入淡出。
  late final CurvedAnimation _scrimProgress;

  /// 内容与按钮幽灵的交叉淡入：入场时幽灵先退、内容交给面板自己的 _Reveal；
  /// 收回时反过来，内容先退、幽灵最后落在按钮位置。
  late final CurvedAnimation _crossFade;

  /// 发送后飞向卡片的独立控制器（路由动画此时已经停在 1）。
  late final AnimationController _cardController;
  late final Animation<double> _cardProgress;

  Rect? _cardFrom;
  RecordCardMorphTarget? _cardTarget;
  bool _landing = false;

  /// 内容裁切后 Key 可能暂时量不到（收回后段已经不再画内容），留一份上次的。
  Rect? _lastSheetRect;

  @override
  void initState() {
    super.initState();
    _rectProgress = CurvedAnimation(
      parent: widget.animation,
      curve: _kMorphEnterCurve,
      reverseCurve: _kMorphExitCurve,
    );
    _scrimProgress = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.5, curve: Curves.easeOut),
      reverseCurve: const Interval(0.3, 1, curve: Curves.easeIn),
    );
    _crossFade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.3, curve: Curves.easeOut),
      reverseCurve: const Interval(0.3, 1, curve: Curves.easeIn),
    );
    _cardController = AnimationController(
      vsync: this,
      duration: _kCardFlightDuration,
    );
    _cardProgress = CurvedAnimation(
      parent: _cardController,
      curve: _kCardFlightCurve,
    );
    _cardController.addStatusListener(_handleCardStatus);
  }

  @override
  void dispose() {
    _cardController.removeStatusListener(_handleCardStatus);
    _cardController.dispose();
    _rectProgress.dispose();
    _scrimProgress.dispose();
    _crossFade.dispose();
    super.dispose();
  }

  /// 面板保存后飞向新卡片；路由动画已经结束，用独立控制器驱动。
  bool startCardMorph(RecordCardMorphTarget target) {
    if (!mounted || _cardTarget != null) return false;
    final from = _readSheetRect() ?? _lastSheetRect;
    if (from == null) return false;
    setState(() {
      _cardFrom = from;
      _cardTarget = target;
    });
    _cardController.forward();
    return true;
  }

  void _handleCardStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final target = _cardTarget;
    if (target == null || _landing) return;
    // 先让页面把真实卡片揭开（盖板还压在上面，看不到跳变），再淡出盖板。
    target.onLanded();
    if (!mounted) return;
    widget.route.prepareLandingExit();
    setState(() => _landing = true);
    Navigator.of(context).pop();
  }

  Rect? _readSheetRect() {
    final box = widget.route.surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 飞行/落位期间锁住返回与遮罩点击，避免面板中途关掉后卡片一直藏着。
      canPop: _cardTarget == null,
      child: Theme(
        data: widget.route.theme,
        // 发送飞行时路由动画已经停在 1，只有这个控制器在跑；
        // 不监听它的话容器会停在起飞点（第一版就是漏了这一步）。
        child: AnimatedBuilder(
          animation: _cardController,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final sheetRect = _readSheetRect();
              if (sheetRect != null) {
                _lastSheetRect = sheetRect;
              }

              if (_landing) {
                return _buildLanding();
              }
              if (_cardTarget != null) {
                return _buildCardFlight(size);
              }
              return _buildAnchorMorph(sheetRect, size);
            },
          ),
        ),
      ),
    );
  }

  /// 打开/关闭：按钮与卡片之间的容器变形。
  Widget _buildAnchorMorph(Rect? sheetRect, Size size) {
    final origin = widget.route.originAnchor!;
    final isReversing = widget.animation.status == AnimationStatus.reverse;
    final liveAnchor = widget.route.readAnchor?.call() ?? origin;
    // 收回时 FAB 可能已经因为发送清空选择而变回 44 圆钮，目标 Rect 要实时读。
    final anchor = isReversing ? liveAnchor : origin;
    final style = DiaryRecordFabStyle.resolve(
      widget.route.theme,
      hasSelection: anchor.selection != null,
    );
    final scheme = widget.route.theme.colorScheme;
    final target = sheetRect ?? _lastSheetRect ?? origin.rect;

    // 入场完成：容器/幽灵撤掉，内容窗口铺满全屏并停止裁切。
    // 面板 widget 必须始终待在同一个带 Key 的窗口里 —— 直接把它挪到
    // Stack 的另一层会让 Element 重新挂载，输入框和焦点会被重置。
    // 窗口铺满全屏还有个好处：键盘把卡片顶上去后，整张卡仍然可点，
    // 不会因为窗口停在旧位置把下半截切在命中区域外。
    if (!isReversing && widget.animation.status == AnimationStatus.completed) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildScrim(1, allowDismiss: true),
          _buildContentWindow(
            Offset.zero & size,
            0,
            1,
            size,
            clip: false,
          ),
        ],
      );
    }

    final t = _rectProgress.value;
    final rect = Rect.lerp(anchor.rect, target, t)!;
    final radius = lerpDouble(DiaryRecordFab.radius, _kSheetRadius, t)!;
    final color = Color.lerp(style.background, scheme.surface, t)!;
    final borderColor = style.border?.top.color;
    final border = borderColor == null || t >= 0.999
        ? null
        : Border.all(
            color: borderColor.withValues(alpha: borderColor.a * (1 - t)),
            width: style.border!.top.width,
          );
    final shadow = _lerpShadow(
      style.boxShadow.first,
      _dialogShadow(widget.route.theme),
      t,
    );

    // 入场内容不套外层淡入：面板自己的 _Reveal 已经把内容错峰点亮了。
    final contentOpacity = isReversing ? _crossFade.value : 1.0;
    final ghostOpacity = 1 - _crossFade.value;

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildScrim(
          _scrimProgress.value,
          allowDismiss: !isReversing && widget.animation.value > 0.4,
        ),
        _buildContainer(
          rect: rect,
          radius: radius,
          color: color,
          border: border,
          shadows: [shadow],
        ),
        _buildContentWindow(
          rect,
          radius,
          contentOpacity,
          size,
          interactive: !isReversing,
        ),
        if (ghostOpacity > 0.001)          Positioned.fromRect(
            key: const ValueKey('record-sheet-ghost'),
            rect: anchor.rect,
            child: Opacity(
              opacity: ghostOpacity,
              child: DiaryRecordFabPreview(
                selection: anchor.selection,
                hasDraft: anchor.hasDraft,
              ),
            ),
          ),
      ],
    );
  }

  /// 发送后：面板先淡成空白盖板，再飞到目标卡片的位置。
  Widget _buildCardFlight(Size size) {
    final target = _cardTarget!;
    final to = target.readRect() ?? target.initialRect;
    final from = _cardFrom!;
    final t = _cardProgress.value;
    final rect = Rect.lerp(from, to, t)!;
    final radius = lerpDouble(_kSheetRadius, _kTimelineCardRadius, t)!;
    final fadeOut = const Interval(0, 0.3, curve: Curves.easeOut).transform(t);
    final contentOpacity = (1 - fadeOut).clamp(0.0, 1.0).toDouble();
    // 盖板越接近卡片，阴影越轻；落到卡片上时完全交给卡片自己的阴影。
    final shadow = _lerpShadow(
      _dialogShadow(widget.route.theme),
      const BoxShadow(color: Colors.transparent),
      t,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildScrim(_scrimProgress.value, allowDismiss: false),
        _buildContainer(
          rect: rect,
          radius: radius,
          color: widget.route.theme.colorScheme.surface,
          border: null,
          shadows: [shadow],
        ),
        _buildContentWindow(
          rect,
          radius,
          contentOpacity,
          size,
          interactive: false,
        ),
      ],
    );
  }

  /// 落位：盖板已经压在真实卡片上，和遮罩一起淡出，把卡片内容让出来。
  Widget _buildLanding() {
    final target = _cardTarget!;
    final rect = target.readRect() ?? target.initialRect;
    final fade = Curves.easeOutCubic.transform(widget.animation.value);
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildScrim(fade, allowDismiss: false),
        Positioned.fromRect(
          key: const ValueKey('record-sheet-landing-slot'),
          rect: rect,
          child: IgnorePointer(
            child: Opacity(
              opacity: fade,
              child: DecoratedBox(
                key: const ValueKey('record-sheet-landing'),
                decoration: BoxDecoration(
                  color: widget.route.theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(_kTimelineCardRadius),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 自绘遮罩。
  ///
  /// 变形路径把路由的 barrier 设成透明，遮罩跟着容器一起动；[allowDismiss]
  /// 为 false 时仍然吃掉点击（空回调），防止穿透到下面的时间线。
  Widget _buildScrim(double opacity, {required bool allowDismiss}) {
    return Positioned.fill(
      key: const ValueKey('record-sheet-scrim'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: allowDismiss ? () => Navigator.of(context).maybePop() : () {},
        child: ColoredBox(
          color: Colors.black.withValues(
            alpha: 0.4 * opacity.clamp(0.0, 1.0).toDouble(),
          ),
        ),
      ),
    );
  }

  /// 变形容器的底色/圆角/描边/阴影。
  Widget _buildContainer({
    required Rect rect,
    required double radius,
    required Color color,
    required Border? border,
    required List<BoxShadow> shadows,
  }) {
    return Positioned.fromRect(
      key: const ValueKey('record-sheet-morph-slot'),
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('record-sheet-morph'),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
            border: border,
            boxShadow: shadows,
          ),
        ),
      ),
    );
  }

  /// 把整页面板内容裁进变形窗口。
  ///
  /// [OverflowBox] 让面板仍按最终全屏尺寸布局，[Transform.translate] 再把
  /// 整页平移回全屏原点——外层 Positioned 的偏移和这里的平移恰好抵消，所以
  /// 窗口怎么变都不会触发面板重新布局，量到的卡片 Rect 也始终是最终值。
  ///
  /// 这个窗口在入场、保持、收回、飞行全程都留在同一层（带固定 Key），
  /// 只改 Rect / 圆角 / 裁切开关；否则面板 Element 会被重新挂载，输入焦点
  /// 和本地草稿状态会在动画切换的那一帧被重置。
  Widget _buildContentWindow(
    Rect rect,
    double radius,
    double opacity,
    Size size, {
    bool clip = true,
    bool interactive = true,
  }) {
    return Positioned.fromRect(
      key: const ValueKey('record-sheet-window'),
      rect: rect,
      child: IgnorePointer(
        // 收回/飞行途中内容已经不可见，不能再让点击命中面板里的按钮。
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
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0).toDouble(),
                child: RepaintBoundary(child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

BoxShadow _dialogShadow(ThemeData theme) {
  return BoxShadow(
    color: theme.colorScheme.shadow.withValues(alpha: 0.16),
    blurRadius: 32,
    offset: const Offset(0, 12),
  );
}

BoxShadow _lerpShadow(BoxShadow from, BoxShadow to, double t) {
  return BoxShadow(
    color: Color.lerp(from.color, to.color, t)!,
    offset: Offset.lerp(from.offset, to.offset, t)!,
    blurRadius: lerpDouble(from.blurRadius, to.blurRadius, t)!,
    spreadRadius: lerpDouble(from.spreadRadius, to.spreadRadius, t)!,
  );
}

/// 面板入场/退场：整卡缩放 + 上浮 + 淡入。
///
/// 缩放用 M3 的「强调减速」曲线（起步快、尾段极缓），卡片像是被轻轻放到
/// 屏幕中央，而不是「啪」地出现。动画对象在 initState 建好、dispose 释放，
/// 避免每次 build 都往路由动画上挂监听。
class _DialogEntrance extends StatefulWidget {
  const _DialogEntrance({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_DialogEntrance> createState() => _DialogEntranceState();
}

class _DialogEntranceState extends State<_DialogEntrance> {
  late final CurvedAnimation _motion;
  late final CurvedAnimation _fade;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _motion = CurvedAnimation(
      parent: widget.animation,
      curve: _kDialogEnterCurve,
      reverseCurve: _kDialogExitCurve,
    );
    // 透明度比缩放更早到位：卡片先「看得见」，再靠缩放收尾，观感更稳。
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.6, curve: Curves.easeOut),
      // 退场时在动画走到 0.4 之前就淡完，剩下的位移不可见，收得干脆。
      reverseCurve: const Interval(0.4, 1, curve: Curves.easeIn),
    );
    _scale = Tween<double>(begin: 0.92, end: 1).animate(_motion);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.035),
      end: Offset.zero,
    ).animate(_motion);
  }

  @override
  void dispose() {
    _motion.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: _scale,
        child: SlideTransition(position: _slide, child: widget.child),
      ),
    );
  }
}

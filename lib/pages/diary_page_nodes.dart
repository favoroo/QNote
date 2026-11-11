part of 'diary_page.dart';
// 从主文件拆出的底部组件，保持同一 library 以便继续访问私有类型。

/// 单次卡片拖动调时的会话状态。
///
/// 只保存拖拽起点与浮层几何，目标时间由 [TimelineTimeShift] 按当前手指位置
/// 重新计算；这样自动滚动、跨节点拖动都走同一条计算路径。
class _RecordTimeDragState {
  _RecordTimeDragState({
    required this.record,
    required this.startGlobalY,
    required this.startScrollOffset,
    required this.grabOffsetY,
    required this.cardLeft,
    required this.cardWidth,
    required this.axisX,
    required this.proxyTop,
    required this.topLimit,
    required this.bottomLimit,
    required this.shift,
  });

  final DiaryRecord record;
  final double startGlobalY;
  final double startScrollOffset;

  /// 长按点相对卡片顶部的偏移，保证浮层不会在起手瞬间跳一下。
  final double grabOffsetY;

  final double cardLeft;
  final double cardWidth;
  final double axisX;
  final double topLimit;
  final double bottomLimit;

  /// 浮层当前顶部位置（跟随手指）。
  double proxyTop;

  /// 当前目标时间平移结果。
  TimelineTimeShift shift;
}

/// 节点行右端的「就地记录」加号槽位。
///
/// 放在节点行的 [Stack] 右端：视觉上压在 1px 时间线的末端，选中时淡入并轻微
/// 放大，取消选择时原路缩回。空态是一个 0 尺寸占位，不参与命中。
class _TimelineRecordButtonSlot extends StatelessWidget {
  const _TimelineRecordButtonSlot({required this.onTap});

  /// 为空表示当前行不是选中区间的末端。
  final ValueChanged<Rect?>? onTap;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : AppDurations.normal,
      switchInCurve: AppCurves.emphasized,
      switchOutCurve: AppCurves.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween<double>(begin: 0.7, end: 1).animate(animation), child: child),
      ),
      child: onTap == null
          ? const SizedBox.shrink(key: ValueKey('timeline-record-slot-empty'))
          : DiaryInlineRecordButton(key: const ValueKey('timeline-record-slot-button'), onTap: onTap!),
    );
  }
}

class _EmptyTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final bool isSelected;
  final bool isMultiSelect;
  final bool isDraggedSelected;
  final bool isCurrentTime;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  /// 本行是选中区间的末端时，在时间线右端显示「就地记录」加号。
  final ValueChanged<Rect?>? onRecordTap;

  const _EmptyTimeNode({
    super.key,
    required this.time,
    required this.isSelected,
    this.isMultiSelect = false,
    this.isDraggedSelected = false,
    this.isCurrentTime = false,
    required this.onTap,
    this.onDoubleTap,
    this.onRecordTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;
    final bool isSingleSelected = isSelected && !isMultiSelect;

    final circleColor = isSelected
        ? theme.colorScheme.primary
        : (isCurrentTime ? distinctColor.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant);

    final double circleSize = isSelected ? (isSingleSelected ? 10 : 16) : (isCurrentTime ? 10 : 8);

    final labelColor = isSelected ? theme.colorScheme.primary : distinctColor;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Center(
                    child: AnimatedContainer(
                      duration: AppDurations.normal,
                      curve: Curves.easeOut,
                      width: circleSize,
                      height: circleSize,
                      decoration: BoxDecoration(
                        color: circleColor,
                        shape: BoxShape.circle,
                        boxShadow: isSelected && !isSingleSelected
                            ? [
                                BoxShadow(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: isSelected && !isSingleSelected
                          ? Center(
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: theme.colorScheme.onPrimary, shape: BoxShape.circle),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                AnimatedDefaultTextStyle(
                  duration: AppDurations.normal,
                  curve: Curves.easeOut,
                  style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : (isCurrentTime ? distinctColor : theme.colorScheme.onSurfaceVariant),
                    fontWeight: isSelected || isCurrentTime ? FontWeight.bold : FontWeight.w500,
                    fontSize: isSelected ? 13 : 12,
                  ),
                  child: Text(timeStr),
                ),
                if (isCurrentTime) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: labelColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '当前时间',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: labelColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedContainer(
                    duration: AppDurations.normal,
                    curve: Curves.easeOut,
                    height: 1,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : (isCurrentTime
                              ? distinctColor.withValues(alpha: 0.2)
                              : theme.colorScheme.outlineVariant.withValues(alpha: 0.15)),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
            Positioned(right: 0, top: 0, bottom: 0, child: _TimelineRecordButtonSlot(onTap: onRecordTap)),
          ],
        ),
      ),
    );
  }
}

class _SelectedTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final bool isCurrentTime;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  /// 本行是选中区间的末端时，在时间线右端显示「就地记录」加号。
  final ValueChanged<Rect?>? onRecordTap;

  const _SelectedTimeNode({
    required this.time,
    this.isCurrentTime = false,
    required this.onTap,
    this.onDoubleTap,
    this.onRecordTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;
    final labelColor = isCurrentTime ? distinctColor : theme.colorScheme.primary;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                    ),
                  ),
                ),
                if (isCurrentTime) ...[
                  Icon(Icons.access_time_rounded, size: 14, color: labelColor),
                  const SizedBox(width: 6),
                ],
                Text(
                  timeStr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                if (isCurrentTime) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: labelColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '当前时间',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: labelColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                Expanded(child: Container(height: 1, color: theme.colorScheme.primary)),
                const SizedBox(width: 16),
              ],
            ),
            Positioned(right: 0, top: 0, bottom: 0, child: _TimelineRecordButtonSlot(onTap: onRecordTap)),
          ],
        ),
      ),
    );
  }
}

class _CurrentTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _CurrentTimeNode({required this.time, required this.onTap, this.onDoubleTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: distinctColor.withValues(alpha: 0.6), shape: BoxShape.circle),
                ),
              ),
            ),
            Icon(Icons.access_time_filled, size: 14, color: distinctColor),
            const SizedBox(width: 6),
            Text(
              timeStr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: distinctColor,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: distinctColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '当前时间',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: distinctColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 9,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Container(height: 1, color: distinctColor.withValues(alpha: 0.3))),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

class TimelineItemWrapper extends StatefulWidget {
  final int index;
  final Widget child;
  final void Function(int index, BuildContext context) onMount;
  final void Function(int index) onUnmount;
  final void Function(int index, double height) onHeightChange;

  const TimelineItemWrapper({
    super.key,
    required this.index,
    required this.child,
    required this.onMount,
    required this.onUnmount,
    required this.onHeightChange,
  });

  @override
  State<TimelineItemWrapper> createState() => _TimelineItemWrapperState();
}

class _TimelineItemWrapperState extends State<TimelineItemWrapper> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onMount(widget.index, context);
        _reportHeight();
      }
    });
  }

  void _reportHeight() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      widget.onHeightChange(widget.index, renderBox.size.height);
    }
  }

  @override
  void didUpdateWidget(TimelineItemWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      widget.onUnmount(oldWidget.index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onMount(widget.index, context);
          _reportHeight();
        }
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reportHeight();
      });
    }
  }

  @override
  void dispose() {
    widget.onUnmount(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// 日记列表项平滑退场包装组件。
///
/// 当 [isCollapsing] 变为 true 时，在 200ms 内同步收缩高度并淡出，
/// 避免长按删除时列表项生硬蒸发的割裂感。
class _CollapsingItemWrapper extends StatefulWidget {
  final bool isCollapsing;
  final Widget child;

  const _CollapsingItemWrapper({required this.isCollapsing, required this.child});

  @override
  State<_CollapsingItemWrapper> createState() => _CollapsingItemWrapperState();
}

class _CollapsingItemWrapperState extends State<_CollapsingItemWrapper> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDurations.normal, value: 1.0);
    _sizeAnimation = CurvedAnimation(parent: _controller, curve: AppCurves.standard);
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: AppCurves.exit);
  }

  @override
  void didUpdateWidget(covariant _CollapsingItemWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCollapsing && !oldWidget.isCollapsing) {
      _controller.reverse();
    } else if (!widget.isCollapsing && oldWidget.isCollapsing) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _sizeAnimation,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: _fadeAnimation, child: widget.child),
    );
  }
}

/// 新记录卡片的入场：从上方「长出来」+ 淡入上移 + 一圈淡出的主色辉光。
///
/// [isInserting] 只在记录面板刚写下这条时为 true。延迟 [_kInsertRevealDelay] 是
/// 为让位：记录面板保存后还要播 320ms 的 ✓ 再花 180ms 退场（见
/// `DiaryRecordSheet._savedFeedbackDuration`），卡片立刻升起会被面板整个盖住，
/// 动画等于白做；440ms 让卡片在面板完全消失前 60ms 开始升起，形成交接。
///
/// [animateSize] 为 false 时只保留辉光：发送后的「弹窗变卡片」由盖板落位负责
/// 出现，卡片本身已经是全高的，不能再从 0 长一遍。
///
/// 辉光画在卡片外层而不是铺一层色块盖在内容上 —— 覆盖式高亮会把卡片文字压暗，
/// 而新增记录恰恰是用户最需要看清内容的时候。
class _InsertingItemWrapper extends StatefulWidget {
  const _InsertingItemWrapper({required this.isInserting, this.animateSize = true, required this.child});

  final bool isInserting;

  /// 是否播放「长高 + 淡入」；false 时只播辉光。
  final bool animateSize;

  final Widget child;

  @override
  State<_InsertingItemWrapper> createState() => _InsertingItemWrapperState();
}

/// 入场时长与让位延迟。
const Duration _kInsertDuration = Duration(milliseconds: 400);
const Duration _kInsertRevealDelay = Duration(milliseconds: 440);

class _InsertingItemWrapperState extends State<_InsertingItemWrapper> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _grow;
  late final Animation<double> _fade;
  late final Animation<double> _glow;
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    // 用平台无障碍开关而不是 MediaQuery：initState 里依赖 InheritedWidget 是违规的。
    final reduceMotion = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    final shouldPlay = widget.isInserting && !reduceMotion;

    _controller = AnimationController(
      vsync: this,
      duration: _kInsertDuration,
      value: shouldPlay && widget.animateSize ? 0 : 1,
    );
    _grow = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.6, curve: Curves.easeOut),
    );
    // 后 75% 用来把辉光收掉：落位那一刻最亮，收尾时不留痕迹
    _glow = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.25, 1, curve: Curves.easeOut),
    );

    if (shouldPlay && widget.animateSize) {
      _startTimer = Timer(_kInsertRevealDelay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _InsertingItemWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 「弹窗变卡片」落位时卡片已经在位，只补一次辉光：从 0 跑到 1，
    // 但不经过 SizeTransition，高度不会被重新拉一遍。
    if (!oldWidget.isInserting && widget.isInserting && !widget.animateSize) {
      final reduceMotion = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
      if (!reduceMotion) {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final content = AnimatedBuilder(
      animation: _glow,
      builder: (context, child) {
        // 只留一圈很淡的主色光晕：新卡片是「亮了一下」，不是霓虹灯。
        final strength = 1 - _glow.value;
        final alpha = strength * 0.24;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: alpha <= 0.01
                ? const []
                : [
                    BoxShadow(
                      color: primary.withValues(alpha: alpha),
                      blurRadius: 18,
                      spreadRadius: 2 * strength,
                    ),
                  ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );

    // 飞行落位：卡片已经在位，只让辉光亮一下，不能再套一层长高/淡入。
    if (!widget.animateSize) {
      return content;
    }

    return SizeTransition(
      sizeFactor: _grow,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(_grow),
          child: content,
        ),
      ),
    );
  }
}

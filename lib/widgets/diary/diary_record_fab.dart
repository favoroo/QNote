import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/utils/timeline_selection_label.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';

/// 记录按钮的底色 / 前景色 / 描边 / 阴影 / 草稿点颜色。
///
/// 按钮本体、打开面板时的静态「幽灵」、路由里的变形容器三处共用同一份规则。
/// 各写一份的话，变形容器的起点会和真实按钮差一点颜色或描边，放大时一眼就能
/// 看出「换了个东西」。
class DiaryRecordFabStyle {
  const DiaryRecordFabStyle({
    required this.background,
    required this.foreground,
    required this.border,
    required this.boxShadow,
    required this.dotColor,
  });

  final Color background;
  final Color foreground;
  final Border? border;
  final List<BoxShadow> boxShadow;
  final Color dotColor;

  factory DiaryRecordFabStyle.resolve(ThemeData theme, {required bool hasSelection, bool compact = false}) {
    final scheme = theme.colorScheme;
    if (compact) {
      // 时间线节点行里的小圆钮：实心主色 + 轻辉光，和 1px 选中线同色，
      // 一眼就能看出「在这条线上记录」。它同时是记录面板容器变形的起点。
      final needsOutline = AppContrast.contrastRatio(scheme.primary, theme.scaffoldBackgroundColor) < 1.35;
      return DiaryRecordFabStyle(
        background: scheme.primary,
        foreground: scheme.onPrimary,
        border: needsOutline ? Border.all(color: scheme.outlineVariant, width: 1.0) : null,
        boxShadow: [
          BoxShadow(color: scheme.primary.withValues(alpha: 0.28), blurRadius: 10, offset: const Offset(0, 3)),
        ],
        dotColor: scheme.onPrimary,
      );
    }
    return DiaryRecordFabStyle(
      // 主题里的 primaryContainer 是带 alpha 的强调色（见 app_theme.dart），
      // 直接拿它铺底等于给时间线开了扇窗——底下滚过的文字会透上来，和胶囊里的
      // 时间叠在一起。先把它混到不透明的 surface 上，色调不变但彻底挡住背后。
      // 选中态用主色容器而不是主色实心：它是过渡状态，不该和右侧实心的智能提取
      // 按钮抢同样的视觉重量；文字/圆点走 onPrimaryContainer，在同色系背景上仍可读。
      background: hasSelection ? Color.alphaBlend(scheme.primaryContainer, scheme.surface) : scheme.surface,
      foreground: hasSelection ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      border: hasSelection ? null : Border.all(color: scheme.outlineVariant, width: 1.5),
      boxShadow: [
        BoxShadow(
          color: scheme.shadow.withValues(alpha: hasSelection ? 0.10 : 0.06),
          blurRadius: hasSelection ? 8 : 6,
          offset: const Offset(0, 3),
        ),
      ],
      dotColor: hasSelection ? scheme.onPrimaryContainer : scheme.tertiary,
    );
  }
}

/// 时间线左下角的记录按钮。
///
/// 空闲时是与右侧「日记 / 智能提取」对称的 44 圆钮；时间线上选了时间后横向
/// 展开成胶囊，把「这次要记在哪一刻」直接摆在按钮上 —— 时间不再是输入栏里的
/// 一个字段，而是记录动作的入口状态本身。
///
/// morph 分三层：
/// - 宽度由 [AnimatedSize] 驱动；
/// - 底色/圆角/描边/阴影挂在它 **外层** 的 [AnimatedContainer] 上，于是胶囊的
///   圆头在整段 morph 里都是完整的。反过来把装饰放进 [AnimatedSize] 内部时，
///   矩形裁剪会把右端切成直口，看起来像一块被推着走的色块；
/// - 时间与 × 用 [AnimatedSwitcher] 淡入，退场内容绝对定位、不参与宽度计算，
///   由外层 [ClipRect] 按动画宽度擦掉 —— 点 × 时胶囊会立刻回缩，而不是等旧
///   内容淡出完（360ms）再动。
class DiaryRecordFab extends ConsumerStatefulWidget {
  const DiaryRecordFab({super.key, required this.onTap});

  /// 空闲态直径 = 胶囊高度；打开面板的容器变形从这里起步。
  static const double height = 44;
  static const double radius = height / 2;

  /// 时间线选中节点右侧「就地记录」小圆钮的直径与加号尺寸。
  ///
  /// 路由里的紧凑幽灵预览也读这两个值：两边不一致时，面板起落会看到加号跳一下。
  static const double inlineDiameter = 28;
  static const double inlineIconSize = 18;

  /// 点胶囊主体（或空闲态的圆钮）时打开记录面板。
  final VoidCallback onTap;

  @override
  ConsumerState<DiaryRecordFab> createState() => _DiaryRecordFabState();
}

class _DiaryRecordFabState extends ConsumerState<DiaryRecordFab> with SingleTickerProviderStateMixin {
  /// 胶囊 morph 时长与曲线。
  ///
  /// 这里是整段交互的主角，宁慢勿快：0.56s 配 M3 emphasized（起步轻、中段
  /// 推进、收尾极缓）才有「从容地展开」的感觉。之前的 380ms + easeOutQuint
  /// 在前 20% 时间就走完三分之二的宽度，观感是「啪」地弹出来。
  static const Duration _morphDuration = Duration(milliseconds: 560);
  static const Curve _morphCurve = Curves.easeInOutCubicEmphasized;
  static const Duration _labelSwapDuration = Duration(milliseconds: 320);

  /// 右侧「时间 + ×」的入场时长。
  ///
  /// 比 [_morphDuration] 短，但要贴着容器增长的后半段收尾：太快内容先亮完、
  /// 容器还在变宽，像文字先闪出来再被撑开；太慢又会拖在宽度定型之后。
  static const Duration _symbolSwapDuration = Duration(milliseconds: 360);
  static const Duration _pressDuration = Duration(milliseconds: 100);

  bool _pressed = false;

  /// 选中瞬间的一次轻微回弹，避免点击后按钮「毫无反应」。
  ///
  /// 幅度压到 1.02、时长放到 360ms：它只是给点击一个即时回应，不该抢
  /// 后面 0.56s 展开动画的戏。原来的 1.08 + easeOutBack 和快速 morph
  /// 叠在一起，正是「弹一下」的主要来源。
  late final AnimationController _bounceController;
  late final Animation<double> _bounce;

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
    _bounce = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.02).chain(CurveTween(curve: Curves.easeOutCubic)), weight: 35),
      TweenSequenceItem(
        tween: Tween(begin: 1.02, end: 1.0).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 65,
      ),
    ]).animate(_bounceController);
  }

  @override
  void dispose() {
    _bounceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selection = ref.watch(diaryInputTimeProvider);
    // 只关心「草稿是不是空的」：默认 watch 会让按钮跟着每一次打字重建。
    final hasDraft = ref.watch(diaryComposeDraftProvider.select((draft) => !draft.isEmpty));
    final hasSelection = selection != null;

    // 从无到有的那一次转换才回弹：改时间、改区间都不该反复弹。
    ref.listen<TimelineTimeSelectEvent?>(diaryInputTimeProvider, (previous, next) {
      if (previous == null && next != null) {
        if (!AppMotion.reduce(context)) {
          _bounceController.forward(from: 0);
        }
        HapticFeedback.selectionClick();
      }
    });

    final reduceMotion = AppMotion.reduce(context);
    final label = selection == null
        ? null
        : buildTimelineSelectionLabel(
            startTime: selection.time,
            endTime: selection.endTime,
            startDate: selection.date,
            endDate: selection.endDate,
            today: _todayOf(DateTime.now()),
          );

    return AnimatedBuilder(
      animation: _bounce,
      builder: (context, child) => Transform.scale(scale: reduceMotion ? 1 : _bounce.value, child: child),
      // morph 的尺寸动画在 _buildBody 内部（贴着装饰层），这里只留按压反馈。
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1,
        duration: reduceMotion ? Duration.zero : _pressDuration,
        curve: Curves.easeOutCubic,
        child: _buildBody(theme, label, hasSelection: hasSelection, hasDraft: hasDraft, reduceMotion: reduceMotion),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    TimelineSelectionLabel? label, {
    required bool hasSelection,
    required bool hasDraft,
    required bool reduceMotion,
  }) {
    final scheme = theme.colorScheme;
    final style = DiaryRecordFabStyle.resolve(theme, hasSelection: hasSelection);

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 装饰挂在外层：AnimatedContainer 的尺寸跟着 AnimatedSize 的动画
            // 宽度走，所以底色、描边和阴影每一帧都画在「当前宽度」上，胶囊
            // 右端始终是圆头，而不是被矩形裁出来的直口。描边单独走前景装饰，
            // 原因见下面 foregroundDecoration 的注释。
            AnimatedContainer(
              duration: reduceMotion ? Duration.zero : _morphDuration,
              curve: _morphCurve,
              height: DiaryRecordFab.height,
              // 空闲态 12+20+12 正好 44 直径，选中态沿用同一内边距，
              // 于是 morph 期间不需要再动画 padding（少一层会不同步的动画）。
              constraints: const BoxConstraints(minWidth: DiaryRecordFab.height),
              decoration: BoxDecoration(
                color: style.background,
                borderRadius: BorderRadius.circular(DiaryRecordFab.radius),
                boxShadow: style.boxShadow,
              ),
              // 描边走前景装饰而不是 decoration：Container 会把 decoration 里
              // border 的宽度算进内边距，1.5 的描边就是左右各让 1.5，空闲态宽度
              // 从 44 被撑到 47（高度被约束钉死在 44），22 的圆角于是画成横向
              // 拉长的椭圆。前景装饰不参与布局，尺寸仍是正 44×44 的圆。
              foregroundDecoration: style.border == null
                  ? null
                  : BoxDecoration(borderRadius: BorderRadius.circular(DiaryRecordFab.radius), border: style.border),
              // 内容（Padding + Row）按自然宽度布局，由 AnimatedSize 报告动画
              // 尺寸；AnimatedSize 只在自身溢出时裁剪，退场中的旧标签溢出的
              // 部分靠这层 ClipRect 按动画宽度切掉。
              child: ClipRect(
                child: AnimatedSize(
                  duration: reduceMotion ? Duration.zero : _morphDuration,
                  curve: _morphCurve,
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 加号永远钉在最左侧不动，时间和 × 依次从它右边长出来 ——
                        // 配合 AnimatedSize 的 centerLeft 对齐与裁剪，观感就是「从加号向右侧
                        // 拉开一条」，而不是整块按钮变宽再重排内容。
                        Icon(Icons.add_rounded, size: 20, color: style.foreground),
                        // 右侧整组（时间 + ×）作为一个单位淡入并自左向右推开，
                        // 让「展开」这件事有方向感：不是凭空出现，而是从加号里被拉出来。
                        AnimatedSwitcher(
                          duration: reduceMotion ? Duration.zero : _symbolSwapDuration,
                          // 等容器先让出一点空间，内容再开始淡入；区间拉长到 0.18 起，
                          // 是因为 morph 改慢后容器前半段几乎是静止的，内容太早亮会显得
                          // 文字先于胶囊出现。
                          switchInCurve: const Interval(0.18, 1, curve: Curves.easeOutCubic),
                          switchOutCurve: Curves.easeIn,
                          // 退场内容绝对定位，不参与宽度计算：点 × 时当前内容
                          // 立刻变成 0 宽，胶囊当帧就开始回缩，旧标签则在收缩的
                          // 边缘后面淡出，不会先停 360ms 再动。
                          layoutBuilder: (current, previous) => ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 20),
                            child: Stack(
                              alignment: Alignment.centerLeft,
                              clipBehavior: Clip.none,
                              children: [
                                for (final child in previous) Positioned(left: 0, top: 0, bottom: 0, child: child),
                                ?current,
                              ],
                            ),
                          ),
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(-0.25, 0),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          ),
                          child: label == null
                              ? const SizedBox.shrink(key: ValueKey('empty'))
                              : Row(
                                  key: const ValueKey('selection'),
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: 2),
                                    _SelectionLabel(label: label, foreground: style.foreground),
                                    const SizedBox(width: 2),
                                    _ClearSelectionButton(foreground: style.foreground, onTap: _clearSelection),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 有草稿没保存时右上角点一颗小圆点，免得关掉面板后再也看不出「还没记完」
            if (hasDraft)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  key: const ValueKey('fab-draft-dot'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: style.dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _clearSelection() {
    HapticFeedback.selectionClick();
    ref.read(diaryInputTimeProvider.notifier).state = null;
  }

  DateTime _todayOf(DateTime now) => DateTime(now.year, now.month, now.day);
}

/// 时间线选中行右端的「就地记录」小圆钮。
///
/// 点它直接打开记录面板，并把面板的容器变形起点交回按钮自身：弹层从这个
/// 圆钮长出来，而不是从屏幕左下角的常驻按钮飞过来。视觉与 [DiaryRecordFab]
/// 的紧凑选中态共用一份配色，命中区扩到 44×44，不必瞄准细线末端。
class DiaryInlineRecordButton extends StatefulWidget {
  const DiaryInlineRecordButton({super.key, required this.onTap});

  /// 回调收到按钮当前的全局 Rect；量不到时传 null，面板退回无锚点入场。
  final ValueChanged<Rect?> onTap;

  @override
  State<DiaryInlineRecordButton> createState() => _DiaryInlineRecordButtonState();
}

class _DiaryInlineRecordButtonState extends State<DiaryInlineRecordButton> {
  /// 量视觉圆钮而不是 44 的命中区：容器变形要从真实的 28 圆起步。
  final GlobalKey _circleKey = GlobalKey();
  bool _pressed = false;
  bool _hovered = false;

  Rect? _measureCircle() {
    final box = _circleKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _handleTap() {
    widget.onTap(_measureCircle());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion = AppMotion.reduce(context);
    final style = DiaryRecordFabStyle.resolve(theme, hasSelection: true, compact: true);
    // 鼠标悬停略放大、按下略缩小；触摸端没有 hover，只剩按压反馈。
    final scale = _pressed ? 0.9 : (_hovered ? 1.06 : 1.0);

    return Semantics(
      button: true,
      label: '记录',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SizedBox(
            width: DiaryRecordFab.height,
            height: DiaryRecordFab.height,
            child: Center(
              child: AnimatedScale(
                scale: scale,
                duration: reduceMotion ? Duration.zero : AppDurations.press,
                curve: AppCurves.emphasized,
                child: Container(
                  key: _circleKey,
                  width: DiaryRecordFab.inlineDiameter,
                  height: DiaryRecordFab.inlineDiameter,
                  decoration: BoxDecoration(
                    color: style.background,
                    shape: BoxShape.circle,
                    border: style.border,
                    boxShadow: style.boxShadow,
                  ),
                  child: Icon(Icons.add_rounded, size: DiaryRecordFab.inlineIconSize, color: style.foreground),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 记录按钮的静态副本，用于打开面板时的容器变形起点。
///
/// 真实按钮在路由打开期间被隐藏，变形容器从按钮 Rect 起步；如果起点上只有
/// 一块纯色，加号/时间会「啪」地消失。这个副本用同一套配色和排版把内容画在
/// 起点上，再随容器长大淡出，观感才是「按钮被拿起来展开」而不是「按钮被替换」。
///
/// 不复制交互：整体包了 [IgnorePointer]，× 只是画出来的圆钮。
class DiaryRecordFabPreview extends StatelessWidget {
  const DiaryRecordFabPreview({super.key, this.selection, this.hasDraft = false, this.compact = false});

  /// 起点时刻按钮上的时间选择（为空表示纯加号圆钮）。
  final TimelineTimeSelectEvent? selection;

  /// 有未保存草稿时按钮右上角的圆点。
  final bool hasDraft;

  /// 紧凑态：起点是时间线行内的 28 小圆钮，只画居中的加号，不铺时间与 ×。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selection = this.selection;
    final style = DiaryRecordFabStyle.resolve(theme, hasSelection: selection != null, compact: compact);

    if (compact) {
      return IgnorePointer(
        child: Center(
          child: Icon(Icons.add_rounded, size: DiaryRecordFab.inlineIconSize, color: style.foreground),
        ),
      );
    }

    final now = DateTime.now();
    final label = selection == null
        ? null
        : buildTimelineSelectionLabel(
            startTime: selection.time,
            endTime: selection.endTime,
            startDate: selection.date,
            endDate: selection.endDate,
            today: DateTime(now.year, now.month, now.day),
          );

    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 20, color: style.foreground),
                    if (label != null) ...[
                      const SizedBox(width: 2),
                      _SelectionLabel(label: label, foreground: style.foreground),
                      const SizedBox(width: 2),
                      _ClearSelectionButton(foreground: style.foreground, onTap: () {}),
                    ],
                  ],
                ),
              ),
            ),
            if (hasDraft)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: style.dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.surface, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊里的清除钮：把「记哪一刻」和「取消这次时间选择」分成两个可点区域，
/// 点时间开面板、点 × 取消选择，互不误触。
class _ClearSelectionButton extends StatefulWidget {
  const _ClearSelectionButton({required this.foreground, required this.onTap});

  final Color foreground;
  final VoidCallback onTap;

  @override
  State<_ClearSelectionButton> createState() => _ClearSelectionButtonState();
}

class _ClearSelectionButtonState extends State<_ClearSelectionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 26,
          height: 26,
          child: Center(
            // 点击时缩一下再弹回：清除是「把这次选择丢掉」，给一个明确的
            // 物理反馈，避免点下去像没反应。
            child: AnimatedScale(
              scale: _pressed ? 0.82 : 1,
              duration: AppMotion.duration(context, AppDurations.press),
              curve: Curves.easeOutCubic,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: widget.foreground.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(Icons.close_rounded, size: 13, color: widget.foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 胶囊里的「可选日期角标 + 时间」。
class _SelectionLabel extends StatelessWidget {
  const _SelectionLabel({required this.label, required this.foreground});

  final TimelineSelectionLabel label;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxTextWidth = math.min(150.0, MediaQuery.sizeOf(context).width * 0.40);

    return AnimatedSwitcher(
      duration: AppMotion.duration(context, _DiaryRecordFabState._labelSwapDuration),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      // 和外面那层一样：旧文字绝对定位、不撑宽度。区间缩短成单点时间时，
      // 胶囊立刻开始回缩，旧文字在收缩边缘后面淡出，而不是先保持最宽再跳一下。
      layoutBuilder: (current, previous) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 16),
        child: Stack(
          alignment: Alignment.centerLeft,
          clipBehavior: Clip.none,
          children: [
            for (final child in previous) Positioned(left: 0, top: 0, bottom: 0, child: child),
            ?current,
          ],
        ),
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0.12, 0), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      // key 带上完整文案：区间被拖长时也能重播一次换字动画
      child: Row(
        key: ValueKey('${label.dayBadge}|${label.time}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label.hasBadge) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: foreground.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label.dayBadge!,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ),
            const SizedBox(width: 5),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTextWidth),
            child: Text(
              label.time,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: foreground,
                // 等宽数字：区间被拖长时数字不会左右跳动
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

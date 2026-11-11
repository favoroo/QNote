import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/utils/timeline_selection_label.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';

/// 时间线左下角的记录按钮。
///
/// 空闲时是与右侧「日记 / 智能提取」对称的 44 圆钮；时间线上选了时间后横向
/// 展开成胶囊，把「这次要记在哪一刻」直接摆在按钮上 —— 时间不再是输入栏里的
/// 一个字段，而是记录动作的入口状态本身。
///
/// morph 用 `AnimatedSize` + `AnimatedSwitcher`：宽度靠前者从 44 缓动到自然宽，
/// 文字与角标靠后者淡入；外层默认 `clipBehavior: Clip.hardEdge`，于是胶囊长出来
/// 的过程天然是「从圆边上把时间抹出来」的擦除观感，不需要额外做遮罩。
class DiaryRecordFab extends ConsumerStatefulWidget {
  const DiaryRecordFab({super.key, required this.onTap});

  /// 点胶囊主体（或空闲态的圆钮）时打开记录面板。
  final VoidCallback onTap;

  @override
  ConsumerState<DiaryRecordFab> createState() => _DiaryRecordFabState();
}

class _DiaryRecordFabState extends ConsumerState<DiaryRecordFab>
    with SingleTickerProviderStateMixin {
  /// 胶囊 morph 时长。比常规 300ms 略长，让宽度变化看起来是「长出来」的。
  static const Duration _morphDuration = Duration(milliseconds: 380);
  static const Duration _labelSwapDuration = Duration(milliseconds: 220);

  /// 右侧「时间 + ×」的入场时长。
  ///
  /// 要比 [_morphDuration] 短一些但不能太短：太快（如 200ms）内容已经亮完、
  /// 容器还在变宽，看着像文字先闪出来再被撑开；贴着宽度增长的后半段收尾，
  /// 才是「从加号往右拉开」的连续感。
  static const Duration _symbolSwapDuration = Duration(milliseconds: 280);
  static const Duration _pressDuration = Duration(milliseconds: 110);

  bool _pressed = false;

  /// 选中瞬间的一次轻微回弹，避免点击后按钮「毫无反应」。
  late final AnimationController _bounceController;
  late final Animation<double> _bounce;

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _bounce = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.08).chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.08, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 60,
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
    final hasDraft = ref.watch(
      diaryComposeDraftProvider.select((draft) => !draft.isEmpty),
    );
    final hasSelection = selection != null;

    // 从无到有的那一次转换才回弹：改时间、改区间都不该反复弹。
    ref.listen<TimelineTimeSelectEvent?>(diaryInputTimeProvider, (previous, next) {
      if (previous == null && next != null) {
        if (!MediaQuery.disableAnimationsOf(context)) {
          _bounceController.forward(from: 0);
        }
        HapticFeedback.selectionClick();
      }
    });

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
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
      builder: (context, child) => Transform.scale(
        scale: reduceMotion ? 1 : _bounce.value,
        child: child,
      ),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1,
        duration: reduceMotion ? Duration.zero : _pressDuration,
        curve: Curves.easeOut,
        child: AnimatedSize(
          duration: reduceMotion ? Duration.zero : _morphDuration,
          curve: Curves.easeOutQuint,
          alignment: Alignment.centerLeft,
          child: _buildBody(theme, label, hasSelection: hasSelection, hasDraft: hasDraft),
        ),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    TimelineSelectionLabel? label, {
    required bool hasSelection,
    required bool hasDraft,
  }) {
    final scheme = theme.colorScheme;
    // 选中态用 primaryContainer 而不是 primary：它是过渡状态，不该和右侧实心的
    // 智能提取按钮抢同样的视觉重量。
    final background = hasSelection ? scheme.primaryContainer : scheme.surface;
    final foreground = hasSelection ? scheme.primary : scheme.onSurfaceVariant;

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 颜色/描边也在动：只靠宽度 morph 的话，填充色会在第一帧硬切，
          // 看起来像「突然换了个按钮」。AnimatedContainer 让底色与描边跟着淡进去。
          AnimatedContainer(
            duration: _labelSwapDuration,
            curve: Curves.easeOut,
            height: 44,
            // 空闲态 12+20+12 正好 44 直径，选中态沿用同一内边距，
            // 于是 morph 期间不需要再动画 padding（少一层会不同步的动画）。
            constraints: const BoxConstraints(minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(22),
              border: hasSelection
                  ? null
                  : Border.all(color: scheme.outlineVariant, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: hasSelection ? 0.10 : 0.06),
                  blurRadius: hasSelection ? 8 : 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            // 加号永远钉在最左侧不动，时间和 × 依次从它右边长出来 ——
            // 配合 AnimatedSize 的 centerLeft 对齐与裁剪，观感就是「从加号向右侧
            // 拉开一条」，而不是整块按钮变宽再重排内容。
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 20, color: foreground),
                // 右侧整组（时间 + ×）作为一个单位淡入并自左向右推开，
                // 让「展开」这件事有方向感：不是凭空出现，而是从加号里被拉出来。
                AnimatedSwitcher(
                  duration: _symbolSwapDuration,
                  // 稍晚于容器起步：容器先撑开一点空间，内容再填进去，
                  // 反过来（内容先亮、容器后宽）会看到文字被挤着跳动。
                  switchInCurve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
                  switchOutCurve: Curves.easeIn,
                  // 默认 layoutBuilder 是居中叠放，收/展时内容会左右跳一下；
                  // 靠左对齐才能让「右侧元素贴着加号长出来」这件事连成一条。
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, ?current],
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
                            _SelectionLabel(label: label, foreground: foreground),
                            const SizedBox(width: 2),
                            _ClearSelectionButton(
                              foreground: foreground,
                              onTap: _clearSelection,
                            ),
                          ],
                        ),
                ),
              ],
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
                  color: hasSelection ? scheme.primary : scheme.tertiary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _clearSelection() {
    HapticFeedback.selectionClick();
    ref.read(diaryInputTimeProvider.notifier).state = null;
  }

  DateTime _todayOf(DateTime now) => DateTime(now.year, now.month, now.day);
}

/// 胶囊里的清除钮：把「记哪一刻」和「取消这次时间选择」分成两个可点区域，
/// 点时间开面板、点 × 取消选择，互不误触。
class _ClearSelectionButton extends StatelessWidget {
  const _ClearSelectionButton({
    required this.foreground,
    required this.onTap,
  });

  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 26,
        height: 26,
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: foreground.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.close_rounded, size: 13, color: foreground),
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
      duration: _DiaryRecordFabState._labelSwapDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.12, 0),
            end: Offset.zero,
          ).animate(animation),
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


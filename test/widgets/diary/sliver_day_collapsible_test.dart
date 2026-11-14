import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/diary/sliver_day_collapsible.dart';

void main() {
  Widget buildTimelineHarness({
    required ScrollController scrollController,
    required Animation<double>? sizeAnimation,
    required Animation<double>? opacityAnimation,
    required bool isExpanding,
    required Set<int> builtIndices,
    VoidCallback? onSlotTap,
    int itemCount = 48,
    double itemHeight = 48.0,
    double leadingHeight = 80.0,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(400, 600)),
        child: Scaffold(
          body: CustomScrollView(
            controller: scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(200),
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(key: const ValueKey('leading_divider'), height: leadingHeight),
              ),
              SliverDayCollapsible(
                sizeAnimation: sizeAnimation,
                opacityAnimation: opacityAnimation,
                isExpanding: isExpanding,
                sliver: SliverList.builder(
                  itemCount: itemCount,
                  addAutomaticKeepAlives: false,
                  itemBuilder: (context, index) {
                    builtIndices.add(index);
                    final box = SizedBox(key: ValueKey('slot_$index'), height: itemHeight, child: Text('Slot $index'));
                    if (onSlotTap == null) {
                      return box;
                    }
                    return GestureDetector(onTap: onSlotTap, behavior: HitTestBehavior.opaque, child: box);
                  },
                ),
              ),
              SliverFixedExtentList.builder(
                itemExtent: 80.0,
                itemCount: 10,
                itemBuilder: (context, index) =>
                    SizedBox(key: ValueKey('trailing_$index'), height: 80.0, child: Text('Trailing $index')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  group('SliverDayCollapsible', () {
    testWidgets('稳态展开直通子 Sliver 并保持按需懒加载', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final builtIndices = <int>{};

      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: null,
          opacityAnimation: null,
          isExpanding: true,
          builtIndices: builtIndices,
        ),
      );

      // 首帧仅构建视口 + 缓存区可见范围，不应一次性构建第 47 个槽位
      expect(builtIndices, contains(0));
      expect(builtIndices, isNot(contains(47)));

      // 向下滚到当天末尾时才会按需构建最后一个槽位
      scrollController.jumpTo(80.0 + 48 * 48.0 - 600.0);
      await tester.pump();
      expect(builtIndices, contains(47));
    });

    testWidgets('展开过渡仅随幕布前沿懒构建可见节点，收尾切换稳态不跳位', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final builtIndices = <int>{};
      final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), value: 0.0);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: controller,
          opacityAnimation: controller,
          isExpanding: true,
          builtIndices: builtIndices,
        ),
      );

      // 展开前第 0 帧：高度为 0，连首个槽位都无需提前构建
      expect(builtIndices, isEmpty);
      expect(tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy, 80.0);

      // 展开到 25%：幕布只打开约百余像素，仅构建前几个槽位，远低于整天 48 个
      controller.value = 0.25;
      await tester.pump();
      final midTrailingTop = tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy;
      expect(midTrailingTop, greaterThan(80.0));
      expect(midTrailingTop, lessThan(400.0));
      expect(builtIndices.length, lessThan(12));
      expect(builtIndices, isNot(contains(47)));

      // 动画走到 1.0 并卸载动画切回稳态直通：顶部已可见槽位位置保持不变
      controller.value = 1.0;
      await tester.pump();
      final animatedSlot0Top = tester.getTopLeft(find.byKey(const ValueKey('slot_0'))).dy;

      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: null,
          opacityAnimation: null,
          isExpanding: true,
          builtIndices: builtIndices,
        ),
      );
      expect(tester.getTopLeft(find.byKey(const ValueKey('slot_0'))).dy, animatedSlot0Top);
    });

    testWidgets('收起过渡应用透明层并平滑将后续内容推回分隔栏下方', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final builtIndices = <int>{};
      final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 150), value: 1.0);
      addTearDown(controller.dispose);

      // 先处于稳态展开
      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: null,
          opacityAnimation: null,
          isExpanding: true,
          builtIndices: builtIndices,
        ),
      );
      expect(find.byKey(const ValueKey('trailing_0')), findsNothing);

      // 触发收起动画：首帧 factor=1.0 时正文刚好铺满剩余视口
      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: controller,
          opacityAnimation: controller,
          isExpanding: false,
          builtIndices: builtIndices,
        ),
      );

      // 收起进行到一半：后续分隔栏平滑滑入视口，且存在 OpacityLayer 淡出
      controller.value = 0.5;
      await tester.pump();
      final halfTop = tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy;
      expect(halfTop, greaterThan(80.0));
      expect(halfTop, lessThan(500.0));
      final opacityLayers = tester.layers.whereType<OpacityLayer>().toList();
      expect(opacityLayers.any((layer) => layer.alpha != null && layer.alpha! < 255), isTrue);

      // 收起完成：后续内容紧贴分隔栏底部 80.0
      controller.value = 0.0;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy, 80.0);
    });

    testWidgets('动画途中点击反向时高度连续不跳变', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final builtIndices = <int>{};
      final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), value: 0.0);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: controller,
          opacityAnimation: controller,
          isExpanding: true,
          builtIndices: builtIndices,
        ),
      );

      controller.value = 0.5;
      await tester.pump();
      final midTopBeforeReverse = tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy;

      // 保持同一进度 0.5 切换为收起方向，位置应保持连续
      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: controller,
          opacityAnimation: controller,
          isExpanding: false,
          builtIndices: builtIndices,
        ),
      );
      final midTopAfterReverse = tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy;
      expect(midTopAfterReverse, closeTo(midTopBeforeReverse, 0.01));

      controller.value = 0.25;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy, lessThan(midTopAfterReverse));
    });

    testWidgets('展开途中向下滑过受限区间时自动补偿 scrollOffset 保持下方内容视觉静止', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final builtIndices = <int>{};
      final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), value: 1.0);
      addTearDown(controller.dispose);

      // 使用较短的 20 槽 * 48px = 960px，确保受限首屏 520px 后仍能向下滑出
      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: controller,
          opacityAnimation: controller,
          isExpanding: true,
          builtIndices: builtIndices,
          itemCount: 20,
        ),
      );

      // 当前处于受限展开末帧：leading(80) + cap(520) = 600，随后有 10*80=800 的后续内容（总长 1400）
      // 向下滑动 650px（越过 600px 分界），trailing_0 原本在 [-50, +30]（部分入镜）
      scrollController.jumpTo(650.0);
      await tester.pump();

      // 验证触发 scrollOffsetCorrection 解除 520px 上限并展到完整 960px 后，
      // trailing_0 依然精准停在屏幕预期的 -50px，不因上方正文高度补齐而突跳
      final trailingTop = tester.getTopLeft(find.byKey(const ValueKey('trailing_0'))).dy;
      expect(trailingTop, closeTo(-50.0, 1.0));
      expect(scrollController.offset, closeTo(80.0 + 20 * 48.0 + 50.0, 1.0));
    });

    testWidgets('收起时裁剪范围外的子节点不触发点击事件', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final builtIndices = <int>{};
      var tapped = false;
      final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 150), value: 1.0);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTimelineHarness(
          scrollController: scrollController,
          sizeAnimation: controller,
          opacityAnimation: controller,
          isExpanding: false,
          builtIndices: builtIndices,
          onSlotTap: () => tapped = true,
        ),
      );

      // 收起至极小值（仅约 52px，slot_2 在 80 + 96 处已完全超出裁剪范围）
      controller.value = 0.1;
      await tester.pump();
      await tester.tapAt(const Offset(200, 80.0 + 96.0 + 24.0));
      expect(tapped, isFalse);

      // 收起到 0 时，连首个槽位都不可点击
      controller.value = 0.0;
      await tester.pump();
      await tester.tapAt(const Offset(200, 80.0 + 24.0));
      expect(tapped, isFalse);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('LoadingRing 自转态', () {
    testWidgets('未传 progress 时用 RotationTransition 自转', (tester) async {
      await tester.pumpWidget(_wrap(const LoadingRing(size: 32)));
      expect(find.byKey(const ValueKey('loading_ring_spin')), findsOneWidget);
      // 自转需要持续帧回调，pump 一次后动画应处于运行态
      await tester.pump(const Duration(milliseconds: 100));
      final rotation = tester.widget<RotationTransition>(find.byKey(const ValueKey('loading_ring_spin')));
      expect(rotation.turns.value, greaterThan(0));
    });
  });

  group('LoadingRing 确定进度', () {
    testWidgets('传入 progress 时不再自转，改用进度绘制', (tester) async {
      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: 0.5)));
      expect(find.byKey(const ValueKey('loading_ring_spin')), findsNothing);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('progress 0 与 1 都能正常渲染（边界不抛异常）', (tester) async {
      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: 0)));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: 1)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('超出 0~1 的进度值被夹取，不会画出整圈以外的弧', (tester) async {
      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: 2.5)));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: -1)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('从自转切到确定进度会停掉旋转动画', (tester) async {
      await tester.pumpWidget(_wrap(const LoadingRing(size: 32)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('loading_ring_spin')), findsOneWidget);

      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: 0.3)));
      await tester.pump();
      expect(find.byKey(const ValueKey('loading_ring_spin')), findsNothing);
    });

    testWidgets('从确定进度切回自转会恢复旋转', (tester) async {
      await tester.pumpWidget(_wrap(const LoadingRing(size: 32, progress: 0.3)));
      await tester.pump();

      await tester.pumpWidget(_wrap(const LoadingRing(size: 32)));
      await tester.pump();
      expect(find.byKey(const ValueKey('loading_ring_spin')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      final rotation = tester.widget<RotationTransition>(find.byKey(const ValueKey('loading_ring_spin')));
      expect(rotation.turns.value, greaterThan(0));
    });

    testWidgets('系统减弱动效时自转停止，进度弧仍按值绘制', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: Center(child: LoadingRing(size: 32))),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final rotation = tester.widget<RotationTransition>(find.byKey(const ValueKey('loading_ring_spin')));
      expect(rotation.turns.value, 0);

      // 减弱动效下确定进度依然要可见：它是静态信息，不是装饰动画
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: Center(child: LoadingRing(size: 32, progress: 0.6))),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';

void main() {
  group('LoadingRing Widget Tests', () {
    testWidgets('renders LoadingRing with default properties', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: LoadingRing(),
            ),
          ),
        ),
      );

      expect(find.byType(LoadingRing), findsOneWidget);
      final rotationFinder = find.descendant(
        of: find.byType(LoadingRing),
        matching: find.byType(RotationTransition),
      );
      expect(rotationFinder, findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);

      // 验证平滑循环转动不报错
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 1000));
    });

    testWidgets('respects custom size and color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: LoadingRing(
                size: 36,
                strokeWidth: 2.5,
                color: Colors.red,
              ),
            ),
          ),
        ),
      );

      final customPaintFinder = find.descendant(
        of: find.byType(LoadingRing),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
      final customPaint = tester.widget<CustomPaint>(customPaintFinder);
      expect(customPaint.size, const Size(36, 36));
    });
  });

  group('MorphingInfinity Widget Tests', () {
    testWidgets('renders MorphingInfinity with default properties', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: MorphingInfinity(),
            ),
          ),
        ),
      );

      expect(find.byType(MorphingInfinity), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);

      // 推进 5 个动画阶段，验证插值计算无异常
      // 0s -> circleA
      await tester.pump(const Duration(milliseconds: 500));
      // 1.25s -> infinity
      await tester.pump(const Duration(milliseconds: 1000));
      // 2.5s -> circleB
      await tester.pump(const Duration(milliseconds: 1250));
      // 3.75s -> infinity
      await tester.pump(const Duration(milliseconds: 1250));
      // 5.0s -> circleA
      await tester.pump(const Duration(milliseconds: 1250));
    });

    testWidgets('respects custom size and strokeWidth', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: MorphingInfinity(
                size: 48,
                strokeWidth: 2.0,
                color: Colors.blue,
              ),
            ),
          ),
        ),
      );

      final customPaintFinder = find.descendant(
        of: find.byType(MorphingInfinity),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
      final customPaint = tester.widget<CustomPaint>(customPaintFinder);
      expect(customPaint.size, const Size(48, 48));
    });
  });
}

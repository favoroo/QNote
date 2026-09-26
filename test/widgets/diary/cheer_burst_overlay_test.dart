import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/cheer_burst.dart';
import 'package:qnote_flutter/widgets/diary/cheer_burst_overlay.dart';

/// 粒子层内部 painter 是私有的，但字段是公开名：走 dynamic 派发读出来断言，
/// 比为了测试把内部实现暴露成公共 API 更划算。
Finder get _burstCanvas => find.descendant(
      of: find.byType(CheerBurstOverlay),
      matching: find.byType(CustomPaint),
    );

// Scaffold 自己树里就挂着 CustomPaint，任何 byType(CustomPaint) 都必须限定在粒子层内。
dynamic _painterOf(WidgetTester tester) =>
    (tester.widget<CustomPaint>(_burstCanvas).painter as dynamic);

Widget _host(
  Widget child, {
  bool disableAnimations = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Stack(
          children: [const SizedBox.expand(), Positioned.fill(child: child)],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final anchor = ValueNotifier<Offset?>(const Offset(120, 600));

  group('CheerBurstOverlay', () {
    testWidgets('满档按档位颗数画出粒子', (tester) async {
      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.full, seed: 5, anchor: anchor),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(_burstCanvas, findsOneWidget);
      expect(_painterOf(tester).particles.length, CheerLevel.full.particleCount);
    });

    testWidgets('破纪录粒子更少，普通记录整层不挂', (tester) async {
      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.record, seed: 5, anchor: anchor),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(_painterOf(tester).particles.length, CheerLevel.record.particleCount);

      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.plain, seed: 5, anchor: anchor),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 普通记录不放粒子，也不该留一块每帧脏重绘的透明画布。
      expect(_burstCanvas, findsNothing);
    });

    testWidgets('爆点取圆环上报的锚点，并换算到本层坐标', (tester) async {
      // 粒子层铺满 body，本层原点和全局原点重合，换算后应当原值落地。
      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.full, seed: 3, anchor: anchor),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final origin = _painterOf(tester).origin as Offset;
      expect(origin, const Offset(120, 600));
    });

    testWidgets('圆环还没上报时按左下角回退，不画在屏幕外', (tester) async {
      final pending = ValueNotifier<Offset?>(null);
      addTearDown(pending.dispose);

      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.full, seed: 3, anchor: pending),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final origin = _painterOf(tester).origin as Offset?;
      expect(origin, isNull);
      // 回退点由 painter 在 paint 时按尺寸算，这里只确认整层照常出图。
      expect(_burstCanvas, findsOneWidget);
    });

    testWidgets('散尽后回调一次并停掉 ticker，不留在树里空转', (tester) async {
      var finished = 0;
      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(
            level: CheerLevel.full,
            seed: 9,
            anchor: anchor,
            onFinished: () => finished++,
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 1300));
      expect(finished, 1);

      // 再推进一段，不该重复回调。
      await tester.pump(const Duration(milliseconds: 600));
      expect(finished, 1);
      expect(_painterOf(tester).progress.value, 1.0);
    });

    testWidgets('系统要求减少动效时整层不出图', (tester) async {
      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.full, seed: 5, anchor: anchor),
          disableAnimations: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(_burstCanvas, findsNothing);
    });

    testWidgets('窄屏与卸载都不抛异常', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          CheerBurstOverlay(level: CheerLevel.full, seed: 2, anchor: anchor),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  });
}

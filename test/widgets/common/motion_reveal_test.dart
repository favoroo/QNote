import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/common/motion_reveal.dart';

class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe({super.key});

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => count++),
      child: Text('count:$count'),
    );
  }
}

void main() {
  Widget wrap(Widget child, {bool disableAnimations = false}) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  group('MotionReveal', () {
    testWidgets('triggerKey 变化时保留子树 State 并触发淡入上移', (tester) async {
      Object key = 'tab_a';

      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  TextButton(onPressed: () => setState(() => key = 'tab_b'), child: const Text('switch')),
                  MotionReveal(
                    triggerKey: key,
                    beginOpacity: 0.4,
                    child: const _StatefulProbe(key: ValueKey('probe')),
                  ),
                ],
              );
            },
          ),
        ),
      );

      // 点击探针使其局部状态变化
      await tester.tap(find.text('count:0'));
      await tester.pump();
      expect(find.text('count:1'), findsOneWidget);

      final initialState = tester.state<_StatefulProbeState>(find.byType(_StatefulProbe));

      // 切换 triggerKey
      await tester.tap(find.text('switch'));
      await tester.pump();

      // 动画起点不透明度应接近 beginOpacity，且同一份 State 被复用
      final fadeDuring = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(MotionReveal), matching: find.byType(FadeTransition)),
      );
      expect(fadeDuring.opacity.value, closeTo(0.4, 0.05));
      expect(identical(tester.state<_StatefulProbeState>(find.byType(_StatefulProbe)), initialState), isTrue);
      expect(find.text('count:1'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(fadeDuring.opacity.value, closeTo(1.0, 0.001));
    });

    testWidgets('减弱动态效果开启时不产生滞后半透明态', (tester) async {
      Object key = 'a';

      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  TextButton(onPressed: () => setState(() => key = 'b'), child: const Text('switch')),
                  MotionReveal(triggerKey: key, beginOpacity: 0.3, child: const Text('body')),
                ],
              );
            },
          ),
          disableAnimations: true,
        ),
      );

      await tester.tap(find.text('switch'));
      await tester.pump();

      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(MotionReveal), matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, closeTo(1.0, 0.001));
    });
  });

  group('MotionFadeSlideEntrance', () {
    testWidgets('挂载时使用 FadeTransition 并在落定后卸除位移 Transform', (tester) async {
      await tester.pumpWidget(wrap(const MotionFadeSlideEntrance(child: Text('chip_item'))));

      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(MotionFadeSlideEntrance), matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, closeTo(0.0, 0.05));
      expect(find.descendant(of: find.byType(MotionFadeSlideEntrance), matching: find.byType(Opacity)), findsNothing);

      await tester.pumpAndSettle();
      expect(fade.opacity.value, closeTo(1.0, 0.001));
      expect(find.descendant(of: find.byType(MotionFadeSlideEntrance), matching: find.byType(Transform)), findsNothing);
    });

    testWidgets('减弱动态效果开启时首帧即处于稳态', (tester) async {
      await tester.pumpWidget(wrap(const MotionFadeSlideEntrance(child: Text('reduced')), disableAnimations: true));

      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(MotionFadeSlideEntrance), matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, closeTo(1.0, 0.001));
      expect(find.descendant(of: find.byType(MotionFadeSlideEntrance), matching: find.byType(Transform)), findsNothing);
    });
  });
}

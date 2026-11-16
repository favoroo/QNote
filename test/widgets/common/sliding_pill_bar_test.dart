import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/common/sliding_pill_bar.dart';

void main() {
  Widget wrap(Widget child, {bool disableAnimations = false}) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('SlidingPillBar', () {
    testWidgets('点击未选中项触发回调，点击已选中项不重复触发，并同步语义选中态', (tester) async {
      int selected = 0;
      final taps = <int>[];

      await tester.pumpWidget(
        wrap(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StatefulBuilder(
              builder: (context, setState) {
                return SlidingPillBar(
                  labels: const ['极简', '默认', '大字'],
                  selectedIndex: selected,
                  onSelected: (index) {
                    taps.add(index);
                    setState(() => selected = index);
                  },
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('极简'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('大字'), findsOneWidget);

      await tester.tap(find.text('极简'));
      await tester.pumpAndSettle();
      expect(taps, isEmpty);

      await tester.tap(find.text('大字'));
      await tester.pumpAndSettle();
      expect(taps, [2]);
      expect(selected, 2);

      await tester.tap(find.text('默认'));
      await tester.pumpAndSettle();
      expect(taps, [2, 1]);
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('支持 fixedSegmentWidth 在无界宽度行容器内布局与减弱动态效果切换', (tester) async {
      int selected = 0;

      await tester.pumpWidget(
        wrap(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatefulBuilder(
                builder: (context, setState) {
                  return SlidingPillBar(
                    labels: const ['支出', '收入'],
                    selectedIndex: selected,
                    fixedSegmentWidth: 64,
                    onSelected: (index) => setState(() => selected = index),
                  );
                },
              ),
            ],
          ),
          disableAnimations: true,
        ),
      );

      await tester.tap(find.text('收入'));
      await tester.pump();
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空标签列表安全折叠不报错', (tester) async {
      await tester.pumpWidget(wrap(SlidingPillBar(labels: const [], selectedIndex: 0, onSelected: (_) {})));

      expect(find.byType(SizedBox), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

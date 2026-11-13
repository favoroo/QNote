import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/time_range_selector.dart';

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

  testWidgets('渲染周月年三个选项，点击未选中项触发回调，点击已选中项不重复触发', (tester) async {
    TimeRangeType current = TimeRangeType.week;
    final changes = <TimeRangeType>[];

    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            return TimeRangeSelector(
              selectedRange: current,
              onRangeChanged: (next) {
                changes.add(next);
                setState(() => current = next);
              },
            );
          },
        ),
      ),
    );

    expect(find.text('周'), findsOneWidget);
    expect(find.text('月'), findsOneWidget);
    expect(find.text('年'), findsOneWidget);

    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);

    await tester.tap(find.text('月'));
    await tester.pumpAndSettle();
    expect(changes, [TimeRangeType.month]);

    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();
    expect(changes, [TimeRangeType.month, TimeRangeType.year]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减弱动态效果下切换时间范围正常落位', (tester) async {
    TimeRangeType current = TimeRangeType.week;

    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            return TimeRangeSelector(selectedRange: current, onRangeChanged: (next) => setState(() => current = next));
          },
        ),
        disableAnimations: true,
      ),
    );

    await tester.tap(find.text('年'));
    await tester.pump();
    expect(current, TimeRangeType.year);
    expect(tester.takeException(), isNull);
  });
}

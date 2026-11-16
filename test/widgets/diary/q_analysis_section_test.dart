import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/diary/q_analysis_section.dart';

void main() {
  testWidgets('小Q分析默认收起，点击标题展开内容，再次点击收起', (tester) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return QAnalysisSection(
                lines: const ['图：米饭约250kcal，合计约620kcal', '整体热量偏高'],
                expanded: expanded,
                onExpandedChanged: (value) => setState(() => expanded = value),
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('小Q分析'), findsOneWidget);
    expect(find.text('图：米饭约250kcal，合计约620kcal'), findsNothing);

    await tester.tap(find.text('小Q分析'));
    await tester.pumpAndSettle();
    expect(find.text('图：米饭约250kcal，合计约620kcal'), findsOneWidget);
    expect(find.text('整体热量偏高'), findsOneWidget);

    await tester.tap(find.text('小Q分析'));
    await tester.pumpAndSettle();
    expect(find.text('图：米饭约250kcal，合计约620kcal'), findsNothing);
  });

  testWidgets('编辑器可清除分析', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return QAnalysisSection(
                lines: const ['图：步数 5047 步'],
                expanded: true,
                onExpandedChanged: (_) {},
                onClear: () => setState(() => cleared = true),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('清除分析'));
    await tester.pump();
    expect(cleared, isTrue);
  });
}

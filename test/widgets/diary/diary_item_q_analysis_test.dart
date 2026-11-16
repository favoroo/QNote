import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';
import 'package:qnote_flutter/widgets/diary/q_analysis_section.dart';

DiaryRecord _record({String content = '', String aiAnalysis = ''}) {
  final now = DateTime(2026, 11, 16, 12, 0);
  return DiaryRecord(
    id: 'q-analysis-1',
    title: '午饭',
    time: now,
    content: content,
    aiAnalysis: aiAnalysis,
    createdAt: now,
    updatedAt: now,
  );
}

Widget _wrap(DiaryRecord record, {VoidCallback? onAiExtract}) {
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: Scaffold(
      body: SizedBox(
        width: 412,
        child: ListView(
          children: [DiaryItem(record: record, onAiExtract: onAiExtract)],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('旧数据「图：」分析从正文剥离并默认折叠', (tester) async {
    await tester.pumpWidget(_wrap(_record(content: '午饭吃了米饭和青菜\n图：米饭约250kcal，青菜约30kcal')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('小Q分析'), findsOneWidget);
    // 正文第一行仍展示，AI 图片解读行收进折叠区
    expect(find.text('午饭吃了米饭和青菜'), findsOneWidget);
    expect(find.text('图：米饭约250kcal，青菜约30kcal'), findsNothing);

    await tester.tap(find.text('小Q分析'));
    await tester.pumpAndSettle();
    expect(find.text('图：米饭约250kcal，青菜约30kcal'), findsOneWidget);
  });

  testWidgets('显式 aiAnalysis 独立于正文展示', (tester) async {
    await tester.pumpWidget(_wrap(_record(content: '午饭吃了米饭和青菜', aiAnalysis: '整餐热量约 520kcal，荤素比例均衡。')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('小Q分析'), findsOneWidget);
    expect(find.text('整餐热量约 520kcal，荤素比例均衡。'), findsNothing);

    await tester.tap(find.text('小Q分析'));
    await tester.pumpAndSettle();
    expect(find.text('整餐热量约 520kcal，荤素比例均衡。'), findsOneWidget);
  });

  testWidgets('小Q分析条右侧给提取钮让位，不与按钮重叠', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _record(content: '午饭吃了米饭和青菜', aiAnalysis: '整餐热量约 520kcal，荤素比例均衡。'),
        onAiExtract: () {},
      ),
    );
    await tester.pumpAndSettle();

    final sectionRect = tester.getRect(find.byType(QAnalysisSection));
    // 提取钮的可视圆钮 32、触控盒 40，图标居中；左缘 = 图标中心 - 20
    final idleIconRect = tester.getRect(find.byKey(const ValueKey('idle')));
    final buttonLeft = idleIconRect.center.dx - 20;
    expect(sectionRect.right, lessThanOrEqualTo(buttonLeft));
  });
}

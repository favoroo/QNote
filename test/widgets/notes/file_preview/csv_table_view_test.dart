import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/widgets/notes/file_preview/csv_table_view.dart';

const String _source = '''姓名,部门,工号,本月工时,上次更新,备注,状态
张伟,产品设计部,EMP-10023,168.5,2026-11-03 09:12,负责移动端表格预览重构，需要同时兼顾窄屏可读性与 Web 端的信息密度。,正常
李娜,数据分析,EMP-10051,142,2026-11-02 18:40,,正常
王强,客户成功,EMP-10077,176.25,2026-11-04 08:05,本周出差，备注为空的那一列保持空值也能正常显示。,请假
''';

void main() {
  testWidgets('表格默认紧凑、可看单元格全文并切换卡片视图', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(const Color(0xFF005BCB)),
        home: const Scaffold(body: CsvTableView(source: _source)),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('表格'), findsOneWidget);
    expect(find.text('卡片'), findsOneWidget);
    expect(find.text('换行'), findsOneWidget);
    expect(find.text('张伟'), findsOneWidget);

    // 点单元格打开全文详情
    await tester.tap(find.text('张伟'));
    await tester.pumpAndSettle();
    expect(find.text('复制内容'), findsOneWidget);
    expect(find.textContaining('单元格内容'), findsOneWidget);
    // 底部详情是独立路由，直接 pop 关闭（没有 AppBar 返回键）
    Navigator.of(tester.element(find.text('复制内容'))).pop();
    await tester.pumpAndSettle();

    // 换行开关在表格模式下可用
    await tester.tap(find.text('换行'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 卡片视图自带换行，换行开关应隐藏
    await tester.tap(find.text('卡片'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('换行'), findsNothing);
    expect(find.textContaining('点卡片看全文'), findsOneWidget);
    expect(find.text('张伟'), findsOneWidget);
  });

  testWidgets('单元格可在详情弹窗内直接编辑并写回源码', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(const Color(0xFF005BCB)),
        home: Scaffold(
          body: CsvTableView(source: _source, onSourceChanged: (source) => saved = source),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点单元格打开可编辑详情
    await tester.tap(find.text('张伟'));
    await tester.pumpAndSettle();
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.byKey(const Key('csv-cell-edit-field')), findsOneWidget);

    // 修改内容并保存
    await tester.enterText(find.byKey(const Key('csv-cell-edit-field')), '张伟明');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    // 弹窗关闭，宿主收到重序列化后的完整源码：目标单元格已改、其余行原样
    expect(find.text('保存修改'), findsNothing);
    expect(saved, isNotNull);
    final lines = saved!.split('\n');
    expect(lines.length, 4, reason: '应与原表行数一致（尾随换行在序列化时归一）');
    expect(lines[0], '姓名,部门,工号,本月工时,上次更新,备注,状态');
    expect(lines[1], startsWith('张伟明,产品设计部,EMP-10023,168.5'));
    expect(lines[2], startsWith('李娜,数据分析'));
    expect(saved, isNot(contains('张伟,')));
  });
}

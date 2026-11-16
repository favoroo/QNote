import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/utils/mermaid_gantt.dart';
import 'package:qnote_flutter/widgets/notes/file_preview/gantt_chart_view.dart';

const String _source = '''
gantt
    title 发布计划
    dateFormat YYYY-MM-DD
    section 开发
    接口联调 :done, a1, 2026-11-10, 2d
    页面开发 :active, a2, after a1, 3d
    section 发布
    灰度 :a3, after a2, 1d
    全量 :milestone, m1, after a3, 0d
''';

void main() {
  testWidgets('窄屏渲染不溢出且缩放控件齐全', (tester) async {
    final plan = parseMermaidGantt(_source);
    expect(plan, isNotNull);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(const Color(0xFF005BCB)),
        home: Scaffold(body: GanttChartView(plan: plan!)),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('日'), findsOneWidget);
    expect(find.text('周'), findsOneWidget);
    expect(find.text('月'), findsOneWidget);
    expect(find.text('接口联调'), findsOneWidget);
    expect(find.text('全量'), findsOneWidget);
  });

  testWidgets('切换月视图后仍不溢出', (tester) async {
    final plan = parseMermaidGantt(_source);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(const Color(0xFF005BCB)),
        home: Scaffold(body: GanttChartView(plan: plan!)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('月'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('发布计划'), findsOneWidget);
  });
}

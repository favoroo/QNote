import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/statistics/diet_stats.dart';
import 'package:qnote_flutter/widgets/statistics/finance_stats.dart';
import 'package:qnote_flutter/widgets/statistics/stat_record_detail_sheet.dart';

DiaryRecord _record({
  required String id,
  required String displayTag,
  required String content,
  required List<TagEntry> tagEntries,
  DateTime? time,
}) {
  final t = time ?? DateTime(2026, 11, 13, 12);
  return DiaryRecord(
    id: id,
    title: 'test',
    time: t,
    tags: [displayTag],
    displayTag: displayTag,
    content: content,
    tagEntries: tagEntries,
    createdAt: t,
    updatedAt: t,
  );
}

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  final start = DateTime(2026, 11, 1);
  final end = DateTime(2026, 11, 30);

  testWidgets('记账 tab 紧凑重排后不溢出、关键信息可见', (tester) async {
    final records = [
      _record(
        id: 'f1',
        displayTag: '记账',
        content: '午饭',
        tagEntries: [
          TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '饮食', 'amount': 25}),
        ],
      ),
      _record(
        id: 'f2',
        displayTag: '记账',
        content: '工资',
        tagEntries: [
          TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'income', 'incomeType': '工资', 'amount': 8000}),
        ],
      ),
    ];
    final stats = calculateFinanceStats(records, start, end);

    await tester.pumpWidget(
      _wrap(FinanceStatsWidget(stats: stats, records: records, startDate: start, endDate: end, onViewAll: () {})),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('结余'), findsOneWidget);
    expect(find.text('分类构成'), findsOneWidget);
    expect(find.text('明细'), findsOneWidget);
    expect(find.text('查看全部'), findsOneWidget);
  });

  testWidgets('饮食 tab 紧凑重排后不溢出、关键信息可见', (tester) async {
    final records = [
      _record(
        id: 'd1',
        displayTag: '饮食',
        content: '午饭外卖',
        tagEntries: [
          TagEntry(id: 'diet', name: '饮食', fields: {'type': '外卖', 'rating': '一般'}),
        ],
      ),
      _record(
        id: 'd2',
        displayTag: '饮食',
        content: '水果',
        tagEntries: [
          TagEntry(id: 'diet', name: '饮食', fields: {'type': '水果', 'rating': '健康'}),
        ],
      ),
    ];
    final stats = calculateDietStats(records, start, end);

    await tester.pumpWidget(_wrap(DietStatsWidget(stats: stats, records: records, onViewAll: () {})));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('记录餐次'), findsOneWidget);
    expect(find.text('吃了什么'), findsOneWidget);
    expect(find.text('健康评价'), findsOneWidget);
    expect(find.text('查看全部'), findsOneWidget);
  });

  testWidgets('只读详情弹层可渲染记录字段与正文', (tester) async {
    final record = _record(
      id: 'd1',
      displayTag: '饮食',
      content: '午饭外卖',
      tagEntries: [
        TagEntry(id: 'diet', name: '饮食', fields: {'type': '外卖', 'rating': '一般'}),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StatRecordDetailSheet(records: [record], initialIndex: 0)),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('记录详情 (1 / 1)'), findsOneWidget);
    expect(find.text('午饭外卖'), findsOneWidget);
  });
}

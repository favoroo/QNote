import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';

DiaryRecord _dietRecord(Map<String, dynamic> fields) {
  final time = DateTime(2026, 11, 15, 12, 0);
  return DiaryRecord(
    id: 'diet_1',
    title: '饮食',
    time: time,
    tags: const ['饮食'],
    displayTag: '饮食',
    content: '午饭',
    tagEntries: [TagEntry(id: 'diet', name: '饮食', fields: fields)],
    createdAt: time,
    updatedAt: time,
  );
}

Widget _wrap(DiaryRecord record) {
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: Scaffold(
      body: ListView(children: [DiaryItem(record: record)]),
    ),
  );
}

void main() {
  testWidgets('饮食卡片只留评价与总热量胶囊，不罗列菜名', (tester) async {
    await tester.pumpWidget(_wrap(_dietRecord({'rating': '健康', 'item': '香菇滑鸡', 'calories': 620})));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 食物名不进卡片胶囊（多道菜罗列太长），明细在正文/notes 里
    expect(find.text('香菇滑鸡'), findsNothing);
    expect(find.text('健康'), findsOneWidget);
    // 与活动卡片一致：只显示「数值+单位」，不重复字段名，也不展示克数
    expect(find.text('620kcal'), findsOneWidget);
    expect(find.text('热量: 620kcal'), findsNothing);
    expect(find.textContaining('g'), findsNothing);
  });

  testWidgets('未识别出热量时不显示对应胶囊', (tester) async {
    await tester.pumpWidget(_wrap(_dietRecord({'rating': '一般', 'item': '牛肉面'})));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('牛肉面'), findsNothing);
    expect(find.textContaining('kcal'), findsNothing);
  });
}

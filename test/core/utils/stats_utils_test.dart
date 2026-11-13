import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';

/// 屏幕时长趋势柱的 Y 轴上限：日粒度再 clamp 到 24 小时
double _axisCeiling(double maxHours) => niceHourCeiling(maxHours * 1.25).clamp(2.0, 24.0);

/// 构造统计用的最小记录；字段形状对齐落库后的 DiaryRecord。
DiaryRecord _record({
  required String displayTag,
  List<String> tags = const [],
  List<TagEntry> tagEntries = const [],
  String content = '',
  Map<String, dynamic>? bodyState,
  DateTime? time,
}) {
  final createdAt = time ?? DateTime(2026, 11, 13, 12);
  return DiaryRecord(
    id: 'id-$displayTag-${tags.join('-')}-${content.hashCode}',
    title: 'test',
    time: createdAt,
    tags: tags.isEmpty ? [displayTag] : tags,
    displayTag: displayTag,
    content: content,
    bodyState: bodyState,
    tagEntries: tagEntries,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

void main() {
  group('niceHourCeiling', () {
    test('抬到便于阅读的整点小时刻度', () {
      expect(niceHourCeiling(0), 2);
      expect(niceHourCeiling(0.5), 2);
      expect(niceHourCeiling(4.75), 6);
      expect(niceHourCeiling(9.125), 12);
      expect(niceHourCeiling(23.75), 24);
      expect(niceHourCeiling(28.125), 32);
      // 超出刻度表后按 10 小时向上取整
      expect(niceHourCeiling(35), 40);
    });

    test('上限恒不低于当日最大值，柱子不会溢出绘图区', () {
      for (double maxHours = 0; maxHours <= 24; maxHours += 0.25) {
        expect(
          _axisCeiling(maxHours),
          greaterThanOrEqualTo(maxHours),
          reason: '单日 $maxHours 小时时上限被截到了 ${_axisCeiling(maxHours)}',
        );
      }
    });

    test('留白适度，柱子不会被压得太矮', () {
      for (double maxHours = 0.5; maxHours <= 24; maxHours += 0.5) {
        expect(
          _axisCeiling(maxHours),
          lessThanOrEqualTo(maxHours * 2 + 2),
          reason: '单日 $maxHours 小时时上限 ${_axisCeiling(maxHours)} 留白过多',
        );
      }
    });

    test('刻度为偶数，右侧 Y 轴标签落在整数小时上', () {
      for (final maxHours in [0.0, 1.5, 7.7, 12.5, 19.0, 23.9, 30.0]) {
        final ceiling = _axisCeiling(maxHours);
        expect(ceiling % 2, 0, reason: '上限 $ceiling 应为偶数');
        expect((ceiling / 2) % 1, 0, reason: '中间刻度 ${ceiling / 2} 应为整数小时');
      }
    });

    test('典型一天 7小时42分：上限 12 小时，柱占约三分之二', () {
      final ceiling = _axisCeiling(7 + 42 / 60.0);
      expect(ceiling, 12);
      expect(7.7 / ceiling, greaterThan(0.5));
      expect(7.7 / ceiling, lessThan(1));
    });
  });

  group('calculateFinanceStats', () {
    final start = DateTime(2026, 11, 1);
    final end = DateTime(2026, 11, 30);

    test('单标签记账记录正常累计支出', () {
      final stats = calculateFinanceStats(
        [
          _record(
            displayTag: '记账',
            tagEntries: [
              TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '饮食', 'amount': 25}),
            ],
            content: '支出 - 支出类型：饮食，金额：25',
          ),
        ],
        start,
        end,
      );

      expect(stats.totalRecords, 1);
      expect(stats.totalExpense, 25);
      expect(stats.totalIncome, 0);
      expect(stats.expenseByType, {'饮食': 25.0});
    });

    test('记账不是主标签（多标签记录）时仍计入统计', () {
      final stats = calculateFinanceStats(
        [
          _record(
            displayTag: '活动',
            tags: const ['活动', '记账'],
            tagEntries: [
              TagEntry(id: 'activity', name: '活动', fields: {'type': '运动', 'duration': 1}),
              TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '饮食', 'amount': 5}),
            ],
            content: '活动 - 类型：运动，时长：1；支出 - 支出类型：饮食，金额：5',
          ),
        ],
        start,
        end,
      );

      expect(stats.totalRecords, 1);
      expect(stats.totalExpense, 5);
      expect(stats.expenseByType, {'饮食': 5.0});
    });

    test('同一条记录的多笔收支逐笔累计', () {
      final stats = calculateFinanceStats(
        [
          _record(
            displayTag: '记账',
            tagEntries: [
              TagEntry(
                id: 'consumption',
                name: '记账',
                fields: {'_category': 'income', 'incomeType': '工资', 'amount': 8000},
              ),
              TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '购物', 'amount': 200}),
            ],
          ),
        ],
        start,
        end,
      );

      expect(stats.totalRecords, 1);
      expect(stats.totalIncome, 8000);
      expect(stats.totalExpense, 200);
      expect(stats.balance, 7800);
      expect(stats.incomeByType, {'工资': 8000.0});
      expect(stats.expenseByType, {'购物': 200.0});
    });

    test('历史数据缺少 _category 时按类型字段回退推断支出', () {
      final stats = calculateFinanceStats(
        [
          _record(displayTag: '记账', bodyState: const {'type': '购物', 'amount': 30}, content: '支出类型：购物，金额：30'),
        ],
        start,
        end,
      );

      expect(stats.totalExpense, 30);
      expect(stats.expenseByType, {'购物': 30.0});
    });

    test('历史数据 tagEntry 字段为空时回退到 bodyState', () {
      final stats = calculateFinanceStats(
        [
          _record(
            displayTag: '记账',
            bodyState: const {'_category': 'expense', 'type': '餐饮', 'amount': 18},
            tagEntries: [TagEntry(id: 'consumption', name: '记账', fields: const {})],
            content: '支出类型：餐饮，金额：18',
          ),
        ],
        start,
        end,
      );

      expect(stats.totalExpense, 18);
      expect(stats.expenseByType, {'餐饮': 18.0});
    });

    test('历史数据没有 tagEntries 时从正文回退解析金额与类型', () {
      final stats = calculateFinanceStats([_record(displayTag: '记账', content: '支出 - 支出类型：交通，金额：12.5')], start, end);

      expect(stats.totalExpense, 12.5);
      expect(stats.expenseByType, {'交通': 12.5});
    });

    test('没有记账标签的记录不计入', () {
      final stats = calculateFinanceStats(
        [
          _record(
            displayTag: '活动',
            tags: const ['活动'],
            tagEntries: [
              TagEntry(id: 'activity', name: '活动', fields: {'type': '运动'}),
            ],
            content: '运动 1 小时',
          ),
        ],
        start,
        end,
      );

      expect(stats.totalRecords, 0);
      expect(stats.totalExpense, 0);
      expect(stats.dailyData, isEmpty);
    });
  });

  group('calculateDietStats', () {
    final start = DateTime(2026, 11, 1);
    final end = DateTime(2026, 11, 30);

    test('饮食不是主标签（多标签记录）时仍计入饮食统计', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '记账',
            tags: const ['记账', '饮食'],
            tagEntries: [
              TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '饮食', 'amount': 35}),
              TagEntry(id: 'diet', name: '饮食', fields: {'type': '外卖', 'rating': '一般'}),
            ],
          ),
        ],
        start,
        end,
      );

      expect(stats.totalMeals, 1);
      expect(stats.typeDistribution, {'外卖': 1});
      expect(stats.healthDistribution['一般'], 1);
    });
  });
}

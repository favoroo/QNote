import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/statistics/stat_detail.dart';

/// 屏幕时长趋势柱的 Y 轴上限：日粒度再 clamp 到 24 小时
double _axisCeiling(double maxHours) => niceHourCeiling(maxHours * 1.25).clamp(2.0, 24.0);

/// 构造统计用的最小记录；字段形状对齐落库后的 DiaryRecord。
DiaryRecord _record({
  required String displayTag,
  List<String> tags = const [],
  List<TagEntry> tagEntries = const [],
  String content = '',
  String aiAnalysis = '',
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
    aiAnalysis: aiAnalysis,
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

  group('记账明细 ledger', () {
    final start = DateTime(2026, 11, 1);
    final end = DateTime(2026, 11, 30);

    test('逐笔收集方向、金额、分类与记录 id', () {
      final record = _record(
        displayTag: '记账',
        tagEntries: [
          TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '饮食', 'amount': 25}),
        ],
        content: '午饭',
      );
      final stats = calculateFinanceStats([record], start, end);

      expect(stats.ledger.length, 1);
      final entry = stats.ledger.first;
      expect(entry.recordId, record.id);
      expect(entry.isIncome, false);
      expect(entry.amount, 25);
      expect(entry.category, '饮食');
      expect(entry.note, '午饭');
    });

    test('一条记录多笔收支拆成多条明细', () {
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

      expect(stats.ledger.length, 2);
      expect(stats.ledger.where((e) => e.isIncome).single.category, '工资');
      expect(stats.ledger.where((e) => !e.isIncome).single.category, '购物');
    });

    test('明细按时间倒序（最新在前）', () {
      final older = _record(
        displayTag: '记账',
        time: DateTime(2026, 11, 10, 9),
        content: 'older',
        tagEntries: [
          TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '交通', 'amount': 5}),
        ],
      );
      final newer = _record(
        displayTag: '记账',
        time: DateTime(2026, 11, 12, 9),
        content: 'newer',
        tagEntries: [
          TagEntry(id: 'consumption', name: '记账', fields: {'_category': 'expense', 'type': '交通', 'amount': 8}),
        ],
      );
      final stats = calculateFinanceStats([older, newer], start, end);

      expect(stats.ledger.first.amount, 8);
      expect(stats.ledger.last.amount, 5);
    });
  });

  group('饮食明细 meals', () {
    final start = DateTime(2026, 11, 1);
    final end = DateTime(2026, 11, 30);

    test('逐条收集吃了什么、评价与备注', () {
      final record = _record(
        displayTag: '饮食',
        tagEntries: [
          TagEntry(id: 'diet', name: '饮食', fields: {'type': '外卖', 'rating': '一般'}),
        ],
        content: '午饭外卖',
      );
      final stats = calculateDietStats([record], start, end);

      expect(stats.meals.length, 1);
      final meal = stats.meals.first;
      expect(meal.recordId, record.id);
      expect(meal.item, '外卖');
      expect(meal.health, '一般');
      expect(meal.note, '午饭外卖');
    });

    test('缺少评价时 health 回落为「一般」', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'type': '水果'}),
            ],
          ),
        ],
        start,
        end,
      );

      expect(stats.meals.single.health, '一般');
      expect(stats.meals.single.item, '水果');
    });

    test('累计估算热量，仅统计填了热量的餐次', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '健康', 'item': '香菇滑鸡', 'calories': 620}),
            ],
          ),
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '一般', 'item': '牛肉面', 'calories': 480}),
            ],
          ),
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '一般', 'item': '西兰花炒虾仁'}),
            ],
          ),
        ],
        start,
        end,
      );

      expect(stats.totalCalories, 1100);
      expect(stats.calorieMealCount, 2);
      expect(stats.meals.firstWhere((m) => m.item == '香菇滑鸡').calories, 620);
      expect(stats.meals.firstWhere((m) => m.item == '西兰花炒虾仁').calories, isNull);
    });

    test('食物名优先取 item，旧数据回退 type', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'item': '香菇滑鸡', 'type': '外卖', 'rating': '健康'}),
            ],
          ),
        ],
        start,
        end,
      );

      expect(stats.typeDistribution, {'香菇滑鸡': 1});
      expect(stats.meals.single.item, '香菇滑鸡');
    });

    test('图片提取记录从 notes 逐项热量明细兜底解析菜名', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '健康', 'calories': 620}),
            ],
            content: '图：米饭约250kcal、香菇滑鸡约320kcal、白灼生菜约50kcal，合计约620kcal',
          ),
        ],
        start,
        end,
      );

      expect(stats.typeDistribution, {'米饭、香菇滑鸡、白灼生菜': 1});
      expect(stats.meals.single.calories, 620);
    });

    test('新版记录从 aiAnalysis 逐项热量明细兜底解析菜名', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '健康', 'calories': 620}),
            ],
            content: '午饭',
            aiAnalysis: '图：米饭约250kcal、香菇滑鸡约320kcal、白灼生菜约50kcal，合计约620kcal',
          ),
        ],
        start,
        end,
      );

      expect(stats.typeDistribution, {'米饭、香菇滑鸡、白灼生菜': 1});
    });

    test('新版分析带份量时也能解析菜名', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '健康', 'calories': 620}),
            ],
            content: '午饭',
            aiAnalysis: '图：米饭 约200g 约250kcal、香菇滑鸡 约180g 约320kcal、白灼生菜 约120g 约50kcal，合计约620kcal（份量按常见餐具估算）',
          ),
        ],
        start,
        end,
      );

      expect(stats.typeDistribution, {'米饭、香菇滑鸡、白灼生菜': 1});
    });

    test('notes 不是逐项热量格式时不强行解析菜名', () {
      final stats = calculateDietStats(
        [
          _record(
            displayTag: '饮食',
            tagEntries: [
              TagEntry(id: 'diet', name: '饮食', fields: {'rating': '一般'}),
            ],
            content: '中午随便吃了点',
          ),
        ],
        start,
        end,
      );

      expect(stats.typeDistribution, isEmpty);
    });
  });

  group('groupByDay', () {
    test('按天倒序分组，天内保持输入顺序', () {
      final b = DateTime(2026, 11, 13, 20);
      final a = DateTime(2026, 11, 13, 9);
      final c = DateTime(2026, 11, 12, 8);

      final groups = groupByDay<DateTime>([b, a, c], (t) => t);

      expect(groups.length, 2);
      expect(groups.first.dateKey, '2026-11-13');
      expect(groups.first.items, [b, a]);
      expect(groups.last.dateKey, '2026-11-12');
    });
  });

  group('formatAmount', () {
    test('整数不带小数，非整数保留两位', () {
      expect(formatAmount(25), '25');
      expect(formatAmount(0), '0');
      expect(formatAmount(12.5), '12.50');
    });
  });
}

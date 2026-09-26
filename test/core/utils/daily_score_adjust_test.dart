import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/models/daily_score.dart';

/// 造一条五维齐全的评分，默认总分 88
DailyScore _score({
  int total = 88,
  Map<String, int> dims = const {
    'sleep': 90,
    'diet': 70,
    'activity': 65,
    'health': 80,
    'screen': 55,
  },
}) => DailyScore(
  id: 'score-1',
  date: DateTime(2026, 9, 3),
  totalScore: total,
  dimensionScores: dims,
  summary: '作息规律',
  suggestions: '晚餐偏晚',
  recordCount: 5,
  createdAt: DateTime(2026, 9, 3, 8),
  updatedAt: DateTime(2026, 9, 3, 8),
);

void main() {
  group('mergeDimensionScores', () {
    test('只传 diet 时其余四维保留原值', () {
      final merged = mergeDimensionScores(
        const {'sleep': 90, 'diet': 70, 'activity': 65, 'health': 80, 'screen': 55},
        const {'diet': 85},
      );
      expect(merged, {'sleep': 90, 'diet': 85, 'activity': 65, 'health': 80, 'screen': 55});
    });

    test('incoming 的新键被追加', () {
      final merged = mergeDimensionScores(const {'diet': 70}, const {'water': 60});
      expect(merged, {'diet': 70, 'water': 60});
    });

    test('incoming 为空时返回等价副本而非同一实例', () {
      final existing = {'diet': 70};
      final merged = mergeDimensionScores(existing, const {});
      expect(merged, existing);
      expect(identical(merged, existing), isFalse);
      merged['diet'] = 10;
      expect(existing['diet'], 70, reason: '不得反向污染入参');
    });

    test('原记录只有三维时合并后仍是四维，不被补齐成五维', () {
      final merged = mergeDimensionScores(
        const {'sleep': 90, 'diet': 70, 'health': 80},
        const {'activity': 66},
      );
      expect(merged.length, 4);
      expect(merged.containsKey('screen'), isFalse);
    });
  });

  group('applyScoreAdjust 加减分', () {
    test('delta -5 且全选时总分与五维各自减 5', () {
      final outcome = applyScoreAdjust(
        _score(),
        const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
      );
      expect(outcome.after.totalScore, 83);
      expect(outcome.after.dimensionScores['sleep'], 85);
      expect(outcome.after.dimensionScores['screen'], 50);
      expect(outcome.changes.length, 6);
    });

    test('触到上限时钳位到 100 并标记 clamped', () {
      final outcome = applyScoreAdjust(
        _score(total: 95),
        const ScoreAdjustSpec(delta: 10, fields: {ScoreField.total}),
      );
      expect(outcome.after.totalScore, 100);
      expect(outcome.clamped, isTrue);
      expect(outcome.changes.single.clamped, isTrue);
    });

    test('不会减成负数', () {
      final outcome = applyScoreAdjust(
        _score(total: 30),
        const ScoreAdjustSpec(delta: -80, fields: {ScoreField.total}),
      );
      expect(outcome.after.totalScore, 0);
      expect(outcome.clamped, isTrue);
    });

    test('原值缺失的维度不被凭空造出来', () {
      final outcome = applyScoreAdjust(
        _score(dims: const {'sleep': 90}),
        const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
      );
      expect(outcome.after.dimensionScores.containsKey('diet'), isFalse);
      expect(outcome.after.totalScore, 83);
    });
  });

  group('applyScoreAdjust 设为固定值', () {
    test('只勾 screen 时总分完全不变', () {
      final outcome = applyScoreAdjust(
        _score(),
        const ScoreAdjustSpec(setValue: 40, fields: {ScoreField.screen}),
      );
      expect(outcome.after.totalScore, 88);
      expect(outcome.after.dimensionScores['screen'], 40);
      expect(outcome.after.dimensionScores['diet'], 70);
      expect(outcome.changes.single.field, ScoreField.screen);
    });

    test('全选时总分与五维都被设为同一值', () {
      final outcome = applyScoreAdjust(
        _score(),
        const ScoreAdjustSpec(setValue: 80, fields: kAllScoreFields),
      );
      expect(outcome.after.totalScore, 80);
      expect(outcome.after.dimensionScores.values.every((v) => v == 80), isTrue);
    });

    test('目标值等于原值时不算变更', () {
      final outcome = applyScoreAdjust(
        _score(total: 88),
        const ScoreAdjustSpec(setValue: 88, fields: {ScoreField.total}),
      );
      expect(outcome.changed, isFalse);
      expect(outcome.changes, isEmpty);
    });

    test('固定值越界被钳位', () {
      final outcome = applyScoreAdjust(
        _score(),
        const ScoreAdjustSpec(setValue: 170, fields: {ScoreField.diet}),
      );
      expect(outcome.after.dimensionScores['diet'], 100);
      expect(outcome.clamped, isTrue);
    });
  });

  group('不变量', () {
    test('summary/suggestions/recordCount 与改前一致', () {
      final existing = _score();
      final outcome = applyScoreAdjust(
        existing,
        const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
      );
      expect(outcome.after.summary, existing.summary);
      expect(outcome.after.suggestions, existing.suggestions);
      expect(outcome.after.recordCount, existing.recordCount);
      expect(outcome.after.id, existing.id);
      expect(outcome.after.date, existing.date);
    });

    test('改后实体不污染入参', () {
      final existing = _score();
      applyScoreAdjust(existing, const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields));
      expect(existing.totalScore, 88);
      expect(existing.dimensionScores['sleep'], 90);
    });
  });

  group('describeScoreAdjustPreview', () {
    test('缺失天数与触界天数按需出现', () {
      final outcomes = [
        applyScoreAdjust(_score(), const ScoreAdjustSpec(delta: -5, fields: {ScoreField.total})),
        applyScoreAdjust(
          _score(total: 98),
          const ScoreAdjustSpec(delta: 5, fields: {ScoreField.total}),
        ),
      ];
      expect(
        describeScoreAdjustPreview(outcomes, missingDays: 2),
        '命中 2 天 · 该区间无评分 2 天（不会被改动） · 1 天已到上下限',
      );
    });

    test('无缺失与触界时只报命中天数', () {
      final outcomes = [
        applyScoreAdjust(_score(), const ScoreAdjustSpec(delta: -5, fields: {ScoreField.total})),
      ];
      expect(describeScoreAdjustPreview(outcomes), '命中 1 天');
    });
  });

  group('ScoreField', () {
    test('fromKey 认存储键与中文标签，未知键返回 null', () {
      expect(ScoreField.fromKey('diet'), ScoreField.diet);
      expect(ScoreField.fromKey(' 屏幕 '), ScoreField.screen);
      expect(ScoreField.fromKey('total'), ScoreField.total);
      expect(ScoreField.fromKey('mood'), isNull);
    });

    test('只有总分不是维度', () {
      expect(ScoreField.total.isDimension, isFalse);
      expect(ScoreField.sleep.isDimension, isTrue);
    });
  });
}

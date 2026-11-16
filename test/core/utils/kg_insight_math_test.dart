import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/kg_insight_math.dart';

void main() {
  Map<String, Set<String>> dailyMap(int days) {
    final result = <String, Set<String>>{};
    final start = DateTime(2026, 1, 1);
    for (var i = 0; i < days; i++) {
      result[_date(start.add(Duration(days: i)))] = <String>{};
    }
    return result;
  }

  test('同日强关联能通过支持度/提升度/z 门槛', () {
    final map = dailyMap(30);
    final dates = map.keys.toList();
    // A 出现 10 天；B 在 A 的 10 天全部出现，另在 3 天单独出现
    for (var i = 0; i < 10; i++) {
      map[dates[i]] = {'a', 'b'};
    }
    for (var i = 20; i < 23; i++) {
      map[dates[i]] = {'b'};
    }

    final result = KgInsightMath.mine(featuresByDate: map);
    expect(result, isNotEmpty);
    final ab = result.firstWhere((c) => c.kind == 'association');
    expect(ab.support, 10);
    expect(ab.aSupport, 10);
    expect(ab.bSupport, 13);
    expect(ab.lift, greaterThan(1.5));
    expect(ab.zScore, greaterThan(1.64));
    expect(ab.evidenceDates.length, 6);
  });

  test('随机共现不会通过阈值', () {
    final map = dailyMap(30);
    final dates = map.keys.toList();
    // A 和 B 各出现 5 天，只有 1 天重叠
    for (var i = 0; i < 5; i++) {
      map[dates[i]] = {'a'};
    }
    for (var i = 4; i < 9; i++) {
      map[dates[i]] = {...map[dates[i]]!, 'b'};
    }

    final result = KgInsightMath.mine(featuresByDate: map);
    expect(result.any((c) => c.kind == 'association'), isFalse);
  });

  test('出现率过高的泛化节点不参与', () {
    final map = dailyMap(30);
    final dates = map.keys.toList();
    for (var i = 0; i < 25; i++) {
      map[dates[i]] = {'ubiquitous'};
    }
    for (var i = 0; i < 10; i++) {
      map[dates[i]] = {...map[dates[i]]!, 'b'};
    }

    final result = KgInsightMath.mine(featuresByDate: map);
    expect(result.any((c) => c.aId == 'ubiquitous' || c.bId == 'ubiquitous'), isFalse);
  });

  test('次日滞后能发现 A 之后 B', () {
    final map = dailyMap(30);
    final dates = map.keys.toList();
    for (var i = 0; i < 10; i++) {
      map[dates[i]] = {...map[dates[i]]!, 'late'};
    }
    for (var i = 1; i <= 10; i++) {
      map[dates[i]] = {...map[dates[i]]!, 'mood_low'};
    }

    final result = KgInsightMath.mine(featuresByDate: map);
    final lagged = result.where((c) => c.kind == 'lagged' && c.aId == 'late' && c.bId == 'mood_low');
    expect(lagged, isNotEmpty);
    expect(lagged.first.support, greaterThanOrEqualTo(4));
  });

  test('排除同一指标派生的状态对', () {
    final map = dailyMap(30);
    final dates = map.keys.toList();
    for (var i = 0; i < 10; i++) {
      map[dates[i]] = {'low_steps', 'no_exercise'};
    }
    for (var i = 20; i < 23; i++) {
      map[dates[i]] = {'no_exercise'};
    }

    final result = KgInsightMath.mine(
      featuresByDate: map,
      excludedPairs: {
        'association|low_steps|no_exercise',
        'lagged|low_steps|no_exercise',
        'lagged|no_exercise|low_steps',
      },
    );
    expect(result, isEmpty);
  });

  test('两比例 z 检验方向正确', () {
    final z = KgInsightMath.twoProportionZ(x1: 8, n1: 10, x2: 2, n2: 20);
    expect(z, greaterThan(1.64));
    final reverse = KgInsightMath.twoProportionZ(x1: 2, n1: 20, x2: 8, n2: 10);
    expect(reverse, lessThan(-1.64));
  });
}

String _date(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';
import 'package:qnote_flutter/pages/health/health_metric_detail_page.dart';

/// 构造某天的健康指标；采样点入参为 (本地时刻, 数值)
HealthDailyMetrics _metrics({
  int? avgHr,
  int? restingHr,
  int? minHr,
  int? maxHr,
  List<(int, int)> hr = const [],
  int? avgSpo2,
  int? minSpo2,
  List<(int, int)> spo2 = const [],
  int? avgStress,
  int? maxStress,
  List<(int, int)> stress = const [],
}) {
  List<Map<String, dynamic>> encode(List<(int, int)> points) => [
        for (final p in points)
          {
            't': DateTime(2026, 9, 20, p.$1).millisecondsSinceEpoch ~/ 1000,
            'v': p.$2,
          },
      ];

  return HealthDailyMetrics(
    date: '2026-09-20',
    updatedAt: DateTime(2026, 9, 20, 22),
    avgHeartRate: avgHr,
    restingHeartRate: restingHr,
    minHeartRate: minHr,
    maxHeartRate: maxHr,
    heartRateSamplesJson: json.encode(encode(hr)),
    avgSpo2: avgSpo2,
    minSpo2: minSpo2,
    spo2SamplesJson: json.encode(encode(spo2)),
    avgStress: avgStress,
    maxStress: maxStress,
    stressSamplesJson: json.encode(encode(stress)),
  );
}

Future<void> _pumpPage(WidgetTester tester, HealthDetailArgs args) async {
  tester.view.physicalSize = const Size(420, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(home: HealthMetricDetailPage(args: args)));
  await tester.pumpAndSettle();
}

void main() {
  group('HealthMetricDetailPage', () {
    testWidgets('心率详情渲染曲线、关键数值与区间分布', (tester) async {
      await _pumpPage(
        tester,
        HealthDetailArgs(
          kind: HealthMetricKind.heartRate,
          title: '心率健康',
          dateLabel: '9月20日 今天',
          metrics: _metrics(
            avgHr: 77,
            restingHr: 56,
            minHr: 53,
            maxHr: 106,
            hr: [(7, 58), (9, 72), (12, 95), (15, 66), (20, 88)],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('心率健康'), findsOneWidget);
      expect(find.text('全天心率曲线'), findsOneWidget);
      expect(find.text('关键数值'), findsOneWidget);
      expect(find.text('采样点区间分布'), findsOneWidget);
      expect(find.text('当日静息心率 56 bpm'), findsOneWidget);
      expect(find.textContaining('共 5 个采样点'), findsOneWidget);
      expect(find.text('106'), findsWidgets);
    });

    testWidgets('心率无采样时给出占位而不是空白页', (tester) async {
      await _pumpPage(
        tester,
        const HealthDetailArgs(
          kind: HealthMetricKind.heartRate,
          title: '心率健康',
          metrics: null,
        ),
      );
      expect(find.text('这一天没有可展示的健康数据'), findsOneWidget);

      await _pumpPage(
        tester,
        HealthDetailArgs(
          kind: HealthMetricKind.heartRate,
          title: '心率健康',
          metrics: _metrics(),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('暂无心率采样'), findsOneWidget);
      expect(find.textContaining('这一天没有心率采样'), findsOneWidget);
    });

    testWidgets('血氧与压力详情渲染两条曲线，低血氧给提示', (tester) async {
      await _pumpPage(
        tester,
        HealthDetailArgs(
          kind: HealthMetricKind.vitals,
          title: '血氧与压力',
          metrics: _metrics(
            avgSpo2: 97,
            minSpo2: 89,
            spo2: [(8, 97), (14, 96), (21, 89)],
            avgStress: 23,
            maxStress: 45,
            stress: [(9, 17), (13, 45), (19, 22)],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('血氧饱和度'), findsOneWidget);
      expect(find.text('全天压力'), findsOneWidget);
      expect(find.text('低于 90% 值得关注'), findsOneWidget);
      expect(find.text('放松时段'), findsOneWidget);
      expect(find.textContaining('共 3 次测量'), findsOneWidget);
      expect(find.textContaining('共 3 个采样点'), findsOneWidget);
    });

    testWidgets('血氧正常时不显示低值提示', (tester) async {
      await _pumpPage(
        tester,
        HealthDetailArgs(
          kind: HealthMetricKind.vitals,
          title: '血氧与压力',
          metrics: _metrics(avgSpo2: 98, minSpo2: 95, spo2: [(10, 98)]),
        ),
      );
      expect(find.text('低于 90% 值得关注'), findsNothing);
    });

    testWidgets('运动详情外显心率五区间时长与训练负荷', (tester) async {
      final record = HealthSportRecord(
        id: 's1',
        sid: 's1',
        category: 'strength',
        title: '力量训练',
        startTime: DateTime(2026, 9, 19, 19, 12),
        endTime: DateTime(2026, 9, 19, 19, 20),
        durationSeconds: 475,
        calories: 38,
        avgHeartRate: 126,
        maxHeartRate: 152,
        detailJson: json.encode({
          'min_hrm': 88,
          'hrm_warm_up_duration': 60,
          'hrm_fat_burning_duration': 219,
          'hrm_aerobic_duration': 135,
          'hrm_anaerobic_duration': 22,
          'hrm_extreme_duration': 0,
          'train_load': 1.6,
          'train_load_level': 2,
          'anaerobic_train_effect': 0.2,
        }),
        createdAt: DateTime(2026, 9, 19, 19, 30),
      );

      await _pumpPage(
        tester,
        HealthDetailArgs(kind: HealthMetricKind.sport, title: '力量训练', sport: record),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('概览'), findsOneWidget);
      expect(find.text('19:12 - 19:20'), findsOneWidget);
      expect(find.text('心率'), findsOneWidget);
      expect(find.text('心率区间时长'), findsOneWidget);
      expect(find.text('燃脂'), findsOneWidget);
      expect(find.text('4分'), findsOneWidget); // 219 秒 → 4 分
      expect(find.text('训练负荷与效果'), findsOneWidget);
      expect(find.text('等级 2'), findsOneWidget);
    });

    testWidgets('运动记录缺 detail_json 时给出可重同步的说明', (tester) async {
      final record = HealthSportRecord(
        id: 's2',
        sid: 's2',
        category: 'running',
        title: '跑步训练',
        startTime: DateTime(2026, 9, 18, 7),
        endTime: DateTime(2026, 9, 18, 7, 30),
        durationSeconds: 1800,
        createdAt: DateTime(2026, 9, 18, 8),
      );

      await _pumpPage(
        tester,
        HealthDetailArgs(kind: HealthMetricKind.sport, title: '跑步训练', sport: record),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('心率区间时长'), findsNothing);
      expect(find.textContaining('重新同步可补齐'), findsOneWidget);
    });
    testWidgets('睡眠详情渲染分期时间轴与时长构成', (tester) async {
      final bed = DateTime(2026, 9, 19, 23, 50).millisecondsSinceEpoch ~/ 1000;
      int sec(int minutes) => bed + minutes * 60;
      final m = HealthDailyMetrics(
        date: '2026-09-20',
        updatedAt: DateTime(2026, 9, 20, 8),
        sleepDurationMinutes: 472,
        deepSleepMinutes: 0,
        lightSleepMinutes: 344,
        remSleepMinutes: 6,
        awakeMinutes: 128,
        sleepStartTime: DateTime(2026, 9, 19, 23, 50).toIso8601String(),
        sleepEndTime: DateTime(2026, 9, 20, 7, 48).toIso8601String(),
        sleepScore: 78,
        sleepStagesJson: json.encode([
          {'state': 2, 'start': sec(0), 'end': sec(120), 'duration': 120},
          {'state': 5, 'start': sec(120), 'end': sec(126), 'duration': 6},
          {'state': 4, 'start': sec(126), 'end': sec(150), 'duration': 24},
          {'state': 2, 'start': sec(150), 'end': sec(478), 'duration': 328},
        ]),
      );

      await _pumpPage(
        tester,
        HealthDetailArgs(kind: HealthMetricKind.sleep, title: '作息睡眠', metrics: m),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('作息概览'), findsOneWidget);
      expect(find.text('睡眠分期时间轴'), findsOneWidget);
      expect(find.text('时长构成'), findsOneWidget);
      // 概览与时间轴两端都会标注入睡/醒来时刻，故用 findsWidgets
      expect(find.text('23:50'), findsWidgets);
      expect(find.text('07:48'), findsWidgets);
      expect(find.text('7h52m'), findsOneWidget);
      expect(find.text('共 7h58m'), findsOneWidget);
      // 「快速眼动」在时间轴图例与时长构成里各出现一次
      expect(find.text('快速眼动'), findsNWidgets(2));
    });

    testWidgets('睡眠无分期数据时给出佩戴提示', (tester) async {
      await _pumpPage(
        tester,
        HealthDetailArgs(
          kind: HealthMetricKind.sleep,
          title: '作息睡眠',
          metrics: _metrics(),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('这一天没有分期数据，多为设备未整夜佩戴'), findsOneWidget);
      expect(find.text('暂无分期数据'), findsOneWidget);
    });
  });
}

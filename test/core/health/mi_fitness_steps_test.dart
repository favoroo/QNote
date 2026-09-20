import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_api_client.dart';

/// 整点基准（epoch 秒，可被 3600 整除），保证按小时分桶与测试机时区无关
const int _h0 = 1789862400;

/// 构造一条步数样本（value 为字符串形式的 JSON，与小米接口返回结构一致）
Map<String, dynamic> _stepItem({
  required String sid,
  required int hour,
  required int minute,
  required int steps,
  double distance = 0,
  double calories = 0,
}) {
  final sec = _h0 + hour * 3600 + minute * 60;
  return {
    'sid': sid,
    'time': sec,
    'value': json.encode({'time': sec, 'steps': steps, 'distance': distance, 'calories': calories}),
  };
}

void main() {
  group('MiFitnessApiClient parseStepSummary', () {
    test('同一小时两条来源各报一份时只计主源，不按分钟跨源取最大', () {
      // 手机 A：70 步；手环 B：60 步。旧的跨源逐分钟取最大会得 50 + 40 = 90
      final data = [
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 30),
        _stepItem(sid: 'A', hour: 0, minute: 2, steps: 40),
        _stepItem(sid: 'B', hour: 0, minute: 1, steps: 50),
        _stepItem(sid: 'B', hour: 0, minute: 2, steps: 10),
      ];

      expect(MiFitnessApiClient.parseStepSummary(data).steps, 70);
    });

    test('主源按小时各自判定，可随时间切换', () {
      final data = [
        // 第 0 小时 A 胜出（70 > 60）
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 30),
        _stepItem(sid: 'A', hour: 0, minute: 2, steps: 40),
        _stepItem(sid: 'B', hour: 0, minute: 1, steps: 50),
        _stepItem(sid: 'B', hour: 0, minute: 2, steps: 10),
        // 第 1 小时 B 胜出（90 > 10）
        _stepItem(sid: 'A', hour: 1, minute: 5, steps: 10),
        _stepItem(sid: 'B', hour: 1, minute: 5, steps: 90),
      ];

      expect(MiFitnessApiClient.parseStepSummary(data).steps, 70 + 90);
    });

    test('距离跟随主源，不把两条来源相加', () {
      final data = [
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 30, distance: 20),
        _stepItem(sid: 'A', hour: 0, minute: 2, steps: 40, distance: 25),
        _stepItem(sid: 'B', hour: 0, minute: 1, steps: 10, distance: 999),
      ];

      expect(MiFitnessApiClient.parseStepSummary(data).distanceMeters, 45);
    });

    test('卡路里仍按全来源累加', () {
      // 实测只取单源会偏低约 280 kcal，官方值更接近两条来源之和
      final data = [
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 30, calories: 1.2),
        _stepItem(sid: 'B', hour: 0, minute: 1, steps: 20, calories: 2.0),
      ];

      expect(MiFitnessApiClient.parseStepSummary(data).calories, closeTo(3.2, 0.001));
    });

    test('同来源同分钟重复上报时取步数较大的那条（含其距离）', () {
      final data = [
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 30, distance: 10),
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 50, distance: 18),
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 40, distance: 15),
      ];

      final r = MiFitnessApiClient.parseStepSummary(data);
      expect(r.steps, 50);
      expect(r.distanceMeters, 18);
      expect(r.sampledMinutes, 1);
    });

    test('单来源时等于其分钟合计，采样分钟数一致', () {
      final data = [
        _stepItem(sid: 'A', hour: 0, minute: 1, steps: 30),
        _stepItem(sid: 'A', hour: 0, minute: 2, steps: 40),
        _stepItem(sid: 'A', hour: 0, minute: 3, steps: 0),
      ];

      final r = MiFitnessApiClient.parseStepSummary(data);
      expect(r.steps, 70);
      expect(r.sampledMinutes, 3);
    });

    test('脏数据不炸：value 非法 JSON 与缺 sid 均安全跳过或归并', () {
      final data = [
        {'sid': 'A', 'time': _h0 + 60, 'value': '{不是JSON'},
        {'sid': 'A', 'time': _h0 + 120, 'value': '{"steps":12}'},
        {'time': _h0 + 180, 'value': '{"steps":8,"distance":5,"calories":0.5}'},
      ];

      final r = MiFitnessApiClient.parseStepSummary(data);
      expect(r.steps, greaterThan(0));
      expect(r.distanceMeters, greaterThanOrEqualTo(0));
    });

    test('空数据返回全零', () {
      final r = MiFitnessApiClient.parseStepSummary([]);
      expect(r.steps, 0);
      expect(r.sampledMinutes, 0);
    });
  });
}

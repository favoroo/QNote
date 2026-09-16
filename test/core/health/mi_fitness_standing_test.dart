import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_api_client.dart';

void main() {
  group('MiFitnessApiClient parseStandingCount', () {
    final testDate = DateTime(2026, 9, 16);

    test('解析 daily_report 官方聚合日汇总', () {
      final data = [
        {
          'time': DateTime(2026, 9, 16, 12, 0).millisecondsSinceEpoch ~/ 1000,
          'tag': 'daily_report',
          'value': json.encode({'count': 7}),
        },
      ];
      final res = MiFitnessApiClient.parseStandingCount(data, testDate);
      expect(res, 7);
    });

    test('解析大于1的聚合总值', () {
      final data = [
        {
          'time': DateTime(2026, 9, 16, 15, 0).millisecondsSinceEpoch ~/ 1000,
          'value': json.encode({'count': 12}),
        },
      ];
      final res = MiFitnessApiClient.parseStandingCount(data, testDate);
      expect(res, 12);
    });

    test('解析按小时上报打点（同小时多设备去重）', () {
      final baseTs = DateTime(2026, 9, 16, 9, 10).millisecondsSinceEpoch ~/ 1000;
      final data = [
        // 9 点 手环上报
        {
          'time': baseTs,
          'value': json.encode({'count': 1}),
        },
        // 9 点 手表上报（重复小时）
        {
          'time': baseTs + 120,
          'value': json.encode({'count': 1}),
        },
        // 10 点 上报
        {
          'time': DateTime(2026, 9, 16, 10, 5).millisecondsSinceEpoch ~/ 1000,
          'value': json.encode({'count': 1}),
        },
        // 11 点 上报
        {
          'time': DateTime(2026, 9, 16, 11, 40).millisecondsSinceEpoch ~/ 1000,
          'value': json.encode({'count': 1}),
        },
      ];
      final res = MiFitnessApiClient.parseStandingCount(data, testDate);
      expect(res, 3);
    });

    test('兼容小米云端原生布尔/空结构/update_time打点', () {
      // 场景：原生 valid_stand 列表中只包含 update_time 和简单 value 或无 count 字段
      final data = [
        // 8点：仅有 update_time，value 为 "1"
        {
          'update_time': DateTime(2026, 9, 16, 8, 20).millisecondsSinceEpoch ~/ 1000,
          'value': '1',
        },
        // 10点：value 为 {"val": 1}
        {
          'time': DateTime(2026, 9, 16, 10, 15).millisecondsSinceEpoch ~/ 1000,
          'value': json.encode({'val': 1}),
        },
        // 13点：value 为 true
        {
          'timestamp': DateTime(2026, 9, 16, 13, 0).millisecondsSinceEpoch ~/ 1000,
          'value': true,
        },
        // 14点：毫秒级时间戳，value 为空对象（但记录本身即代表站立打点）
        {
          'time': DateTime(2026, 9, 16, 14, 50).millisecondsSinceEpoch,
          'value': '{}',
        },
        // 15点：明确显式未达标/未站立（应过滤）
        {
          'time': DateTime(2026, 9, 16, 15, 10).millisecondsSinceEpoch ~/ 1000,
          'value': json.encode({'count': 0, 'has_stand': false}),
        },
      ];
      final res = MiFitnessApiClient.parseStandingCount(data, testDate);
      // 8点, 10点, 13点, 14点 共 4 个有效小时
      expect(res, 4);
    });

    test('跨天数据过滤：只统计属于所选日期的站立小时', () {
      final data = [
        // 昨天的打点
        {
          'time': DateTime(2026, 9, 15, 23, 50).millisecondsSinceEpoch ~/ 1000,
          'value': '1',
        },
        // 今天的打点（8点、9点）
        {
          'time': DateTime(2026, 9, 16, 8, 10).millisecondsSinceEpoch ~/ 1000,
          'value': '1',
        },
        {
          'time': DateTime(2026, 9, 16, 9, 10).millisecondsSinceEpoch ~/ 1000,
          'value': '1',
        },
      ];
      final res = MiFitnessApiClient.parseStandingCount(data, testDate);
      expect(res, 2);
    });
  });
}

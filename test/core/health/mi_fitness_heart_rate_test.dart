import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_api_client.dart';

/// 构造一条 resting_heart_rate 样本（value 为字符串形式的 JSON，与小米接口返回结构一致）
Map<String, dynamic> _item(int? bpm, {int time = 1789776000, int? updateTime}) => {
      'sid': '2069986756',
      'key': 'resting_heart_rate',
      'time': time,
      'value': bpm == null ? '{不是JSON' : json.encode({'bpm': bpm, 'date_time': time}),
      'update_time': ?updateTime,
    };

void main() {
  group('MiFitnessApiClient parseRestingHeartRate', () {
    test('单日一条时直接取用', () {
      expect(MiFitnessApiClient.parseRestingHeartRate([_item(56)]), 56);
    });

    test('多条时按写入时间取最新（设备当天会重算）', () {
      final data = [
        _item(58, updateTime: 100),
        _item(52, updateTime: 300),
        _item(56, updateTime: 200),
      ];
      expect(MiFitnessApiClient.parseRestingHeartRate(data), 52);
    });

    test('缺 update_time 时退回 time 字段比较', () {
      final data = [
        _item(58, time: 100),
        _item(54, time: 200),
      ];
      expect(MiFitnessApiClient.parseRestingHeartRate(data), 54);
    });

    test('越界与脏数据忽略，全部无效时返回 null', () {
      final data = [_item(0), _item(240), _item(null), {'value': '{"no_bpm":1}'}];
      expect(MiFitnessApiClient.parseRestingHeartRate(data), isNull);
      expect(MiFitnessApiClient.parseRestingHeartRate([]), isNull);
    });
  });
}

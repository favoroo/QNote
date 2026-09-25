import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_api_client.dart';
import 'package:qnote_flutter/core/health/mi_fitness_auth_service.dart';

/// 按 key 返回预置数据、并可指定某些 key 抛异常的假客户端（不触网）
class _StubMiFitnessApiClient extends MiFitnessApiClient {
  _StubMiFitnessApiClient({required this.dataByKey, this.failingKeys = const {}})
      : super(MiFitnessAuthService());

  final Map<String, List<Map<String, dynamic>>> dataByKey;
  final Set<String> failingKeys;

  @override
  Future<List<Map<String, dynamic>>> fetchFitnessData({
    required DateTime startTime,
    required DateTime endTime,
    required String key,
  }) async {
    if (failingKeys.contains(key)) {
      throw Exception('模拟故障: $key');
    }
    return dataByKey[key] ?? const [];
  }
}

/// 一条最小可用的分钟步数样本（value 为云端原样的 JSON 字符串）
Map<String, dynamic> _stepItem(int epochSec, int steps) => {
      'time': epochSec,
      'sid': 'hlth.gen_1',
      'value': '{"steps":$steps,"distance":0.8,"calories":0.03}',
    };

void main() {
  final date = DateTime(2026, 9, 25);
  // 2026-09-25 10:00 本地（东八区）对应的秒级时间戳，避免跨时区漂移直接用当天偏移量
  final sampleTime = DateTime(2026, 9, 25, 10).millisecondsSinceEpoch ~/ 1000;

  group('MiFitnessApiClient fetchDaySummary 故障不写全 0', () {
    test('所有指标一起失败时抛异常，而不是返回全零汇总覆盖已有数据', () async {
      final client = _StubMiFitnessApiClient(
        dataByKey: {},
        failingKeys: {
          'steps',
          'sleep',
          'heart_rate',
          'spo2',
          'stress',
          'valid_stand',
          'resting_heart_rate',
        },
      );

      expect(
        () => client.fetchDaySummary(date),
        throwsA(isA<Exception>()),
      );
    });

    test('个别指标不支持（血氧/压力抛错）时当天仍可同步，其余数据正常解析', () async {
      final client = _StubMiFitnessApiClient(
        dataByKey: {
          'steps': [_stepItem(sampleTime, 100), _stepItem(sampleTime + 60, 200)],
        },
        failingKeys: {'spo2', 'stress'},
      );

      final summary = await client.fetchDaySummary(date);

      expect(summary.steps, equals(300));
      expect(summary.avgSpo2, isNull);
      expect(summary.avgStress, isNull);
    });

    test('全部指标成功但当天确实没数据：返回全零且不抛异常', () async {
      final client = _StubMiFitnessApiClient(dataByKey: {});

      final summary = await client.fetchDaySummary(date);

      expect(summary.steps, equals(0));
      expect(summary.sleepDurationMinutes, equals(0));
      expect(summary.standingCount, equals(0));
    });
  });
}

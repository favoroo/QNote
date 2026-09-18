import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/health/mi_fitness_crypto.dart';
import 'package:qnote_flutter/core/health/mi_fitness_auth_service.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';

final miFitnessApiClientProvider = Provider<MiFitnessApiClient>((ref) {
  final authService = ref.watch(miFitnessAuthServiceProvider);
  return MiFitnessApiClient(authService);
});

class MiFitnessApiClient {
  final MiFitnessAuthService _authService;
  static const String host = 'https://hlth.io.mi.com';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (status) => status != null && status < 500,
  ));

  MiFitnessApiClient(this._authService);

  /// 通用加密请求
  ///
  /// [allowAuthRetry] 为 true 时，若服务端返回 401（serviceToken 失效），
  /// 会用 passToken 静默刷新登录态并用新凭据重试一次；重试请求不再触发刷新，避免死循环。
  Future<dynamic> _postEncrypted({
    required String path,
    required Map<String, dynamic> payload,
    required MiAuthCredentials credentials,
    bool allowAuthRetry = true,
  }) async {
    final encFormData = MiFitnessCrypto.encryptRequestParams(
      method: 'POST',
      path: path,
      ssecurityB64: credentials.ssecurity,
      payload: payload,
    );

    final cookieParts = <String>[
      if (credentials.serviceToken.isNotEmpty) 'serviceToken=${credentials.serviceToken}',
      if (credentials.cUserId != null && credentials.cUserId!.isNotEmpty) 'cUserId=${credentials.cUserId}',
      'userId=${credentials.userId}',
    ];

    final response = await _dio.post(
      '$host$path',
      data: encFormData,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {
          'Cookie': cookieParts.join('; '),
          'region_tag': 'cn',
          'handleparams': 'true',
          'User-Agent': 'Android-12-3.53.1-vivo-V2284A',
        },
        responseType: ResponseType.plain,
      ),
    );

    // serviceToken 失效（auth err）：用 passToken 静默刷新后以新凭据重试一次。
    // refreshServiceToken 内部有并发去重，fetchDaySummary 的多个并行请求只会触发一次刷新。
    if (response.statusCode == 401 && allowAuthRetry) {
      final refreshed = await _authService.refreshServiceToken();
      return _postEncrypted(
        path: path,
        payload: payload,
        credentials: refreshed,
        allowAuthRetry: false,
      );
    }

    if (response.statusCode != 200) {
      throw Exception('小米云端接口响应异常 HTTP ${response.statusCode}: ${response.data}');
    }

    final rawNonce = encFormData['_nonce']!;
    final decrypted = MiFitnessCrypto.decryptResponse(
      ssecurityB64: credentials.ssecurity,
      nonceB64: rawNonce,
      responseBodyText: response.data.toString(),
    );

    return decrypted;
  }

  /// 拉取指定时间段的某种健康指标数据（如 steps, sleep, heart_rate, spo2, stress）
  Future<List<Map<String, dynamic>>> fetchFitnessData({
    required DateTime startTime,
    required DateTime endTime,
    required String key,
  }) async {
    final credentials = await _authService.loadCredentials();
    if (credentials == null) {
      throw Exception('未登录小米运动健康账号');
    }

    const path = '/app/v1/data/get_fitness_data_by_time';
    final payload = {
      'start_time': startTime.millisecondsSinceEpoch ~/ 1000,
      'end_time': endTime.millisecondsSinceEpoch ~/ 1000,
      'key': key,
      'reverse': false,
    };

    final res = await _postEncrypted(
      path: path,
      payload: payload,
      credentials: credentials,
    );

    if (res is Map && res['code'] == 0 && res['result'] != null) {
      final list = res['result']['data_list'];
      if (list is List) {
        return list.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }

  /// 容灾拉取站立/活动数据（依次尝试 valid_stand, stand, standing, activity）
  Future<List<Map<String, dynamic>>> _fetchStandingData({
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    const candidateKeys = ['valid_stand', 'stand', 'standing', 'activity'];
    for (final key in candidateKeys) {
      try {
        final list = await fetchFitnessData(startTime: startTime, endTime: endTime, key: key);
        if (list.isNotEmpty) {
          LoggerService.instance.info('MiFitness standing data fetched successfully with key: $key, count: ${list.length}');
          return list;
        }
      } catch (e) {
        LoggerService.instance.warning('MiFitness fetchFitnessData failed for key $key: $e');
      }
    }
    return [];
  }

  /// 获取指定单日的完整健康汇总指标
  Future<HealthDailyMetrics> fetchDaySummary(DateTime date) async {
    final startOfDay = DateTime(date.year, date.month, date.day, 0, 0, 0);
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);
    final dateStr = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    // 睡眠查询窗口扩展到前一天 12:00，确保能捞到跨午夜睡眠（前晚入睡→当天醒来）
    final sleepQueryStart = startOfDay.subtract(const Duration(hours: 12));

    // 并行拉取各维度的指标（站立优先使用多候选 Key 容灾拉取）
    final results = await Future.wait([
      fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'steps').catchError((e) => <Map<String, dynamic>>[]),
      fetchFitnessData(startTime: sleepQueryStart, endTime: endOfDay, key: 'sleep').catchError((e) => <Map<String, dynamic>>[]),
      fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'heart_rate').catchError((e) => <Map<String, dynamic>>[]),
      fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'spo2').catchError((e) => <Map<String, dynamic>>[]),
      fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'stress').catchError((e) => <Map<String, dynamic>>[]),
      _fetchStandingData(startTime: startOfDay, endTime: endOfDay).catchError((e) => <Map<String, dynamic>>[]),
    ]);

    final stepsData = results[0];
    final sleepData = results[1];
    final hrData = results[2];
    final spo2Data = results[3];
    final stressData = results[4];
    final standingData = results[5];

    // 1. 步数处理与分钟去重 (解决手表与手机同时计步虚高)
    int totalSteps = 0;
    double totalDistance = 0.0;
    double totalCalories = 0.0;
    final minuteStepMap = <int, int>{};

    for (final item in stepsData) {
      final time = (item['time'] as num?)?.toInt() ?? 0;
      final minuteBucket = time ~/ 60;
      try {
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;
        final st = (valJson['steps'] as num?)?.toInt() ?? 0;
        final dist = (valJson['distance'] as num?)?.toDouble() ?? 0.0;
        final cal = (valJson['calories'] as num?)?.toDouble() ?? 0.0;

        if (!minuteStepMap.containsKey(minuteBucket) || st > minuteStepMap[minuteBucket]!) {
          minuteStepMap[minuteBucket] = st;
        }
        totalDistance += dist;
        totalCalories += cal;
      } catch (_) {}
    }
    totalSteps = minuteStepMap.values.fold(0, (sum, val) => sum + val);

    // 2. 睡眠解析（只保留醒来日 = 目标日期的睡眠记录）
    int sleepDuration = 0;
    int deepSleep = 0;
    int lightSleep = 0;
    int remSleep = 0;
    int awakeTime = 0;
    String? sleepStartStr;
    String? sleepEndStr;
    int? sleepScore;
    final sleepStages = <Map<String, dynamic>>[];

    for (final item in sleepData) {
      try {
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;

        final bedtime = valJson['bedtime'];
        final wakeup = valJson['wake_up_time'] ?? valJson['wake_time'];

        // 解析完整时间戳，用于判断醒来日是否匹配目标日期
        DateTime? wakeDt;
        if (wakeup != null) {
          wakeDt = DateTime.fromMillisecondsSinceEpoch((wakeup as num).toInt() * 1000);
        }
        // 只保留醒来日 = 目标日期的睡眠（跨午夜睡眠归属到醒来当天）
        if (wakeDt != null &&
            (wakeDt.year != date.year || wakeDt.month != date.month || wakeDt.day != date.day)) {
          continue;
        }

        if (bedtime != null) {
          final bt = DateTime.fromMillisecondsSinceEpoch((bedtime as num).toInt() * 1000);
          sleepStartStr = bt.toIso8601String();
        }
        if (wakeDt != null) {
          sleepEndStr = wakeDt.toIso8601String();
        }

        sleepDuration = (valJson['duration'] as num?)?.toInt() ?? sleepDuration;
        sleepScore = (valJson['score'] as num?)?.toInt() ?? sleepScore;

        if (valJson['items'] is List) {
          for (final stg in valJson['items']) {
            if (stg is Map) {
              final state = stg['state'] as int? ?? 0;
              final st = (stg['start_time'] as num?)?.toInt() ?? 0;
              final et = (stg['end_time'] as num?)?.toInt() ?? 0;
              final durMin = (et - st) ~/ 60;
              if (state == 1) deepSleep += durMin;
              if (state == 2 || state == 3) lightSleep += durMin;
              if (state == 4) awakeTime += durMin;
              if (state == 5) remSleep += durMin;
              sleepStages.add({
                'state': state,
                'start': st,
                'end': et,
                'duration': durMin,
              });
            }
          }
        }
      } catch (e) {
        LoggerService.instance.warning('Failed to parse sleep item: $e');
      }
    }

    if (sleepDuration == 0 && (deepSleep + lightSleep + remSleep) > 0) {
      sleepDuration = deepSleep + lightSleep + remSleep;
    }

    // 3. 心率曲线与极值
    final hrSamples = <Map<String, dynamic>>[];
    int hrSum = 0;
    int? hrMax;
    int? hrMin;
    int? restingHr;

    for (final item in hrData) {
      try {
        final t = (item['time'] as num?)?.toInt() ?? 0;
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;
        final bpm = (valJson['bpm'] as num?)?.toInt();
        if (bpm != null && bpm > 30 && bpm < 240) {
          hrSamples.add({'t': t, 'v': bpm});
          hrSum += bpm;
          if (hrMax == null || bpm > hrMax) hrMax = bpm;
          if (hrMin == null || bpm < hrMin) hrMin = bpm;
        }
        if (valJson.containsKey('resting_bpm')) {
          restingHr = (valJson['resting_bpm'] as num?)?.toInt();
        }
      } catch (_) {}
    }
    final avgHr = hrSamples.isNotEmpty ? (hrSum ~/ hrSamples.length) : null;

    // 4. 血氧数据
    final spo2Samples = <Map<String, dynamic>>[];
    int spo2Sum = 0;
    int? spo2Min;
    for (final item in spo2Data) {
      try {
        final t = (item['time'] as num?)?.toInt() ?? 0;
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;
        final spo2 = (valJson['spo2'] as num?)?.toInt();
        if (spo2 != null && spo2 > 50 && spo2 <= 100) {
          spo2Samples.add({'t': t, 'v': spo2});
          spo2Sum += spo2;
          if (spo2Min == null || spo2 < spo2Min) spo2Min = spo2;
        }
      } catch (_) {}
    }
    final avgSpo2 = spo2Samples.isNotEmpty ? (spo2Sum ~/ spo2Samples.length) : null;

    // 5. 压力数据
    final stressSamples = <Map<String, dynamic>>[];
    int stressSum = 0;
    int? stressMax;
    for (final item in stressData) {
      try {
        final t = (item['time'] as num?)?.toInt() ?? 0;
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;
        final stress = (valJson['stress'] as num?)?.toInt();
        if (stress != null && stress >= 0 && stress <= 100) {
          stressSamples.add({'t': t, 'v': stress});
          stressSum += stress;
          if (stressMax == null || stress > stressMax) stressMax = stress;
        }
      } catch (_) {}
    }
    final avgStress = stressSamples.isNotEmpty ? (stressSum ~/ stressSamples.length) : null;

    // 6. 站立次数解析（支持多协议兼容、非标准结构与小时区间去重）
    final totalStanding = parseStandingCount(standingData, date);

    return HealthDailyMetrics(
      date: dateStr,
      steps: totalSteps,
      distanceMeters: totalDistance,
      calories: totalCalories,
      activeMinutes: minuteStepMap.length,
      standingCount: totalStanding,
      sleepDurationMinutes: sleepDuration,
      deepSleepMinutes: deepSleep,
      lightSleepMinutes: lightSleep,
      remSleepMinutes: remSleep,
      awakeMinutes: awakeTime,
      sleepStartTime: sleepStartStr,
      sleepEndTime: sleepEndStr,
      sleepScore: sleepScore,
      avgHeartRate: avgHr,
      maxHeartRate: hrMax,
      minHeartRate: hrMin,
      restingHeartRate: restingHr,
      avgSpo2: avgSpo2,
      minSpo2: spo2Min,
      avgStress: avgStress,
      maxStress: stressMax,
      heartRateSamplesJson: json.encode(hrSamples),
      spo2SamplesJson: json.encode(spo2Samples),
      stressSamplesJson: json.encode(stressSamples),
      sleepStagesJson: json.encode(sleepStages),
      source: 'mi_fitness',
      updatedAt: DateTime.now(),
    );
  }

  /// 拉取指定时间段内的单次运动记录
  Future<List<HealthSportRecord>> fetchSportRecords({
    required DateTime startTime,
    required DateTime endTime,
    int limit = 50,
  }) async {
    final credentials = await _authService.loadCredentials();
    if (credentials == null) {
      throw Exception('未登录小米运动健康账号');
    }

    const path = '/app/v1/data/get_sport_records_by_time';
    final payload = {
      'start_time': startTime.millisecondsSinceEpoch ~/ 1000,
      'end_time': endTime.millisecondsSinceEpoch ~/ 1000,
      'limit': limit,
      'category': null,
      'reverse': true,
      'next_key': null,
    };

    final res = await _postEncrypted(
      path: path,
      payload: payload,
      credentials: credentials,
    );

    final sportRecords = <HealthSportRecord>[];
    if (res is Map && res['code'] == 0 && res['result'] != null) {
      final list = res['result']['sport_records'];
      if (list is List) {
        for (final item in list) {
          if (item is Map) {
            try {
              final sid = item['sid']?.toString() ?? '';
              final valStr = item['value'] as String? ?? '{}';
              final val = json.decode(valStr) as Map<String, dynamic>;

              final startSec = (val['start_time'] as num?)?.toInt() ??
                  (item['time'] as num?)?.toInt() ??
                  0;
              final endSec = (val['end_time'] as num?)?.toInt() ?? startSec;
              final duration = (val['duration'] as num?)?.toInt() ?? (endSec - startSec);
              final dist = (val['distance'] as num?)?.toDouble() ?? 0.0;
              final cal = (val['calories'] as num?)?.toDouble() ??
                  (val['total_cal'] as num?)?.toDouble() ??
                  0.0;
              final category = _mapCategory(val['sport_type'] ?? item['category']);
              final title = _mapTitle(category, val['sport_type']);

              sportRecords.add(HealthSportRecord(
                id: sid.isNotEmpty ? sid : 'sport_$startSec',
                sid: sid,
                category: category,
                title: title,
                startTime: DateTime.fromMillisecondsSinceEpoch(startSec * 1000),
                endTime: DateTime.fromMillisecondsSinceEpoch(endSec * 1000),
                durationSeconds: duration,
                distanceMeters: dist,
                calories: cal,
                avgPace: (val['avg_pace'] as num?)?.toDouble(),
                maxPace: (val['max_pace'] as num?)?.toDouble(),
                avgSpeed: (val['avg_speed'] as num?)?.toDouble(),
                avgHeartRate: (val['avg_hrm'] as num?)?.toInt(),
                maxHeartRate: (val['max_hrm'] as num?)?.toInt(),
                steps: (val['steps'] as num?)?.toInt(),
                avgCadence: (val['avg_cadence'] as num?)?.toInt(),
                detailJson: valStr,
                source: 'mi_fitness',
                createdAt: DateTime.now(),
              ));
            } catch (e) {
              LoggerService.instance.warning('Failed to parse sport record item: $e');
            }
          }
        }
      }
    }

    return sportRecords;
  }

  String _mapCategory(dynamic sportType) {
    final typeStr = sportType?.toString().toLowerCase() ?? '';
    if (typeStr.contains('run') || typeStr == '1' || typeStr == '7') return 'running';
    if (typeStr.contains('cycl') || typeStr.contains('bike') || typeStr == '9' || typeStr == '10') return 'cycling';
    if (typeStr.contains('walk') || typeStr == '6') return 'walking';
    if (typeStr.contains('swim') || typeStr == '8') return 'swimming';
    if (typeStr.contains('hike')) return 'hiking';
    return 'workout';
  }

  String _mapTitle(String category, dynamic sportType) {
    switch (category) {
      case 'running':
        return '跑步训练';
      case 'cycling':
        return '骑行运动';
      case 'walking':
        return '健走记录';
      case 'swimming':
        return '游泳训练';
      case 'hiking':
        return '登山徒步';
      default:
        return '日常运动';
    }
  }

  /// 解析站立/活动次数（支持多协议兼容、非标准 value 结构与小时事件打点去重）
  static int parseStandingCount(List<Map<String, dynamic>> standingData, DateTime date) {
    int totalStanding = 0;
    int? dailyReportStanding;
    final standingHourSet = <int>{};

    for (final item in standingData) {
      try {
        // 1. 时间戳提取：支持 time, update_time, start_time, timestamp，兼容秒(10位)与毫秒(13位)
        final rawTs = (item['time'] ?? item['update_time'] ?? item['start_time'] ?? item['timestamp']) as num?;
        int timeSec = rawTs?.toInt() ?? 0;
        if (timeSec > 10000000000) {
          timeSec ~/= 1000;
        }

        // 2. 标签提取
        final tag = item['tag']?.toString() ?? '';

        // 3. 解析 value 结构（支持 Map, num, bool, 字符串形式）
        num? standVal;
        bool? explicitHasStand;
        final rawValue = item['value'];

        if (rawValue is num) {
          standVal = rawValue;
        } else if (rawValue is bool) {
          explicitHasStand = rawValue;
        } else if (rawValue is Map) {
          standVal = _extractStandNum(rawValue);
          explicitHasStand = _extractHasStandBool(rawValue);
        } else if (rawValue is String) {
          final trimmed = rawValue.trim();
          if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
            try {
              final decoded = json.decode(trimmed);
              if (decoded is Map) {
                standVal = _extractStandNum(decoded);
                explicitHasStand = _extractHasStandBool(decoded);
              }
            } catch (_) {}
          } else {
            // 纯数字或布尔文本，如 "1", "12", "true", "false"
            final parsedNum = num.tryParse(trimmed);
            if (parsedNum != null) {
              standVal = parsedNum;
            } else if (trimmed.toLowerCase() == 'true') {
              explicitHasStand = true;
            } else if (trimmed.toLowerCase() == 'false') {
              explicitHasStand = false;
            }
          }
        }

        // 4. 若带有 daily_report 标签，此为官方聚合日汇总
        if (tag == 'daily_report' && standVal != null && standVal > 0) {
          dailyReportStanding = standVal.toInt();
        }

        // 5. 若单项 count > 1 且未有日结汇总，通常也是已聚合的日汇总值
        if (standVal != null && standVal.toInt() > 1 && dailyReportStanding == null) {
          dailyReportStanding = standVal.toInt();
        }

        // 6. 有效站立事件打点认定：
        // 凡出现在 valid_stand / stand / standing 中的记录，本身即代表该时段发生了有效活动/站立，
        // 除非该记录显式标记为 0、无站立或 false
        final isExplicitlyInactive = (standVal != null && standVal <= 0) || (explicitHasStand == false);
        final isStandingEvent = !isExplicitlyInactive;

        if (timeSec > 0 && isStandingEvent) {
          final dt = DateTime.fromMillisecondsSinceEpoch(timeSec * 1000);
          if (dt.year == date.year && dt.month == date.month && dt.day == date.day) {
            standingHourSet.add(dt.hour);
          }
        }
      } catch (e) {
        LoggerService.instance.warning('Failed to parse standing item: $e');
      }
    }

    if (dailyReportStanding != null && dailyReportStanding > 0) {
      totalStanding = dailyReportStanding;
    } else if (standingHourSet.isNotEmpty) {
      totalStanding = standingHourSet.length;
    } else {
      // 兜底：若以上皆为0，检查是否有有效记录总数
      totalStanding = standingData.where((item) {
        final val = item['value'];
        if (val is num) return val > 0;
        if (val is bool) return val;
        if (val is String) {
          final trimmed = val.trim();
          if (trimmed == '0' || trimmed.toLowerCase() == 'false') return false;
        }
        return true;
      }).length;
    }

    LoggerService.instance.info(
      'MiFitness standing parsed: total=$totalStanding, hours=${standingHourSet.toList()}, '
      'dailyReport=$dailyReportStanding, rawItems=${standingData.length}',
    );

    return totalStanding;
  }

  static num? _extractStandNum(Map<dynamic, dynamic> map) {
    const keys = [
      'count',
      'standing_count',
      'stand_count',
      'standing',
      'stand',
      'value',
      'val',
      'effective_stand',
      'activity_count',
    ];
    for (final k in keys) {
      final v = map[k];
      if (v is num) return v;
      if (v is String) {
        final parsed = num.tryParse(v);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static bool? _extractHasStandBool(Map<dynamic, dynamic> map) {
    const keys = ['has_stand', 'is_stand', 'is_valid', 'status', 'effective'];
    for (final k in keys) {
      final v = map[k];
      if (v is bool) return v;
      if (v is num) return v > 0;
      if (v is String) {
        if (v.toLowerCase() == 'true' || v == '1') return true;
        if (v.toLowerCase() == 'false' || v == '0') return false;
      }
    }
    return null;
  }
}

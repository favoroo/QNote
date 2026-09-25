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

/// 小米单日睡眠聚合结果（一天可能包含多段：跨夜段 + 午睡段）
class MiSleepSummary {
  const MiSleepSummary({
    this.durationMinutes = 0,
    this.deepMinutes = 0,
    this.lightMinutes = 0,
    this.remMinutes = 0,
    this.awakeMinutes = 0,
    this.mainStartTime,
    this.mainEndTime,
    this.mainScore,
    this.stages = const [],
  });

  /// 各段时长之和，对齐小米「全天睡眠」口径
  final int durationMinutes;
  final int deepMinutes;
  final int lightMinutes;
  final int remMinutes;
  final int awakeMinutes;

  /// 主睡眠段（时长最长的那一段）的入睡/醒来 ISO8601 与评分
  final String? mainStartTime;
  final String? mainEndTime;
  final int? mainScore;

  /// 全部分期采样，跨段累加
  final List<Map<String, dynamic>> stages;
}

/// 小米单日步数合并结果（多来源样本按小时选主源后汇总）
class MiStepSummary {
  const MiStepSummary({
    required this.steps,
    required this.distanceMeters,
    required this.calories,
    required this.sampledMinutes,
  });

  final int steps;
  final double distanceMeters;

  /// 全来源累加，不走主源口径
  final double calories;

  /// 有步数采样的分钟数
  final int sampledMinutes;
}

/// 单条步数样本的来源、时间桶与取值
class _MiStepSample {
  const _MiStepSample({
    required this.sid,
    required this.minute,
    required this.hour,
    required this.steps,
    required this.distanceMeters,
    required this.calories,
  });

  final String sid;
  final int minute;
  final int hour;
  final int steps;
  final double distanceMeters;
  final double calories;
}

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
    //
    // 单个指标报错容忍为空（设备可能不支持 spo2/stress），但 6 个直接请求一起抛异常绝不是「这天没数据」——
    // 真没数据时云端回 code=0 + 空列表、不走异常。这种情况是登录态或网络故障，必须抛出而不是返回全 0，
    // 否则会把库里已有的真实数据抹成空白（历史踩坑：serviceToken 过期后整周同步成 0 步）。
    final failures = <Object>[];
    Future<List<Map<String, dynamic>>> guarded(
      Future<List<Map<String, dynamic>>> Function() fetch,
    ) async {
      try {
        return await fetch();
      } catch (e) {
        failures.add(e);
        return <Map<String, dynamic>>[];
      }
    }

    // 不含站立：站立链内部已多 Key 容灾，不会向外抛
    const directFetchCount = 6;
    final results = await Future.wait([
      guarded(() => fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'steps')),
      guarded(() => fetchFitnessData(startTime: sleepQueryStart, endTime: endOfDay, key: 'sleep')),
      guarded(() => fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'heart_rate')),
      guarded(() => fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'spo2')),
      guarded(() => fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'stress')),
      _fetchStandingData(startTime: startOfDay, endTime: endOfDay),
      guarded(() => fetchFitnessData(startTime: startOfDay, endTime: endOfDay, key: 'resting_heart_rate')),
    ]);
    if (failures.length >= directFetchCount) throw failures.first;

    final stepsData = results[0];
    final sleepData = results[1];
    final hrData = results[2];
    final spo2Data = results[3];
    final stressData = results[4];
    final standingData = results[5];
    final restingHrData = results[6];

    // 1. 步数与距离：多来源样本按小时选主源合并（见 parseStepSummary）
    final stepSummary = parseStepSummary(stepsData);
    final totalSteps = stepSummary.steps;
    final totalDistance = stepSummary.distanceMeters;
    final totalCalories = stepSummary.calories;
    final sampledMinutes = stepSummary.sampledMinutes;

    // 2. 睡眠解析（一天可能多段：时长跨段累加，起止与评分取主睡眠段）
    final sleep = parseSleepSummary(sleepData, date);

    // 3. 心率曲线与极值
    final hrSamples = <Map<String, dynamic>>[];
    int hrSum = 0;
    int? hrMax;
    int? hrMin;

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
      } catch (_) {}
    }
    final avgHr = hrSamples.isNotEmpty ? (hrSum ~/ hrSamples.length) : null;
    // 静息心率在独立的 resting_heart_rate key 里；heart_rate 样本只有 time/bpm/type，
    // 旧代码在样本里找一个不存在的 resting_bpm 字段，导致这一格永远显示 --
    final restingHr = parseRestingHeartRate(restingHrData);

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
      activeMinutes: sampledMinutes,
      standingCount: totalStanding,
      sleepDurationMinutes: sleep.durationMinutes,
      deepSleepMinutes: sleep.deepMinutes,
      lightSleepMinutes: sleep.lightMinutes,
      remSleepMinutes: sleep.remMinutes,
      awakeMinutes: sleep.awakeMinutes,
      sleepStartTime: sleep.mainStartTime,
      sleepEndTime: sleep.mainEndTime,
      sleepScore: sleep.mainScore,
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
      sleepStagesJson: json.encode(sleep.stages),
      source: 'mi_fitness',
      updatedAt: DateTime.now(),
    );
  }

  /// 解析当日静息心率（云端 `resting_heart_rate` 独立 key，value 为 `{bpm, date_time}`）
  ///
  /// 实测每天一条；出现多条时（多设备各报一份、或当天重算）按 `update_time` 取最新那条，
  /// 与小米「以当日最后一次结算为准」的展示口径一致。
  static int? parseRestingHeartRate(List<Map<String, dynamic>> data) {
    int? bpm;
    int latestWrite = -1;
    for (final item in data) {
      try {
        final valJson = json.decode(item['value'] as String? ?? '{}') as Map<String, dynamic>;
        final v = (valJson['bpm'] as num?)?.toInt();
        if (v == null || v <= 20 || v >= 200) continue;
        final write = (item['update_time'] as num?)?.toInt() ?? (item['time'] as num?)?.toInt() ?? 0;
        if (bpm == null || write >= latestWrite) {
          bpm = v;
          latestWrite = write;
        }
      } catch (_) {}
    }
    return bpm;
  }

  /// 合并小米云端按分钟切片的步数样本，得到与小米 App 一致的日汇总
  ///
  /// 同一段步行会被多条来源各上报一份（`sid` 即来源：手机是 `hlth.gen_*`、手环/手表是设备号），
  /// 逐分钟跨来源取最大值会把这些重复全天累加，实测比小米首页恒定多算 4.4%。
  /// 改为逐小时选主源——每小时只统计「该小时步数最多的那条序列」的分钟，与小米的
  /// 「多数据源融合」对齐后，6 天实测误差 +0.5%，距离日均 4.89 km（官方 4.91 km）。
  /// 卡路里不走主源：只取单条会偏低约 280 kcal，全来源累加才最接近官方（±9%）。
  static MiStepSummary parseStepSummary(List<Map<String, dynamic>> stepsData) {
    final samples = <_MiStepSample>[];

    for (final item in stepsData) {
      final time = (item['time'] as num?)?.toInt() ?? 0;
      try {
        final val = json.decode(item['value'] as String? ?? '{}') as Map<String, dynamic>;
        samples.add(_MiStepSample(
          sid: item['sid']?.toString() ?? '',
          minute: time ~/ 60,
          hour: time ~/ 3600,
          steps: (val['steps'] as num?)?.toInt() ?? 0,
          distanceMeters: (val['distance'] as num?)?.toDouble() ?? 0.0,
          calories: (val['calories'] as num?)?.toDouble() ?? 0.0,
        ));
      } catch (_) {}
    }

    // 每小时定主源
    final hourTotals = <int, Map<String, int>>{};
    for (final s in samples) {
      final bySid = hourTotals.putIfAbsent(s.hour, () => <String, int>{});
      bySid[s.sid] = (bySid[s.sid] ?? 0) + s.steps;
    }
    final primarySid = <int, String>{};
    hourTotals.forEach((hour, bySid) {
      primarySid[hour] = bySid.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    });

    // 只留主源样本，同一分钟重复上报时取步数较大的那条
    final kept = <int, _MiStepSample>{};
    for (final s in samples) {
      if (primarySid[s.hour] != s.sid) continue;
      final cur = kept[s.minute];
      if (cur == null || s.steps > cur.steps) kept[s.minute] = s;
    }

    return MiStepSummary(
      steps: kept.values.fold(0, (a, b) => a + b.steps),
      distanceMeters: kept.values.fold<double>(0, (a, b) => a + b.distanceMeters),
      // 卡路里刻意保持「全来源累加」，与步数/距离的逐小时选主源不同口径：
      // 见 test/core/health/mi_fitness_steps_test.dart 的既定用例。是否应按主源去重尚未定案。
      calories: samples.fold<double>(0, (a, b) => a + b.calories),
      sampledMinutes: kept.length,
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
    // 云端 category 直接用蛇形命名（实测有 strength_training），
    // 不识别会被兜成「日常运动」，力量训练看起来就像随便一次锻炼
    if (typeStr.contains('strength') || typeStr.contains('gym')) return 'strength';
    if (typeStr.contains('interval') || typeStr.contains('circuit')) return 'circuit';
    if (typeStr.contains('yoga') || typeStr.contains('pilates')) return 'yoga';
    if (typeStr.contains('elliptical')) return 'elliptical';
    if (typeStr.contains('rowing')) return 'rowing';
    if (typeStr.contains('rope')) return 'rope';
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
      case 'strength':
        return '力量训练';
      case 'circuit':
        return '间歇循环训练';
      case 'yoga':
        return '瑜伽';
      case 'elliptical':
        return '椭圆机';
      case 'rowing':
        return '划船机';
      case 'rope':
        return '跳绳';
      default:
        return '日常运动';
    }
  }

  /// 解析单日睡眠（支持一天多段：跨夜段 + 午睡段）
  ///
  /// 小米云端把每段睡眠作为独立 item 返回，且请求 `reverse: false` 按时间升序，
  /// 若按「最后一段胜出」会让午睡覆盖整夜睡眠（曾导致一天只记 20 分钟）。
  /// 因此时长与分期跨段累加，入睡/醒来/评分只取最长的那一段。
  static MiSleepSummary parseSleepSummary(
    List<Map<String, dynamic>> sleepData,
    DateTime date,
  ) {
    int durationMinutes = 0;
    int deepSleep = 0;
    int lightSleep = 0;
    int remSleep = 0;
    int awakeTime = 0;
    final sleepStages = <Map<String, dynamic>>[];
    final seenSegments = <String>{};

    String? mainStartTime;
    String? mainEndTime;
    int? mainScore;
    // 用 -1 起算，保证只要有合格段就一定能锚定主睡眠
    int mainSegmentMinutes = -1;

    for (final item in sleepData) {
      try {
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;

        final rawBedtime = valJson['bedtime'];
        final rawWake = valJson['wake_up_time'] ?? valJson['wake_time'];
        final bedtimeSec = rawBedtime is num ? rawBedtime.toInt() : null;
        int? wakeSec = rawWake is num ? rawWake.toInt() : null;
        final reportedDuration = (valJson['duration'] as num?)?.toInt() ?? 0;

        // 缺醒来时间时用「入睡 + 时长」推导；仍推不出说明该段尚未结算（睡眠进行中），
        // 不计入当天，下次同步会带上完整段
        if (wakeSec == null && bedtimeSec != null && reportedDuration > 0) {
          wakeSec = bedtimeSec + reportedDuration * 60;
        }
        if (wakeSec == null) {
          continue;
        }

        // 只保留醒来日 = 目标日期的睡眠（跨午夜睡眠归属到醒来当天）
        final wakeDt = DateTime.fromMillisecondsSinceEpoch(wakeSec * 1000);
        if (wakeDt.year != date.year || wakeDt.month != date.month || wakeDt.day != date.day) {
          continue;
        }

        // 手环与手机可能重复上报同一段，按起止时间戳去重避免双计
        if (!seenSegments.add('$bedtimeSec-$wakeSec')) {
          continue;
        }

        int segDeep = 0;
        int segLight = 0;
        int segRem = 0;
        int segAwake = 0;
        int segmentStageMinutes = 0;
        if (valJson['items'] is List) {
          for (final stg in valJson['items']) {
            if (stg is Map) {
              final state = stg['state'] as int? ?? 0;
              final st = (stg['start_time'] as num?)?.toInt() ?? 0;
              final et = (stg['end_time'] as num?)?.toInt() ?? 0;
              final durMin = (et - st) ~/ 60;
              // 小米云端 state 枚举实测为 2=深睡 3=浅睡 4=快速眼动 5=清醒（state=1 从不出现）。
              // 旧代码按 1=深睡/2,3=浅睡/4=清醒/5=REM 映射，结果深睡恒为 0、REM 与清醒互换。
              if (state == 2) {
                segDeep += durMin;
              } else if (state == 3) {
                segLight += durMin;
              } else if (state == 4) {
                segRem += durMin;
              } else if (state == 5) {
                segAwake += durMin;
              }
              segmentStageMinutes += durMin;
              sleepStages.add({
                'state': state,
                'start': st,
                'end': et,
                'duration': durMin,
              });
            }
          }
        }

        // 四期时长以云端自己算好的聚合值为权威口径，直接取用；整段都没带这些字段时
        // （如未结算的小睡段）才退回上面按 items 反推的结果。
        if (valJson.containsKey('sleep_deep_duration') ||
            valJson.containsKey('sleep_light_duration') ||
            valJson.containsKey('sleep_rem_duration') ||
            valJson.containsKey('sleep_awake_duration')) {
          deepSleep += (valJson['sleep_deep_duration'] as num?)?.toInt() ?? 0;
          lightSleep += (valJson['sleep_light_duration'] as num?)?.toInt() ?? 0;
          remSleep += (valJson['sleep_rem_duration'] as num?)?.toInt() ?? 0;
          awakeTime += (valJson['sleep_awake_duration'] as num?)?.toInt() ?? 0;
        } else {
          deepSleep += segDeep;
          lightSleep += segLight;
          remSleep += segRem;
          awakeTime += segAwake;
        }

        // duration 单位是分钟；缺失时退回该段分期之和，让总时长与分期口径保持一致
        final segmentMinutes = reportedDuration > 0 ? reportedDuration : segmentStageMinutes;
        durationMinutes += segmentMinutes;

        // 主睡眠取最长段；等长时因严格大于而保留较早那段（夜睡优先于午睡）
        if (segmentMinutes > mainSegmentMinutes) {
          mainSegmentMinutes = segmentMinutes;
          mainScore = (valJson['score'] as num?)?.toInt();
          mainStartTime = bedtimeSec != null
              ? DateTime.fromMillisecondsSinceEpoch(bedtimeSec * 1000).toIso8601String()
              : null;
          mainEndTime = wakeDt.toIso8601String();
        }
      } catch (e) {
        LoggerService.instance.warning('Failed to parse sleep item: $e');
      }
    }

    LoggerService.instance.info(
      'MiFitness sleep parsed for ${date.toIso8601String()}: total=$durationMinutes min, '
      'segments=${seenSegments.length}, main=$mainStartTime~$mainEndTime',
    );

    return MiSleepSummary(
      durationMinutes: durationMinutes,
      deepMinutes: deepSleep,
      lightMinutes: lightSleep,
      remMinutes: remSleep,
      awakeMinutes: awakeTime,
      mainStartTime: mainStartTime,
      mainEndTime: mainEndTime,
      mainScore: mainScore,
      stages: sleepStages,
    );
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

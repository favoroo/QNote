import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_api_client.dart';

/// 秒级时间戳（小米云端睡眠记录的 bedtime / wake_up_time 均为秒）
int _sec(DateTime dt) => dt.millisecondsSinceEpoch ~/ 1000;

/// 构造一段睡眠记录（value 为字符串形式的 JSON，与小米接口返回结构一致）
///
/// 传入 deep/light/rem/awake 任一项即模拟云端自带的四期聚合字段（真实接口的常态）。
Map<String, dynamic> _sleepItem({
  DateTime? bedtime,
  DateTime? wake,
  int? duration,
  int? score,
  int? deep,
  int? light,
  int? rem,
  int? awake,
  List<Map<String, dynamic>> items = const [],
}) {
  final value = <String, dynamic>{'items': items};
  if (bedtime != null) value['bedtime'] = _sec(bedtime);
  if (wake != null) value['wake_up_time'] = _sec(wake);
  if (duration != null) value['duration'] = duration;
  if (score != null) value['score'] = score;
  if (deep != null) value['sleep_deep_duration'] = deep;
  if (light != null) value['sleep_light_duration'] = light;
  if (rem != null) value['sleep_rem_duration'] = rem;
  if (awake != null) value['sleep_awake_duration'] = awake;
  return {
    'time': _sec(bedtime ?? wake ?? DateTime(2026, 9, 19)),
    'value': json.encode(value),
  };
}

/// 构造一个睡眠分期采样
///
/// 小米云端 state 枚举实测为：2=深睡、3=浅睡、4=快速眼动、5=清醒（1 从不出现）。
Map<String, dynamic> _stage(int state, DateTime start, DateTime end) => {
      'state': state,
      'start_time': _sec(start),
      'end_time': _sec(end),
    };

void main() {
  group('MiFitnessApiClient parseSleepSummary', () {
    final testDate = DateTime(2026, 9, 19);

    // 真实场景（2026-09-19）：跨夜段 9/18 23:39 → 9/19 06:31 共 409 分钟，
    // 午睡段 13:47 → 14:07 共 20 分钟。小米「全天睡眠」为 7小时9分钟 = 429 分钟。
    final nightBedtime = DateTime(2026, 9, 18, 23, 39);
    final nightWake = DateTime(2026, 9, 19, 6, 31);
    final napBedtime = DateTime(2026, 9, 19, 13, 47);
    final napWake = DateTime(2026, 9, 19, 14, 7);

    // 分期按正确枚举解读为：深睡 178 / 浅睡 120 / REM 111 / 清醒 3（合计 412）
    final nightStages = [
      _stage(4, DateTime(2026, 9, 18, 23, 39), DateTime(2026, 9, 19, 0, 20)), // 41 分 REM
      _stage(2, DateTime(2026, 9, 19, 0, 20), DateTime(2026, 9, 19, 3, 0)), // 160 分深睡
      _stage(3, DateTime(2026, 9, 19, 3, 0), DateTime(2026, 9, 19, 5, 0)), // 120 分浅睡
      _stage(5, DateTime(2026, 9, 19, 5, 0), DateTime(2026, 9, 19, 5, 3)), // 3 分清醒
      _stage(4, DateTime(2026, 9, 19, 5, 3), DateTime(2026, 9, 19, 6, 13)), // 70 分 REM
      _stage(2, DateTime(2026, 9, 19, 6, 13), DateTime(2026, 9, 19, 6, 31)), // 18 分深睡
    ];
    final napStages = [
      _stage(2, napBedtime, napWake), // 20 分深睡
    ];

    final nightItem = _sleepItem(
      bedtime: nightBedtime,
      wake: nightWake,
      duration: 409,
      score: 85,
      items: nightStages,
    );
    final napItem = _sleepItem(
      bedtime: napBedtime,
      wake: napWake,
      duration: 20,
      score: 60,
      items: napStages,
    );

    test('跨夜段与午睡段累加，起止与评分取主睡眠段（回归用例）', () {
      // 接口按时间升序返回，午睡排在最后 —— 旧实现会让午睡覆盖跨夜段
      final res = MiFitnessApiClient.parseSleepSummary([nightItem, napItem], testDate);

      expect(res.durationMinutes, 429); // 409 + 20，对齐小米「全天睡眠 7小时9分钟」
      expect(res.mainStartTime, nightBedtime.toIso8601String());
      expect(res.mainEndTime, nightWake.toIso8601String());
      expect(res.mainScore, 85); // 取夜睡段评分，不被午睡的 60 覆盖
      expect(res.deepMinutes, 198); // 178 + 20（state 2）
      expect(res.lightMinutes, 120); // state 3
      expect(res.remMinutes, 111); // state 4
      expect(res.awakeMinutes, 3); // state 5
      expect(res.stages.length, 7); // 两段分期全部保留
    });

    test('主睡眠取最长段，不依赖列表顺序', () {
      // 故意把午睡放在前面
      final res = MiFitnessApiClient.parseSleepSummary([napItem, nightItem], testDate);

      expect(res.durationMinutes, 429);
      expect(res.mainStartTime, nightBedtime.toIso8601String());
      expect(res.mainEndTime, nightWake.toIso8601String());
      expect(res.mainScore, 85);
    });

    test('单日仅一段时行为与旧实现一致', () {
      final res = MiFitnessApiClient.parseSleepSummary([nightItem], testDate);

      expect(res.durationMinutes, 409);
      expect(res.mainStartTime, nightBedtime.toIso8601String());
      expect(res.mainEndTime, nightWake.toIso8601String());
      expect(res.mainScore, 85);
    });

    test('醒来日不是目标日期的段被过滤掉', () {
      // 前一天早上的那段（醒来日 9/18），不应计入 9/19
      final prevDayItem = _sleepItem(
        bedtime: DateTime(2026, 9, 17, 23, 0),
        wake: DateTime(2026, 9, 18, 7, 0),
        duration: 480,
        score: 90,
      );
      final res = MiFitnessApiClient.parseSleepSummary([prevDayItem, nightItem, napItem], testDate);

      expect(res.durationMinutes, 429);
      expect(res.mainScore, 85);
    });

    test('缺醒来时间时用「入睡 + 时长」推导并正确归属', () {
      final res = MiFitnessApiClient.parseSleepSummary(
        [
          _sleepItem(
            bedtime: DateTime(2026, 9, 19, 1, 0),
            duration: 120,
            score: 70,
          ),
        ],
        testDate,
      );

      expect(res.durationMinutes, 120);
      expect(res.mainStartTime, DateTime(2026, 9, 19, 1, 0).toIso8601String());
      expect(res.mainEndTime, DateTime(2026, 9, 19, 3, 0).toIso8601String());
    });

    test('无法确定醒来时间的段不计入（睡眠尚未结算）', () {
      // 旧实现里 wakeDt == null 会绕过醒来日过滤，被当成目标日数据
      final res = MiFitnessApiClient.parseSleepSummary(
        [
          _sleepItem(duration: 300, score: 80),
          _sleepItem(bedtime: DateTime(2026, 9, 19, 2, 0)),
        ],
        testDate,
      );

      expect(res.durationMinutes, 0);
      expect(res.mainStartTime, isNull);
      expect(res.mainEndTime, isNull);
      expect(res.mainScore, isNull);
    });

    test('手环与手机重复上报同一段时去重，不双计', () {
      final res = MiFitnessApiClient.parseSleepSummary(
        [nightItem, nightItem, napItem],
        testDate,
      );

      expect(res.durationMinutes, 429);
      expect(res.deepMinutes, 198);
      expect(res.lightMinutes, 120);
      expect(res.stages.length, 7);
    });

    test('duration 缺失时退回该段分期之和', () {
      final res = MiFitnessApiClient.parseSleepSummary(
        [
          _sleepItem(
            bedtime: nightBedtime,
            wake: nightWake,
            score: 85,
            items: nightStages,
          ),
        ],
        testDate,
      );

      expect(res.durationMinutes, 412); // 分期之和，与深睡/浅睡/REM/清醒口径一致
    });

    test('空数据返回全零', () {
      final res = MiFitnessApiClient.parseSleepSummary(const [], testDate);

      expect(res.durationMinutes, 0);
      expect(res.deepMinutes, 0);
      expect(res.lightMinutes, 0);
      expect(res.remMinutes, 0);
      expect(res.awakeMinutes, 0);
      expect(res.mainStartTime, isNull);
      expect(res.mainEndTime, isNull);
      expect(res.mainScore, isNull);
      expect(res.stages, isEmpty);
    });

    test('两段等长时主睡眠取较早那段', () {
      final earlyBedtime = DateTime(2026, 9, 19, 1, 0);
      final earlyWake = DateTime(2026, 9, 19, 2, 40);
      final lateBedtime = DateTime(2026, 9, 19, 13, 0);
      final lateWake = DateTime(2026, 9, 19, 14, 40);

      final res = MiFitnessApiClient.parseSleepSummary(
        [
          _sleepItem(bedtime: earlyBedtime, wake: earlyWake, duration: 100, score: 55),
          _sleepItem(bedtime: lateBedtime, wake: lateWake, duration: 100, score: 99),
        ],
        testDate,
      );

      expect(res.durationMinutes, 200);
      expect(res.mainStartTime, earlyBedtime.toIso8601String());
      expect(res.mainEndTime, earlyWake.toIso8601String());
      expect(res.mainScore, 55);
    });

    test('脏数据不炸：value 非法 JSON 时跳过该条', () {
      final res = MiFitnessApiClient.parseSleepSummary(
        [
          {'time': _sec(DateTime(2026, 9, 19, 10, 0)), 'value': 'not-json'},
          nightItem,
        ],
        testDate,
      );

      expect(res.durationMinutes, 409);
    });
  });

  group('MiFitnessApiClient parseSleepSummary 真实云端 payload（2026-09-25 抓取）', () {
    // 2026-09-25 00:10 → 07:27 的整夜段原文（state, start_time, end_time）
    const realStages = <List<int>>[
      [3, 1790266200, 1790266860],
      [2, 1790266860, 1790267700],
      [3, 1790267700, 1790268060],
      [2, 1790268060, 1790268240],
      [4, 1790268240, 1790268540],
      [2, 1790268540, 1790269080],
      [3, 1790269080, 1790269860],
      [4, 1790269860, 1790270580],
      [2, 1790270580, 1790270640],
      [3, 1790270640, 1790271840],
      [4, 1790271840, 1790272740],
      [2, 1790272740, 1790274120],
      [4, 1790274120, 1790275140],
      [2, 1790275140, 1790275980],
      [3, 1790275980, 1790276700],
      [4, 1790276700, 1790277180],
      [5, 1790277180, 1790278740],
      [4, 1790278740, 1790279820],
      [2, 1790279820, 1790280120],
      [4, 1790280120, 1790280420],
      [2, 1790280420, 1790281740],
      [3, 1790281740, 1790284500],
      [4, 1790284500, 1790284800],
      [2, 1790284800, 1790286900],
      [3, 1790286900, 1790289660],
      [4, 1790289660, 1790290440],
      [2, 1790290440, 1790290980],
      [3, 1790290980, 1790291940],
      [4, 1790291940, 1790292240],
      [3, 1790292240, 1790292420],
    ];

    // 云端为该段给出的权威四期时长，实测与上面 items 按 2深/3浅/4REM/5清醒 逐段之和完全相等
    const realDeep = 135;
    const realLight = 173;
    const realRem = 103;
    const realAwake = 26;

    Map<String, dynamic> realNightItem({
      bool withAggregates = true,
      int? overrideDeep,
    }) {
      final value = <String, dynamic>{
        'bedtime': 1790266200,
        'wake_up_time': 1790292420,
        'duration': 411,
        'items': realStages
            .map((s) => {'state': s[0], 'start_time': s[1], 'end_time': s[2]})
            .toList(),
      };
      if (withAggregates) {
        value['sleep_deep_duration'] = overrideDeep ?? realDeep;
        value['sleep_light_duration'] = realLight;
        value['sleep_rem_duration'] = realRem;
        value['sleep_awake_duration'] = realAwake;
      }
      return {'time': 1790266200, 'value': json.encode(value)};
    }

    final nightOf = DateTime(2026, 9, 25);

    test('带聚合字段：深睡不再是 0，REM 与清醒不再互换', () {
      final res = MiFitnessApiClient.parseSleepSummary([realNightItem()], nightOf);

      expect(res.deepMinutes, realDeep);
      expect(res.lightMinutes, realLight);
      expect(res.remMinutes, realRem);
      expect(res.awakeMinutes, realAwake);
      expect(res.durationMinutes, 411);
    });

    test('缺聚合字段时按 items 反推，结果与云端权威值一致', () {
      final res = MiFitnessApiClient.parseSleepSummary(
        [realNightItem(withAggregates: false)],
        nightOf,
      );

      expect(res.deepMinutes, realDeep);
      expect(res.lightMinutes, realLight);
      expect(res.remMinutes, realRem);
      expect(res.awakeMinutes, realAwake);
    });

    test('聚合字段与 items 冲突时以聚合字段为准', () {
      final res = MiFitnessApiClient.parseSleepSummary(
        [realNightItem(overrideDeep: 200)],
        nightOf,
      );

      expect(res.deepMinutes, 200);
      expect(res.lightMinutes, realLight);
    });
  });
}

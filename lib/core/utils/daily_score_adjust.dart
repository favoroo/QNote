import 'package:qnote_flutter/models/daily_score.dart';

/// 每日生活评分的可调字段。
///
/// 维度键名必须与 `lib/config/defaults.dart` 里 AI 输出的 `dimensionScores` 键一致，
/// 集中在这里是为了让 VFS 端点、统计页抽屉和单测共用一份口径，
/// 不再各处散落 `'diet'` 这类字面量。
enum ScoreField {
  total('total', '总分'),
  sleep('sleep', '睡眠'),
  diet('diet', '饮食'),
  activity('activity', '活动'),
  health('health', '健康'),
  screen('screen', '屏幕');

  const ScoreField(this.storageKey, this.label);

  /// 维度在 `dimension_scores` JSON 里的键；[total] 存独立列，键仅作展示用途。
  final String storageKey;
  final String label;

  bool get isDimension => this != ScoreField.total;

  static ScoreField? fromKey(String key) {
    final normalized = key.trim().toLowerCase();
    for (final field in ScoreField.values) {
      if (field.storageKey == normalized || field.label == key.trim()) {
        return field;
      }
    }
    return null;
  }
}

/// 全选作用面：「整体降 5 分」这类请求同时对总分与五个维度生效。
const Set<ScoreField> kAllScoreFields = {
  ScoreField.total,
  ScoreField.sleep,
  ScoreField.diet,
  ScoreField.activity,
  ScoreField.health,
  ScoreField.screen,
};

/// 一次调整意图：[delta] 与 [setValue] 二选一，作用于 [fields] 列出的字段。
class ScoreAdjustSpec {
  const ScoreAdjustSpec({
    this.delta,
    this.setValue,
    required this.fields,
  }) : assert(
         (delta == null) != (setValue == null),
         'delta 与 setValue 必须且只能提供一个',
       );

  /// 相对加减分，可为负。
  final int? delta;

  /// 设为绝对值。
  final int? setValue;

  final Set<ScoreField> fields;

  bool get isAbsolute => setValue != null;
}

/// 单个字段的变更明细；[before] 为 null 表示该字段原本缺失。
class ScoreFieldChange {
  const ScoreFieldChange({
    required this.field,
    required this.before,
    required this.after,
    required this.clamped,
  });

  final ScoreField field;
  final int? before;
  final int after;

  /// 目标值是否触到 0/100 上下限。
  final bool clamped;

  String get label => '${before ?? '—'} → $after';
}

/// 单日调整结果。
class ScoreAdjustOutcome {
  const ScoreAdjustOutcome({
    required this.before,
    required this.after,
    required this.changes,
  });

  final DailyScore before;
  final DailyScore after;
  final List<ScoreFieldChange> changes;

  bool get changed => changes.isNotEmpty;
  bool get clamped => changes.any((c) => c.clamped);
}

/// 把分值钳位到 0~100。
int clampScore(int value) => value < 0 ? 0 : (value > 100 ? 100 : value);

/// 对单日应用调整，返回改前/改后实体与逐字段明细。
///
/// 纯函数：不取当前时间、不碰数据库，`updated_at` 由仓储层负责。
/// 语义要点：
/// - 只改 [ScoreAdjustSpec.fields] 列出的字段，其余字段与 summary/suggestions 原样保留；
/// - 总分**不**按维度重算（AI 打分时两者是并列输出，重算会逐批漂移）；
/// - 加减分遇到原值缺失的维度直接跳过，不凭空造字段。
ScoreAdjustOutcome applyScoreAdjust(DailyScore existing, ScoreAdjustSpec spec) {
  final changes = <ScoreFieldChange>[];
  var total = existing.totalScore;
  final dims = Map<String, int>.from(existing.dimensionScores);

  for (final field in ScoreField.values) {
    if (!spec.fields.contains(field)) continue;

    final current = field.isDimension ? dims[field.storageKey] : total;
    final int target;
    if (spec.isAbsolute) {
      target = spec.setValue!;
    } else {
      if (current == null) continue;
      target = current + spec.delta!;
    }

    final applied = clampScore(target);
    if (applied == current) continue;

    changes.add(
      ScoreFieldChange(
        field: field,
        before: current,
        after: applied,
        clamped: applied != target,
      ),
    );
    if (field.isDimension) {
      dims[field.storageKey] = applied;
    } else {
      total = applied;
    }
  }

  final after = existing.copyWith(totalScore: total, dimensionScores: dims);
  return ScoreAdjustOutcome(before: existing, after: after, changes: changes);
}

/// 按键增量合并维度分：[incoming] 未出现的键一律保留 [existing] 的原值。
///
/// 这是「只改饮食分却把其余四维写成总分」那个缺陷的正解。
Map<String, int> mergeDimensionScores(
  Map<String, int> existing,
  Map<String, int> incoming,
) {
  final merged = Map<String, int>.from(existing);
  incoming.forEach((key, value) => merged[key] = value);
  return merged;
}

/// 预览摘要，统计页与端点返回值共用同一份文案口径。
String describeScoreAdjustPreview(
  List<ScoreAdjustOutcome> outcomes, {
  int missingDays = 0,
}) {
  final applied = outcomes.where((o) => o.changed).length;
  final parts = <String>['命中 $applied 天'];
  if (missingDays > 0) {
    parts.add('该区间无评分 $missingDays 天（不会被改动）');
  }
  final clampedDays = outcomes.where((o) => o.clamped).length;
  if (clampedDays > 0) {
    parts.add('$clampedDays 天已到上下限');
  }
  return parts.join(' · ');
}

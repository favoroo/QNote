/// 单餐热量的合理上限（千卡）。
///
/// AI 估算是粗略值，设上限只用于拦截明显异常的输出（如负数、把千焦当千卡、
/// 误把整日热量写成单餐），不是营养学意义上的严格上限。
const int maxMealCalories = 5000;

/// 归一化 AI 提取的饮食热量。
///
/// 接受数字或带单位的字符串（如 `620`、`620kcal`、`约620千卡`），只保留有限、
/// 正数且不超过 [maxMealCalories] 的值并取整；0、负数、无法解析或超出合理
/// 范围时返回 null，由调用方按「未填写热量」处理，不阻塞其余字段落库。
int? normalizeDietCalories(dynamic raw) {
  double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    final text = raw.trim().replaceAll(',', '');
    // 先整体解析，避免 "1e9" 被正则截成 "1" 后误判为合法值
    value = double.tryParse(text) ?? _parseCalorieFromText(text);
  }
  if (value == null || !value.isFinite || value <= 0 || value > maxMealCalories) {
    return null;
  }
  return value.round();
}

/// 从带说明的字符串里提取热量。
///
/// 优先取带 kcal/千卡 单位的数字（通常就是总量），避免把「每100g」里的 100
/// 误当成热量；没有再退化为最后一个数字，覆盖「米饭2碗共620」这类写法。
double? _parseCalorieFromText(String text) {
  final unitMatches = _calorieWithUnitPattern.allMatches(text).toList();
  if (unitMatches.isNotEmpty) {
    final match = unitMatches.last;
    final parsed = double.tryParse(match.group(1) ?? '');
    if (parsed != null) return parsed;
  }
  final numberMatches = _calorieNumberPattern.allMatches(text).toList();
  if (numberMatches.isEmpty) return null;
  return double.tryParse(numberMatches.last.group(0) ?? '');
}

final RegExp _calorieWithUnitPattern = RegExp(r'(\d+(?:\.\d+)?)\s*(?:kcal|千卡)', caseSensitive: false);
final RegExp _calorieNumberPattern = RegExp(r'-?\d+(?:\.\d+)?');

import 'package:qnote_flutter/models/shortcut_config.dart';

/// 将 ShortcutConfig 列表格式化为紧凑的纯文本 Schema 表达形式，以减少 Token 消耗。
String formatCompressedSchema(List<ShortcutConfig> shortcuts) {
  final sb = StringBuffer();
  sb.writeln('[Schema: ID(名称) -> 字段1(类型:选项), 字段2...]');
  for (final s in shortcuts) {
    sb.write('${s.id}(${s.name})');
    final fieldsList = <String>[];

    // 标准字段
    if (s.fields.isNotEmpty) {
      for (final f in s.fields) {
        final optionsPart = f.options.isNotEmpty ? ':${f.options.join("/")}' : '';
        final customPart = f.allowCustom ? ',可自定义' : '';
        fieldsList.add('${f.id}(${f.type}$optionsPart$customPart)');
      }
    }

    // 分类字段 (如记账)
    if (s.hasPopup && s.categories != null && s.categories!.isNotEmpty) {
      final categoryNames = s.categories!.map((c) => '${c.id}${c.name}').join('/');
      fieldsList.add('_category($categoryNames)');

      final processedFields = <String>{};
      for (final c in s.categories!) {
        for (final f in c.fields) {
          final fieldKey = f.id;
          if (processedFields.contains(fieldKey)) continue;
          processedFields.add(fieldKey);

          final optionsPart = f.options.isNotEmpty ? ':${f.options.join("/")}' : '';
          final customPart = f.allowCustom ? ',可自定义' : '';
          fieldsList.add('${f.id}(${f.type}$optionsPart$customPart)');
        }
      }
    }

    if (fieldsList.isNotEmpty) {
      sb.write(' -> ${fieldsList.join(", ")}');
    }
    sb.writeln();
  }
  return sb.toString().trim();
}

/// 智能纠错与别名映射：将 AI 提取的原始 fields 进行规范化处理，自动纠正拼写偏差或别名（如 _category -> type）。
Map<String, dynamic> normalizeExtractedFields(Map<String, dynamic> rawFields, ShortcutConfig? shortcut) {
  if (shortcut == null) return rawFields;
  final normalized = <String, dynamic>{};

  // 1. 建立有效的字段 ID 集合
  final validFieldIds = shortcut.fields.map((f) => f.id).toSet();
  if (shortcut.categories != null) {
    for (final cat in shortcut.categories!) {
      validFieldIds.addAll(cat.fields.map((f) => f.id));
    }
  }

  // 常见同义词/别名映射表 (当 AI 提取的 key 不在有效字段中，但别名在时进行映射)
  const aliasMapping = {
    'type': ['_category', 'category', 'class', 'classify', 'tag', 'name', 'label'],
    'amount': ['money', 'price', 'cost', 'expense', 'income'],
    'symptom': ['symptoms', 'illness', 'disease'],
    'rating': ['ratings', 'score', 'level'],
    'duration': ['time', 'minutes', 'hours', 'length'],
  };

  // 2. 先保留原本就有效且存在于 Schema 中的字段
  for (final entry in rawFields.entries) {
    if (validFieldIds.contains(entry.key)) {
      normalized[entry.key] = entry.value;
    }
  }

  // 3. 对于不在 Schema 中的无效字段，尝试通过别名映射到有效的缺失字段
  for (final entry in rawFields.entries) {
    if (validFieldIds.contains(entry.key)) continue;

    String? targetKey;
    for (final aliasEntry in aliasMapping.entries) {
      final canonicalKey = aliasEntry.key;
      final aliases = aliasEntry.value;

      // 如果当前快捷标签支持这个规范字段，且目前提取结果里还没有该字段的值
      if (validFieldIds.contains(canonicalKey) && !normalized.containsKey(canonicalKey)) {
        if (aliases.contains(entry.key.toLowerCase())) {
          targetKey = canonicalKey;
          break;
        }
      }
    }

    if (targetKey != null) {
      normalized[targetKey] = entry.value;
    } else {
      // 如果没有别名匹配，对于非系统内部私有字段（不以 _ 开头），予以保留以支持潜在自定义或扩展
      if (!entry.key.startsWith('_')) {
        normalized[entry.key] = entry.value;
      }
    }
  }

  return normalized;
}

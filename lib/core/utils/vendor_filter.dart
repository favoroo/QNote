/// 厂商模板的搜索与分组过滤（纯函数，不依赖 UI）
///
/// 厂商数量扩充到 50+ 后，选择器必须同时支持「按分组浏览」与「直接搜」两条路径。
/// 过滤规则抽在这里而不是写在弹层里，是为了让「搜什么能搜到」这件事可被单测锁定，
/// 改匹配字段时不会静默漏掉某一类命中。
library;

import 'package:qnote_flutter/config/ai_vendors.dart';

/// 单个厂商是否命中关键词
///
/// 命中范围：名称、模板 id、一行说明、官方地址、分组名与种子模型名。
/// 关键词按空白拆成多个片段，要求**全部**片段都命中（如 `qwen 阿里`），
/// 与各平台搜索框的直觉一致，也避免了「多打一个词反而搜不到」。
bool vendorMatchesQuery(AiProviderConfig spec, String query) {
  final tokens = query.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  if (tokens.isEmpty) return true;

  final haystack = [
    spec.name,
    spec.id,
    spec.note,
    spec.defaultBaseUrl,
    spec.category.label,
    spec.authMode,
    ...spec.models,
  ].join('\n').toLowerCase();

  return tokens.every(haystack.contains);
}

/// 按分组与关键词过滤厂商模板，保持目录原有顺序
///
/// [category] 为 null 表示不限分组（展示全部分区）。
List<AiProviderConfig> filterVendors(List<AiProviderConfig> all, {VendorCategory? category, String query = ''}) {
  return all
      .where((spec) => category == null || spec.category == category)
      .where((spec) => vendorMatchesQuery(spec, query))
      .toList();
}

/// 按分组归类，分组顺序固定为 [VendorCategory.values]，空分组不出现
Map<VendorCategory, List<AiProviderConfig>> groupVendors(List<AiProviderConfig> vendors) {
  final grouped = <VendorCategory, List<AiProviderConfig>>{};
  for (final category in VendorCategory.values) {
    final items = vendors.where((spec) => spec.category == category).toList();
    if (items.isNotEmpty) grouped[category] = items;
  }
  return grouped;
}

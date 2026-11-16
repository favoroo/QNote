import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/output_types/output_type_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('清单为 8 项，id 唯一', () {
    expect(kOutputTypes.length, 8);
    final ids = kOutputTypes.map((o) => o.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'id 必须唯一，否则选择状态会串台');
  });

  test('每个条目字段完整，分类属于预设类别', () {
    for (final option in kOutputTypes) {
      expect(option.label, isNotEmpty, reason: '${option.id} 缺少显示名');
      expect(option.description, isNotEmpty, reason: '${option.id} 缺少卡片副标题');
      expect(
        option.description.length,
        inInclusiveRange(6, 12),
        reason: '${option.id} 的 description 需控制在 6~12 字，避免卡片里被截断',
      );
      expect(option.hint, isNotEmpty, reason: '${option.id} 缺少注入提示');
      expect(kOutputTypeCategories.contains(option.category), isTrue, reason: '${option.id} 分类 ${option.category} 未登记');
    }
  });

  test('引用的技能名均为内置技能', () {
    for (final option in kOutputTypes) {
      final skillName = option.skillName;
      if (skillName == null) continue;
      expect(
        SkillRegistry.builtinSkillNames.contains(skillName),
        isTrue,
        reason: '${option.id} 引用的技能 $skillName 必须存在于内置技能',
      );
    }
  });

  test('目标后缀合法（不含点、仅小写字母数字）', () {
    for (final option in kOutputTypes) {
      final ext = option.extension;
      if (ext == null) continue;
      expect(ext.startsWith('.'), isFalse, reason: '${option.id} 后缀不应带点');
      expect(RegExp(r'^[a-z0-9]+$').hasMatch(ext), isTrue, reason: '${option.id} 后缀 "$ext" 非法');
    }
  });

  test('已移除的时间线、代码、JSON 与关系图不可查询', () {
    for (final id in ['timeline', 'code', 'json', 'er']) {
      expect(outputTypeById(id), isNull, reason: '精简后的 $id 不应再出现在注册表');
    }
  });

  test('byId 命中与未命中', () {
    expect(outputTypeById('flowchart')?.label, '流程图');
    expect(outputTypeById('table')?.extension, 'csv');
    expect(outputTypeById('nope'), isNull);
    expect(outputTypeById(null), isNull);
    expect(outputTypeById(''), isNull);
  });

  test('分组覆盖全部条目，顺序为图示 → 数据与图表 → 文档', () {
    final groups = groupedOutputTypes();
    expect(groups.map((g) => g.key).toList(), [kOutputCategoryDiagram, kOutputCategoryData, kOutputCategoryDocument]);
    expect(groups.map((g) => g.key).toList(), kOutputTypeCategories, reason: '类别表不得出现没有内容的分组');
    final flat = groups.expand((g) => g.value).toList();
    expect(flat.length, kOutputTypes.length, reason: '分组不得遗漏条目');
    expect(flat.toSet().length, kOutputTypes.length, reason: '条目不得重复出现在多个分组');
  });

  test('每个类别至少 2 项，图示类别覆盖五种常用图', () {
    final groups = {for (final group in groupedOutputTypes()) group.key: group.value};
    for (final category in kOutputTypeCategories) {
      expect(groups[category]!.length, greaterThanOrEqualTo(2), reason: '$category 至少保留 2 项');
    }
    expect(groups[kOutputCategoryDiagram]!.map((o) => o.id), ['flowchart', 'sequence', 'gantt', 'mindmap']);
    expect(groups[kOutputCategoryData]!.map((o) => o.id), ['table', 'chart']);
    expect(groups[kOutputCategoryDocument]!.length, 2);
  });
}

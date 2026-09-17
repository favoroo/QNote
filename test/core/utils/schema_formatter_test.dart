import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/schema_formatter.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';

void main() {
  test('formatCompressedSchema outputs correct compressed schema', () {
    final testShortcuts = [
      ShortcutConfig(
        id: 'sleep',
        name: '睡眠',
        hasPopup: true,
        fields: [
          ShortcutField(id: 'fallAsleepTime', label: '入睡时间', type: 'time', options: []),
          ShortcutField(id: 'duration', label: '时长 (小时)', type: 'number', options: []),
          ShortcutField(id: 'quality', label: '睡眠质量', type: 'select', options: ['极好', '良好', '一般', '较差']),
        ],
        sortOrder: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      ShortcutConfig(
        id: 'diet',
        name: '饮食',
        hasPopup: true,
        fields: [
          ShortcutField(id: 'type', label: '种类', type: 'select', options: ['自制', '外卖'], allowCustom: true),
        ],
        sortOrder: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ];

    final schema = formatCompressedSchema(testShortcuts);
    expect(schema.contains('[Schema: ID(名称) -> 字段1(类型:选项), 字段2...]'), isTrue);
    expect(schema.contains('sleep(睡眠) -> fallAsleepTime(time), duration(number), quality(select:极好/良好/一般/较差)'), isTrue);
    expect(schema.contains('diet(饮食) -> type(select:自制/外卖,可自定义)'), isTrue);
  });

  test('normalizeExtractedFields preserves _category for categorized shortcuts', () {
    // 模拟记账标签：带 categories（支出/收入），AI 同时输出 _category 与 type
    final consumption = ShortcutConfig(
      id: 'consumption',
      name: '记账',
      hasPopup: true,
      fields: [],
      categories: [
        ShortcutCategory(
          id: 'expense',
          name: '支出',
          fields: [
            ShortcutField(id: 'type', label: '支出类型', type: 'select', options: ['数码'], allowCustom: true),
            ShortcutField(id: 'amount', label: '金额', type: 'number', options: []),
          ],
        ),
        ShortcutCategory(
          id: 'income',
          name: '收入',
          fields: [
            ShortcutField(id: 'incomeType', label: '收入类型', type: 'select', options: ['工资'], allowCustom: true),
            ShortcutField(id: 'amount', label: '金额', type: 'number', options: []),
          ],
        ),
      ],
      sortOrder: 0,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // AI 按 Schema 输出 _category，规范化后必须保留，否则统计无法判定收支方向
    final normalized = normalizeExtractedFields({
      '_category': 'expense',
      'type': '数码',
      'amount': 10,
    }, consumption);

    expect(normalized['_category'], 'expense');
    expect(normalized['type'], '数码');
    expect(normalized['amount'], 10);
  });
}

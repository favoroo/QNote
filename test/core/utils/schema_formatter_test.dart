import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/schema_formatter.dart';
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
}

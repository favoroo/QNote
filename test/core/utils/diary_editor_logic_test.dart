import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/diary_editor_logic.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/tag_entry.dart';

/// 从 `_DiaryEditorViewState` 抽出的纯逻辑测试。
///
/// 这些文案会随记录落库（字段摘要、备注前缀、分隔符），测试按现状固定，
/// 后续若有人改动拼接方式应在这里直接暴露，而不是等历史数据被污染。
void main() {
  final dietShortcut = ShortcutConfig(
    id: 'diet',
    name: '饮食',
    hasPopup: true,
    fields: [
      ShortcutField(id: 'type', label: '种类', type: 'select', options: ['自制', '外卖', '堂食']),
      ShortcutField(id: 'rating', label: '评价', type: 'select', options: ['健康', '一般']),
    ],
    sortOrder: 1,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  final sportShortcut = ShortcutConfig(
    id: 'sport',
    name: '运动',
    hasPopup: true,
    categories: [
      ShortcutCategory(
        id: 'run',
        name: '跑步',
        fields: [
          ShortcutField(id: 'distance', label: '距离', type: 'number'),
          ShortcutField(id: 'tags', label: '感受', type: 'multi-select'),
        ],
      ),
      ShortcutCategory(id: 'swim', name: '游泳', fields: []),
    ],
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  // 未开启弹窗字段的标签：不应参与摘要生成
  final noteShortcut = ShortcutConfig(
    id: 'note',
    name: '随笔',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  final shortcuts = [dietShortcut, sportShortcut, noteShortcut];

  TagEntry dietEntry([Map<String, dynamic> fields = const {}]) => TagEntry(id: 'diet', name: '饮食', fields: fields);

  group('字段摘要生成 buildDiaryPopupDetails', () {
    test('单字段只输出该字段', () {
      final details = buildDiaryPopupDetails([
        dietEntry({'type': '自制'}),
      ], shortcuts);
      expect(details, equals('种类：自制'));
    });

    test('多字段用「，」连接，字段顺序以配置为准', () {
      final details = buildDiaryPopupDetails([
        dietEntry({'rating': '健康', 'type': '自制'}),
      ], shortcuts);
      expect(details, equals('种类：自制，评价：健康'));
    });

    test('值为空（null 或字段缺失）时不产生输出', () {
      expect(buildDiaryPopupDetails([dietEntry()], shortcuts), equals(''));
      expect(
        buildDiaryPopupDetails([
          dietEntry({'type': null, 'rating': '健康'}),
        ], shortcuts),
        equals('评价：健康'),
      );
      expect(buildDiaryPopupDetails([], shortcuts), equals(''));
    });

    test('未开启弹窗字段或未匹配到配置的标签被跳过', () {
      expect(
        buildDiaryPopupDetails([
          TagEntry(id: 'note', name: '随笔', fields: {'text': '随手记'}),
        ], shortcuts),
        equals(''),
      );
      expect(
        buildDiaryPopupDetails([
          TagEntry(id: 'unknown', name: '未知', fields: {'x': '1'}),
        ], shortcuts),
        equals(''),
      );
    });

    test('特殊字符（中文标点/英文逗号）与空串值原样拼接，不做转义', () {
      final details = buildDiaryPopupDetails([
        dietEntry({'type': '外卖, 堂食', 'rating': ''}),
      ], shortcuts);
      expect(details, equals('种类：外卖, 堂食，评价：'));
    });

    test('列表值用「、」连接', () {
      final details = buildDiaryPopupDetails([
        TagEntry(
          id: 'sport',
          name: '运动',
          fields: {
            '_category': 'run',
            'distance': 5,
            'tags': ['畅快', '腿酸'],
          },
        ),
      ], shortcuts);
      expect(details, equals('跑步 - 距离：5，感受：畅快、腿酸'));
    });

    test('多个标签之间用「；」连接', () {
      final details = buildDiaryPopupDetails([
        dietEntry({'type': '自制'}),
        TagEntry(id: 'sport', name: '运动', fields: {'_category': 'run', 'distance': 1}),
      ], shortcuts);
      expect(details, equals('种类：自制；跑步 - 距离：1'));
    });
  });

  group('纯字段摘要判定 isDiaryFieldSummaryOnly', () {
    test('纯字段摘要为 true', () {
      expect(
        isDiaryFieldSummaryOnly('种类：自制，评价：健康', [
          dietEntry({'type': '自制', 'rating': '健康'}),
        ], shortcuts),
        isTrue,
      );
    });

    test('摘要 + 用户备注为 false', () {
      expect(
        isDiaryFieldSummaryOnly('种类：自制，评价：健康\n备注：很好吃', [
          dietEntry({'type': '自制', 'rating': '健康'}),
        ], shortcuts),
        isFalse,
      );
    });

    test('纯用户正文为 false（含冒号、图：也不例外）', () {
      expect(
        isDiaryFieldSummaryOnly('清蒸鲈鱼\n图：清蒸鲈鱼，凉拌猪耳', [
          dietEntry({'type': '自制'}),
        ], shortcuts),
        isFalse,
      );
    });

    test('空正文视为纯摘要（true）', () {
      expect(isDiaryFieldSummaryOnly('   ', [dietEntry()], shortcuts), isTrue);
      expect(isDiaryFieldSummaryOnly('', [dietEntry()], shortcuts), isTrue);
    });

    test('没有已知字段名时一律 false（不误判自由正文）', () {
      expect(isDiaryFieldSummaryOnly('随便写点什么', [], shortcuts), isFalse);
    });

    test('无冒号片段命中字段值或字段名为 true', () {
      expect(
        isDiaryFieldSummaryOnly('自制', [
          dietEntry({'type': '自制'}),
        ], shortcuts),
        isTrue,
      );
      expect(isDiaryFieldSummaryOnly('type', [dietEntry()], shortcuts), isTrue);
    });
  });

  group('用户备注剥离 parseDiaryUserRemarks', () {
    test('「\\n备注：」前缀能还原手写正文', () {
      const content = '种类：自制，评价：健康\n备注：今天做的清蒸鲈鱼非常鲜美';
      expect(
        parseDiaryUserRemarks(content, [
          dietEntry({'type': '自制', 'rating': '健康'}),
        ], shortcuts),
        equals('今天做的清蒸鲈鱼非常鲜美'),
      );
    });

    test('半角「\\n备注:」与前缀形式同样能剥离', () {
      expect(
        parseDiaryUserRemarks('种类：自制\n备注:睡得很好', [
          dietEntry({'type': '自制'}),
        ], shortcuts),
        equals('睡得很好'),
      );
      expect(parseDiaryUserRemarks('备注：只写备注', [dietEntry()], shortcuts), equals('只写备注'));
      expect(parseDiaryUserRemarks('备注: 半角前缀', [dietEntry()], shortcuts), equals('半角前缀'));
    });

    test('纯摘要返回空串', () {
      expect(
        parseDiaryUserRemarks('种类：自制，评价：健康', [
          dietEntry({'type': '自制', 'rating': '健康'}),
        ], shortcuts),
        equals(''),
      );
    });

    test('摘要后直接跟正文时去掉分隔符后还原', () {
      expect(
        parseDiaryUserRemarks('种类：自制； 加了个蛋', [
          dietEntry({'type': '自制'}),
        ], shortcuts),
        equals('加了个蛋'),
      );
    });

    test('自由正文（AI 提取/小Q 编辑）原样返回，不被清空', () {
      const content = '清蒸鲈鱼、凉拌猪耳、肉沫酸豆角\n图：清蒸鲈鱼，凉拌猪耳';
      expect(
        parseDiaryUserRemarks(content, [
          dietEntry({'type': '自制'}),
        ], shortcuts),
        equals(content),
      );
    });

    test('无弹窗字段时原样返回（含空正文）', () {
      expect(parseDiaryUserRemarks('随手记的内容', [], shortcuts), equals('随手记的内容'));
      expect(parseDiaryUserRemarks('   ', [], shortcuts), equals(''));
    });

    test('保存格式往返：拼出的「摘要 + 备注」能还原出原手写内容', () {
      final tagEntries = [
        dietEntry({'type': '自制', 'rating': '健康'}),
      ];
      final allDetails = buildDiaryPopupDetails(tagEntries, shortcuts);
      const remarks = '今天做的清蒸鲈鱼非常鲜美';
      final saved = '$allDetails\n备注：$remarks';
      expect(parseDiaryUserRemarks(saved, tagEntries, shortcuts), equals(remarks));
    });
  });

  group('字段名/值格式化', () {
    test('已知字段名（大小写不敏感）翻译为中文', () {
      expect(formatDiaryExtraFieldLabel('sub_type'), equals('运动项目'));
      expect(formatDiaryExtraFieldLabel('DISTANCE_KM'), equals('距离'));
      expect(formatDiaryExtraFieldLabel('cal'), equals('消耗'));
      expect(formatDiaryExtraFieldLabel('heart_rate'), equals('平均心率'));
      expect(formatDiaryExtraFieldLabel('avg_pace'), equals('平均配速'));
      expect(formatDiaryExtraFieldLabel('duration'), equals('时长'));
    });

    test('未知字段名原样返回', () {
      expect(formatDiaryExtraFieldLabel('custom_key'), equals('custom_key'));
      expect(formatDiaryExtraFieldLabel(''), equals(''));
    });

    test('已知字段值补单位，已带单位不重复追加', () {
      expect(formatDiaryExtraFieldValue('distance', 5), equals('5km'));
      expect(formatDiaryExtraFieldValue('distance_km', '5km'), equals('5km'));
      expect(formatDiaryExtraFieldValue('calories', 320), equals('320kcal'));
      expect(formatDiaryExtraFieldValue('cal', '320 kcal'), equals('320 kcal'));
      expect(formatDiaryExtraFieldValue('avg_hr', 72), equals('72bpm'));
    });

    test('未知字段值直接 toString', () {
      expect(formatDiaryExtraFieldValue('custom', 'abc'), equals('abc'));
      expect(formatDiaryExtraFieldValue('custom', null), equals('null'));
    });

    test('null 值沿用原编辑器行为：按 toString 参与单位拼接', () {
      // 现状是 'nullkm'。这里固定既有行为，避免顺手「修」掉造成展示口径漂移。
      expect(formatDiaryExtraFieldValue('distance', null), equals('nullkm'));
    });
  });

  group('备注与正文合并 mergeDiaryNotesWithContent', () {
    test('正文为空时返回去空白后的备注', () {
      expect(mergeDiaryNotesWithContent('  图：新图  ', ''), equals('图：新图'));
      expect(mergeDiaryNotesWithContent('图：新图', '   '), equals('图：新图'));
    });

    test('备注为空时原样返回正文（保留原文空白）', () {
      expect(mergeDiaryNotesWithContent('', '原始正文 '), equals('原始正文 '));
      expect(mergeDiaryNotesWithContent('  ', '原始正文'), equals('原始正文'));
    });

    test('两者都有时用换行追加备注', () {
      expect(mergeDiaryNotesWithContent('图：另外一张图', '清蒸鲈鱼'), equals('清蒸鲈鱼\n图：另外一张图'));
    });

    test('正文已包含该备注时不重复追加', () {
      const original = '清蒸鲈鱼\n图：清蒸鲈鱼，凉拌猪耳';
      expect(mergeDiaryNotesWithContent('图：清蒸鲈鱼，凉拌猪耳', original), equals(original));
    });
  });

  group('时间格式化 formatDiaryEditorDateTime', () {
    test('同一天的不同时间共享日期前缀', () {
      expect(formatDiaryEditorDateTime(DateTime(2026, 9, 19, 10, 30)), equals('09-19 10:30'));
      expect(formatDiaryEditorDateTime(DateTime(2026, 9, 19, 23, 5)), equals('09-19 23:05'));
    });

    test('跨天与跨年通过日期部分区分，凌晨补零', () {
      expect(formatDiaryEditorDateTime(DateTime(2026, 9, 20, 0, 5)), equals('09-20 00:05'));
      expect(formatDiaryEditorDateTime(DateTime(2027, 1, 1, 0, 0)), equals('01-01 00:00'));
    });
  });

  group('编辑指纹 diaryEditSignature', () {
    DiaryEditSnapshot snapshot({
      String content = '正文',
      List<String> tags = const ['饮食'],
      Map<String, dynamic> fields = const {'type': '自制'},
    }) {
      return DiaryEditSnapshot(
        content: content,
        time: DateTime(2026, 9, 19, 10, 30),
        startTime: DateTime(2026, 9, 19, 10, 30),
        tags: tags,
        displayTag: tags.isEmpty ? '' : tags.first,
        photos: const ['/tmp/a.jpg'],
        tagEntries: [TagEntry(id: 'diet', name: '饮食', fields: fields)],
      );
    }

    test('内容相同则指纹相同', () {
      expect(diaryEditSignature(snapshot()), equals(diaryEditSignature(snapshot())));
    });

    test('字段 Map 插入顺序不同不改变指纹', () {
      expect(
        diaryEditSignature(snapshot(fields: {'type': '自制', 'rating': '健康'})),
        equals(diaryEditSignature(snapshot(fields: {'rating': '健康', 'type': '自制'}))),
      );
    });

    test('正文或标签变化会改变指纹', () {
      expect(diaryEditSignature(snapshot(content: '正文')), isNot(equals(diaryEditSignature(snapshot(content: '正文2')))));
      expect(
        diaryEditSignature(snapshot(tags: const ['饮食'])),
        isNot(equals(diaryEditSignature(snapshot(tags: const ['运动'])))),
      );
    });
  });
}

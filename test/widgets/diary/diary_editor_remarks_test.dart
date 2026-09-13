import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/tag_entry.dart';

void main() {
  group('日记编辑器内容解析与备注提取测试', () {
    final dietShortcut = ShortcutConfig(
      id: 'diet',
      name: '饮食',
      hasPopup: true,
      fields: [
        ShortcutField(
          id: 'type',
          label: '种类',
          type: 'select',
          options: ['自制', '外卖', '堂食', '零食', '水果', '饮品', '补剂'],
          allowCustom: true,
        ),
        ShortcutField(
          id: 'rating',
          label: '评价',
          type: 'select',
          options: ['健康', '一般', '不健康'],
        ),
      ],
      sortOrder: 1,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    final shortcuts = [dietShortcut];

    String buildPopupDetails(List<TagEntry> tagEntries, List<ShortcutConfig> shortcuts) {
      final popupEntries = <TagEntry>[];
      final popupConfigs = <ShortcutConfig>[];

      for (final entry in tagEntries) {
        try {
          final config = shortcuts.firstWhere(
            (s) => s.id == entry.id || s.name == entry.name,
          );
          if (config.hasPopup) {
            popupEntries.add(entry);
            popupConfigs.add(config);
          }
        } catch (_) {}
      }

      if (popupEntries.isEmpty) return '';

      final detailParts = <String>[];

      for (int pi = 0; pi < popupEntries.length; pi++) {
        final entry = popupEntries[pi];
        final config = popupConfigs[pi];

        List<ShortcutField> fieldsToProcess = config.fields;
        Map<String, dynamic> entryFields = Map<String, dynamic>.from(
          entry.fields,
        );
        String categoryPrefix = '';

        if (config.categories != null && config.categories!.isNotEmpty) {
          final currentCategory = config.categories!.firstWhere(
            (c) => c.id == entryFields['_category'],
            orElse: () => config.categories!.first,
          );
          fieldsToProcess = currentCategory.fields;
          categoryPrefix = '${currentCategory.name} - ';
        }

        final details = fieldsToProcess
            .map((f) {
              final val = entryFields[f.id];
              if (val == null) return null;
              if (val is List) return '${f.label}：${val.join('、')}';
              return '${f.label}：$val';
            })
            .where((s) => s != null && s.isNotEmpty)
            .join('，');

        final fullDetails = categoryPrefix.isNotEmpty
            ? '$categoryPrefix$details'
            : details;
        if (fullDetails.isNotEmpty) detailParts.add(fullDetails);
      }

      return detailParts.join('；');
    }

    bool isPurelyFieldSummary(
      String content,
      List<TagEntry> tagEntries,
      List<ShortcutConfig> shortcuts,
    ) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return true;

      final knownLabels = <String>{};
      final knownValues = <String>{};

      for (final entry in tagEntries) {
        final sc = shortcuts
            .where((s) => s.id == entry.id || s.name == entry.name)
            .firstOrNull;
        if (sc != null) {
          for (final f in sc.fields) {
            knownLabels.add(f.label);
            knownLabels.add(f.id);
          }
          if (sc.categories != null) {
            for (final cat in sc.categories!) {
              knownLabels.add(cat.name);
              for (final f in cat.fields) {
                knownLabels.add(f.label);
                knownLabels.add(f.id);
              }
            }
          }
        }
        for (final f in entry.fields.entries) {
          knownLabels.add(f.key);
          if (f.value != null) {
            if (f.value is List) {
              knownValues.addAll((f.value as List).map((e) => e.toString()));
            } else {
              knownValues.add(f.value.toString());
            }
          }
        }
      }

      if (knownLabels.isEmpty) return false;

      final lines = trimmed.split(RegExp(r'[\r\n]+'));
      for (final line in lines) {
        final l = line.trim();
        if (l.isEmpty) continue;

        final segments = l.split(RegExp(r'[；;，,]'));
        for (final seg in segments) {
          final s = seg.trim();
          if (s.isEmpty) continue;

          if (s.contains('：') || s.contains(':')) {
            final parts = s.split(RegExp(r'[:：]'));
            final key = parts[0].trim().replaceAll(RegExp(r'^.*-\s*'), '');
            if (!knownLabels.contains(key)) {
              return false;
            }
          } else {
            if (!knownLabels.contains(s) && !knownValues.contains(s)) {
              return false;
            }
          }
        }
      }

      return true;
    }

    String parseUserRemarks(
      String content,
      List<TagEntry> tagEntries,
      List<ShortcutConfig> shortcuts,
    ) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return '';

      if (content.contains('\n备注：')) {
        final idx = content.indexOf('\n备注：');
        return content.substring(idx + '\n备注：'.length).trim();
      }
      if (content.contains('\n备注:')) {
        final idx = content.indexOf('\n备注:');
        return content.substring(idx + '\n备注:'.length).trim();
      }
      if (content.startsWith('备注：') || content.startsWith('备注:')) {
        return content.replaceFirst(RegExp(r'^备注[:：]\s*'), '').trim();
      }

      final hasPopupFields = tagEntries.any((entry) {
        final sc = shortcuts
            .where((s) => s.id == entry.id || s.name == entry.name)
            .firstOrNull;
        return sc != null && sc.hasPopup;
      });

      if (!hasPopupFields) {
        return content;
      }

      final allDetails = buildPopupDetails(tagEntries, shortcuts);
      if (allDetails.isNotEmpty) {
        if (trimmed == allDetails.trim()) {
          return '';
        }
        if (content.startsWith(allDetails)) {
          final remainder = content.substring(allDetails.length).trim();
          if (remainder.startsWith('备注：') || remainder.startsWith('备注:')) {
            return remainder.replaceFirst(RegExp(r'^备注[:：]\s*'), '').trim();
          }
          return remainder.replaceFirst(RegExp(r'^[\n\r；;,，\s]+'), '');
        }
      }

      if (isPurelyFieldSummary(content, tagEntries, shortcuts)) {
        return '';
      }

      return content;
    }

    test('智能提取或小Q编辑的内容包含冒号与图：时，绝不能被误清空', () {
      final tagEntries = [
        TagEntry(
          id: 'diet',
          name: '饮食',
          fields: {'type': '自制', 'rating': '健康'},
        ),
      ];
      final content = '清蒸鲈鱼、凉拌猪耳、肉沫酸豆角、青菜豆腐荷包蛋汤、米饭与芋圆啵啵甜品\n'
          '图：清蒸鲈鱼，凉拌猪耳，肉沫酸豆角，青菜豆腐荷包蛋汤，米饭与芋圆啵啵甜品';

      final remarks = parseUserRemarks(content, tagEntries, shortcuts);
      expect(remarks, equals(content));
    });

    test('纯由结构化字段组成的摘要字符串应返回空正文', () {
      final tagEntries = [
        TagEntry(
          id: 'diet',
          name: '饮食',
          fields: {'type': '自制', 'rating': '健康'},
        ),
      ];
      const content = '种类：自制，评价：健康';

      final remarks = parseUserRemarks(content, tagEntries, shortcuts);
      expect(remarks, equals(''));
    });

    test('带有「备注：」或「\\n备注：」前缀的应正确剥离并提取用户正文', () {
      final tagEntries = [
        TagEntry(
          id: 'diet',
          name: '饮食',
          fields: {'type': '自制', 'rating': '健康'},
        ),
      ];
      const content1 = '种类：自制，评价：健康\n备注：今天做的清蒸鲈鱼非常鲜美';
      expect(parseUserRemarks(content1, tagEntries, shortcuts), equals('今天做的清蒸鲈鱼非常鲜美'));

      const content2 = '备注：今天做的清蒸鲈鱼非常鲜美';
      expect(parseUserRemarks(content2, tagEntries, shortcuts), equals('今天做的清蒸鲈鱼非常鲜美'));
    });

    test('多重提取或合并notes时已存在内容不再重复追加', () {
      String mergeNotesWithContent(String notes, String originalContent) {
        final trimmedNotes = notes.trim();
        final trimmedOriginal = originalContent.trim();
        if (trimmedNotes.isEmpty) return originalContent;
        if (trimmedOriginal.isEmpty) return trimmedNotes;
        if (trimmedOriginal.contains(trimmedNotes)) {
          return originalContent;
        }
        return '$originalContent\n$trimmedNotes';
      }

      const initial = '清蒸鲈鱼\n图：清蒸鲈鱼，凉拌猪耳';
      const duplicateNote = '图：清蒸鲈鱼，凉拌猪耳';
      final merged = mergeNotesWithContent(duplicateNote, initial);
      expect(merged, equals(initial));

      const newNote = '图：另外一张图';
      final mergedNew = mergeNotesWithContent(newNote, initial);
      expect(mergedNew, equals('清蒸鲈鱼\n图：清蒸鲈鱼，凉拌猪耳\n图：另外一张图'));
    });
  });
}

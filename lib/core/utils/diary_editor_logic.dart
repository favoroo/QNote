import 'package:intl/intl.dart';

import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/tag_entry.dart';

/// 日记编辑器里不依赖 ref / setState / Controller 的纯逻辑。
///
/// 这些函数原先都是 `_DiaryEditorViewState` 的私有方法，只能靠起 App 手动编辑记录来验证。
/// 抽到顶层后，字段摘要、备注剥离、脏检查指纹等文案拼接可以在纯 Dart 环境里逐个锁住。
///
/// 注意：这里输出的分隔符与文案会随记录落库，改动会污染历史数据，测试里按现状固定。

/// 编辑器一次脏检查所需的全部可编辑状态。
///
/// 对应 State 里的正文、时间、标签、图片与标签表单字段；只做值传递，不持有 Controller。
class DiaryEditSnapshot {
  /// 创建一个编辑快照。
  const DiaryEditSnapshot({
    required this.content,
    required this.time,
    this.startTime,
    this.endTime,
    this.tags = const [],
    this.displayTag = '',
    this.photos = const [],
    this.tagEntries = const [],
  });

  /// 正文输入框的当前文本。
  final String content;

  /// 记录时间（时间线锚点）。
  final DateTime time;

  /// 开始时间；未单独设置时编辑器沿用 [time]。
  final DateTime? startTime;

  /// 结束时间；为空表示没有结束时间。
  final DateTime? endTime;

  /// 标签名称列表。
  final List<String> tags;

  /// 展示标签（通常是最外层标签名）。
  final String displayTag;

  /// 图片路径列表。
  final List<String> photos;

  /// 标签结构化字段条目。
  final List<TagEntry> tagEntries;
}

/// 把弹窗类标签的结构化字段拼成摘要文案。
///
/// 输出形如「种类：自制，评价：健康」：字段之间用「，」连接，多个标签之间用「；」连接；
/// 若标签配置了分类，则在该标签摘要前加「分类名 - 」前缀。
/// [tagEntries] 为记录当前标签条目，[shortcuts] 为当前可用快捷标签配置；
/// 找不到对应配置或配置未开启弹窗字段的条目会被跳过，没有可展示字段时返回空串。
String buildDiaryPopupDetails(List<TagEntry> tagEntries, List<ShortcutConfig> shortcuts) {
  final popupEntries = <TagEntry>[];
  final popupConfigs = <ShortcutConfig>[];

  for (final entry in tagEntries) {
    try {
      final config = shortcuts.firstWhere((s) => s.id == entry.id || s.name == entry.name);
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
    final Map<String, dynamic> entryFields = Map<String, dynamic>.from(entry.fields);
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

    final fullDetails = categoryPrefix.isNotEmpty ? '$categoryPrefix$details' : details;
    if (fullDetails.isNotEmpty) detailParts.add(fullDetails);
  }

  return detailParts.join('；');
}

/// 严谨判定内容是否纯粹由结构化标签字段构成（没有用户正文 / AI 正文）。
///
/// 逐行、逐段比对：含冒号的片段按「标签名：值」取冒号前的标签名，
/// 不含冒号的片段则要求命中已知字段名或字段值；空内容视为纯摘要（true）。
/// [tagEntries] 提供已知字段名与值，[shortcuts] 提供字段 label 与分类字段定义。
bool isDiaryFieldSummaryOnly(String content, List<TagEntry> tagEntries, List<ShortcutConfig> shortcuts) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) return true;

  final knownLabels = <String>{};
  final knownValues = <String>{};

  for (final entry in tagEntries) {
    final sc = shortcuts.where((s) => s.id == entry.id || s.name == entry.name).firstOrNull;
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

/// 从记录正文中剥离结构化字段摘要，返回用户手写的备注正文。
///
/// 优先识别「\n备注：」「\n备注:」「备注：」「备注:」前缀，取其后内容；
/// 否则尝试删除开头的字段摘要，剩余部分去掉分隔符后作为备注。
/// 纯字段摘要返回空串；看起来是自由正文（含冒号、图：等）时原样返回，避免误清空。
/// [shortcuts] 为当前快捷标签配置，用于识别弹窗字段。
String parseDiaryUserRemarks(String content, List<TagEntry> tagEntries, List<ShortcutConfig> shortcuts) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) return '';

  // 1. 如果包含「\n备注：」或「\n备注:」，截取后面的用户正文
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
    final sc = shortcuts.where((s) => s.id == entry.id || s.name == entry.name).firstOrNull;
    return sc != null && sc.hasPopup;
  });

  if (!hasPopupFields) {
    return content;
  }

  // 2. 比对生成的标签字段详情
  final allDetails = buildDiaryPopupDetails(tagEntries, shortcuts);
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

  // 3. 严谨检查是否纯由结构化字段构成（无用户正文）
  if (isDiaryFieldSummaryOnly(content, tagEntries, shortcuts)) {
    return '';
  }

  // 4. 用户/AI正文（严禁因包含冒号、图：、时间等误清空）
  return content;
}

/// 额外字段名的展示文案：把运动类常见英文键翻译为中文。
///
/// 已知键（大小写不敏感）返回中文名，未知键原样返回 [key]，供「键: 值」小标签使用。
String formatDiaryExtraFieldLabel(String key) {
  switch (key.toLowerCase()) {
    case 'sub_type':
    case 'subtype':
      return '运动项目';
    case 'distance_km':
    case 'distance':
      return '距离';
    case 'calories':
    case 'cal':
      return '消耗';
    case 'avg_hr':
    case 'heart_rate':
      return '平均心率';
    case 'avg_pace':
    case 'pace':
      return '平均配速';
    case 'duration':
      return '时长';
    default:
      return key;
  }
}

/// 额外字段值的展示文案：为距离 / 消耗 / 心率补上单位。
///
/// 距离追加 `km`、消耗追加 `kcal`、心率追加 `bpm`，已带单位则不重复追加；
/// 其他键直接返回 `value.toString()`（null 会显示为 `null`，沿用原编辑器行为）。
String formatDiaryExtraFieldValue(String key, dynamic value) {
  final vStr = value.toString();
  switch (key.toLowerCase()) {
    case 'distance_km':
    case 'distance':
      if (!vStr.contains('km')) return '${vStr}km';
      return vStr;
    case 'calories':
    case 'cal':
      if (!vStr.contains('kcal')) return '${vStr}kcal';
      return vStr;
    case 'avg_hr':
    case 'heart_rate':
      if (!vStr.contains('bpm')) return '${vStr}bpm';
      return vStr;
    default:
      return vStr;
  }
}

/// 计算编辑内容的指纹，用于判断是否有未保存改动。
///
/// 指纹覆盖正文、起止时间、标签、展示标签、图片以及每个标签条目的时间与字段；
/// 字段名会先排序再拼接，避免 Map 插入顺序变化把同一内容算成不同指纹。
/// 返回值是带换行分隔的多行字符串，只用于相等比较，不面向用户展示。
String diaryEditSignature(DiaryEditSnapshot snapshot) {
  final buffer = StringBuffer()
    ..writeln(snapshot.content)
    ..writeln(snapshot.time.microsecondsSinceEpoch)
    ..writeln(snapshot.startTime?.microsecondsSinceEpoch ?? 0)
    ..writeln(snapshot.endTime?.microsecondsSinceEpoch ?? 0)
    ..writeln(snapshot.tags.join('\u0000'))
    ..writeln(snapshot.displayTag)
    ..writeln(snapshot.photos.join('\u0000'));
  for (final entry in snapshot.tagEntries) {
    buffer.write(
      '${entry.id}|${entry.name}|${entry.time}|'
      '${entry.startHour}:${entry.startMinute}:${entry.startOffset}|'
      '${entry.endHour}:${entry.endMinute}:${entry.endOffset}|',
    );
    // 字段名排序后拼接：Map 插入顺序会变，不排序会把同一内容编成不同指纹
    final fieldKeys = entry.fields.keys.toList()..sort();
    for (final key in fieldKeys) {
      buffer.write('$key=${entry.fields[key]};');
    }
    buffer.writeln();
  }
  return buffer.toString();
}

/// 把 AI 提取出的备注合并进当前正文。
///
/// [notes] 为空时原样返回 [originalContent]；正文为空时返回去掉首尾空白的备注；
/// 正文已包含该备注时不再追加，避免二次提取重复拼接；否则用换行追加到正文末尾。
String mergeDiaryNotesWithContent(String notes, String originalContent) {
  final trimmedNotes = notes.trim();
  final trimmedOriginal = originalContent.trim();
  if (trimmedNotes.isEmpty) return originalContent;
  if (trimmedOriginal.isEmpty) return trimmedNotes;
  // 包含已有解析（如以图：开头或普通说明）则去重，防止二次提取重复追加
  if (trimmedOriginal.contains(trimmedNotes)) {
    return originalContent;
  }
  return '$originalContent\n$trimmedNotes';
}

/// 编辑器时间标签文案，固定格式 `MM-dd HH:mm`。
///
/// 同日与跨天的起止时间都走同一格式，跨天时靠日期部分区分，不做「今天 / 昨天」相对化。
String formatDiaryEditorDateTime(DateTime dt) {
  return DateFormat('MM-dd HH:mm').format(dt);
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/models/tag_entry.dart';

/// 记录面板里不依赖 ref / setState / Controller 的换算与校验。
///
/// 这些逻辑原先埋在 `_DiaryRecordSheetState` 里，只能靠起 App 点时间线来验证。
/// 抽到顶层后，跨天偏移、固定事件去重、备注拼接都能在没有 Provider 和 UI 的环境下锁住。

/// 时间线一次选择换算出的草稿时间。
///
/// [startOffset] / [endOffset] 是相对当前选中日期的天数偏移，而不是绝对日期：
/// 草稿存偏移，用户把时间线切到别的日期时时间才不会漂到今天。
/// 当结束时间缺失时，[endOffset] 仍与开始偏移一致，由调用方决定是否清空。
class DiarySelectionTimes {
  const DiarySelectionTimes({
    required this.startTime,
    required this.startOffset,
    required this.endTime,
    required this.endOffset,
  });

  /// 开始时间。
  final TimeOfDay startTime;

  /// 开始日相对选中日期的天数偏移，可为负（补记前一天）。
  final int startOffset;

  /// 结束时间；时间点选择时为 null。
  final TimeOfDay? endTime;

  /// 结束日相对选中日期的天数偏移；结束时间缺失时等于 [startOffset]。
  final int endOffset;
}

/// 把时间线上的一次选择换算成草稿的起止时间与跨天偏移。
///
/// [selectedDate] 是时间线当前选中的日期，[startDate] 是开始时间所在的绝对日期。
/// [endDate] 为空表示结束时间落在开始那天（时间线区间选择就是这么表达的），
/// 此时结束偏移取开始日的偏移；留空会沿用草稿里上一段的旧偏移，跨天会算错。
DiarySelectionTimes resolveDiarySelectionTimes({
  required DateTime selectedDate,
  required TimeOfDay startTime,
  required DateTime startDate,
  TimeOfDay? endTime,
  DateTime? endDate,
}) {
  final baseDay = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
  int offsetOf(DateTime date) => DateTime(date.year, date.month, date.day).difference(baseDay).inDays;

  return DiarySelectionTimes(
    startTime: startTime,
    startOffset: offsetOf(startDate),
    endTime: endTime,
    endOffset: endDate == null ? offsetOf(startDate) : offsetOf(endDate),
  );
}

/// 把「选中日期 + 时分 + 天数偏移」拼成绝对时间。
///
/// 与记录面板原有的换算顺序一致：先构造当天的时分，再加天数偏移。
/// [dayOffset] 为空或 0 时就是选中日期当天；负数用于补记前一天。
DateTime resolveDiaryDateTime({required DateTime selectedDate, required TimeOfDay time, int? dayOffset}) {
  var result = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, time.hour, time.minute);
  if (dayOffset != null) {
    result = result.add(Duration(days: dayOffset));
  }
  return result;
}

/// 判断指定固定事件模板在目标日期是否已经添加过。
///
/// 只统计未删除且归属 [date] 当天的记录。识别顺序与面板原有逻辑一致：
/// 1. `bodyState['fixed_event_id']` 非空时只认 id，命中与否都立即返回；
/// 2. `bodyState['fixed_event_name']` 非空时只认名称；
/// 3. 兼容历史记录，用 `title` 或 `displayTag` 与模板名称比对。
bool isFixedEventAddedOnDate(FixedEventTemplate template, DateTime date, List<DiaryRecord> records) {
  final targetDate = DateTime(date.year, date.month, date.day);
  return records.any((r) {
    if (r.isDeleted) return false;
    if (!r.belongsToDate(targetDate)) return false;

    final fixedId = r.bodyState?['fixed_event_id'] as String?;
    if (fixedId != null && fixedId.isNotEmpty) {
      return fixedId == template.id;
    }
    final fixedName = r.bodyState?['fixed_event_name'] as String?;
    if (fixedName != null && fixedName.isNotEmpty) {
      return fixedName == template.name;
    }

    return r.title == template.name || r.displayTag == template.name;
  });
}

/// 固定事件模板换算出的起止时间。
///
/// [endTime] 为空表示这是时间点事件，或第一个时间段没有结束时间；
/// 调用方仍按模板的 `isTimePoint` 决定是否清空草稿里旧的结束时间。
class FixedEventSelectionTimes {
  const FixedEventSelectionTimes({required this.startTime, this.endTime});

  /// 开始时间，取模板第一个时间段的开始时间。
  final TimeOfDay startTime;

  /// 结束时间；时间点模式或结束时间为空串时为 null。
  final TimeOfDay? endTime;
}

/// 取固定事件模板第一个时间段的起止时间。
///
/// 模板带多个时间段时只用第一个，与面板「最后选中的模板决定时间」的规则配套。
/// 时间字符串解析失败时回退到模板自身的 `startHour` / `startMinute` 一类 getter；
/// `HH` 这种没有冒号的值按 0 分处理，保持原有兜底口径。
FixedEventSelectionTimes resolveFixedEventSelectionTimes(FixedEventTemplate template) {
  final firstPeriod = template.timePeriods.isNotEmpty
      ? template.timePeriods.first
      : TimePeriod(startTime: template.startTime, endTime: template.endTime);

  final startParts = firstPeriod.startTime.split(':');
  final startTime = TimeOfDay(
    hour: int.tryParse(startParts[0]) ?? template.startHour,
    minute: startParts.length > 1 ? int.tryParse(startParts[1]) ?? template.startMinute : 0,
  );
  final TimeOfDay? endTime = template.isTimePoint || firstPeriod.endTime.isEmpty
      ? null
      : () {
          final endParts = firstPeriod.endTime.split(':');
          return TimeOfDay(
            hour: int.tryParse(endParts[0]) ?? template.endHour,
            minute: endParts.length > 1 ? int.tryParse(endParts[1]) ?? template.endMinute : 0,
          );
        }();

  return FixedEventSelectionTimes(startTime: startTime, endTime: endTime);
}

/// 按传入顺序合并多个固定事件的备注。
///
/// 每个模板先取 `effectiveContent`（未填备注时回退为事件名称），内容为空串的跳过，
/// 其余用 `\n` 拼接。传入顺序就是用户在面板里的选中顺序。
String mergeFixedEventContents(Iterable<FixedEventTemplate> templates) {
  return templates.map((t) => t.effectiveContent).where((c) => c.isNotEmpty).join('\n');
}

/// 标签字段的必填校验，返回需要提示的文案；全部通过时返回 null。
///
/// 只拦两类会直接落成脏数据的字段：记账没有金额、睡眠没有时长。
/// 按草稿里的标签顺序检查，命中第一条即返回，保证提示与原先逐条 Toast 的顺序一致。
String? diaryTagValidationWarning(Iterable<TagEntry> tagEntries) {
  for (final entry in tagEntries) {
    if (entry.id == 'consumption' && entry.fields['amount'] == null) {
      return '请输入金额';
    }
    if (entry.id == 'sleep' && entry.fields['duration'] == null) {
      return '请输入睡眠时长';
    }
  }
  return null;
}

/// 草稿是否为空：正文去空白后为空、没有标签、也没有待发送图片。
///
/// 任一项有内容就算非空。与 `DiaryComposeDraft.isEmpty` 同一口径，
/// 抽出来是为了让发送与按钮禁用共用一份可测试的判断。
bool isDiaryDraftEmpty({required String inputText, required int tagEntryCount, required int photoCount}) {
  return inputText.trim().isEmpty && tagEntryCount == 0 && photoCount == 0;
}

/// 时间胶囊上的时间文案。
///
/// 时间线顶部已经显示当前选中的日期，所以同一天（[offset] 为空或 0）时只写 `HH:mm`；
/// 只有跨天补记才补上 `MM-dd` 前缀。输入输出均为纯值，偏移不改变传入的 [selectedDate]。
String formatDiaryTimeLabel(DateTime selectedDate, TimeOfDay time, {int? offset}) {
  final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (offset == null || offset == 0) {
    return timeStr;
  }
  final date = selectedDate.add(Duration(days: offset));
  return '${DateFormat('MM-dd').format(date)} $timeStr';
}

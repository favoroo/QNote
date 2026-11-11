import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/diary_record_sheet_logic.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/models/tag_entry.dart';

FixedEventTemplate _template({
  String id = 't1',
  String name = '晨跑',
  String startTime = '07:00',
  String endTime = '07:30',
  bool isTimePoint = false,
  String? content,
  List<TimePeriod>? timePeriods,
}) {
  return FixedEventTemplate(
    id: id,
    name: name,
    startTime: startTime,
    endTime: endTime,
    isTimePoint: isTimePoint,
    content: content,
    timePeriods: timePeriods,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

DiaryRecord _record({
  String id = 'r1',
  String title = '记录',
  String displayTag = '',
  Map<String, dynamic>? bodyState,
  DateTime? time,
  bool isDeleted = false,
}) {
  final at = time ?? DateTime(2026, 11, 11, 9);
  return DiaryRecord(
    id: id,
    title: title,
    time: at,
    displayTag: displayTag,
    bodyState: bodyState,
    isDeleted: isDeleted,
    createdAt: at,
    updatedAt: at,
  );
}

void main() {
  group('resolveDiarySelectionTimes 跨天偏移', () {
    test('同日起止：开始与结束偏移都是 0', () {
      final result = resolveDiarySelectionTimes(
        selectedDate: DateTime(2026, 11, 11),
        startTime: const TimeOfDay(hour: 9, minute: 0),
        startDate: DateTime(2026, 11, 11, 9),
        endTime: const TimeOfDay(hour: 10, minute: 30),
      );

      expect(result.startOffset, 0);
      expect(result.endOffset, 0);
      expect(result.startTime, const TimeOfDay(hour: 9, minute: 0));
      expect(result.endTime, const TimeOfDay(hour: 10, minute: 30));
    });

    test('跨天结束：结束日比选中日期晚一天，endOffset 为 1', () {
      final result = resolveDiarySelectionTimes(
        selectedDate: DateTime(2026, 11, 11),
        startTime: const TimeOfDay(hour: 22, minute: 0),
        startDate: DateTime(2026, 11, 11, 22),
        endTime: const TimeOfDay(hour: 7, minute: 0),
        endDate: DateTime(2026, 11, 12, 7),
      );

      expect(result.startOffset, 0);
      expect(result.endOffset, 1);
    });

    test('无结束时间（时间点）：endTime 为 null，endOffset 跟随开始日', () {
      final result = resolveDiarySelectionTimes(
        selectedDate: DateTime(2026, 11, 11),
        startTime: const TimeOfDay(hour: 22, minute: 15),
        startDate: DateTime(2026, 11, 10, 22, 15),
        endTime: null,
      );

      expect(result.startOffset, -1);
      expect(result.endOffset, -1, reason: '结束时间缺失时也要给出与开始一致的偏移');
      expect(result.endTime, isNull);
    });

    test('有结束时间但 endDate 为空：结束落在开始那天，沿用开始偏移', () {
      final result = resolveDiarySelectionTimes(
        selectedDate: DateTime(2026, 11, 11),
        startTime: const TimeOfDay(hour: 23, minute: 0),
        startDate: DateTime(2026, 11, 10, 23),
        endTime: const TimeOfDay(hour: 23, minute: 30),
        endDate: null,
      );

      expect(result.startOffset, -1);
      expect(result.endOffset, -1);
    });
  });

  group('resolveDiaryDateTime', () {
    test('无偏移时落在选中日期当天', () {
      final result = resolveDiaryDateTime(
        selectedDate: DateTime(2026, 11, 11),
        time: const TimeOfDay(hour: 8, minute: 5),
      );

      expect(result, DateTime(2026, 11, 11, 8, 5));
    });

    test('负偏移回到前一天，正偏移到后一天', () {
      final previous = resolveDiaryDateTime(
        selectedDate: DateTime(2026, 11, 11),
        time: const TimeOfDay(hour: 22, minute: 0),
        dayOffset: -1,
      );
      final next = resolveDiaryDateTime(
        selectedDate: DateTime(2026, 11, 11),
        time: const TimeOfDay(hour: 7, minute: 0),
        dayOffset: 1,
      );

      expect(previous, DateTime(2026, 11, 10, 22, 0));
      expect(next, DateTime(2026, 11, 12, 7, 0));
    });
  });

  group('isFixedEventAddedOnDate 固定事件去重', () {
    final date = DateTime(2026, 11, 11);
    final template = _template();

    test('优先按 bodyState 的 fixed_event_id 识别', () {
      final records = [
        _record(title: '完全不同的标题', bodyState: {'fixed_event_id': 't1'}),
      ];

      expect(isFixedEventAddedOnDate(template, date, records), isTrue);
    });

    test('fixed_event_id 命中时不再回退标题比对', () {
      final records = [
        _record(title: '晨跑', bodyState: {'fixed_event_id': 'other'}),
      ];

      expect(isFixedEventAddedOnDate(template, date, records), isFalse, reason: '有 id 元数据时以 id 为准，标题相同也不能误判');
    });

    test('其次按 bodyState 的 fixed_event_name 识别', () {
      final records = [
        _record(title: '别的标题', bodyState: {'fixed_event_name': '晨跑'}),
      ];

      expect(isFixedEventAddedOnDate(template, date, records), isTrue);
    });

    test('历史记录按 title 兜底识别', () {
      final records = [_record(title: '晨跑')];

      expect(isFixedEventAddedOnDate(template, date, records), isTrue);
    });

    test('历史记录按 displayTag 兜底识别', () {
      final records = [_record(title: '走了 8000 步', displayTag: '晨跑')];

      expect(isFixedEventAddedOnDate(template, date, records), isTrue);
    });

    test('已删除或不在目标日期的记录不算已添加', () {
      final records = [
        _record(id: 'deleted', title: '晨跑', isDeleted: true),
        _record(id: 'other-day', title: '晨跑', time: DateTime(2026, 11, 12, 9)),
      ];

      expect(isFixedEventAddedOnDate(template, date, records), isFalse);
    });
  });

  group('resolveFixedEventSelectionTimes 固定事件时间', () {
    test('多时间段只取第一个', () {
      final template = _template(
        timePeriods: [
          TimePeriod(startTime: '08:15', endTime: '11:45'),
          TimePeriod(startTime: '13:00', endTime: '18:00'),
        ],
      );

      final result = resolveFixedEventSelectionTimes(template);

      expect(result.startTime, const TimeOfDay(hour: 8, minute: 15));
      expect(result.endTime, const TimeOfDay(hour: 11, minute: 45));
    });

    test('时间点模式 endTime 为 null，即使时间段里写了结束时间', () {
      final template = _template(
        isTimePoint: true,
        timePeriods: [TimePeriod(startTime: '07:00', endTime: '07:30')],
      );

      final result = resolveFixedEventSelectionTimes(template);

      expect(result.startTime, const TimeOfDay(hour: 7, minute: 0));
      expect(result.endTime, isNull);
    });

    test('时间段结束为空串时 endTime 为 null', () {
      final template = _template(
        timePeriods: [TimePeriod(startTime: '21:30', endTime: '')],
      );

      final result = resolveFixedEventSelectionTimes(template);

      expect(result.startTime, const TimeOfDay(hour: 21, minute: 30));
      expect(result.endTime, isNull);
    });

    test('没有时间段时回退到模板自身的 startTime / endTime', () {
      final template = _template(startTime: '06:40', endTime: '07:10', timePeriods: const []);

      final result = resolveFixedEventSelectionTimes(template);

      expect(result.startTime, const TimeOfDay(hour: 6, minute: 40));
      expect(result.endTime, const TimeOfDay(hour: 7, minute: 10));
    });

    test('只有小时没有冒号时分钟按 0 处理', () {
      final template = _template(
        timePeriods: [TimePeriod(startTime: '09', endTime: '10')],
      );

      final result = resolveFixedEventSelectionTimes(template);

      expect(result.startTime, const TimeOfDay(hour: 9, minute: 0));
      expect(result.endTime, const TimeOfDay(hour: 10, minute: 0));
    });
  });

  group('mergeFixedEventContents 备注合并', () {
    test('按传入顺序换行拼接', () {
      final templates = [_template(id: 'a', content: '第一段'), _template(id: 'b', content: '第二段')];

      expect(mergeFixedEventContents(templates), '第一段\n第二段');
    });

    test('未填备注时回退事件名称', () {
      final templates = [_template(id: 'a', name: '晨跑', content: '')];

      expect(mergeFixedEventContents(templates), '晨跑');
    });

    test('内容和名称都为空时跳过该模板', () {
      final templates = [_template(id: 'a', name: '', content: ''), _template(id: 'b', name: '早饭', content: '')];

      expect(mergeFixedEventContents(templates), '早饭');
    });

    test('空集合得到空串', () {
      expect(mergeFixedEventContents(const []), '');
    });
  });

  group('diaryTagValidationWarning 标签必填校验', () {
    test('记账缺少金额', () {
      final entries = [TagEntry(id: 'consumption', name: '记账', fields: {})];

      expect(diaryTagValidationWarning(entries), '请输入金额');
    });

    test('记账金额为 0 也算已填写', () {
      final entries = [
        TagEntry(id: 'consumption', name: '记账', fields: {'amount': 0}),
      ];

      expect(diaryTagValidationWarning(entries), isNull);
    });

    test('睡眠缺少时长', () {
      final entries = [TagEntry(id: 'sleep', name: '睡眠', fields: {})];

      expect(diaryTagValidationWarning(entries), '请输入睡眠时长');
    });

    test('睡眠已填时长时通过', () {
      final entries = [
        TagEntry(id: 'sleep', name: '睡眠', fields: {'duration': 7.5}),
      ];

      expect(diaryTagValidationWarning(entries), isNull);
    });

    test('有标签字段但不在必填名单内时通过', () {
      final entries = [
        TagEntry(id: 'sport', name: '运动', fields: {'minutes': 30}),
      ];

      expect(diaryTagValidationWarning(entries), isNull);
    });

    test('同时缺金额和时长时先提示金额，保持原遍历顺序', () {
      final entries = [
        TagEntry(id: 'consumption', name: '记账', fields: {}),
        TagEntry(id: 'sleep', name: '睡眠', fields: {}),
      ];

      expect(diaryTagValidationWarning(entries), '请输入金额');
    });
  });

  group('isDiaryDraftEmpty 草稿是否为空', () {
    test('正文、标签、图片都为空时为空草稿', () {
      expect(isDiaryDraftEmpty(inputText: '', tagEntryCount: 0, photoCount: 0), isTrue);
    });

    test('纯空白正文仍算空草稿', () {
      expect(isDiaryDraftEmpty(inputText: '  \n\t ', tagEntryCount: 0, photoCount: 0), isTrue);
    });

    test('有正文时不为空', () {
      expect(isDiaryDraftEmpty(inputText: '喝了杯咖啡', tagEntryCount: 0, photoCount: 0), isFalse);
    });

    test('只有标签字段时不为空', () {
      expect(isDiaryDraftEmpty(inputText: '   ', tagEntryCount: 1, photoCount: 0), isFalse);
    });

    test('只有图片时不为空', () {
      expect(isDiaryDraftEmpty(inputText: '', tagEntryCount: 0, photoCount: 1), isFalse);
    });
  });

  group('formatDiaryTimeLabel 时间文案', () {
    final selectedDate = DateTime(2026, 11, 11);

    test('同一天只写时分', () {
      expect(formatDiaryTimeLabel(selectedDate, const TimeOfDay(hour: 9, minute: 5)), '09:05');
      expect(formatDiaryTimeLabel(selectedDate, const TimeOfDay(hour: 9, minute: 5), offset: 0), '09:05');
    });

    test('跨天补上 MM-dd 前缀', () {
      expect(formatDiaryTimeLabel(selectedDate, const TimeOfDay(hour: 22, minute: 0), offset: -1), '11-10 22:00');
      expect(formatDiaryTimeLabel(selectedDate, const TimeOfDay(hour: 7, minute: 30), offset: 1), '11-12 07:30');
    });
  });
}

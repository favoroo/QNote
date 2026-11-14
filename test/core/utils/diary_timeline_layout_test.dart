import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/diary_timeline_layout.dart';

void main() {
  group('diaryDateOnly', () {
    test('归一到当天零点，忽略时分秒', () {
      expect(diaryDateOnly(DateTime(2026, 11, 11, 23, 59, 58)), DateTime(2026, 11, 11));
      expect(diaryDateOnly(DateTime(2026, 11, 11)), DateTime(2026, 11, 11));
    });
  });

  group('diaryDateKey', () {
    test('年月日补零，同一天不同时刻得到同一个键', () {
      expect(diaryDateKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(diaryDateKey(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
    });

    test('年份不足四位时补零', () {
      expect(diaryDateKey(DateTime(999, 12, 31)), '0999-12-31');
    });
  });

  group('diaryDayOffset', () {
    test('同一天任意时刻偏移为 0', () {
      final start = DateTime(2026, 11, 11, 23, 30);
      expect(diaryDayOffset(DateTime(2026, 11, 11, 0, 5), start), 0);
      expect(diaryDayOffset(DateTime(2026, 11, 11, 23, 59), start), 0);
    });

    test('跨月按自然日计数', () {
      final start = DateTime(2026, 1, 31);
      expect(diaryDayOffset(DateTime(2026, 2, 1), start), 1);
      expect(diaryDayOffset(DateTime(2026, 3, 1), start), 29);
    });

    test('跨年按自然日计数', () {
      final start = DateTime(2025, 12, 20);
      expect(diaryDayOffset(DateTime(2026, 1, 5), start), 16);
    });

    test('闰年 2 月 29 日计为一天', () {
      expect(diaryDayOffset(DateTime(2024, 3, 1), DateTime(2024, 2, 28)), 2);
      expect(diaryDayOffset(DateTime(2023, 3, 1), DateTime(2023, 2, 28)), 1);
    });

    test('目标早于窗口起点时返回负数', () {
      expect(diaryDayOffset(DateTime(2026, 2, 28), DateTime(2026, 3, 1)), -1);
    });

    test('窗口起点带时分秒时也先归一到零点', () {
      final start = DateTime(2026, 11, 11, 18, 30);
      expect(diaryDayOffset(DateTime(2026, 11, 12, 1), start), 1);
    });
  });

  group('diaryDateForDayOffset', () {
    test('偏移 0 返回窗口起点当天零点', () {
      expect(diaryDateForDayOffset(DateTime(2026, 1, 31, 15), 0), DateTime(2026, 1, 31));
    });

    test('跨月推进', () {
      final start = DateTime(2026, 1, 31);
      expect(diaryDateForDayOffset(start, 1), DateTime(2026, 2, 1));
      expect(diaryDateForDayOffset(start, 29), DateTime(2026, 3, 1));
    });

    test('跨年推进', () {
      expect(diaryDateForDayOffset(DateTime(2025, 12, 31), 1), DateTime(2026, 1, 1));
    });

    test('闰年 2 月 29 日不会被跳过', () {
      final start = DateTime(2024, 2, 28);
      expect(diaryDateForDayOffset(start, 1), DateTime(2024, 2, 29));
      expect(diaryDateForDayOffset(start, 2), DateTime(2024, 3, 1));
      expect(diaryDateForDayOffset(DateTime(2023, 2, 28), 1), DateTime(2023, 3, 1));
    });

    test('负偏移回到窗口起点之前', () {
      expect(diaryDateForDayOffset(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });
  });

  group('isSameCalendarDay / isTodayDate', () {
    test('同一天不同时刻判等', () {
      expect(isSameCalendarDay(DateTime(2026, 11, 11, 0, 1), DateTime(2026, 11, 11, 23, 59)), isTrue);
    });

    test('不同日、月、年都不相等', () {
      final date = DateTime(2026, 11, 11, 12);
      expect(isSameCalendarDay(date, DateTime(2026, 11, 12, 12)), isFalse);
      expect(isSameCalendarDay(date, DateTime(2026, 12, 11, 12)), isFalse);
      expect(isSameCalendarDay(date, DateTime(2025, 11, 11, 12)), isFalse);
    });

    test('今天判断使用注入的 today，忽略时刻', () {
      final today = DateTime(2026, 11, 11, 20, 30);
      expect(isTodayDate(DateTime(2026, 11, 11, 0, 5), today), isTrue);
      expect(isTodayDate(DateTime(2026, 11, 10, 23, 59), today), isFalse);
      expect(isTodayDate(DateTime(2025, 11, 11), today), isFalse);
    });
  });

  group('isDiaryDateExpandedByDefault', () {
    test('昨天、今天、明天默认展开', () {
      final today = DateTime(2026, 11, 11, 9);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 11, 10), today), isTrue);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 11, 11), today), isTrue);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 11, 12), today), isTrue);
    });

    test('更早或更晚的日期默认折叠', () {
      final today = DateTime(2026, 11, 11);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 11, 9), today), isFalse);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 11, 13), today), isFalse);
      expect(isDiaryDateExpandedByDefault(DateTime(2025, 11, 11), today), isFalse);
    });

    test('跨月、跨年边界仍以日历日为准', () {
      final monthStart = DateTime(2026, 3, 1);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 2, 28), monthStart), isTrue);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 3, 2), monthStart), isTrue);

      final yearStart = DateTime(2026, 1, 1);
      expect(isDiaryDateExpandedByDefault(DateTime(2025, 12, 31), yearStart), isTrue);
      expect(isDiaryDateExpandedByDefault(DateTime(2026, 1, 2), yearStart), isTrue);
    });
  });

  group('日期文案', () {
    test('今天标题与分隔栏按现有格式输出', () {
      final today = DateTime(2026, 11, 11, 18, 30);
      expect(formatDiaryDateTitle(today), '26年11月11日 周三');
      expect(formatDiaryDividerDate(today), '11月11日 周三');
    });

    test('昨天标题与分隔栏按现有格式输出', () {
      final yesterday = DateTime(2026, 11, 10);
      expect(formatDiaryDateTitle(yesterday), '26年11月10日 周二');
      expect(formatDiaryDividerDate(yesterday), '11月10日 周二');
    });

    test('普通日期月日补零，闰日正常展示', () {
      expect(formatDiaryDateTitle(DateTime(2024, 2, 29)), '24年02月29日 周四');
      expect(formatDiaryDateTitle(DateTime(2026, 1, 5)), '26年01月05日 周一');
      expect(formatDiaryDividerDate(DateTime(2024, 2, 29)), '2月29日 周四');
    });

    test('跨年分隔栏不显示年份', () {
      expect(formatDiaryDividerDate(DateTime(2027, 1, 1)), '1月1日 周五');
    });
  });

  group('diaryTimelineNodeIndex', () {
    test('按 30 分钟分桶，忽略秒', () {
      expect(diaryTimelineNodeIndex(DateTime(2026, 11, 11, 0, 0)), 0);
      expect(diaryTimelineNodeIndex(DateTime(2026, 11, 11, 0, 29, 59)), 0);
      expect(diaryTimelineNodeIndex(DateTime(2026, 11, 11, 0, 30)), 1);
      expect(diaryTimelineNodeIndex(DateTime(2026, 11, 11, 9, 59)), 19);
      expect(diaryTimelineNodeIndex(DateTime(2026, 11, 11, 12, 30)), 25);
      expect(diaryTimelineNodeIndex(DateTime(2026, 11, 11, 23, 59)), 47);
    });
  });

  group('diaryDragPreviewText', () {
    test('优先展示裁剪后的正文', () {
      expect(diaryDragPreviewText(content: '  正文内容  ', title: '标题', photoCount: 2), '正文内容');
    });

    test('正文为空时退回标题', () {
      expect(diaryDragPreviewText(content: '   ', title: ' 标题 ', photoCount: 0), '标题');
    });

    test('正文和标题都为空时按图片数量展示', () {
      expect(diaryDragPreviewText(content: '', title: '', photoCount: 3), '3 张图片');
    });

    test('没有任何内容时展示兜底文案', () {
      expect(diaryDragPreviewText(content: '', title: '', photoCount: 0), '一条记录');
    });
  });

  group('calculateDiaryDaysHeight', () {
    test('0 天或负数天返回 0', () {
      expect(calculateDiaryDaysHeight(startDate: DateTime(2026, 11, 11), daysCount: 0, isExpanded: (_) => true), 0);
      expect(calculateDiaryDaysHeight(startDate: DateTime(2026, 11, 11), daysCount: -3, isExpanded: (_) => true), 0);
    });

    test('单天折叠只计算分割栏', () {
      expect(
        calculateDiaryDaysHeight(startDate: DateTime(2026, 11, 11), daysCount: 1, isExpanded: (_) => false),
        kDiaryTimelineDividerHeight,
      );
    });

    test('单天展开计算分割栏与 48 个节点', () {
      expect(
        calculateDiaryDaysHeight(startDate: DateTime(2026, 11, 11), daysCount: 1, isExpanded: (_) => true),
        80 + 48 * 48,
      );
    });

    test('多天混合展开状态并按天累加记录额外高度', () {
      final start = DateTime(2026, 11, 11);
      final total = calculateDiaryDaysHeight(
        startDate: start,
        daysCount: 3,
        isExpanded: (date) => date.day == 12,
        recordCountForDate: (date) => date.day == 12 ? 2 : 0,
      );

      // 11 日折叠 80 + 12 日展开 80+2304+2*130 + 13 日折叠 80
      expect(total, 80 + 80 + 48 * 48 + 2 * 130 + 80);
    });

    test('记录数回调为空时按 0 条处理', () {
      expect(
        calculateDiaryDaysHeight(startDate: DateTime(2026, 11, 11), daysCount: 1, isExpanded: (_) => true),
        80 + 48 * 48,
      );
    });

    test('支持自定义分割栏、节点与记录额外高度', () {
      final total = calculateDiaryDaysHeight(
        startDate: DateTime(2024, 2, 28),
        daysCount: 2,
        isExpanded: (date) => date.day == 29,
        recordCountForDate: (_) => 2,
        dividerHeight: 100,
        nodeHeight: 10,
        averageRecordExtraHeight: 5,
      );

      // 2 月 28 日折叠 100 + 2 月 29 日展开 100+48*10+2*5
      expect(total, 100 + 100 + 48 * 10 + 2 * 5);
    });
  });

  group('estimateDiaryOffsetForIndex', () {
    test('目标下标为 0 时偏移为 0', () {
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 0,
          measuredHeights: const {},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => true,
        ),
        0,
      );
    });

    test('已测量高度优先于固定高度', () {
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 3,
          measuredHeights: const {0: 100, 1: 20, 2: 7},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => true,
        ),
        127,
      );
    });

    test('未测量时分割栏与展开节点分别计数', () {
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 1,
          measuredHeights: const {},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => true,
        ),
        kDiaryTimelineDividerHeight,
      );
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 2,
          measuredHeights: const {},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => true,
        ),
        kDiaryTimelineDividerHeight + kDiaryTimelineNodeHeight,
      );
    });

    test('折叠日期的节点不产生高度', () {
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 49,
          measuredHeights: const {},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => false,
        ),
        kDiaryTimelineDividerHeight,
      );
    });

    test('跨天累加完整一天的展开高度', () {
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 49,
          measuredHeights: const {},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => true,
        ),
        kDiaryTimelineDividerHeight + 48 * kDiaryTimelineNodeHeight,
      );
    });

    test('目标下标超出窗口时仍按日期继续累加', () {
      // 第 2 天的分割栏（下标 49）再加 10 个节点
      expect(
        estimateDiaryOffsetForIndex(
          targetIndex: 60,
          measuredHeights: const {},
          windowStartDate: DateTime(2026, 11, 11),
          isExpanded: (_) => false,
        ),
        2 * kDiaryTimelineDividerHeight,
      );
    });
  });

  group('estimateDiaryOffsetForTimeWithRecords', () {
    final start = DateTime(2026, 11, 11);
    final laterToday = DateTime(2026, 11, 13);

    test('折叠日期且无记录时只计算顶部内边距与分割栏', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => false,
      );

      expect(offset, kDiaryTimelineTopPadding + kDiaryTimelineDividerHeight);
    });

    test('展开日期无记录时按节点下标累加并补节点半高', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => true,
      );

      // 12 + 80 + 18*48 + 24
      expect(offset, 12 + 80 + 18 * 48 + 24);
    });

    test('目标节点之前的单条记录增加额外高度', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9, 30),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => true,
        displayTimesForDate: (_) => [DateTime(2026, 11, 11, 8)],
      );

      // 12 + 80 + 19*48 + 130 + 24
      expect(offset, 12 + 80 + 19 * 48 + 130 + 24);
    });

    test('多条记录只累加目标节点之前的记录', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 10),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => true,
        displayTimesForDate: (_) => [
          DateTime(2026, 11, 11, 8),
          DateTime(2026, 11, 11, 9, 45),
          DateTime(2026, 11, 11, 10, 30),
        ],
      );

      // 12 + 80 + 20*48 + 2*130 + 24
      expect(offset, 12 + 80 + 20 * 48 + 2 * 130 + 24);
    });

    test('目标日之前的展开日期按满节点与记录数累加', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9),
        windowStartDate: DateTime(2026, 11, 10),
        today: laterToday,
        isExpanded: (_) => true,
        recordCountForDate: (date) => date.day == 10 ? 2 : 0,
        displayTimesForDate: (_) => const [],
      );

      const previousDay = 80 + 48 * 48 + 2 * 130;
      const targetDay = 80 + 18 * 48 + 24;
      expect(offset, 12 + previousDay + targetDay);
    });

    test('今天非整点/半点时补当前时刻指示节点', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9, 15),
        windowStartDate: start,
        today: start,
        isExpanded: (_) => true,
      );

      // 12 + 80 + 18*48 + 指示节点半高 24 + 节点半高 24
      expect(offset, 12 + 80 + 18 * 48 + 24 + 24);
    });

    test('今天整点或半点时不补当前时刻指示节点', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9, 30),
        windowStartDate: start,
        today: start,
        isExpanded: (_) => true,
      );

      expect(offset, 12 + 80 + 19 * 48 + 24);
    });

    test('目标早于窗口起点时只返回顶部内边距', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 9, 9),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => true,
      );

      expect(offset, kDiaryTimelineTopPadding);
    });

    test('目标晚于窗口末尾时不裁剪，继续累加沿途分割栏', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 13, 0),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => false,
      );

      // 11、12、13 日各一个分割栏
      expect(offset, 12 + 3 * 80);
    });

    test('记录回调为空时按无记录处理', () {
      final offset = estimateDiaryOffsetForTimeWithRecords(
        targetTime: DateTime(2026, 11, 11, 9),
        windowStartDate: start,
        today: laterToday,
        isExpanded: (_) => true,
        recordCountForDate: null,
        displayTimesForDate: null,
      );

      expect(offset, 12 + 80 + 18 * 48 + 24);
    });
  });

  group('resolveTimelineRecordAnchor', () {
    test('单选直接落在选中时刻', () {
      expect(resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 19, 30)), DateTime(2026, 11, 11, 19, 30));
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 22, 13)),
        DateTime(2026, 11, 11, 22, 13),
        reason: '非半小时的选中时刻由专用节点渲染，加号仍跟着它',
      );
    });

    test('区间取末端所在的半小时节点', () {
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 19, 30), end: DateTime(2026, 11, 11, 21, 0)),
        DateTime(2026, 11, 11, 21, 0),
      );
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 19, 30), end: DateTime(2026, 11, 11, 21, 10)),
        DateTime(2026, 11, 11, 21, 0),
        reason: '末端不是整半点时，加号贴在包含它的节点上',
      );
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 19, 30), end: DateTime(2026, 11, 11, 21, 40)),
        DateTime(2026, 11, 11, 21, 30),
      );
    });

    test('区间完全落在两个节点之间时退回起点', () {
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 22, 5), end: DateTime(2026, 11, 11, 22, 13)),
        DateTime(2026, 11, 11, 22, 5),
      );
    });

    test('跨天区间取结束日期的节点', () {
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 23, 30), end: DateTime(2026, 11, 12, 0, 0)),
        DateTime(2026, 11, 12, 0, 0),
      );
      expect(
        resolveTimelineRecordAnchor(start: DateTime(2026, 11, 11, 23, 30), end: DateTime(2026, 11, 12, 1, 10)),
        DateTime(2026, 11, 12, 1, 0),
      );
    });
  });

  group('buildDiaryTimelineSegments', () {
    final start = DateTime(2026, 11, 10);

    test('天数非正数返回空列表', () {
      expect(buildDiaryTimelineSegments(windowStartDate: start, daysCount: 0, hasBody: (_) => true), isEmpty);
      expect(buildDiaryTimelineSegments(windowStartDate: start, daysCount: -3, hasBody: (_) => false), isEmpty);
    });

    test('全部折叠时合并为单个仅含分隔栏的分段', () {
      final segments = buildDiaryTimelineSegments(windowStartDate: start, daysCount: 10, hasBody: (_) => false);

      expect(segments, hasLength(1));
      expect(segments.first.startDayOffset, 0);
      expect(segments.first.endDayOffset, 9);
      expect(segments.first.dividerCount, 10);
      expect(segments.first.hasExpandedBody, isFalse);
    });

    test('仅中间一天展开时切分为前段展开与后段纯折叠', () {
      final target = DateTime(2026, 11, 14); // offset 4
      final segments = buildDiaryTimelineSegments(
        windowStartDate: start,
        daysCount: 10,
        hasBody: (d) => isSameCalendarDay(d, target),
      );

      expect(segments, hasLength(2));
      expect(segments[0].startDayOffset, 0);
      expect(segments[0].endDayOffset, 4);
      expect(segments[0].dividerCount, 5);
      expect(segments[0].hasExpandedBody, isTrue);

      expect(segments[1].startDayOffset, 5);
      expect(segments[1].endDayOffset, 9);
      expect(segments[1].dividerCount, 5);
      expect(segments[1].hasExpandedBody, isFalse);
    });

    test('多天与相邻天展开时无遗漏无重叠覆盖整个窗口', () {
      // offset 2, 3, 9 展开
      final expandedOffsets = {2, 3, 9};
      final segments = buildDiaryTimelineSegments(
        windowStartDate: start,
        daysCount: 10,
        hasBody: (d) => expandedOffsets.contains(diaryDayOffset(d, start)),
      );

      expect(segments, hasLength(3));
      expect(segments.map((s) => (s.startDayOffset, s.endDayOffset, s.hasExpandedBody)).toList(), [
        (0, 2, true),
        (3, 3, true),
        (4, 9, true),
      ]);

      final covered = <int>[];
      for (final seg in segments) {
        for (var i = seg.startDayOffset; i <= seg.endDayOffset; i++) {
          covered.add(i);
        }
      }
      expect(covered, List.generate(10, (i) => i));
    });
  });

  group('resolveDiaryTimelineSlot', () {
    final slot1400 = DateTime(2026, 11, 14, 14, 0);
    final slot1430 = DateTime(2026, 11, 14, 14, 30);

    test('未选中且当前时刻非整半点时，仅展示未选中的当前时间专用节点', () {
      final slot = resolveDiaryTimelineSlot(
        slotStart: slot1400,
        nodeIndex: 28,
        now: DateTime(2026, 11, 14, 14, 15),
        isToday: true,
      );

      expect(slot.isStandardNodeSelected, isFalse);
      expect(slot.isStandardNodeCurrentTime, isFalse);
      expect(slot.dedicatedSelectedStart, isNull);
      expect(slot.dedicatedSelectedCurrentTime, isNull);
      expect(slot.dedicatedSelectedEnd, isNull);
      expect(slot.dedicatedCurrentTime, DateTime(2026, 11, 14, 14, 15));
    });

    test('点击当前时间（非整半点）后只选中该时刻，不再额外渲染未选中当前时间节点', () {
      final now = DateTime(2026, 11, 14, 14, 15);
      final slot = resolveDiaryTimelineSlot(
        slotStart: slot1400,
        nodeIndex: 28,
        now: now,
        isToday: true,
        selectionStart: now,
      );

      expect(slot.isStandardNodeSelected, isFalse);
      expect(slot.dedicatedSelectedStart, now);
      expect(slot.dedicatedSelectedCurrentTime, isNull);
      expect(slot.dedicatedSelectedEnd, isNull);
      expect(slot.dedicatedCurrentTime, isNull);
    });

    test('选中了早前的非整半点后当前时间推进到新分钟，旧选中与新当前时间各自独立展示', () {
      final slot = resolveDiaryTimelineSlot(
        slotStart: slot1400,
        nodeIndex: 28,
        now: DateTime(2026, 11, 14, 14, 18),
        isToday: true,
        selectionStart: DateTime(2026, 11, 14, 14, 10),
      );

      expect(slot.dedicatedSelectedStart, DateTime(2026, 11, 14, 14, 10));
      expect(slot.dedicatedCurrentTime, DateTime(2026, 11, 14, 14, 18));
      expect(slot.dedicatedSelectedCurrentTime, isNull);
    });

    test('跨当前时间的多选区间内，当前时间渲染为已选中专用节点', () {
      final slot = resolveDiaryTimelineSlot(
        slotStart: slot1400,
        nodeIndex: 28,
        now: DateTime(2026, 11, 14, 14, 15),
        isToday: true,
        selectionStart: DateTime(2026, 11, 14, 14, 0),
        selectionEnd: DateTime(2026, 11, 14, 15, 0),
      );

      expect(slot.isStandardNodeSelected, isTrue);
      expect(slot.dedicatedSelectedStart, isNull);
      expect(slot.dedicatedSelectedCurrentTime, DateTime(2026, 11, 14, 14, 15));
      expect(slot.dedicatedSelectedEnd, isNull);
      expect(slot.dedicatedCurrentTime, isNull);
    });

    test('区间终点落在非整半点（如先点当前时间再向上扩到 14:00）时也正确渲染并去重', () {
      final now = DateTime(2026, 11, 14, 14, 15);
      final slot = resolveDiaryTimelineSlot(
        slotStart: slot1400,
        nodeIndex: 28,
        now: now,
        isToday: true,
        selectionStart: DateTime(2026, 11, 14, 14, 0),
        selectionEnd: now,
      );

      expect(slot.isStandardNodeSelected, isTrue);
      expect(slot.dedicatedSelectedStart, isNull);
      expect(slot.dedicatedSelectedCurrentTime, isNull);
      expect(slot.dedicatedSelectedEnd, now);
      expect(slot.dedicatedCurrentTime, isNull);
    });

    test('整点或半点时内联在标准节点展示当前时间，不生成专用行', () {
      final slot = resolveDiaryTimelineSlot(
        slotStart: slot1430,
        nodeIndex: 29,
        now: DateTime(2026, 11, 14, 14, 30),
        isToday: true,
        selectionStart: DateTime(2026, 11, 14, 14, 30),
      );

      expect(slot.isStandardNodeSelected, isTrue);
      expect(slot.isStandardNodeCurrentTime, isTrue);
      expect(slot.dedicatedSelectedStart, isNull);
      expect(slot.dedicatedSelectedCurrentTime, isNull);
      expect(slot.dedicatedCurrentTime, isNull);
    });

    test('非当天节点即使时刻一致也不展示当前时间', () {
      final slot = resolveDiaryTimelineSlot(
        slotStart: DateTime(2026, 11, 13, 14, 0),
        nodeIndex: 28,
        now: DateTime(2026, 11, 14, 14, 15),
        isToday: false,
      );

      expect(slot.isStandardNodeCurrentTime, isFalse);
      expect(slot.dedicatedCurrentTime, isNull);
    });
  });
}

import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';
import 'package:qnote_flutter/widgets/diary/diary_input_bar.dart';
import 'package:qnote_flutter/widgets/diary/custom_date_picker.dart';

class DiaryPage extends ConsumerStatefulWidget {
  const DiaryPage({super.key});

  @override
  ConsumerState<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends ConsumerState<DiaryPage> with WidgetsBindingObserver {
  static const int _itemsPerDay = 49;
  static const double _dayHeight = 2384.0;
  static const double _dividerHeight = 80.0;
  static const double _nodeHeight = 48.0;

  late DateTime _today;
  late DateTime _windowStartDate;
  int _windowDays = 7;
  late ScrollController _scrollController;
  final GlobalKey _viewportKey = GlobalKey();
  // GlobalKey placed on the current-time node so we can read its actual RenderBox position
  final GlobalKey _currentTimeNodeKey = GlobalKey();
  int? _dragStartIndex;
  int? _dragEndIndex;
  bool _isShiftingWindow = false;
  double? _shiftTargetOffset;
  final Map<int, BuildContext> _itemContexts = {};
  final Map<int, double> _itemHeights = {};
  Timer? _autoScrollTimer;
  Offset? _lastDragPosition;
  bool _isScrollingFromList = false;
  bool _hasPerformedInitialScroll = false;
  bool _isProgrammaticScrolling = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _windowStartDate = _today.subtract(const Duration(days: 3));
    _hasPerformedInitialScroll = false;
    _itemContexts.clear();
    _itemHeights.clear();

    _scrollController = ScrollController(
      keepScrollOffset: false,
    );
    _scrollController.addListener(_onScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  double _estimateOffsetForIndex(int targetIndex) {
    double offset = 0;
    for (int i = 0; i < targetIndex; i++) {
      if (_itemHeights.containsKey(i)) {
        offset += _itemHeights[i]!;
      } else if (i % _itemsPerDay == 0) {
        offset += _dividerHeight;
      } else {
        offset += _nodeHeight;
      }
    }
    return offset;
  }

  static const double _averageRecordExtraHeight = 80.0;

  double _estimateOffsetForTimeWithRecords(
    DateTime targetTime,
    Map<String, List<DiaryRecord>> recordsByDate,
  ) {
    final targetDate = DateTime(targetTime.year, targetTime.month, targetTime.day);
    final dayOffset = _dateToDayOffset(targetDate);
    final nodeIndex = targetTime.hour * 2 + (targetTime.minute >= 30 ? 1 : 0);

    double offset = 0;
    for (int d = 0; d <= dayOffset; d++) {
      final date = _indexToDate(d);
      final dateKey = '${date.year}-${date.month}-${date.day}';
      final dayRecords = recordsByDate[dateKey] ?? [];

      offset += _dividerHeight;

      if (d < dayOffset) {
        offset += 48 * _nodeHeight;
        offset += dayRecords.length * _averageRecordExtraHeight;
      } else {
        offset += nodeIndex * _nodeHeight;
        for (final r in dayRecords) {
          final rNodeIndex = r.time.hour * 2 + (r.time.minute >= 30 ? 1 : 0);
          if (rNodeIndex < nodeIndex) {
            offset += _averageRecordExtraHeight;
          }
        }
      }
    }

    return offset;
  }

  void _performInitialScrollToCurrentTime(
    Map<String, List<DiaryRecord>> recordsByDate, {
    int frameCount = 0,
  }) {
    if (!_scrollController.hasClients || !mounted) {
      if (frameCount < 20) {
        Future.delayed(const Duration(milliseconds: 50), () {
          if (mounted) {
            _performInitialScrollToCurrentTime(recordsByDate, frameCount: frameCount + 1);
          }
        });
      }
      return;
    }

    final now = DateTime.now();
    final estimatedOffset = _estimateOffsetForTimeWithRecords(now, recordsByDate);
    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final targetOffset = (estimatedOffset - viewportHeight / 2).clamp(0.0, maxScroll);

    _isProgrammaticScrolling = true;
    _scrollController.jumpTo(targetOffset);

    if (frameCount < 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            _performInitialScrollToCurrentTime(recordsByDate, frameCount: frameCount + 1);
          }
        });
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _isProgrammaticScrolling = false;
      });
    }

    ref.read(selectedDateProvider.notifier).state = DateTime(now.year, now.month, now.day);
  }

  void _scrollToTarget({
    required int targetIndex,
    GlobalKey? targetKey,
    bool smooth = true,
    double alignment = 0.5,
    int attempts = 0,
    Map<String, List<DiaryRecord>>? recordsByDate,
    DateTime? targetTime,
  }) {
    if (!_scrollController.hasClients) return;

    if (attempts == 0) {
      _isProgrammaticScrolling = true;
    }

    if (attempts > 15) {
      _fallbackScroll(targetIndex, smooth, alignment);
      return;
    }

    BuildContext? targetContext;
    if (targetKey != null) {
      targetContext = targetKey.currentContext;
    }
    targetContext ??= _itemContexts[targetIndex];

    if (targetContext != null && targetContext.mounted) {
      _scrollToContext(targetContext, smooth: smooth, alignment: alignment);
      return;
    }

    double estimatedOffset;
    if (attempts == 0 && recordsByDate != null && targetTime != null) {
      estimatedOffset = _estimateOffsetForTimeWithRecords(targetTime, recordsByDate);
    } else {
      estimatedOffset = _estimateOffsetForIndex(targetIndex);
    }
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = (estimatedOffset - viewportHeight * alignment)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    _scrollController.jumpTo(targetOffset);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          _scrollToTarget(
            targetIndex: targetIndex,
            targetKey: targetKey,
            smooth: smooth,
            alignment: alignment,
            attempts: attempts + 1,
          );
        }
      });
    });
  }

  void _scrollToContext(BuildContext targetContext, {
    bool smooth = true,
    double alignment = 0.5,
  }) {
    if (!targetContext.mounted) return;

    final renderBox = targetContext.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: alignment,
        duration: smooth ? const Duration(milliseconds: 400) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      _finishProgrammaticScroll();
      return;
    }

    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: alignment,
        duration: smooth ? const Duration(milliseconds: 400) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      _finishProgrammaticScroll();
      return;
    }

    final viewportHeight = viewportBox.size.height;
    final nodeHeight = renderBox.size.height;
    final viewportTopOnScreen = viewportBox.localToGlobal(Offset.zero).dy;
    final nodeTopOnScreen = renderBox.localToGlobal(Offset.zero).dy;
    final scrollOffset = _scrollController.offset;
    final nodeTopInScroll = scrollOffset + (nodeTopOnScreen - viewportTopOnScreen);
    final preciseTarget = (nodeTopInScroll - (viewportHeight - nodeHeight) * alignment)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    if ((scrollOffset - preciseTarget).abs() < 5.0) {
      _finishProgrammaticScroll();
      return;
    }

    if (smooth) {
      _scrollController.animateTo(
        preciseTarget,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      ).then((_) {
        if (mounted) {
          _finishProgrammaticScroll();
        }
      });
    } else {
      _scrollController.jumpTo(preciseTarget);
      _finishProgrammaticScroll();
    }
  }

  void _fallbackScroll(int targetIndex, bool smooth, double alignment) {
    final estimatedOffset = _estimateOffsetForIndex(targetIndex);
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = (estimatedOffset - viewportHeight * alignment)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    if (smooth) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      ).then((_) {
        if (mounted) {
          _finishProgrammaticScroll();
        }
      });
    } else {
      _scrollController.jumpTo(targetOffset);
      _finishProgrammaticScroll();
    }
  }

  void _finishProgrammaticScroll() {
    _isProgrammaticScrolling = false;
  }

  void _scrollToCurrentTime({
    bool smooth = true,
    Map<String, List<DiaryRecord>>? recordsByDate,
  }) {
    if (!_scrollController.hasClients) return;

    final now = DateTime.now();
    final dayOffset = _dateToDayOffset(now);

    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(now);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCurrentTime(smooth: smooth, recordsByDate: recordsByDate);
      });
      return;
    }

    final nodeIndex = now.hour * 2 + (now.minute >= 30 ? 1 : 0);
    final targetIndex = dayOffset * _itemsPerDay + (nodeIndex + 1);

    _scrollToTarget(
      targetIndex: targetIndex,
      targetKey: _currentTimeNodeKey,
      smooth: smooth,
      alignment: 0.5,
      recordsByDate: recordsByDate,
      targetTime: now,
    );

    ref.read(selectedDateProvider.notifier).state = DateTime(now.year, now.month, now.day);
  }

  void _scrollToTime(DateTime targetTime, {bool smooth = true}) {
    if (!_scrollController.hasClients) return;

    final dayOffset = _dateToDayOffset(targetTime);

    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(targetTime);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToTime(targetTime, smooth: smooth);
      });
      return;
    }

    final nodeIndex = targetTime.hour * 2 + (targetTime.minute >= 30 ? 1 : 0);
    final targetIndex = dayOffset * _itemsPerDay + (nodeIndex + 1);

    _scrollToTarget(
      targetIndex: targetIndex,
      smooth: smooth,
      alignment: 0.5,
    );

    ref.read(selectedDateProvider.notifier).state = DateTime(targetTime.year, targetTime.month, targetTime.day);
  }

  void _handleNodeTap(DateTime date, TimeOfDay time) {
    final selectEvent = ref.read(diaryInputTimeProvider);
    
    if (selectEvent == null || selectEvent.endTime == null) {
      if (selectEvent != null &&
          _isSameDay(selectEvent.date, date) &&
          selectEvent.time.hour == time.hour &&
          selectEvent.time.minute == time.minute) {
        ref.read(diaryInputTimeProvider.notifier).state = null;
      } else {
        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
          time,
          date: date,
        );
      }
      return;
    }

    final clickedDateTime = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    final selectionStart = DateTime(
      selectEvent.date.year,
      selectEvent.date.month,
      selectEvent.date.day,
      selectEvent.time.hour,
      selectEvent.time.minute,
    );

    final selEndDate = selectEvent.endDate ?? selectEvent.date;
    final selectionEnd = DateTime(
      selEndDate.year,
      selEndDate.month,
      selEndDate.day,
      selectEvent.endTime!.hour,
      selectEvent.endTime!.minute,
    );

    if (clickedDateTime.isAtSameMomentAs(selectionStart)) {
      // 1. 点击开始时间节点：取消全部勾选
      ref.read(diaryInputTimeProvider.notifier).state = null;
    } else if (clickedDateTime.isAfter(selectionStart) && !clickedDateTime.isAfter(selectionEnd)) {
      // 2. 点击范围内的某个节点（排除开始节点）：将该节点及之后的节点取消勾选，即新范围是 [开始, 点击节点 - 30分钟]
      final newEndDateTime = clickedDateTime.subtract(const Duration(minutes: 30));
      final newEndTime = TimeOfDay(hour: newEndDateTime.hour, minute: newEndDateTime.minute);
      
      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        selectEvent.time,
        endTime: newEndTime,
        date: selectEvent.date,
        endDate: DateTime(newEndDateTime.year, newEndDateTime.month, newEndDateTime.day),
      );
    } else if (clickedDateTime.isAfter(selectionEnd)) {
      // 3. 点击结束节点之后的节点：将范围延长到该节点，即新范围是 [开始, 点击节点]
      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        selectEvent.time,
        endTime: time,
        date: selectEvent.date,
        endDate: date,
      );
    } else if (clickedDateTime.isBefore(selectionStart)) {
      // 4. 点击开始节点之前的节点：将范围向左（前）延长，即新范围是 [点击节点, 结束]
      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        time,
        endTime: selectEvent.endTime,
        date: date,
        endDate: selEndDate,
      );
    }
  }

  void _handleNodeDoubleTap(DateTime date, TimeOfDay time) {
    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
      time,
      date: date,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final now = DateTime.now();
      final todayNow = DateTime(now.year, now.month, now.day);
      if (!_isSameDay(_today, todayNow)) {
        setState(() {
          _today = todayNow;
          _windowStartDate = _today.subtract(const Duration(days: 3));
        });
        _scrollToCurrentTime(smooth: true);
      }
    }
  }

  @override
  void dispose() {
    try {
      ScaffoldMessenger.of(context).clearSnackBars();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoScrollTimer();
    _itemContexts.clear();
    _itemHeights.clear();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isShiftingWindow || _isProgrammaticScrolling || !_scrollController.hasClients) return;

    final offset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (offset < viewportHeight * 0.5 && _windowStartDate.isBefore(_today)) {
      _shiftWindowBackward();
    } else if (offset > maxScroll - viewportHeight * 0.5) {
      _shiftWindowForward();
    }

    // Determine currently visible date based on the exact center of the viewport
    final viewportCtx = _viewportKey.currentContext;
    if (viewportCtx != null) {
      final RenderBox? viewportBox = viewportCtx.findRenderObject() as RenderBox?;
      if (viewportBox != null && viewportBox.hasSize) {
        // Find the Y coordinate for the center of the viewport on screen
        final double centerYOnScreen = viewportBox.localToGlobal(Offset(0, viewportBox.size.height / 2)).dy;

        int? centerIndex;
        // Convert to list to avoid ConcurrentModificationError during iteration
        final entries = _itemContexts.entries.toList();
        for (final entry in entries) {
          final ctx = entry.value;
          if (!ctx.mounted) continue;
          final RenderBox? itemBox = ctx.findRenderObject() as RenderBox?;
          if (itemBox != null && itemBox.hasSize) {
            final double itemTop = itemBox.localToGlobal(Offset.zero).dy;
            final double itemBottom = itemTop + itemBox.size.height;
            if (centerYOnScreen >= itemTop && centerYOnScreen <= itemBottom) {
              centerIndex = entry.key;
              break;
            }
          }
        }

        if (centerIndex != null) {
          final dayOffset = centerIndex ~/ _itemsPerDay;
          final visibleDate = _indexToDate(dayOffset);

          final selectedDate = ref.read(selectedDateProvider);
          if (!_isSameDay(selectedDate, visibleDate)) {
            _isScrollingFromList = true;
            ref.read(selectedDateProvider.notifier).state = visibleDate;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _isScrollingFromList = false;
              }
            });
          }
        }
      }
    }
  }

  void _shiftWindowBackward() {
    if (_isShiftingWindow) return;
    _isShiftingWindow = true;

    final prevOffset = _scrollController.offset;
    _windowStartDate = _windowStartDate.subtract(const Duration(days: 2));
    _shiftTargetOffset = prevOffset + 2 * _dayHeight;

    setState(() {
      _isShiftingWindow = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _shiftTargetOffset != null) {
        _scrollController.jumpTo(_shiftTargetOffset!);
        _shiftTargetOffset = null;
      }
    });
  }

  void _shiftWindowForward() {
    if (_isShiftingWindow) return;
    _isShiftingWindow = true;

    final prevOffset = _scrollController.offset;
    _windowStartDate = _windowStartDate.add(const Duration(days: 2));
    _shiftTargetOffset = prevOffset - 2 * _dayHeight;

    setState(() {
      _isShiftingWindow = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _shiftTargetOffset != null) {
        _scrollController.jumpTo(_shiftTargetOffset!);
        _shiftTargetOffset = null;
      }
    });
  }

  DateTime _indexToDate(int dayOffset) {
    return _windowStartDate.add(Duration(days: dayOffset));
  }

  int _dateToDayOffset(DateTime date) {
    final target = DateTime(date.year, date.month, date.day);
    return target.difference(_windowStartDate).inDays;
  }

  String _formatDateTitle(DateTime date) {
    final weekDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final year = date.year.toString().substring(2);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final weekday = weekDays[date.weekday - 1];
    return '${year}年${month}月${day}日 $weekday';
  }

  String _formatDividerDate(DateTime date) {
    final weekDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final weekday = weekDays[date.weekday - 1];
    return '${date.month}月${date.day}日 $weekday';
  }

  bool _isToday(DateTime date) {
    return date.year == _today.year &&
        date.month == _today.month &&
        date.day == _today.day;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void _goToDate(DateTime date) {
    ref.read(selectedDateProvider.notifier).state = date;
    if (_isScrollingFromList) return;

    final dayOffset = _dateToDayOffset(date);

    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(date);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goToDate(date);
      });
      return;
    }

    final targetIndex = dayOffset * _itemsPerDay;

    _scrollToTarget(
      targetIndex: targetIndex,
      smooth: true,
      alignment: 0.0,
    );
  }

  void _ensureDateInWindow(DateTime date) {
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(_today).inDays;

    int newStartDiff;
    if (diff < 0) {
      newStartDiff = math.max(diff - 2, -365);
    } else {
      newStartDiff = math.min(diff - 3, 362);
    }

    _windowStartDate = _today.add(Duration(days: newStartDiff));
    _itemContexts.clear();
    _itemHeights.clear();

    setState(() {});
  }

  void _showColorMarkDialog() {
    final selectedDate = ref.read(selectedDateProvider);
    final colorMarks = ref.read(diaryColorMarkProvider);
    final dateStr = DateFormat('yyyy-MM-dd').format(selectedDate);
    final currentMark = colorMarks.where((m) {
      final markDateStr = DateFormat('yyyy-MM-dd').format(m.date);
      return markDateStr == dateStr;
    }).firstOrNull;

    final colors = [
      {'name': '红色', 'color': const Color(0xFFFF3B30)},
      {'name': '绿色', 'color': const Color(0xFF34C759)},
      {'name': '蓝色', 'color': const Color(0xFF007AFF)},
      {'name': '橙色', 'color': const Color(0xFFFF9500)},
      {'name': '紫色', 'color': const Color(0xFFAF52DE)},
      {'name': '清除', 'color': null},
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('标记日期颜色'),
        content: SizedBox(
          width: 240,
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.8,
            children: colors.map((item) {
              final colorValue = item['color'] as Color?;
              return GestureDetector(
                onTap: () {
                  final notifier = ref.read(diaryColorMarkProvider.notifier);
                  if (colorValue == null) {
                    if (currentMark != null) {
                      notifier.removeMarkByDate(selectedDate);
                    }
                  } else {
                    notifier.setMark(
                      DateColorMark(
                        id: currentMark?.id ?? '',
                        date: selectedDate,
                        color:
                            '#${colorValue.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                      ),
                    );
                  }
                  Navigator.pop(context);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorValue,
                        shape: BoxShape.circle,
                        border: colorValue == null
                            ? Border.all(
                                color: Theme.of(context).colorScheme.outline,
                                width: 2,
                                strokeAlign: BorderSide.strokeAlignInside,
                              )
                            : null,
                      ),
                      child: colorValue == null
                          ? Icon(
                              Icons.close,
                              size: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            )
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item['name'] as String,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _showDatePicker() async {
    final selectedDate = ref.read(selectedDateProvider);
    final colorMarks = ref.read(diaryColorMarkProvider);
    final result = await showDialog<DateTime>(
      context: context,
      builder: (context) => CustomDatePickerDialog(
        initialDate: selectedDate,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        colorMarks: colorMarks,
      ),
    );
    if (result != null) {
      _goToDate(result);
    }
  }

  void _navigateToSearch() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchView()));
  }

  void _navigateToBatchManage() {
    context.push('/diary/batch');
  }

  void _handleDelete(DiaryRecord record) {
    ref.read(diaryListProvider.notifier).deleteDiary(record.id);
    ScaffoldMessenger.of(context).clearSnackBars();
    final controller = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已删除记录'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            ref.read(diaryListProvider.notifier).undoDelete();
          },
        ),
        duration: const Duration(seconds: 3),
      ),
    );

    // Force close the SnackBar after 3.2 seconds to bypass any system-level 
    // accessibility timeout or ROM-specific SnackBar persistence settings.
    Future.delayed(const Duration(milliseconds: 3200), () {
      try {
        controller.close();
      } catch (_) {}
    });
  }

  void _handleEdit(DiaryRecord record) {
    try {
      ScaffoldMessenger.of(context).clearSnackBars();
    } catch (_) {}
    context.push('/diary/editor', extra: record);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      if (next != null && !_isProgrammaticScrolling) {
        _goToDate(next);
      }
    });

    ref.listen<int>(diaryScrollTriggerProvider, (previous, next) {
      if (next != 0) {
        _scrollToCurrentTime(smooth: true);
      }
    });

    ref.listen<DateTime?>(diaryScrollToTimeProvider, (previous, next) {
      if (next != null) {
        _scrollToTime(next);
        ref.read(diaryScrollToTimeProvider.notifier).state = null;
      }
    });

    final theme = Theme.of(context);
    final selectedDate = ref.watch(selectedDateProvider);
    final diaryListAsync = ref.watch(diaryListProvider);
    final colorMarks = ref.watch(diaryColorMarkProvider);
    final selectEvent = ref.watch(diaryInputTimeProvider);
    final currentInputTime = ref.watch(currentInputTimeProvider);

    if (diaryListAsync is AsyncData && !_hasPerformedInitialScroll) {
      _hasPerformedInitialScroll = true;
      final allRecords = diaryListAsync.value ?? [];
      final Map<String, List<DiaryRecord>> recordsByDate = {};
      for (final r in allRecords) {
        if (r.isDeleted) continue;
        final key = '${r.time.year}-${r.time.month}-${r.time.day}';
        recordsByDate.putIfAbsent(key, () => []).add(r);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            _performInitialScrollToCurrentTime(recordsByDate);
          }
        });
      });
    }

    final dateStr = DateFormat('yyyy-MM-dd').format(selectedDate);
    final currentColorMark = colorMarks.where((m) {
      final markDateStr = DateFormat('yyyy-MM-dd').format(m.date);
      return markDateStr == dateStr;
    }).firstOrNull;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          Container(
            color: theme.colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 2),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.04),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(
                          Icons.palette_outlined,
                          size: 18,
                        ),
                        color: theme.colorScheme.primary,
                        onPressed: _showColorMarkDialog,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: _showDatePicker,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (currentColorMark != null) ...[
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: _hexToColor(currentColorMark.color),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  _formatDateTitle(selectedDate),
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.04),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.list_alt_rounded, size: 18),
                        color: theme.colorScheme.primary,
                        onPressed: _navigateToBatchManage,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      onPressed: _navigateToSearch,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: diaryListAsync.when(
              data: (allRecords) {
                final Map<String, List<DiaryRecord>> recordsByDate = {};
                for (final r in allRecords) {
                  if (r.isDeleted) continue;
                  final key = '${r.time.year}-${r.time.month}-${r.time.day}';
                  recordsByDate.putIfAbsent(key, () => []).add(r);
                }

                return Stack(
                  children: [
                    Positioned(
                      left: 40,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    GestureDetector(
                      key: _viewportKey,
                      onLongPressStart: _handleDragStart,
                      onLongPressMoveUpdate: _handleDragUpdate,
                      onLongPressEnd: _handleDragEnd,
                      child: ListView.builder(
                        cacheExtent: 1500,
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: _windowDays * _itemsPerDay,
                        itemBuilder: (context, i) {
                          final dayOffset = i ~/ _itemsPerDay;
                          final subIndex = i % _itemsPerDay;
                          final date = _indexToDate(dayOffset);

                          Widget childWidget;

                          if (subIndex == 0) {
                            childWidget = Container(
                              key: ValueKey('div_${dayOffset}_${date.millisecondsSinceEpoch}'),
                              height: 80.0,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.center,
                              child: Row(
                                children: [
                                  Expanded(child: Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: Text(
                                      _formatDividerDate(date),
                                      style: theme.textTheme.titleSmall?.copyWith(
                                        color: _isToday(date) ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Expanded(child: Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
                                ],
                              ),
                            );
                          } else {
                            final nodeIndex = subIndex - 1;
                            final time = TimeOfDay(hour: nodeIndex ~/ 2, minute: (nodeIndex % 2) * 30);
                            final currentMinutes = time.hour * 60 + time.minute;
                            final nextMinutes = currentMinutes + 30;
                            final nodeStartDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);

                            final dateKey = '${date.year}-${date.month}-${date.day}';
                            final dayRecords = recordsByDate[dateKey] ?? const [];
                            final recordsInInterval = dayRecords.where((r) {
                              final rMinutes = r.time.hour * 60 + r.time.minute;
                              if (nodeIndex == 47) {
                                return rMinutes >= currentMinutes;
                              } else {
                                return rMinutes >= currentMinutes && rMinutes < nextMinutes;
                              }
                            }).toList();

                            final isUserSelected = selectEvent != null;

                            bool isStandardNodeSelected = false;
                            if (isUserSelected) {
                              final selectionStart = DateTime(
                                selectEvent.date.year,
                                selectEvent.date.month,
                                selectEvent.date.day,
                                selectEvent.time.hour,
                                selectEvent.time.minute,
                              );

                              if (selectEvent.endTime == null) {
                                isStandardNodeSelected = nodeStartDateTime.isAtSameMomentAs(selectionStart);
                              } else {
                                final selEndDate = selectEvent.endDate ?? selectEvent.date;
                                final selectionEnd = DateTime(
                                  selEndDate.year,
                                  selEndDate.month,
                                  selEndDate.day,
                                  selectEvent.endTime!.hour,
                                  selectEvent.endTime!.minute,
                                );
                                isStandardNodeSelected = !nodeStartDateTime.isBefore(selectionStart) &&
                                    !nodeStartDateTime.isAfter(selectionEnd);
                              }
                            }

                            bool isDraggedSelected = false;
                            if (_dragStartIndex != null && _dragEndIndex != null) {
                              final start = math.min(_dragStartIndex!, _dragEndIndex!);
                              final end = math.max(_dragStartIndex!, _dragEndIndex!);
                              isDraggedSelected = i >= start && i <= end;
                            }

                            final bool finalIsSelected = isDraggedSelected || isStandardNodeSelected;
                            final bool isMultiSelect = isDraggedSelected || (isUserSelected && selectEvent.endTime != null);

                            final inputMinutes = currentInputTime.hour * 60 + currentInputTime.minute;
                            final now = TimeOfDay.now();
                            final nowMinutes = now.hour * 60 + now.minute;

                            final isSelectedTimeInThisInterval = nodeIndex == 47
                                ? inputMinutes >= currentMinutes
                                : (inputMinutes >= currentMinutes && inputMinutes < nextMinutes);

                            final showDedicatedSelectedNode = isUserSelected &&
                                _isSameDay(selectEvent.date, date) &&
                                isSelectedTimeInThisInterval &&
                                !(currentInputTime.minute == 0 || currentInputTime.minute == 30);

                            final isNowInThisInterval = nodeIndex == 47
                                ? nowMinutes >= currentMinutes
                                : (nowMinutes >= currentMinutes && nowMinutes < nextMinutes);

                            final showDedicatedCurrentTimeNode = isNowInThisInterval &&
                                _isToday(date) &&
                                !(now.minute == 0 || now.minute == 30) &&
                                (!isUserSelected || !_isSameDay(selectEvent.date, date) || (now.hour != currentInputTime.hour || now.minute != currentInputTime.minute));

                            final isStandardNodeCurrentTime = _isToday(date) && (now.hour == time.hour && now.minute == time.minute);

                            childWidget = Column(
                              key: (isNowInThisInterval && _isToday(date)) ? _currentTimeNodeKey : null,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _EmptyTimeNode(
                                  key: ValueKey('n_${dayOffset}_${nodeIndex}'),
                                  time: time,
                                  isSelected: finalIsSelected,
                                  isMultiSelect: isMultiSelect,
                                  isDraggedSelected: isDraggedSelected,
                                  isCurrentTime: isStandardNodeCurrentTime,
                                  onTap: () => _handleNodeTap(date, time),
                                  onDoubleTap: () => _handleNodeDoubleTap(date, time),
                                ),
                                if (showDedicatedSelectedNode)
                                  _SelectedTimeNode(
                                    time: currentInputTime,
                                    onTap: () => _handleNodeTap(date, currentInputTime),
                                    onDoubleTap: () => _handleNodeDoubleTap(date, currentInputTime),
                                  ),
                                if (showDedicatedCurrentTimeNode)
                                  _CurrentTimeNode(
                                    time: now,
                                    onTap: () => _handleNodeTap(date, now),
                                    onDoubleTap: () => _handleNodeDoubleTap(date, now),
                                  ),
                                ...recordsInInterval.map((record) => DiaryItem(
                                      record: record,
                                      onTap: () => _handleEdit(record),
                                      onEdit: _handleEdit,
                                      onDelete: _handleDelete,
                                    )),
                              ],
                            );
                          }

                          return TimelineItemWrapper(
                            index: i,
                            onMount: (index, ctx) => _itemContexts[index] = ctx,
                            onUnmount: (index) => _itemContexts.remove(index),
                            onHeightChange: (index, height) => _itemHeights[index] = height,
                            child: childWidget,
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
            ),
          ),
          const DiaryInputBar(),
        ],
      ),
    );
  }

  Color _hexToColor(String hex) {
    final hexStr = hex.replaceFirst('#', '');
    if (hexStr.length == 6) {
      return Color(int.parse('FF$hexStr', radix: 16));
    }
    if (hexStr.length == 8) {
      return Color(int.parse(hexStr, radix: 16));
    }
    return Colors.grey;
  }

  int _pointToItemIndex(Offset globalPosition) {
    for (final entry in _itemContexts.entries) {
      final index = entry.key;
      final ctx = entry.value;
      if (!ctx.mounted) continue;

      final renderBox = ctx.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) continue;

      final localPos = renderBox.globalToLocal(globalPosition);
      final size = renderBox.size;

      if (localPos.dy >= 0 && localPos.dy <= size.height) {
        return index;
      }
    }
    return -1;
  }

  void _handleDragStart(LongPressStartDetails details) {
    final index = _pointToItemIndex(details.globalPosition);
    if (index != -1 && index % _itemsPerDay != 0) {
      setState(() {
        _dragStartIndex = index;
        _dragEndIndex = index;
      });
      _lastDragPosition = details.globalPosition;
      _startAutoScrollTimer();
    }
  }

  void _handleDragUpdate(LongPressMoveUpdateDetails details) {
    _lastDragPosition = details.globalPosition;
    final index = _pointToItemIndex(details.globalPosition);
    if (index != -1 && index % _itemsPerDay != 0) {
      setState(() {
        _dragEndIndex = index;
      });
    }
  }

  void _handleDragEnd(LongPressEndDetails details) {
    _stopAutoScrollTimer();
    _lastDragPosition = null;

    if (_dragStartIndex != null && _dragEndIndex != null) {
      final start = math.min(_dragStartIndex!, _dragEndIndex!);
      final end = math.max(_dragStartIndex!, _dragEndIndex!);

      final startDayOffset = start ~/ _itemsPerDay;
      final startSubIndex = start % _itemsPerDay;
      final startNodeIndex = math.max(0, startSubIndex - 1);
      final startTime = TimeOfDay(hour: startNodeIndex ~/ 2, minute: (startNodeIndex % 2) * 30);
      final startDate = _indexToDate(startDayOffset);

      final endDayOffset = end ~/ _itemsPerDay;
      final endSubIndex = end % _itemsPerDay;
      final endNodeIndex = math.max(0, endSubIndex - 1);
      final endTime = TimeOfDay(hour: endNodeIndex ~/ 2, minute: (endNodeIndex % 2) * 30);
      final endDate = _indexToDate(endDayOffset);

      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        startTime,
        endTime: endTime,
        date: startDate,
        endDate: endDate,
      );
    }
    setState(() {
      _dragStartIndex = null;
      _dragEndIndex = null;
    });
  }

  void _startAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (_lastDragPosition == null || !mounted || !_scrollController.hasClients) return;

      final renderBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) return;

      final localPos = renderBox.globalToLocal(_lastDragPosition!);
      final viewportHeight = renderBox.size.height;

      const double threshold = 60.0; // 触发自动滚动的边缘距离
      const double maxSpeed = 12.0;    // 每次 Tick (20ms) 的最大滚动速度

      double scrollDelta = 0.0;

      if (localPos.dy < threshold && localPos.dy >= 0) {
        // 向上滚动 (越靠近边缘，滚动速度越快)
        final ratio = (threshold - localPos.dy) / threshold;
        scrollDelta = -maxSpeed * ratio;
      } else if (localPos.dy > viewportHeight - threshold && localPos.dy <= viewportHeight) {
        // 向下滚动 (越靠近边缘，滚动速度越快)
        final ratio = (localPos.dy - (viewportHeight - threshold)) / threshold;
        scrollDelta = maxSpeed * ratio;
      }

      if (scrollDelta != 0.0) {
        final currentOffset = _scrollController.offset;
        final targetOffset = (currentOffset + scrollDelta).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );

        if (targetOffset != currentOffset) {
          _scrollController.jumpTo(targetOffset);

          // 列表发生滚动后，手指下方的节点发生改变，动态更新选择范围！
          final index = _pointToItemIndex(_lastDragPosition!);
          if (index != -1 && index % _itemsPerDay != 0) {
            setState(() {
              _dragEndIndex = index;
            });
          }
        }
      }
    });
  }

  void _stopAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }
}

class _EmptyTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final bool isSelected;
  final bool isMultiSelect;
  final bool isDraggedSelected;
  final bool isCurrentTime;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _EmptyTimeNode({
    super.key,
    required this.time,
    required this.isSelected,
    this.isMultiSelect = false,
    this.isDraggedSelected = false,
    this.isCurrentTime = false,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;
    final bool isSingleSelected = isSelected && !isMultiSelect;

    final circleColor = isSelected
        ? (isSingleSelected ? theme.colorScheme.primary.withValues(alpha: 0.6) : theme.colorScheme.primary)
        : (isCurrentTime ? distinctColor.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant);

    final double circleSize = isSelected
        ? (isSingleSelected ? 10 : 16)
        : (isCurrentTime ? 10 : 8);

    final labelColor = isSelected ? theme.colorScheme.primary : distinctColor;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  width: circleSize,
                  height: circleSize,
                  decoration: BoxDecoration(
                    color: circleColor,
                    shape: BoxShape.circle,
                    boxShadow: isSelected && !isSingleSelected
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(alpha: 0.3),
                              blurRadius: 8,
                              spreadRadius: 2,
                            )
                          ]
                        : null,
                  ),
                  child: isSelected && !isSingleSelected
                      ? Center(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: isSelected
                    ? theme.colorScheme.primary
                    : (isCurrentTime ? distinctColor : theme.colorScheme.onSurfaceVariant),
                fontWeight: isSelected || isCurrentTime ? FontWeight.bold : FontWeight.w500,
                fontSize: isSelected ? 13 : 12,
              ),
              child: Text(timeStr),
            ),
            if (isCurrentTime) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: labelColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '当前时间',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: labelColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 9,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                height: 1,
                color: isSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.3)
                    : (isCurrentTime
                        ? distinctColor.withValues(alpha: 0.2)
                        : theme.colorScheme.outlineVariant.withValues(alpha: 0.15)),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

class _SelectedTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _SelectedTimeNode({
    required this.time,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.primary.withValues(alpha: 0.04),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 2,
                      )
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Icon(
              Icons.access_time_filled,
              size: 14,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              timeStr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 1,
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

class _CurrentTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _CurrentTimeNode({
    required this.time,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: distinctColor.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            Icon(
              Icons.access_time_filled,
              size: 14,
              color: distinctColor,
            ),
            const SizedBox(width: 6),
            Text(
              timeStr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: distinctColor,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: distinctColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '当前时间',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: distinctColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 9,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 1,
                color: distinctColor.withValues(alpha: 0.3),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

class TimelineItemWrapper extends StatefulWidget {
  final int index;
  final Widget child;
  final void Function(int index, BuildContext context) onMount;
  final void Function(int index) onUnmount;
  final void Function(int index, double height) onHeightChange;

  const TimelineItemWrapper({
    super.key,
    required this.index,
    required this.child,
    required this.onMount,
    required this.onUnmount,
    required this.onHeightChange,
  });

  @override
  State<TimelineItemWrapper> createState() => _TimelineItemWrapperState();
}

class _TimelineItemWrapperState extends State<TimelineItemWrapper> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onMount(widget.index, context);
        _reportHeight();
      }
    });
  }

  void _reportHeight() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      widget.onHeightChange(widget.index, renderBox.size.height);
    }
  }

  @override
  void didUpdateWidget(TimelineItemWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      widget.onUnmount(oldWidget.index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onMount(widget.index, context);
          _reportHeight();
        }
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reportHeight();
      });
    }
  }

  @override
  void dispose() {
    widget.onUnmount(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

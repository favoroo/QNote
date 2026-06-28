import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/widgets/diary/ai_extract_helper.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';
import 'package:qnote_flutter/widgets/diary/model_selection_dialog.dart';
import 'package:qnote_flutter/widgets/diary/diary_input_bar.dart';
import 'package:qnote_flutter/widgets/diary/custom_date_picker.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';

class DiaryPage extends ConsumerStatefulWidget {
  const DiaryPage({super.key});

  @override
  ConsumerState<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends ConsumerState<DiaryPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const int _itemsPerDay = 49;
  static const double _dayHeight = 2384.0;
  static const double _dividerHeight = 80.0;
  static const double _nodeHeight = 48.0;

  late DateTime _today;
  late DateTime _windowStartDate;
  final int _windowDays = 7;
  late ScrollController _scrollController;
  final GlobalKey _viewportKey = GlobalKey();
  // GlobalKey placed on the current-time node so we can read its actual RenderBox position
  final GlobalKey _currentTimeNodeKey = GlobalKey();
  final GlobalKey _smartExtractFabKey = GlobalKey();
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
  String? _extractingRecordId;
  CancelToken? _cancelToken;
  // Multi-record undo mapping
  final Map<String, DiaryRecord> _undoRecords = {};
  final Map<String, AnimationController> _undoControllers = {};

  // _buildRecordsByDate 结果缓存，避免每次 rebuild 重算全表分组+排序
  List<DiaryRecord>? _lastAllRecords;
  Map<String, List<DiaryRecord>>? _cachedRecordsByDate;
  int _undoRecordsVersion = 0;
  int _cachedUndoRecordsVersion = -1;

  /// 标记 _undoRecords 变化，使下次 _buildRecordsByDate 重算而非命中缓存
  void _bumpUndoRecordsVersion() {
    _undoRecordsVersion++;
  }

  // Batch extraction state
  bool _isBatchExtracting = false;
  int _batchExtractTotal = 0;
  int _batchExtractCompleted = 0;
  bool _batchExtractCancelled = false;

  bool _showBatchConfirmButton = false;
  final Set<String> _batchExtractedRecordIds = {};

  Map<String, List<DiaryRecord>> _buildRecordsByDate(List<DiaryRecord> allRecords) {
    // 缓存命中：allRecords 引用相同 + _undoRecords 版本未变
    if (identical(allRecords, _lastAllRecords) &&
        _undoRecordsVersion == _cachedUndoRecordsVersion &&
        _cachedRecordsByDate != null) {
      return _cachedRecordsByDate!;
    }
    final Map<String, List<DiaryRecord>> recordsByDate = {};
    for (final r in allRecords) {
      if (r.isDeleted) continue;
      final preRecord = _undoRecords[r.id];
      final displayDate = preRecord != null ? preRecord.getEffectiveDate() : r.getEffectiveDate();
      final key = '${displayDate.year}-${displayDate.month}-${displayDate.day}';
      recordsByDate.putIfAbsent(key, () => []).add(r);
    }
    // Sort each day's records by display time
    recordsByDate.forEach((key, list) {
      list.sort((a, b) {
        final preA = _undoRecords[a.id];
        final displayTimeA = preA != null ? preA.getDisplayTime() : a.getDisplayTime();
        final preB = _undoRecords[b.id];
        final displayTimeB = preB != null ? preB.getDisplayTime() : b.getDisplayTime();
        return displayTimeA.compareTo(displayTimeB);
      });
    });
    // 写入缓存
    _lastAllRecords = allRecords;
    _cachedRecordsByDate = recordsByDate;
    _cachedUndoRecordsVersion = _undoRecordsVersion;
    return recordsByDate;
  }

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
    final targetDate = DateTime(
      targetTime.year,
      targetTime.month,
      targetTime.day,
    );
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
          final displayTime = r.getDisplayTime();
          final rNodeIndex = displayTime.hour * 2 + (displayTime.minute >= 30 ? 1 : 0);
          if (rNodeIndex < nodeIndex) {
            offset += _averageRecordExtraHeight;
          }
        }
      }
    }

    return offset;
  }

  void _performInitialScrollToCurrentTime({
    int retryCount = 0,
    Map<String, List<DiaryRecord>>? recordsByDate,
  }) {
    if (!mounted) return;
    if (!_scrollController.hasClients) {
      if (retryCount < 10) {
        Future.delayed(const Duration(milliseconds: 50), () {
          _performInitialScrollToCurrentTime(
            retryCount: retryCount + 1,
            recordsByDate: recordsByDate,
          );
        });
      }
      return;
    }
    _scrollToCurrentTime(smooth: false, recordsByDate: recordsByDate); // 初始定位不用动画
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
      estimatedOffset = _estimateOffsetForTimeWithRecords(
        targetTime,
        recordsByDate,
      );
    } else {
      estimatedOffset = _estimateOffsetForIndex(targetIndex);
    }
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = (estimatedOffset - viewportHeight * alignment).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if (smooth) {
      final currentOffset = _scrollController.offset;
      final distance = (targetOffset - currentOffset).abs();
      final threshold = viewportHeight * 1.2;

      if (attempts == 0 && distance > threshold) {
        // Jump close to the target first to avoid loading too many items and causing jank.
        // We leave 0.7 viewports of distance so the user still sees a smooth sliding motion.
        double jumpOffset;
        if (targetOffset > currentOffset) {
          jumpOffset = targetOffset - viewportHeight * 0.7;
        } else {
          jumpOffset = targetOffset + viewportHeight * 0.7;
        }
        jumpOffset = jumpOffset.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );

        _scrollController.jumpTo(jumpOffset);

        // Allow a frame for the layout to mount new items, then continue.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 50), () {
            if (mounted) {
              _scrollToTarget(
                targetIndex: targetIndex,
                targetKey: targetKey,
                smooth: smooth,
                alignment: alignment,
                attempts: attempts + 1,
                recordsByDate: recordsByDate,
                targetTime: targetTime,
              );
            }
          });
        });
      } else {
        // Target is close or we already jumped, animate to estimated target.
        _scrollController
            .animateTo(
              targetOffset,
              duration: AppDurations.medium,
              curve: Curves.easeOutCubic,
            )
            .then((_) {
              if (mounted) {
                _scrollToTarget(
                  targetIndex: targetIndex,
                  targetKey: targetKey,
                  smooth: smooth,
                  alignment: alignment,
                  attempts: attempts + 1,
                  recordsByDate: recordsByDate,
                  targetTime: targetTime,
                );
              }
            });
      }
    } else {
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
              recordsByDate: recordsByDate,
              targetTime: targetTime,
            );
          }
        });
      });
    }
  }

  void _scrollToContext(
    BuildContext targetContext, {
    bool smooth = true,
    double alignment = 0.5,
  }) {
    if (!targetContext.mounted) return;

    final renderBox = targetContext.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: alignment,
        duration: smooth ? const Duration(milliseconds: 350) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      _finishProgrammaticScroll();
      return;
    }

    final viewportBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: alignment,
        duration: smooth ? const Duration(milliseconds: 350) : Duration.zero,
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
    final nodeTopInScroll =
        scrollOffset + (nodeTopOnScreen - viewportTopOnScreen);
    final preciseTarget =
        (nodeTopInScroll - (viewportHeight - nodeHeight) * alignment).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );

    if ((scrollOffset - preciseTarget).abs() < 2.0) {
      _finishProgrammaticScroll();
      return;
    }

    if (smooth) {
      final distance = (scrollOffset - preciseTarget).abs();
      final duration = distance < 50.0
          ? const Duration(milliseconds: 150)
          : const Duration(milliseconds: 350);

      _scrollController
          .animateTo(
            preciseTarget,
            duration: duration,
            curve: Curves.easeOutCubic,
          )
          .then((_) {
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
    final targetOffset = (estimatedOffset - viewportHeight * alignment).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if (smooth) {
      _scrollController
          .animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
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
        if (mounted)
          _scrollToCurrentTime(smooth: smooth, recordsByDate: recordsByDate);
      });
      return;
    }

    _isProgrammaticScrolling = true;
    ref.read(selectedDateProvider.notifier).state = DateTime(
      now.year,
      now.month,
      now.day,
    );

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
  }

  void _scrollToTime(
    DateTime targetTime, {
    bool smooth = true,
    Map<String, List<DiaryRecord>>? recordsByDate,
  }) {
    if (!_scrollController.hasClients) return;

    final dayOffset = _dateToDayOffset(targetTime);

    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(targetTime);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToTime(targetTime, smooth: smooth, recordsByDate: recordsByDate);
        }
      });
      return;
    }

    _isProgrammaticScrolling = true;
    ref.read(selectedDateProvider.notifier).state = DateTime(
      targetTime.year,
      targetTime.month,
      targetTime.day,
    );

    final nodeIndex = targetTime.hour * 2 + (targetTime.minute >= 30 ? 1 : 0);
    final targetIndex = dayOffset * _itemsPerDay + (nodeIndex + 1);

    _scrollToTarget(
      targetIndex: targetIndex,
      smooth: smooth,
      alignment: 0.5,
      recordsByDate: recordsByDate,
      targetTime: targetTime,
    );
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
        ref.read(diaryInputTimeProvider.notifier).state =
            TimelineTimeSelectEvent(time, date: date);
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
    } else if (clickedDateTime.isAfter(selectionStart) &&
        !clickedDateTime.isAfter(selectionEnd)) {
      // 2. 点击范围内的某个节点（排除开始节点）：将该节点及之后的节点取消勾选，即新范围是 [开始, 点击节点 - 30分钟]
      final newEndDateTime = clickedDateTime.subtract(
        const Duration(minutes: 30),
      );
      final newEndTime = TimeOfDay(
        hour: newEndDateTime.hour,
        minute: newEndDateTime.minute,
      );

      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        selectEvent.time,
        endTime: newEndTime,
        date: selectEvent.date,
        endDate: DateTime(
          newEndDateTime.year,
          newEndDateTime.month,
          newEndDateTime.day,
        ),
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
        final allRecords = ref.read(diaryListProvider).valueOrNull;
        final recordsByDate = allRecords != null ? _buildRecordsByDate(allRecords) : null;
        _scrollToCurrentTime(smooth: true, recordsByDate: recordsByDate);
      }
    }
  }

  @override
  void dispose() {
    try {
      Toast.dismiss();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoScrollTimer();
    _itemContexts.clear();
    _itemHeights.clear();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    for (final c in _undoControllers.values) {
      c.dispose();
    }
    _undoControllers.clear();
    _undoRecords.clear();
    super.dispose();
  }

  void _onScroll() {
    if (_isShiftingWindow ||
        _isProgrammaticScrolling ||
        !_scrollController.hasClients)
      return;

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
      final RenderBox? viewportBox =
          viewportCtx.findRenderObject() as RenderBox?;
      if (viewportBox != null && viewportBox.hasSize) {
        // Find the Y coordinate for the center of the viewport on screen
        final double centerYOnScreen = viewportBox
            .localToGlobal(Offset(0, viewportBox.size.height / 2))
            .dy;

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
    return '$year年$month月$day日 $weekday';
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

    final allRecords = ref.read(diaryListProvider).valueOrNull;
    final recordsByDate = allRecords != null ? _buildRecordsByDate(allRecords) : null;

    _scrollToTarget(
      targetIndex: targetIndex,
      smooth: true,
      alignment: 0.0,
      recordsByDate: recordsByDate,
      targetTime: date,
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
    final colorMarks = ref.read(diaryColorMarkProvider).valueOrNull ?? [];
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
    final colorMarks = ref.read(diaryColorMarkProvider).valueOrNull ?? [];
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SearchView()));
  }

  void _navigateToBatchManage() {
    context.push('/diary/batch');
  }

  void _handleDelete(DiaryRecord record) {
    HapticFeedback.heavyImpact();
    _clearUndoForRecord(record.id);
    ref.read(diaryListProvider.notifier).deleteDiary(record.id);
    Toast.show(
      context,
      '已删除',
      type: ToastType.info,
      duration: const Duration(seconds: 4),
      actionLabel: '撤销',
      onAction: () {
        ref.read(diaryListProvider.notifier).undoDelete();
      },
    );
  }

  void _handleEdit(DiaryRecord record) {
    _clearUndoForRecord(record.id);
    Toast.dismiss();
    context.push('/diary/editor', extra: record);
  }

  Future<void> _handleAiExtract(DiaryRecord record) async {
    if (_extractingRecordId != null) {
      if (_extractingRecordId == record.id) {
        _cancelToken?.cancel();
        _cancelToken = null;
      }
      return;
    }
    final contentText = record.content.trim();
    if (contentText.isEmpty && record.photos.isEmpty) return;

    setState(() {
      _extractingRecordId = record.id;
    });

    _cancelToken = CancelToken();
    final result = await extractExistingRecord(
      ref: ref,
      context: context,
      content: contentText,
      photos: record.photos,
      recordTime: record.time,
      startTime: record.startTime,
      endTime: record.endTime,
      cancelToken: _cancelToken,
    );

    if (result != null && mounted) {
      final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
      final foundShortcut = findShortcutById(result.shortcutId, shortcuts);

      List<String> newTags = List.from(record.tags);
      String newDisplayTag = record.displayTag;
      DateTime? newStartTime = record.startTime;
      DateTime? newEndTime = record.endTime;
      DateTime newTime = record.time;
      String newContent = record.content;
      if (result.notes.isNotEmpty && record.photos.isNotEmpty) {
        if (newContent.isEmpty) {
          newContent = result.notes;
        } else if (result.notes.startsWith('图：') || result.notes.startsWith('图:')) {
          newContent = '$newContent\n${result.notes}';
        } else if (!newContent.contains(result.notes)) {
          newContent = '$newContent\n${result.notes}';
        }
      }
      Map<String, dynamic>? newBodyState = record.bodyState != null
          ? Map.from(record.bodyState!)
          : null;
      List<TagEntry> newTagEntries = result.tagEntries.isNotEmpty
          ? result.tagEntries
          : record.tagEntries;

      if (result.tagEntries.isNotEmpty) {
        newTags = result.tagEntries.map((e) => e.name).toList();
        newDisplayTag = result.tagEntries.first.name;
        newBodyState = Map<String, dynamic>.from(
          result.tagEntries.first.fields,
        );
      } else if (foundShortcut != null) {
        if (!newTags.contains(foundShortcut.name)) {
          newTags = [
            foundShortcut.name,
            ...newTags.where((t) => t != newDisplayTag),
          ];
        }
        newDisplayTag = foundShortcut.name;
      }

      if (result.time.isNotEmpty) {
        final baseDate = DateTime(
          record.time.year,
          record.time.month,
          record.time.day,
        );
        if (result.time['start'] != null) {
          final parts = (result.time['start'] as String).split(':');
          if (parts.length >= 2) {
            final hour = int.tryParse(parts[0]) ?? record.time.hour;
            final minute = int.tryParse(parts[1]) ?? record.time.minute;
            final startOffset = result.time['startOffset'] as int? ?? 0;
            final dt = baseDate.add(
              Duration(days: startOffset, hours: hour, minutes: minute),
            );
            newTime = dt;
            newStartTime = dt;
          }
        }
        if (result.time['end'] != null) {
          final parts = (result.time['end'] as String).split(':');
          if (parts.length >= 2) {
            final hour = int.tryParse(parts[0]) ?? 0;
            final minute = int.tryParse(parts[1]) ?? 0;
            final endOffset = result.time['endOffset'] as int? ?? 0;
            newEndTime = baseDate.add(
              Duration(days: endOffset, hours: hour, minutes: minute),
            );
          }
        } else {
          newEndTime = null;
        }
      }

      final updated = record.copyWith(
        time: newTime,
        startTime: newStartTime,
        endTime: newEndTime,
        tags: newTags,
        displayTag: newDisplayTag,
        content: newContent,
        bodyState: newBodyState,
        tagEntries: newTagEntries,
        updatedAt: DateTime.now(),
      );

      // Store pre-extract record and create undo controller
      _undoRecords[record.id] = record;
      _bumpUndoRecordsVersion();
      if (_isBatchExtracting) {
        _batchExtractedRecordIds.add(record.id);
      } else {
        _createUndoController(record.id);
      }

      await ref.read(diaryListProvider.notifier).updateDiary(updated);
      if (mounted && !_isBatchExtracting) {
        Toast.success(context, '优化完成');
      }

      if (!_isBatchExtracting) {
        _undoControllers[record.id]?.forward(from: 0);
      }
    }

    _cancelToken = null;
    if (mounted) {
      setState(() => _extractingRecordId = null);
    }
  }

  void _undoExtract(DiaryRecord record) async {
    final preRecord = _undoRecords[record.id];
    if (preRecord == null) return;

    _clearUndoForRecord(record.id);

    await ref.read(diaryListProvider.notifier).updateDiary(preRecord);
    if (mounted) {
      Toast.success(context, '已撤回优化');
    }
  }

  /// Clear undo state for a specific record
  void _clearUndoForRecord(String recordId) {
    final controller = _undoControllers.remove(recordId);
    controller?.stop();
    controller?.dispose();
    _undoRecords.remove(recordId);
    _bumpUndoRecordsVersion();
    _batchExtractedRecordIds.remove(recordId);
    if (_batchExtractedRecordIds.isEmpty && !_isBatchExtracting) {
      _showBatchConfirmButton = false;
    }
    if (mounted) setState(() {});
  }

  /// Create an undo countdown controller for a record
  void _createUndoController(String recordId) {
    // Dispose existing if any
    _undoControllers[recordId]?.dispose();

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    );
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        final preRecord = _undoRecords[recordId];
        final currentRecords = ref.read(diaryListProvider).valueOrNull;
        DiaryRecord? currentRecord;
        if (currentRecords != null) {
          try {
            currentRecord = currentRecords.firstWhere((r) => r.id == recordId);
          } catch (_) {}
        }

        _undoControllers.remove(recordId)?.dispose();
        _undoRecords.remove(recordId);
        _bumpUndoRecordsVersion();

        if (mounted) {
          setState(() {});
          if (preRecord != null &&
              currentRecord != null &&
              currentRecord.time != preRecord.time) {
            _scrollToTime(currentRecord.time, smooth: true);
          }
        }
      }
    });
    _undoControllers[recordId] = controller;
  }

  /// Handle smart extract button tap with triple-click detection
  void _handleSmartExtractTap() {
    if (_isBatchExtracting) {
      // Stop ongoing batch extraction
      setState(() {
        _batchExtractCancelled = true;
      });
      _cancelToken?.cancel();
      _cancelToken = null;
      return;
    }

    final allRecords = ref.read(diaryListProvider).valueOrNull;
    if (allRecords == null) return;

    final selectedDate = ref.read(selectedDateProvider);

    int untaggedToday = 0;
    int untaggedAll = 0;

    for (final r in allRecords) {
      if (r.isDeleted) continue;
      if (r.displayTag.isNotEmpty && r.displayTag != '记录') continue;
      if (r.content.trim().isEmpty && r.photos.isEmpty) continue;
      
      untaggedAll++;
      if (_isSameDay(r.time, selectedDate)) {
        untaggedToday++;
      }
    }

    if (untaggedAll == 0) {
      Toast.info(context, '没有需要优化的记录');
      return;
    }

    final items = <ActionMenuItem>[];
    
    if (untaggedToday > 0) {
      items.add(
        ActionMenuItem(
          icon: Icons.today,
          label: '提取今日记录 ($untaggedToday条)',
          onTap: () => _startBatchExtract(allDates: false),
        ),
      );
    }
    
    if (untaggedAll > untaggedToday) {
      items.add(
        ActionMenuItem(
          icon: Icons.date_range,
          label: '提取全部记录 ($untaggedAll条)',
          onTap: () => _startBatchExtract(allDates: true),
        ),
      );
    }

    if (items.length == 1) {
      // If only one option, just execute it directly
      items.first.onTap();
    } else {
      ActionMenu.show(
        context: context,
        key: _smartExtractFabKey,
        items: items,
      );
    }
  }

  /// Start batch extraction of untagged records
  Future<void> _startBatchExtract({required bool allDates}) async {
    final allRecords = ref.read(diaryListProvider).valueOrNull;
    if (allRecords == null) return;

    final selectedDate = ref.read(selectedDateProvider);

    // Filter records: no displayTag (or default '记录'), not deleted, has content or photos
    final untaggedRecords = allRecords.where((r) {
      if (r.isDeleted) return false;
      if (r.displayTag.isNotEmpty && r.displayTag != '记录') return false;
      if (r.content.trim().isEmpty && r.photos.isEmpty) return false;
      if (!allDates) {
        return _isSameDay(r.time, selectedDate);
      }
      return true;
    }).toList();

    if (untaggedRecords.isEmpty) {
      if (mounted) {
        Toast.info(context, allDates ? '没有需要提取的记录' : '当天没有需要提取的记录');
      }
      return;
    }

    // Sort by time
    untaggedRecords.sort((a, b) => a.time.compareTo(b.time));

    setState(() {
      _isBatchExtracting = true;
      _batchExtractTotal = untaggedRecords.length;
      _batchExtractCompleted = 0;
      _batchExtractCancelled = false;
      _showBatchConfirmButton = false;
      _batchExtractedRecordIds.clear();
    });

    if (mounted) {
      Toast.info(
        context,
        '开始提取 ${untaggedRecords.length} 条记录${allDates ? '（全部日期）' : ''}',
      );
    }

    for (int i = 0; i < untaggedRecords.length; i++) {
      if (_batchExtractCancelled || !mounted) break;

      final record = untaggedRecords[i];

      // Re-read the record from provider in case it was modified
      final currentRecords = ref.read(diaryListProvider).valueOrNull;
      DiaryRecord currentRecord = record;
      if (currentRecords != null) {
        try {
          currentRecord = currentRecords.firstWhere((r) => r.id == record.id);
        } catch (_) {}
      }

      // Skip if already tagged (might have been manually tagged during batch)
      if (currentRecord.displayTag.isNotEmpty &&
          currentRecord.displayTag != '记录') {
        setState(() {
          _batchExtractCompleted = i + 1;
        });
        continue;
      }

      // Scroll to the record being extracted
      _scrollToTime(currentRecord.time, smooth: true);

      // Small delay to let scroll animation settle
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted || _batchExtractCancelled) break;

      // Extract
      await _handleAiExtract(currentRecord);

      if (mounted) {
        setState(() {
          _batchExtractCompleted = i + 1;
        });
      }

      // Pause for a few seconds to let user review the extraction result before moving on
      if (i < untaggedRecords.length - 1 && !_batchExtractCancelled) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }

    if (mounted) {
      final cancelled = _batchExtractCancelled;
      setState(() {
        _isBatchExtracting = false;
        _batchExtractCancelled = false;
        if (_batchExtractedRecordIds.isNotEmpty) {
          _showBatchConfirmButton = true;
        }
      });
      if (cancelled) {
        Toast.info(
          context,
          '已停止提取（完成 $_batchExtractCompleted/$_batchExtractTotal）',
        );
      } else {
        Toast.success(context, '批量提取完成（$_batchExtractTotal 条）');
      }
    }
  }

  /// Long press on smart extract button to select model
  Future<void> _handleSmartExtractLongPress() async {
    if (_isBatchExtracting) return;

    List<AiConfig> configs = [];
    try {
      configs = await ref.read(aiConfigListProvider.future);
    } catch (_) {}

    if (!mounted || configs.isEmpty) {
      Toast.warning(context, '无可用模型');
      return;
    }

    final roles = await AiRoleService.instance.getRoles();
    final currentModelId = roles.timelineOptimizationUseFreeModel
        ? '__free_model__'
        : roles.timelineOptimization;
    if (!mounted) return;

    final selectedId = await showDialog<String>(
      context: context,
      builder: (context) =>
          ModelSelectionDialog(configs: configs, selectedId: currentModelId),
    );

    if (selectedId != null && mounted) {
      final isFree = selectedId == '__free_model__';
      final newRoles = AiRoles(
        assistant: roles.assistant,
        assistantUseFreeModel: roles.assistantUseFreeModel,
        timelineOptimization: isFree ? null : selectedId,
        timelineOptimizationUseFreeModel: isFree,
      );
      await AiRoleService.instance.saveRoles(newRoles);
      if (mounted) {
        final displayName = isFree
            ? '免费模型'
            : (configs
                    .firstWhere((c) => c.id == selectedId,
                        orElse: () => configs.first)
                    .name);
        Toast.success(
          context,
          '已切换：$displayName',
          duration: const Duration(seconds: 1),
        );
      }
    }
  }

  /// Build the smart extract floating action button
  Widget _buildSmartExtractFAB(ThemeData theme) {
    if (_showBatchConfirmButton) return const SizedBox.shrink();
    return GestureDetector(
      key: _smartExtractFabKey,
      onTap: _handleSmartExtractTap,
      onLongPress: _handleSmartExtractLongPress,
      child: AnimatedGradientBorder(
        isAnimating: _isBatchExtracting,
        borderRadius: 26, // For width 52, radius is 26
        strokeWidth: 2,
        child: AnimatedContainer(
          duration: AppDurations.medium,
          curve: Curves.easeOutCubic,
          width: _isBatchExtracting ? 52 : 44,
          height: _isBatchExtracting ? 52 : 44,
          decoration: BoxDecoration(
            color: _isBatchExtracting
                ? theme.colorScheme.surface
                : theme.colorScheme.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _isBatchExtracting
                    ? theme.colorScheme.primary.withValues(alpha: 0.25)
                    : theme.colorScheme.shadow.withValues(alpha: 0.06),
                blurRadius: _isBatchExtracting ? 12 : 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: _isBatchExtracting
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        value: _batchExtractTotal > 0
                            ? _batchExtractCompleted / _batchExtractTotal
                            : null,
                        strokeWidth: 2.5,
                        color: theme.colorScheme.primary,
                        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                      ),
                    ),
                    Text(
                      '$_batchExtractCompleted',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                )
              : Icon(
                  Icons.auto_fix_high,
                  size: 20,
                  color: theme.colorScheme.onPrimary,
                ),
        ),
      ),
    );
  }

  Future<void> _handleAiExtractModelSelect(DiaryRecord record) async {
    List<AiConfig> configs = [];
    try {
      configs = await ref.read(aiConfigListProvider.future);
    } catch (_) {}

    if (!mounted || configs.isEmpty) {
      Toast.warning(context, '无可用模型');
      return;
    }

    final roles = await AiRoleService.instance.getRoles();
    final currentModelId = roles.timelineOptimizationUseFreeModel ? '__free_model__' : roles.timelineOptimization;
    if (!mounted) return;

    final selectedId = await showDialog<String>(
      context: context,
      builder: (context) =>
          ModelSelectionDialog(configs: configs, selectedId: currentModelId),
    );

    if (selectedId != null && mounted) {
      final isFree = selectedId == '__free_model__';
      final newRoles = AiRoles(
        assistant: roles.assistant,
        assistantUseFreeModel: roles.assistantUseFreeModel,
        timelineOptimization: isFree ? null : selectedId,
        timelineOptimizationUseFreeModel: isFree,
      );
      await AiRoleService.instance.saveRoles(newRoles);
      if (mounted) {
        final displayName = isFree ? '免费模型' : (configs.firstWhere((c) => c.id == selectedId, orElse: () => configs.first).name);
        Toast.success(
          context,
          '已切换：$displayName',
          duration: const Duration(seconds: 1),
        );
      }
    }
  }

  void _confirmBatchExtract() {
    setState(() {
      for (final id in _batchExtractedRecordIds) {
        _undoRecords.remove(id);
        final controller = _undoControllers.remove(id);
        controller?.stop();
        controller?.dispose();
      }
      _bumpUndoRecordsVersion();
      _batchExtractedRecordIds.clear();
      _showBatchConfirmButton = false;
    });
    Toast.success(context, '已确认保存');
  }

  Widget _buildBatchConfirmPanel(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome,
              color: theme.colorScheme.primary,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              '已批量提取并优化 ${_batchExtractedRecordIds.length} 条记录',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _confirmBatchExtract,
              style: FilledButton.styleFrom(
                elevation: 0,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              ),
              child: const Text('确认保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      if (!_isProgrammaticScrolling) {
        _goToDate(next);
      }
    });

    ref.listen<int>(diaryScrollTriggerProvider, (previous, next) {
      if (next != 0) {
        final allRecords = ref.read(diaryListProvider).valueOrNull;
        final recordsByDate = allRecords != null ? _buildRecordsByDate(allRecords) : null;
        _scrollToCurrentTime(smooth: true, recordsByDate: recordsByDate);
      }
    });

    ref.listen<DateTime?>(diaryScrollToTimeProvider, (previous, next) {
      if (next != null) {
        final allRecords = ref.read(diaryListProvider).valueOrNull;
        final recordsByDate = allRecords != null ? _buildRecordsByDate(allRecords) : null;
        _scrollToTime(next, recordsByDate: recordsByDate);
        ref.read(diaryScrollToTimeProvider.notifier).state = null;
      }
    });

    final theme = Theme.of(context);
    final diaryListAsync = ref.watch(diaryListProvider);
    final selectEvent = ref.watch(diaryInputTimeProvider);
    final currentInputTime = ref.watch(currentInputTimeProvider);

    if (diaryListAsync is AsyncData && !_hasPerformedInitialScroll) {
      _hasPerformedInitialScroll = true;
      final allRecords = diaryListAsync.value ?? const [];
      final recordsByDate = _buildRecordsByDate(allRecords);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 50), () {
          if (!mounted || !_scrollController.hasClients) return;

          final now = DateTime.now();
          final viewportHeight = _scrollController.position.viewportDimension;
          final estimatedOffset = _estimateOffsetForTimeWithRecords(now, recordsByDate);
          final targetOffset = (estimatedOffset - viewportHeight * 0.5).clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          );
          _scrollController.jumpTo(targetOffset);
        });
      });
    }

    // P1-19: selectedDate / colorMarks 改在 Consumer 内局部 watch，
    // 避免日期或颜色标记变化时整个 DiaryPage（含 ListView.builder）重建
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          Consumer(
            builder: (context, ref, _) {
              final selectedDate = ref.watch(selectedDateProvider);
              final colorMarks =
                  ref.watch(diaryColorMarkProvider).valueOrNull ?? [];
              final dateStr = DateFormat('yyyy-MM-dd').format(selectedDate);
              final currentColorMark = colorMarks.where((m) {
                final markDateStr = DateFormat('yyyy-MM-dd').format(m.date);
                return markDateStr == dateStr;
              }).firstOrNull;

              return Container(
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
                          onPressed: () =>
                              rootScaffoldKey.currentState?.openDrawer(),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 2),
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon:
                                    const Icon(Icons.palette_outlined, size: 18),
                                color: theme.colorScheme.primary,
                                onPressed: _showColorMarkDialog,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ),
                            if (currentColorMark != null)
                              Positioned(
                                right: -1,
                                top: -1,
                                child: Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    color: _hexToColor(currentColorMark.color),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.colorScheme.surface,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: _showDatePicker,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8.0),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _formatDateTitle(selectedDate),
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
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
              );
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                diaryListAsync.when(
                  data: (allRecords) {
                    final recordsByDate = _buildRecordsByDate(allRecords);

                    return Stack(
                      children: [
                        Positioned(
                          left: 39,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 2,
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.4,
                            ),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            itemCount: _windowDays * _itemsPerDay,
                            itemBuilder: (context, i) {
                              final dayOffset = i ~/ _itemsPerDay;
                              final subIndex = i % _itemsPerDay;
                              final date = _indexToDate(dayOffset);

                              Widget childWidget;

                              if (subIndex == 0) {
                                childWidget = Container(
                                  key: ValueKey(
                                    'div_${dayOffset}_${date.millisecondsSinceEpoch}',
                                  ),
                                  height: 80.0,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Divider(
                                          color: theme
                                              .colorScheme
                                              .outlineVariant
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        child: Text(
                                          _formatDividerDate(date),
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                color: _isToday(date)
                                                    ? theme.colorScheme.primary
                                                    : theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Divider(
                                          color: theme
                                              .colorScheme
                                              .outlineVariant
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              } else {
                                final nodeIndex = subIndex - 1;
                                final time = TimeOfDay(
                                  hour: nodeIndex ~/ 2,
                                  minute: (nodeIndex % 2) * 30,
                                );
                                final currentMinutes =
                                    time.hour * 60 + time.minute;
                                final nextMinutes = currentMinutes + 30;
                                final nodeStartDateTime = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  time.hour,
                                  time.minute,
                                );

                                final dateKey =
                                    '${date.year}-${date.month}-${date.day}';
                                final dayRecords =
                                    recordsByDate[dateKey] ?? const [];
                                final recordsInInterval = dayRecords.where((r) {
                                  final preRecord = _undoRecords[r.id];
                                  final displayTime = preRecord != null
                                      ? preRecord.getDisplayTime()
                                      : r.getDisplayTime();
                                  final rMinutes =
                                      displayTime.hour * 60 +
                                      displayTime.minute;
                                  if (nodeIndex == 47) {
                                    return rMinutes >= currentMinutes;
                                  } else {
                                    return rMinutes >= currentMinutes &&
                                        rMinutes < nextMinutes;
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
                                    isStandardNodeSelected = nodeStartDateTime
                                        .isAtSameMomentAs(selectionStart);
                                  } else {
                                    final selEndDate =
                                        selectEvent.endDate ?? selectEvent.date;
                                    final selectionEnd = DateTime(
                                      selEndDate.year,
                                      selEndDate.month,
                                      selEndDate.day,
                                      selectEvent.endTime!.hour,
                                      selectEvent.endTime!.minute,
                                    );
                                    isStandardNodeSelected =
                                        !nodeStartDateTime.isBefore(
                                          selectionStart,
                                        ) &&
                                        !nodeStartDateTime.isAfter(
                                          selectionEnd,
                                        );
                                  }
                                }

                                bool isDraggedSelected = false;
                                if (_dragStartIndex != null &&
                                    _dragEndIndex != null) {
                                  final start = math.min(
                                    _dragStartIndex!,
                                    _dragEndIndex!,
                                  );
                                  final end = math.max(
                                    _dragStartIndex!,
                                    _dragEndIndex!,
                                  );
                                  isDraggedSelected = i >= start && i <= end;
                                }

                                final bool finalIsSelected =
                                    isDraggedSelected || isStandardNodeSelected;
                                final bool isMultiSelect =
                                    isDraggedSelected ||
                                    (isUserSelected &&
                                        selectEvent.endTime != null);

                                final inputMinutes =
                                    currentInputTime.hour * 60 +
                                    currentInputTime.minute;
                                final now = TimeOfDay.now();
                                final nowMinutes = now.hour * 60 + now.minute;

                                final isSelectedTimeInThisInterval =
                                    nodeIndex == 47
                                    ? inputMinutes >= currentMinutes
                                    : (inputMinutes >= currentMinutes &&
                                          inputMinutes < nextMinutes);

                                final showDedicatedSelectedNode =
                                    isUserSelected &&
                                    _isSameDay(selectEvent.date, date) &&
                                    isSelectedTimeInThisInterval &&
                                    !(currentInputTime.minute == 0 ||
                                        currentInputTime.minute == 30);

                                final isNowInThisInterval = nodeIndex == 47
                                    ? nowMinutes >= currentMinutes
                                    : (nowMinutes >= currentMinutes &&
                                          nowMinutes < nextMinutes);

                                final selectionStartForCurrentTime =
                                    isUserSelected
                                    ? DateTime(
                                        selectEvent.date.year,
                                        selectEvent.date.month,
                                        selectEvent.date.day,
                                        selectEvent.time.hour,
                                        selectEvent.time.minute,
                                      )
                                    : DateTime(0);
                                final selectionEndForCurrentTime =
                                    isUserSelected &&
                                        selectEvent.endTime != null
                                    ? DateTime(
                                        (selectEvent.endDate ??
                                                selectEvent.date)
                                            .year,
                                        (selectEvent.endDate ??
                                                selectEvent.date)
                                            .month,
                                        (selectEvent.endDate ??
                                                selectEvent.date)
                                            .day,
                                        selectEvent.endTime!.hour,
                                        selectEvent.endTime!.minute,
                                      )
                                    : DateTime(0);

                                final nowDateTime = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  now.hour,
                                  now.minute,
                                );
                                final isCurrentTimeSelected =
                                    isUserSelected &&
                                    _isToday(date) &&
                                    (selectEvent.endTime != null
                                        ? (!nowDateTime.isBefore(
                                                selectionStartForCurrentTime,
                                              ) &&
                                              !nowDateTime.isAfter(
                                                selectionEndForCurrentTime,
                                              ))
                                        : (_isSameDay(selectEvent.date, date) &&
                                              now.hour ==
                                                  currentInputTime.hour &&
                                              now.minute ==
                                                  currentInputTime.minute));

                                final showDedicatedCurrentTimeNode =
                                    isNowInThisInterval &&
                                    _isToday(date) &&
                                    !(now.minute == 0 || now.minute == 30) &&
                                    !isCurrentTimeSelected;

                                final showDedicatedSelectedCurrentTimeNode =
                                    isNowInThisInterval &&
                                    _isToday(date) &&
                                    !(now.minute == 0 || now.minute == 30) &&
                                    isCurrentTimeSelected &&
                                    !(isUserSelected &&
                                        _isSameDay(selectEvent.date, date) &&
                                        now.hour == currentInputTime.hour &&
                                        now.minute == currentInputTime.minute);

                                final isStandardNodeCurrentTime =
                                    _isToday(date) &&
                                    (now.hour == time.hour &&
                                        now.minute == time.minute);

                                childWidget = Column(
                                  key: (isNowInThisInterval && _isToday(date))
                                      ? _currentTimeNodeKey
                                      : null,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _EmptyTimeNode(
                                      key: ValueKey(
                                        'n_${dayOffset}_$nodeIndex',
                                      ),
                                      time: time,
                                      isSelected: finalIsSelected,
                                      isMultiSelect: isMultiSelect,
                                      isDraggedSelected: isDraggedSelected,
                                      isCurrentTime: isStandardNodeCurrentTime,
                                      onTap: () => _handleNodeTap(date, time),
                                      onDoubleTap: () =>
                                          _handleNodeDoubleTap(date, time),
                                    ),
                                    if (showDedicatedSelectedNode)
                                      _SelectedTimeNode(
                                        time: currentInputTime,
                                        isCurrentTime:
                                            _isToday(date) &&
                                            (now.hour ==
                                                    currentInputTime.hour &&
                                                now.minute ==
                                                    currentInputTime.minute),
                                        onTap: () => _handleNodeTap(
                                          date,
                                          currentInputTime,
                                        ),
                                        onDoubleTap: () => _handleNodeDoubleTap(
                                          date,
                                          currentInputTime,
                                        ),
                                      ),
                                    if (showDedicatedSelectedCurrentTimeNode)
                                      _SelectedTimeNode(
                                        time: now,
                                        isCurrentTime: true,
                                        onTap: () => _handleNodeTap(date, now),
                                        onDoubleTap: () =>
                                            _handleNodeDoubleTap(date, now),
                                      ),
                                    if (showDedicatedCurrentTimeNode)
                                      _CurrentTimeNode(
                                        time: now,
                                        onTap: () => _handleNodeTap(date, now),
                                        onDoubleTap: () =>
                                            _handleNodeDoubleTap(date, now),
                                      ),
                                    ...recordsInInterval.map(
                                      (record) => RepaintBoundary(
                                        child: DiaryItem(
                                          record: record,
                                          onTap: () => _handleEdit(record),
                                          onEdit: _handleEdit,
                                          onDelete: _handleDelete,
                                          onAiExtract: () =>
                                              _handleAiExtract(record),
                                          onAiExtractLongPress: () =>
                                              _handleAiExtractModelSelect(record),
                                          isExtracting:
                                              _extractingRecordId == record.id,
                                          onUndo: () => _undoExtract(record),
                                          isUndoable: _undoRecords.containsKey(
                                            record.id,
                                          ),
                                          undoAnimation:
                                              _undoControllers[record.id],
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              }

                              return TimelineItemWrapper(
                                index: i,
                                onMount: (index, ctx) =>
                                    _itemContexts[index] = ctx,
                                onUnmount: (index) =>
                                    _itemContexts.remove(index),
                                onHeightChange: (index, height) =>
                                    _itemHeights[index] = height,
                                child: childWidget,
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('加载失败: $e')),
                ),
                // Smart Extract FAB
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: _buildSmartExtractFAB(theme),
                ),
              ],
            ),
          ),
          if (_showBatchConfirmButton) _buildBatchConfirmPanel(theme),
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
    return Theme.of(context).colorScheme.outlineVariant;
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
      HapticFeedback.mediumImpact();
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
      final startTime = TimeOfDay(
        hour: startNodeIndex ~/ 2,
        minute: (startNodeIndex % 2) * 30,
      );
      final startDate = _indexToDate(startDayOffset);

      final endDayOffset = end ~/ _itemsPerDay;
      final endSubIndex = end % _itemsPerDay;
      final endNodeIndex = math.max(0, endSubIndex - 1);
      final endTime = TimeOfDay(
        hour: endNodeIndex ~/ 2,
        minute: (endNodeIndex % 2) * 30,
      );
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
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 20), (
      timer,
    ) {
      if (_lastDragPosition == null ||
          !mounted ||
          !_scrollController.hasClients)
        return;

      final renderBox =
          _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) return;

      final localPos = renderBox.globalToLocal(_lastDragPosition!);
      final viewportHeight = renderBox.size.height;

      const double threshold = 60.0; // 触发自动滚动的边缘距离
      const double maxSpeed = 12.0; // 每次 Tick (20ms) 的最大滚动速度

      double scrollDelta = 0.0;

      if (localPos.dy < threshold && localPos.dy >= 0) {
        // 向上滚动 (越靠近边缘，滚动速度越快)
        final ratio = (threshold - localPos.dy) / threshold;
        scrollDelta = -maxSpeed * ratio;
      } else if (localPos.dy > viewportHeight - threshold &&
          localPos.dy <= viewportHeight) {
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
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;
    final bool isSingleSelected = isSelected && !isMultiSelect;

    final circleColor = isSelected
        ? theme.colorScheme.primary
        : (isCurrentTime
              ? distinctColor.withValues(alpha: 0.6)
              : theme.colorScheme.outlineVariant);

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
        margin: const EdgeInsets.only(
          left: 0.0,
          right: 4.0,
          top: 2.0,
          bottom: 2.0,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: AnimatedContainer(
                  duration: AppDurations.normal,
                  curve: Curves.easeOut,
                  width: circleSize,
                  height: circleSize,
                  decoration: BoxDecoration(
                    color: circleColor,
                    shape: BoxShape.circle,
                    boxShadow: isSelected && !isSingleSelected
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.3,
                              ),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: isSelected && !isSingleSelected
                      ? Center(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
            AnimatedDefaultTextStyle(
              duration: AppDurations.normal,
              curve: Curves.easeOut,
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: isSelected
                    ? theme.colorScheme.primary
                    : (isCurrentTime
                          ? distinctColor
                          : theme.colorScheme.onSurfaceVariant),
                fontWeight: isSelected || isCurrentTime
                    ? FontWeight.bold
                    : FontWeight.w500,
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
                duration: AppDurations.normal,
                curve: Curves.easeOut,
                height: 1,
                color: isSelected
                    ? theme.colorScheme.primary
                    : (isCurrentTime
                          ? distinctColor.withValues(alpha: 0.2)
                          : theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.15,
                            )),
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
  final bool isCurrentTime;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _SelectedTimeNode({
    required this.time,
    this.isCurrentTime = false,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;
    final labelColor = isCurrentTime
        ? distinctColor
        : theme.colorScheme.primary;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(
          left: 0.0,
          right: 4.0,
          top: 2.0,
          bottom: 2.0,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            if (isCurrentTime) ...[
              Icon(Icons.access_time_rounded, size: 14, color: labelColor),
              const SizedBox(width: 6),
            ],
            Text(
              timeStr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
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
              child: Container(height: 1, color: theme.colorScheme.primary),
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
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44.0,
        margin: const EdgeInsets.only(
          left: 0.0,
          right: 4.0,
          top: 2.0,
          bottom: 2.0,
        ),
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
            Icon(Icons.access_time_filled, size: 14, color: distinctColor),
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



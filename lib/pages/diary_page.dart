import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';
import 'package:qnote_flutter/widgets/diary/diary_input_bar.dart';

class DiaryPage extends ConsumerStatefulWidget {
  const DiaryPage({super.key});

  @override
  ConsumerState<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends ConsumerState<DiaryPage> {
  static const int _itemsPerDay = 49;
  static const double _dayHeight = 2180.0;
  static const double _dividerHeight = 80.0;
  static const double _nodeHeight = 48.0;

  late DateTime _today;
  late DateTime _windowStartDate;
  int _windowDays = 7;
  late ScrollController _scrollController;
  final GlobalKey _viewportKey = GlobalKey();
  int? _dragStartIndex;
  int? _dragEndIndex;
  bool _isShiftingWindow = false;
  double? _shiftTargetOffset;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _windowStartDate = _today.subtract(const Duration(days: 3));

    final nodeIndex = now.hour * 2 + (now.minute >= 30 ? 1 : 0);
    final initialOffset = 3 * _dayHeight + _dividerHeight + nodeIndex * _nodeHeight - 200.0;

    _scrollController = ScrollController(initialScrollOffset: initialOffset);
    _scrollController.addListener(_onScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isShiftingWindow || !_scrollController.hasClients) return;

    final offset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (offset < viewportHeight * 0.5 && _windowStartDate.isBefore(_today)) {
      _shiftWindowBackward();
    } else if (offset > maxScroll - viewportHeight * 0.5) {
      _shiftWindowForward();
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
    final dayOffset = _dateToDayOffset(date);
    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(date);
      return;
    }
    final targetOffset = dayOffset * _dayHeight;
    if (_scrollController.hasClients && (_scrollController.offset - targetOffset).abs() > 200.0) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
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

    final dayOffset = _dateToDayOffset(date);
    final targetOffset = dayOffset * _dayHeight + _dividerHeight;

    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(targetOffset);
      }
    });
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
    final result = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('zh', 'CN'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).colorScheme.primary,
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
            dialogTheme: DialogThemeData(
              barrierColor: Colors.black.withValues(alpha: 0.2),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                splashFactory: NoSplash.splashFactory,
              ),
            ),
          ),
          child: child!,
        );
      },
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已删除记录'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            ref.read(diaryListProvider.notifier).undoDelete();
          },
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _handleEdit(DiaryRecord record) {
    context.push('/diary/editor', extra: record);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      if (next != null) {
        _goToDate(next);
      }
    });

    final theme = Theme.of(context);
    final selectedDate = ref.watch(selectedDateProvider);
    final diaryListAsync = ref.watch(diaryListProvider);
    final colorMarks = ref.watch(diaryColorMarkProvider);
    final selectEvent = ref.watch(diaryInputTimeProvider);
    final currentInputTime = ref.watch(currentInputTimeProvider);

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
                    IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
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
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
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
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      onPressed: _navigateToSearch,
                    ),
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
                      left: 39,
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
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: _windowDays * _itemsPerDay,
                        itemBuilder: (context, i) {
                          final dayOffset = i ~/ _itemsPerDay;
                          final subIndex = i % _itemsPerDay;
                          final date = _indexToDate(dayOffset);

                          if (subIndex == 0) {
                            return Container(
                              key: ValueKey('div_${dayOffset}_${date.millisecondsSinceEpoch}'),
                              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
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
                          }

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
                              isStandardNodeSelected = nodeStartDateTime.isAtSameMomentAs(selectionStart) ||
                                  (nodeStartDateTime.isAfter(selectionStart) && nodeStartDateTime.isBefore(selectionEnd));
                            }
                          }

                          bool isDraggedSelected = false;
                          if (_dragStartIndex != null && _dragEndIndex != null) {
                            final start = math.min(_dragStartIndex!, _dragEndIndex!);
                            final end = math.max(_dragStartIndex!, _dragEndIndex!);
                            isDraggedSelected = i >= start && i <= end;
                          }

                          final bool finalIsSelected = isDraggedSelected || isStandardNodeSelected;

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

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _EmptyTimeNode(
                                key: ValueKey('n_${dayOffset}_${nodeIndex}'),
                                time: time,
                                isSelected: finalIsSelected,
                                isDraggedSelected: isDraggedSelected,
                                isCurrentTime: isStandardNodeCurrentTime,
                                onTap: () {
                                  if (isUserSelected) {
                                    if (selectEvent.endTime == null) {
                                      if (_isSameDay(selectEvent.date, date) &&
                                          selectEvent.time.hour == time.hour &&
                                          selectEvent.time.minute == time.minute) {
                                        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                          TimeOfDay.now(),
                                          date: DateTime.now(),
                                        );
                                      } else {
                                        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                          time,
                                          date: date,
                                        );
                                      }
                                    } else {
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

                                      if (nodeStartDateTime.isAtSameMomentAs(selectionStart) ||
                                          (nodeStartDateTime.isAfter(selectionStart) && nodeStartDateTime.isBefore(selectionEnd))) {
                                        if (nodeStartDateTime.isAtSameMomentAs(selectionStart)) {
                                          ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                            TimeOfDay.now(),
                                            date: DateTime.now(),
                                          );
                                        } else {
                                          ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                            selectEvent.time,
                                            endTime: time,
                                            date: selectEvent.date,
                                            endDate: date,
                                          );
                                        }
                                      } else {
                                        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                          time,
                                          date: date,
                                        );
                                      }
                                    }
                                  } else {
                                    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                      time,
                                      date: date,
                                    );
                                  }
                                },
                              ),
                              if (showDedicatedSelectedNode)
                                _SelectedTimeNode(
                                  time: currentInputTime,
                                  onTap: () {
                                    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                      TimeOfDay.now(),
                                      date: DateTime.now(),
                                    );
                                  },
                                ),
                              if (showDedicatedCurrentTimeNode)
                                _CurrentTimeNode(
                                  time: now,
                                  onTap: () {
                                    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                                      now,
                                      date: DateTime.now(),
                                    );
                                  },
                                ),
                              ...recordsInInterval.map((record) => DiaryItem(
                                    record: record,
                                    onTap: () => _handleEdit(record),
                                    onEdit: _handleEdit,
                                    onDelete: _handleDelete,
                                  )),
                            ],
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

  int _pointToItemIndex(Offset localPosition) {
    if (!_scrollController.hasClients) return -1;

    final localY = localPosition.dy;
    final absoluteY = localY + _scrollController.offset;

    final dayOffset = absoluteY ~/ _dayHeight;
    if (dayOffset < 0 || dayOffset >= _windowDays) return -1;

    final relativeY = absoluteY % _dayHeight;

    int subIndex;
    if (relativeY < _dividerHeight) {
      subIndex = 0;
    } else {
      subIndex = 1 + ((relativeY - _dividerHeight) ~/ _nodeHeight);
      if (subIndex > 48) subIndex = 48;
    }

    return dayOffset * _itemsPerDay + subIndex;
  }

  void _handleDragStart(LongPressStartDetails details) {
    final index = _pointToItemIndex(details.localPosition);
    if (index != -1 && index % _itemsPerDay != 0) {
      setState(() {
        _dragStartIndex = index;
        _dragEndIndex = index;
      });
    }
  }

  void _handleDragUpdate(LongPressMoveUpdateDetails details) {
    final index = _pointToItemIndex(details.localPosition);
    if (index != -1 && index % _itemsPerDay != 0) {
      setState(() {
        _dragEndIndex = index;
      });
    }
  }

  void _handleDragEnd(LongPressEndDetails details) {
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
}

class _EmptyTimeNode extends StatelessWidget {
  final TimeOfDay time;
  final bool isSelected;
  final bool isDraggedSelected;
  final bool isCurrentTime;
  final VoidCallback onTap;

  const _EmptyTimeNode({
    super.key,
    required this.time,
    required this.isSelected,
    this.isDraggedSelected = false,
    this.isCurrentTime = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;

    final circleColor = isSelected
        ? theme.colorScheme.primary
        : (isCurrentTime ? distinctColor : theme.colorScheme.outlineVariant);

    final double circleSize = isSelected ? 16 : (isCurrentTime ? 12 : 8);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(
          vertical: isSelected ? 16.0 : 12.0,
        ),
        margin: EdgeInsets.only(
          left: 0.0,
          right: 4.0,
          top: isDraggedSelected ? 0.0 : 2.0,
          bottom: isDraggedSelected ? 0.0 : 2.0,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(isDraggedSelected ? 4 : 16),
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.08)
              : (isCurrentTime ? distinctColor.withValues(alpha: 0.04) : Colors.transparent),
          border: Border.all(
            color: isSelected && !isDraggedSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                : (isCurrentTime ? distinctColor.withValues(alpha: 0.1) : Colors.transparent),
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
                  width: circleSize,
                  height: circleSize,
                  decoration: BoxDecoration(
                    color: circleColor,
                    shape: BoxShape.circle,
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(alpha: 0.3),
                              blurRadius: 8,
                              spreadRadius: 2,
                            )
                          ]
                        : (isCurrentTime
                            ? [
                                BoxShadow(
                                  color: distinctColor.withValues(alpha: 0.2),
                                  blurRadius: 4,
                                  spreadRadius: 1,
                                )
                              ]
                            : null),
                  ),
                  child: isSelected
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
                      : (isCurrentTime
                          ? Center(
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : null),
                ),
              ),
            ),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 300),
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: isSelected
                    ? theme.colorScheme.primary
                    : (isCurrentTime ? distinctColor : theme.colorScheme.onSurfaceVariant),
                fontWeight: isSelected || isCurrentTime ? FontWeight.bold : FontWeight.w500,
                fontSize: isSelected ? 13 : 12,
              ),
              child: Text(timeStr),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
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

  const _SelectedTimeNode({
    required this.time,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
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
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
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
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.white,
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

  const _CurrentTimeNode({
    required this.time,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final distinctColor = theme.colorScheme.secondary;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        margin: const EdgeInsets.only(left: 0.0, right: 4.0, top: 2.0, bottom: 2.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: distinctColor.withValues(alpha: 0.08),
          border: Border.all(
            color: distinctColor.withValues(alpha: 0.15),
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
                    color: distinctColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: distinctColor.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 2,
                      )
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.white,
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

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/providers/diary_progress_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/health_timeline_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/core/utils/batch_review_navigation.dart';
import 'package:qnote_flutter/core/utils/cheer_burst.dart';
import 'package:qnote_flutter/core/utils/concurrent_batch.dart';
import 'package:qnote_flutter/core/utils/diary_progress.dart';
import 'package:qnote_flutter/core/utils/diary_timeline_layout.dart';
import 'package:qnote_flutter/core/utils/health_timeline.dart';
import 'package:qnote_flutter/core/utils/timeline_time_drag.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/core/utils/widget_utils.dart';
import 'package:qnote_flutter/providers/journal_provider.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';
import 'package:qnote_flutter/widgets/diary/ai_extract_helper.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';
import 'package:qnote_flutter/widgets/diary/health_daily_placeholder_card.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/diary/model_selection_dialog.dart';
import 'package:qnote_flutter/widgets/diary/diary_record_fab.dart';
import 'package:qnote_flutter/widgets/diary/diary_record_sheet.dart';
import 'package:qnote_flutter/widgets/diary/cheer_burst_overlay.dart';
import 'package:qnote_flutter/widgets/diary/record_cheer_toast.dart';
import 'package:qnote_flutter/widgets/diary/journal_editor_view.dart';
import 'package:qnote_flutter/widgets/diary/custom_date_picker.dart';
import 'package:qnote_flutter/widgets/diary/sliver_day_collapsible.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';

part 'diary_page_nodes.dart';

class DiaryPage extends ConsumerStatefulWidget {
  const DiaryPage({super.key});

  @override
  ConsumerState<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends ConsumerState<DiaryPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  static const int _itemsPerDay = kDiaryTimelineItemsPerDay;
  static const double _nodeHeight = kDiaryTimelineNodeHeight;

  /// 时间线之外的固定高度：56 顶栏 + 1 分割线 + 66 底栏。
  /// 仅用于首帧滚动偏移估算，随后会用真实 RenderBox 做像素级校准。
  static const double _timelineChromeHeight = 56 + 1 + 66;

  late DateTime _today;
  late TimeOfDay _currentMinute;
  late DateTime _windowStartDate;
  final int _windowDays = 120;
  static const int _shiftDays = 30;
  int _lastShiftTimestamp = 0;
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

  /// 日期分隔栏 context，按时间线全局 index 索引（与 [_itemContexts] 同键）。
  /// 滚动判断当前日期时只量这些每天一个的锚点，避免遍历展开日里 48 个时间槽和全部记录卡。
  final Map<int, BuildContext> _dividerContexts = {};
  final Map<int, double> _itemHeights = {};
  Timer? _autoScrollTimer;
  Timer? _minuteTickTimer;
  Offset? _lastDragPosition;
  bool _isScrollingFromList = false;
  bool _hasPerformedInitialScroll = false;

  /// 首屏定位是否已完成。完成前时间线保持不可见，避免用户看到列表从顶部跳动。
  bool _initialTimelineSettled = false;
  bool _isProgrammaticScrolling = true;

  /// 正在提取的记录（批量并发时可能同时有多条）。
  ///
  /// 从单个 id 改成 Set 是并发的前提：3 路并行时三张卡片要各自转圈，
  /// 用单个 id 只会留下最后一条的状态，其余卡片看起来「没反应」。
  final Set<String> _extractingRecordIds = {};

  /// 正在原地更新的今日运动健康日结卡记录 id（同一时间只允许更新一张）。
  String? _updatingHealthSummaryId;

  /// 记录 id → 该条提取的取消令牌（停止时逐条 cancel）
  final Map<String, CancelToken> _cancelTokens = {};
  // Multi-record undo mapping
  final Map<String, DiaryRecord> _undoRecords = {};
  final Map<String, AnimationController> _undoControllers = {};

  /// 提取后可撤回的窗口时长。
  ///
  /// 窗口内卡片停留在提取前的时间位置，方便用户就地撤回；过期后新时间才生效。
  /// 15s 太长，用户往往已经看完结果还要干等，改为 8s。
  static const Duration _undoWindow = Duration(seconds: 8);

  // 卡片拖动调时：长按时间线左侧圆形节点后，手指位移换算为整条记录的时间平移。
  // 手势统一由外层 GestureDetector 持有，避免卡片被 ListView 回收时拖拽中断。
  final Map<String, GlobalKey> _recordHandleKeys = {};
  _RecordTimeDragState? _cardDrag;
  OverlayEntry? _cardDragOverlay;

  /// 记录按钮的 Key：打开面板时量它的全局 Rect，作为容器变形的起点。
  final GlobalKey _recordFabKey = GlobalKey();

  /// 每条记录卡片本体的 Key：发送后「弹窗变卡片」要量新卡片的落点。
  final Map<String, GlobalKey> _recordCardKeys = {};

  /// 进行中的单日展开/折叠动画控制器，key 为 'yyyy-MM-dd'；稳态日期不常驻动画器。
  final Map<String, _DayExpandAnimation> _dayAnimations = {};

  /// 已结束或被取消的单日动画器：延后到本帧卸载/更新完成后再释放，避免 Widget 解绑监听器时踩到已销毁对象。
  final List<_DayExpandAnimation> _retiredDayAnimations = [];
  bool _retiredFlushScheduled = false;

  /// 顶栏日期标题的长按菜单锚点（标题不随 ListView 回收）。
  final GlobalKey _topBarDateKey = GlobalKey();

  /// 面板打开期间按钮暂时隐藏（它已经变成面板本身）。
  bool _recordFabHidden = false;

  /// 正在作为飞行目标的记录：盖板落位前先隐藏，避免卡片提前从底下露出来。
  String? _hiddenMorphRecordId;

  /// 只播辉光、不播长高的记录（盖板落位后使用）。
  String? _glowOnlyRecordId;
  Timer? _glowClearTimer;

  /// 面板打开期间产生的庆祝胶囊先入队，等路由彻底结束再播，避免在面板背后
  /// 播完或彩带盖住飞行过程。
  CheerEvent? _pendingCheer;

  /// 拖动吸附反馈节流：快速拖动时每帧都变档，避免连续震动糊成一片。
  int _lastDragHapticMs = 0;

  /// 拖动灵敏度：与时间线节点高度保持同一口径（一个节点 = 30 分钟）。
  static const double _dragPixelsPerMinute = _nodeHeight / kTimelineNodeMinutes;

  // _buildRecordsByDate 结果缓存，避免每次 rebuild 重算全表分组+排序与每槽 O(48 * R) 扫描
  List<DiaryRecord>? _lastAllRecords;
  Map<String, List<DiaryRecord>>? _cachedRecordsByDate;
  Map<String, Map<int, List<DiaryRecord>>> _cachedDayNodesByDate = const {};
  Set<String> _cachedDatesWithHealthSummary = const {};
  int _undoRecordsVersion = 0;
  int _cachedUndoRecordsVersion = -1;

  /// 标记 _undoRecords 变化，使下次 _buildRecordsByDate 重算而非命中缓存
  void _bumpUndoRecordsVersion() {
    _undoRecordsVersion++;
  }

  // Batch extraction state
  bool _isBatchExtracting = false;
  int _batchExtractTotal = 0;

  /// 已处理条数（含跳过与失败），只驱动 FAB 进度环
  int _batchExtractCompleted = 0;

  /// 真正提取成功的条数，收尾文案用它 —— 与 [count] 区分开，
  /// 否则跳过的记录会让「提取完成 N 条」虚高
  int _batchExtractSucceeded = 0;

  /// 本批提取失败 / 无结果的条数，收尾时汇总提示
  int _batchExtractFailed = 0;
  bool _batchExtractCancelled = false;

  bool _showBatchConfirmButton = false;
  final Set<String> _batchExtractedRecordIds = {};

  /// 记录 id → 本批内的时间线序号。
  ///
  /// 并发完成后到达顺序与时间线顺序无关，上/下箭头要按用户在列表里看到的顺序
  /// 跳转，必须记下每条的原始序号重新排序，而不是直接用完成顺序。
  final Map<String, int> _batchExtractOrder = {};

  /// [_batchReviewOrderedIds] 的缓存（完成/撤回/清空时失效）
  List<String>? _batchReviewOrderedIdsCache;

  /// 已优化记录按时间线顺序排列的 id 列表（箭头导航与收尾锚点都用它）。
  ///
  /// 结果缓存起来：底部栏每帧重建都会取它，几十条时每帧重排是白费。
  List<String> get _batchReviewOrderedIds {
    final cached = _batchReviewOrderedIdsCache;
    if (cached != null) return cached;
    final ids = _batchExtractedRecordIds.toList();
    ids.sort((a, b) => (_batchExtractOrder[a] ?? 0).compareTo(_batchExtractOrder[b] ?? 0));
    _batchReviewOrderedIdsCache = ids;
    return ids;
  }

  /// 失效已优化记录的排序缓存（集合或序号发生变化时调用）
  void _invalidateBatchReviewOrder() => _batchReviewOrderedIdsCache = null;

  /// 日记写库串行锁。
  ///
  /// 并发提取时多个 worker 会同时提交 updateDiary：SQLite 并发写容易撞
  /// database is locked，且列表状态是「读全表 → 替换一项 → 写回」，
  /// 并发提交会互相覆盖丢更新。
  final SerialExecutor _diaryWriteLock = SerialExecutor();

  /// 底部确认栏上/下箭头当前锚定的记录下标（按提取顺序）。
  int _batchReviewIndex = -1;

  /// 刚通过箭头跳转到的记录：短暂描边高亮，方便用户在列表里定位。
  String? _batchReviewHighlightId;
  Timer? _batchReviewHighlightTimer;

  // 记完即时庆祝胶囊状态：todayCount 变大时才浮现，1s 内连记只展示最后一次
  CheerEvent? _cheerEvent;
  Timer? _cheerTimer;
  int _cheerSeq = 0;

  /// 停留到点后置 true，交给胶囊播退场动画，播完再真正移除。
  bool _cheerLeaving = false;

  /// 兜底移除：退场回调万一没送达（胶囊被父级抢先卸载等），胶囊会永久挂着。
  Timer? _cheerExitTimer;

  /// 彩带层。挂 OverlayEntry 而不是包进 body：见 [_showCheerBurst]。
  OverlayEntry? _cheerBurstEntry;

  static String _dateKey(DateTime date) => diaryDateKey(date);

  Map<String, List<DiaryRecord>> _buildRecordsByDate(List<DiaryRecord> allRecords) {
    // 缓存命中：allRecords 引用相同 + _undoRecords 版本未变
    if (identical(allRecords, _lastAllRecords) &&
        _undoRecordsVersion == _cachedUndoRecordsVersion &&
        _cachedRecordsByDate != null) {
      return _cachedRecordsByDate!;
    }
    final Map<String, List<DiaryRecord>> recordsByDate = {};
    final Map<String, Map<int, List<DiaryRecord>>> dayNodesByDate = {};
    final Set<String> datesWithHealthSummary = {};
    for (final r in allRecords) {
      if (r.isDeleted) continue;
      final preRecord = _undoRecords[r.id];
      final displayDate = preRecord != null ? preRecord.getEffectiveDate() : r.getEffectiveDate();
      final key = _dateKey(displayDate);
      recordsByDate.putIfAbsent(key, () => []).add(r);
      final bs = r.bodyState;
      if (bs != null && bs['source'] == 'mi_fitness' && bs['type'] == 'daily_summary') {
        datesWithHealthSummary.add(key);
      }
    }
    // 按显示时间升序排列，并分桶到 48 个半小时槽位，避免时间线构建时每行全天扫描 O(48 * R)
    recordsByDate.forEach((key, list) {
      list.sort((a, b) {
        final preA = _undoRecords[a.id];
        final displayTimeA = preA != null ? preA.getDisplayTime() : a.getDisplayTime();
        final preB = _undoRecords[b.id];
        final displayTimeB = preB != null ? preB.getDisplayTime() : b.getDisplayTime();
        return displayTimeA.compareTo(displayTimeB);
      });
      final nodeMap = <int, List<DiaryRecord>>{};
      for (final r in list) {
        final pre = _undoRecords[r.id];
        final displayTime = pre != null ? pre.getDisplayTime() : r.getDisplayTime();
        final nodeIdx = ((displayTime.hour * 60 + displayTime.minute) ~/ 30).clamp(0, 47);
        nodeMap.putIfAbsent(nodeIdx, () => []).add(r);
      }
      dayNodesByDate[key] = nodeMap;
    });
    // 写入缓存
    _lastAllRecords = allRecords;
    _cachedRecordsByDate = recordsByDate;
    _cachedDayNodesByDate = dayNodesByDate;
    _cachedDatesWithHealthSummary = datesWithHealthSummary;
    _cachedUndoRecordsVersion = _undoRecordsVersion;
    return recordsByDate;
  }

  // 用户手动切换的展开/折叠状态，key 为 'yyyy-MM-dd'
  final Map<String, bool> _dateExpandedOverrides = {};

  bool _isDefaultExpanded(DateTime date) {
    return isDiaryDateExpandedByDefault(date, _today);
  }

  bool _isDateExpanded(DateTime date) {
    final key = _dateKey(date);
    return _dateExpandedOverrides[key] ?? _isDefaultExpanded(date);
  }

  void _retireDayAnimation(_DayExpandAnimation anim) {
    anim.controller.stop();
    anim.generation++;
    _retiredDayAnimations.add(anim);
    if (_retiredFlushScheduled) {
      return;
    }
    _retiredFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retiredFlushScheduled = false;
      if (_retiredDayAnimations.isEmpty) {
        return;
      }
      final toDispose = List<_DayExpandAnimation>.from(_retiredDayAnimations);
      _retiredDayAnimations.clear();
      for (final item in toDispose) {
        item.dispose();
      }
    });
  }

  void _attachDayAnimationListener(String key, _DayExpandAnimation anim) {
    anim.controller.addStatusListener((status) {
      if (status != AnimationStatus.completed && status != AnimationStatus.dismissed) {
        return;
      }
      // 仅在停稳在当前目标方向对应的终点时回收动画器，避免中途反向误删
      final reachedTarget =
          (anim.isExpanding && status == AnimationStatus.completed) ||
          (!anim.isExpanding && status == AnimationStatus.dismissed);
      if (!reachedTarget) {
        return;
      }
      if (!mounted || !identical(_dayAnimations[key], anim)) {
        return;
      }
      setState(() {
        _dayAnimations.remove(key);
        _retireDayAnimation(anim);
      });
    });
  }

  void _toggleDateExpanded(DateTime date) {
    final key = _dateKey(date);
    final current = _isDateExpanded(date);
    final willExpand = !current;
    final forwardDuration = AppMotion.duration(context, AppDurations.normal);
    final reverseDuration = AppMotion.duration(context, AppDurations.fast);

    _DayExpandAnimation? startedAnim;

    // 当用户点击屏幕上可见的日期分割栏时，内容是在该分割栏下方展开/收起；
    // 该分割栏本身在视口中的起始 offset 完全不变，严禁强行 jumpTo。
    setState(() {
      _dateExpandedOverrides[key] = willExpand;

      // 折叠后正文槽位会卸载，清掉旧槽位测量高度与 context，避免下次估算拿到过期值
      if (!willExpand) {
        final dayOffset = _dateToDayOffset(date);
        if (dayOffset >= 0 && dayOffset < _windowDays) {
          final baseIndex = dayOffset * _itemsPerDay;
          for (var sub = 1; sub < _itemsPerDay; sub++) {
            _itemHeights.remove(baseIndex + sub);
            _itemContexts.remove(baseIndex + sub);
          }
        }
      }

      if (forwardDuration == Duration.zero && reverseDuration == Duration.zero) {
        final existing = _dayAnimations.remove(key);
        if (existing != null) {
          _retireDayAnimation(existing);
        }
      } else {
        final existing = _dayAnimations[key];
        if (existing != null) {
          existing.generation++;
          existing.isExpanding = willExpand;
          startedAnim = existing;
        } else {
          final anim = _DayExpandAnimation(
            vsync: this,
            forwardDuration: forwardDuration,
            reverseDuration: reverseDuration,
            initialValue: willExpand ? 0.0 : 1.0,
            isExpanding: willExpand,
            generation: 0,
          );
          _attachDayAnimationListener(key, anim);
          _dayAnimations[key] = anim;
          startedAnim = anim;
        }
      }
    });

    if (startedAnim != null) {
      if (willExpand) {
        startedAnim!.controller.forward();
      } else {
        startedAnim!.controller.reverse();
      }
    }
    HapticFeedback.lightImpact();
  }

  void _expandDate(DateTime date) {
    final key = _dateKey(date);
    final existing = _dayAnimations.remove(key);
    if (existing != null) {
      _retireDayAnimation(existing);
    }
    if (!_isDateExpanded(date)) {
      setState(() {
        _dateExpandedOverrides[key] = true;
      });
    } else if (existing != null) {
      // 原先正在收起途中被代码展开时，补一次重建以切回无动画稳态 Sliver
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _currentMinute = TimeOfDay(hour: now.hour, minute: now.minute);
    _windowStartDate = _today.subtract(const Duration(days: 60));
    _hasPerformedInitialScroll = false;
    _itemContexts.clear();
    _dividerContexts.clear();
    _itemHeights.clear();

    _scrollController = ScrollController(keepScrollOffset: false);
    _scrollController.addListener(_onScroll);
    _scheduleMinuteTick();
  }

  double _estimateOffsetForIndex(int targetIndex) {
    return estimateDiaryOffsetForIndex(
      targetIndex: targetIndex,
      measuredHeights: _itemHeights,
      windowStartDate: _windowStartDate,
      isExpanded: _isDateExpanded,
    );
  }

  double _estimateOffsetForTimeWithRecords(DateTime targetTime, Map<String, List<DiaryRecord>> recordsByDate) {
    return estimateDiaryOffsetForTimeWithRecords(
      targetTime: targetTime,
      windowStartDate: _windowStartDate,
      today: _today,
      isExpanded: _isDateExpanded,
      recordCountForDate: (date) => (recordsByDate[_dateKey(date)] ?? const <DiaryRecord>[]).length,
      displayTimesForDate: (date) =>
          (recordsByDate[_dateKey(date)] ?? const <DiaryRecord>[]).map((record) => record.getDisplayTime()),
    );
  }

  void _scrollToTarget({
    required int targetIndex,
    GlobalKey? targetKey,
    bool smooth = true,
    double alignment = 0.5,
    int attempts = 0,
    Map<String, List<DiaryRecord>>? recordsByDate,
    DateTime? targetTime,
    VoidCallback? onSettled,
  }) {
    if (!_scrollController.hasClients) {
      _finishProgrammaticScroll();
      onSettled?.call();
      return;
    }

    if (attempts == 0) {
      _isProgrammaticScrolling = true;
    }

    if (attempts > 15) {
      _fallbackScroll(targetIndex, smooth, alignment, onSettled: onSettled);
      return;
    }

    BuildContext? targetContext;
    if (targetKey != null) {
      targetContext = targetKey.currentContext;
    }
    targetContext ??= _itemContexts[targetIndex];

    if (targetContext != null && targetContext.mounted) {
      _scrollToContext(targetContext, smooth: smooth, alignment: alignment, onSettled: onSettled);
      return;
    }

    double estimatedOffset;
    if (recordsByDate != null && targetTime != null) {
      estimatedOffset = _estimateOffsetForTimeWithRecords(targetTime, recordsByDate);
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
        jumpOffset = jumpOffset.clamp(0.0, _scrollController.position.maxScrollExtent);

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
                onSettled: onSettled,
              );
            } else {
              onSettled?.call();
            }
          });
        });
      } else {
        // Target is close or we already jumped, animate to estimated target.
        AppMotion.animateScrollTo(_scrollController, targetOffset, context: context).then((_) {
          if (mounted) {
            _scrollToTarget(
              targetIndex: targetIndex,
              targetKey: targetKey,
              smooth: smooth,
              alignment: alignment,
              attempts: attempts + 1,
              recordsByDate: recordsByDate,
              targetTime: targetTime,
              onSettled: onSettled,
            );
          } else {
            onSettled?.call();
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
              onSettled: onSettled,
            );
          } else {
            onSettled?.call();
          }
        });
      });
    }
  }

  void _scrollToContext(
    BuildContext targetContext, {
    bool smooth = true,
    double alignment = 0.5,
    VoidCallback? onSettled,
  }) {
    if (!targetContext.mounted) {
      _finishProgrammaticScroll();
      onSettled?.call();
      return;
    }

    final renderBox = targetContext.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: alignment,
        duration: smooth ? AppMotion.duration(context, AppDurations.medium) : Duration.zero,
        curve: AppCurves.emphasized,
      ).then((_) {
        _finishProgrammaticScroll();
        onSettled?.call();
      });
      return;
    }

    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: alignment,
        duration: smooth ? AppMotion.duration(context, AppDurations.medium) : Duration.zero,
        curve: AppCurves.emphasized,
      ).then((_) {
        _finishProgrammaticScroll();
        onSettled?.call();
      });
      return;
    }

    final viewportHeight = viewportBox.size.height;
    final nodeHeight = renderBox.size.height;
    final viewportTopOnScreen = viewportBox.localToGlobal(Offset.zero).dy;
    final nodeTopOnScreen = renderBox.localToGlobal(Offset.zero).dy;
    final scrollOffset = _scrollController.offset;
    final nodeTopInScroll = scrollOffset + (nodeTopOnScreen - viewportTopOnScreen);
    final preciseTarget = (nodeTopInScroll - (viewportHeight - nodeHeight) * alignment).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if ((scrollOffset - preciseTarget).abs() < 2.0) {
      _finishProgrammaticScroll();
      onSettled?.call();
      return;
    }

    if (smooth) {
      final distance = (scrollOffset - preciseTarget).abs();
      final baseDuration = distance < 50.0 ? AppDurations.fast : AppDurations.medium;

      AppMotion.animateScrollTo(_scrollController, preciseTarget, context: context, baseDuration: baseDuration).then((
        _,
      ) {
        if (mounted) {
          _finishProgrammaticScroll();
          onSettled?.call();
        } else {
          onSettled?.call();
        }
      });
    } else {
      _scrollController.jumpTo(preciseTarget);
      _finishProgrammaticScroll();
      onSettled?.call();
    }
  }

  void _fallbackScroll(int targetIndex, bool smooth, double alignment, {VoidCallback? onSettled}) {
    final estimatedOffset = _estimateOffsetForIndex(targetIndex);
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = (estimatedOffset - viewportHeight * alignment).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if (smooth) {
      AppMotion.animateScrollTo(_scrollController, targetOffset, context: context).then((_) {
        if (mounted) {
          _finishProgrammaticScroll();
          onSettled?.call();
        } else {
          onSettled?.call();
        }
      });
    } else {
      _scrollController.jumpTo(targetOffset);
      _finishProgrammaticScroll();
      onSettled?.call();
    }
  }

  void _finishProgrammaticScroll() {
    _isProgrammaticScrolling = false;
  }

  void _scrollToCurrentTime({
    bool smooth = true,
    Map<String, List<DiaryRecord>>? recordsByDate,
    VoidCallback? onSettled,
  }) {
    if (!_scrollController.hasClients) {
      // 页面还没完成布局时不能留下「程序滚动中」标记，否则窗口平移会被永久禁用。
      _finishProgrammaticScroll();
      onSettled?.call();
      return;
    }

    final now = DateTime.now();
    final dayOffset = _dateToDayOffset(now);

    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(now);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToCurrentTime(smooth: smooth, recordsByDate: recordsByDate, onSettled: onSettled);
        } else {
          onSettled?.call();
        }
      });
      return;
    }

    _isProgrammaticScrolling = true;
    ref.read(selectedDateProvider.notifier).state = DateTime(now.year, now.month, now.day);

    final nodeIndex = diaryTimelineNodeIndex(now);
    final targetIndex = dayOffset * _itemsPerDay + (nodeIndex + 1);

    _scrollToTarget(
      targetIndex: targetIndex,
      targetKey: _currentTimeNodeKey,
      smooth: smooth,
      alignment: 0.5,
      recordsByDate: recordsByDate,
      targetTime: now,
      onSettled: onSettled,
    );
  }

  /// 首帧直接把时间线定位到当前时刻，避免先渲染列表顶部再跳转造成的闪动。
  ///
  /// [ScrollController.initialScrollOffset] 只能在构造时指定，因此这里在列表首次
  /// 挂载前替换控制器；此时旧控制器还没有任何滚动位置，替换不会丢失滚动状态。
  void _prepareInitialTimelineScroll(Map<String, List<DiaryRecord>> recordsByDate, double viewportHeight) {
    final now = DateTime.now();
    final estimatedOffset = _estimateOffsetForTimeWithRecords(now, recordsByDate);
    final initialOffset = (estimatedOffset - viewportHeight * 0.5).clamp(0.0, double.infinity);

    if (_scrollController.hasClients) {
      // 兜底：列表已挂载时不再替换控制器，直接定位到估算位置。
      _scrollController.jumpTo(initialOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
      return;
    }

    final previous = _scrollController;
    previous.removeListener(_onScroll);
    previous.dispose();
    _scrollController = ScrollController(initialScrollOffset: initialOffset, keepScrollOffset: false);
    _scrollController.addListener(_onScroll);
  }

  void _scrollToTime(DateTime targetTime, {bool smooth = true, Map<String, List<DiaryRecord>>? recordsByDate}) {
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
    _expandDate(targetTime);
    ref.read(selectedDateProvider.notifier).state = DateTime(targetTime.year, targetTime.month, targetTime.day);

    final nodeIndex = diaryTimelineNodeIndex(targetTime);
    final targetIndex = dayOffset * _itemsPerDay + (nodeIndex + 1);

    _scrollToTarget(
      targetIndex: targetIndex,
      smooth: smooth,
      alignment: 0.5,
      recordsByDate: recordsByDate,
      targetTime: targetTime,
    );
  }

  /// 目标记录卡片当前是否完整落在视口安全区内。
  ///
  /// 批量提取前用它代替「按时间估算」：同一时间段可能压着多条记录，
  /// 估算只能保证时间节点可见，未必能保证目标卡片可见。
  bool _isRecordInViewport(DiaryRecord record) {
    if (!_scrollController.hasClients) return false;
    final targetDate = record.getEffectiveDate();
    if (!_isDateExpanded(targetDate)) return false;

    final cardContext = _recordCardKeys[record.id]?.currentContext;
    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (cardContext != null && cardContext.mounted && viewportBox != null && viewportBox.hasSize) {
      final cardBox = cardContext.findRenderObject() as RenderBox?;
      if (cardBox != null && cardBox.hasSize) {
        final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
        final viewportBottom = viewportTop + viewportBox.size.height;
        final cardTop = cardBox.localToGlobal(Offset.zero).dy;
        final cardBottom = cardTop + cardBox.size.height;
        // 顶部让开导航栏，底部让开悬浮钮与批量确认栏
        return cardTop >= viewportTop + 24 && cardBottom <= viewportBottom - 120;
      }
    }

    // 卡片未挂载时沿用按时间估算的兜底
    final allRecords = ref.read(diaryListProvider).valueOrNull;
    if (allRecords == null) return false;
    final recordsByDate = _buildRecordsByDate(allRecords);
    final estimatedOffset = _estimateOffsetForTimeWithRecords(record.getDisplayTime(), recordsByDate);
    final scrollOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;
    return estimatedOffset >= scrollOffset + 40 && estimatedOffset <= scrollOffset + viewportHeight - 140;
  }

  /// 平滑滚动到指定记录卡片，滚动动画落定后返回。
  ///
  /// 与 [_scrollToTime] 只定位时间节点不同，这里优先使用卡片自己的 Key，
  /// 保证同一时间段有多条记录时也能准确落到目标卡片。
  Future<void> _scrollToRecordCard(DiaryRecord record, {bool smooth = true}) async {
    if (!_scrollController.hasClients) return;

    final targetDate = record.getEffectiveDate();
    final dayOffset = _dateToDayOffset(targetDate);
    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(targetDate);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      // 早于时间线可回溯窗口（约一年）的记录无法渲染，直接放弃滚动，
      // 避免“平移窗口 → 仍不可见 → 再平移”的递归空转。
      final adjustedOffset = _dateToDayOffset(targetDate);
      if (adjustedOffset < 0 || adjustedOffset >= _windowDays) return;
      await _scrollToRecordCard(record, smooth: smooth);
      return;
    }

    if (!_isDateExpanded(targetDate)) {
      _expandDate(targetDate);
      // 展开会改变列表整体高度，等新布局落帧后再定位，避免拿旧偏移滚动。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }

    ref.read(selectedDateProvider.notifier).state = targetDate;

    final targetIndex = dayOffset * _itemsPerDay + (diaryTimelineNodeIndex(record.getDisplayTime()) + 1);
    final allRecords = ref.read(diaryListProvider).valueOrNull ?? const <DiaryRecord>[];
    final recordsByDate = _buildRecordsByDate(allRecords);

    final settled = Completer<void>();
    void finish() {
      if (!settled.isCompleted) {
        settled.complete();
      }
    }

    _scrollToTarget(
      targetIndex: targetIndex,
      targetKey: _recordCardKeyFor(record.id),
      smooth: smooth,
      alignment: 0.5,
      recordsByDate: recordsByDate,
      targetTime: record.getDisplayTime(),
      onSettled: finish,
    );

    // 兜底超时：滚动重试链有界，但异常布局下不能让批量流程一直挂住。
    await settled.future.timeout(const Duration(milliseconds: 2500), onTimeout: () {});
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
        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(time, date: date);
      }
      return;
    }

    final clickedDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);

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
      if (newEndDateTime.isBefore(selectionStart)) {
        // 当点击的是落在起点半小时以内的专用节点（如「当前时间」）时，退回单选起点，避免终点早于起点。
        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
          selectEvent.time,
          date: selectEvent.date,
        );
      } else {
        final newEndTime = TimeOfDay(hour: newEndDateTime.hour, minute: newEndDateTime.minute);

        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
          selectEvent.time,
          endTime: newEndTime,
          date: selectEvent.date,
          endDate: DateTime(newEndDateTime.year, newEndDateTime.month, newEndDateTime.day),
        );
      }
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
    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(time, date: date);
  }

  /// 行内记录加号要挂到的时刻：单选是选中点，区间是末端所在的半小时节点。
  ///
  /// 返回 null 表示当前没有选中；调用方拿它和每一行的时刻比较，只有相等的那
  /// 一行会渲染加号，避免区间选中时每一条绿线都冒出一个按钮。
  DateTime? _resolveTimelineRecordAnchor(TimelineTimeSelectEvent? selection) {
    if (selection == null) {
      return null;
    }
    final start = DateTime(
      selection.date.year,
      selection.date.month,
      selection.date.day,
      selection.time.hour,
      selection.time.minute,
    );
    if (selection.endTime == null) {
      return resolveTimelineRecordAnchor(start: start);
    }
    final endDate = selection.endDate ?? selection.date;
    final end = DateTime(endDate.year, endDate.month, endDate.day, selection.endTime!.hour, selection.endTime!.minute);
    return resolveTimelineRecordAnchor(start: start, end: end);
  }

  void _scheduleMinuteTick() {
    _minuteTickTimer?.cancel();
    final now = DateTime.now();
    // 对齐到下一分钟整点后 50ms 触发，防止系统定时器微提前导致分钟尚未跳变。
    final delayMs = ((60 - now.second) * 1000 - now.millisecond + 50).clamp(50, 61000);
    _minuteTickTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      _syncCurrentTimeIfChanged();
      _scheduleMinuteTick();
    });
  }

  void _syncCurrentTimeIfChanged() {
    final now = DateTime.now();
    final todayNow = DateTime(now.year, now.month, now.day);
    final minuteNow = TimeOfDay(hour: now.hour, minute: now.minute);
    final dayChanged = !_isSameDay(_today, todayNow);
    final minuteChanged = minuteNow.hour != _currentMinute.hour || minuteNow.minute != _currentMinute.minute;

    if (!dayChanged && !minuteChanged) {
      return;
    }

    if (dayChanged) {
      setState(() {
        _today = todayNow;
        _currentMinute = minuteNow;
        _windowStartDate = _today.subtract(const Duration(days: 60));
      });
      final allRecords = ref.read(diaryListProvider).valueOrNull;
      final recordsByDate = allRecords != null ? _buildRecordsByDate(allRecords) : null;
      _scrollToCurrentTime(smooth: true, recordsByDate: recordsByDate);
    } else {
      setState(() {
        _currentMinute = minuteNow;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从后台恢复时定时器可能被系统挂起，立即同步当前分钟并重排下一分钟滴答。
      _syncCurrentTimeIfChanged();
      _scheduleMinuteTick();
    }
  }

  @override
  void dispose() {
    try {
      Toast.dismiss();
    } catch (_) {}
    // 页面销毁时在途的提取请求必须一并取消，否则它们会继续占着 Key 与配额，
    // 并在回调里对已卸载的 State 调 setState
    _batchExtractCancelled = true;
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoScrollTimer();
    _minuteTickTimer?.cancel();
    _removeCardDragOverlay();
    _cardDrag = null;
    _recordHandleKeys.clear();
    _glowClearTimer?.cancel();
    _cheerTimer?.cancel();
    _cheerExitTimer?.cancel();
    _insertClearTimer?.cancel();
    _batchReviewHighlightTimer?.cancel();
    _removeCheerBurst();
    _itemContexts.clear();
    _dividerContexts.clear();
    _itemHeights.clear();
    for (final anim in _dayAnimations.values) {
      anim.dispose();
    }
    _dayAnimations.clear();
    for (final anim in _retiredDayAnimations) {
      anim.dispose();
    }
    _retiredDayAnimations.clear();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    for (final c in _undoControllers.values) {
      c.dispose();
    }
    _undoControllers.clear();
    _undoRecords.clear();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 切回时间线标签页时顺便对齐当前时间，避免后台页签期间跨分钟导致旧「当前时间」残留一帧
    if (TickerMode.valuesOf(context).enabled) {
      final now = DateTime.now();
      final todayNow = DateTime(now.year, now.month, now.day);
      final minuteNow = TimeOfDay(hour: now.hour, minute: now.minute);
      if (!_isSameDay(_today, todayNow)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncCurrentTimeIfChanged();
        });
      } else {
        _currentMinute = minuteNow;
      }
    }
    // 系统开启「减弱动画」时立即清掉进行中的日折叠过渡，直接按稳态渲染
    if (AppMotion.reduce(context) && _dayAnimations.isNotEmpty) {
      final active = _dayAnimations.values.toList();
      _dayAnimations.clear();
      for (final anim in active) {
        _retireDayAnimation(anim);
      }
    }
  }

  DateTime? _lastVisibleDate;

  void _onScroll() {
    if (_isShiftingWindow ||
        _isProgrammaticScrolling ||
        // 拖动调时依赖页面内稳定的列表窗口：自动滚动到窗口边缘时禁止平移窗口，
        // 否则日期与 item 索引会在拖拽中途整体偏移。
        _cardDrag != null ||
        !_scrollController.hasClients) {
      return;
    }

    final offset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 冷却期保护：平移完成后至少等待 200ms，防止高频震荡
    final canShift = nowMs - _lastShiftTimestamp >= 200;

    // 允许双向自由滑动平移窗口（最早 -365 天，最晚 +365 天）
    // 在 120 天超宽窗口支持下，固定使用 300px 的边缘安全触发线，平移步长为 30 天（至少 2400px），
    // 平移后新 offset 永远距离触发线有超过 2000px 的安全跑道，彻底杜绝触顶震荡
    const edgeBuffer = 300.0;
    if (canShift && maxScroll > edgeBuffer * 2.5) {
      final earliestDate = _today.subtract(const Duration(days: 365));
      final latestDate = _today.add(const Duration(days: 365));

      if (offset < edgeBuffer && _windowStartDate.isAfter(earliestDate)) {
        _shiftWindowBackward();
      } else if (offset > maxScroll - edgeBuffer && _windowStartDate.isBefore(latestDate)) {
        _shiftWindowForward();
      }
    }

    // Determine currently visible date based on the exact center of the viewport
    final viewportCtx = _viewportKey.currentContext;
    if (viewportCtx != null) {
      final RenderBox? viewportBox = viewportCtx.findRenderObject() as RenderBox?;
      if (viewportBox != null && viewportBox.hasSize) {
        // Find the Y coordinate for the center of the viewport on screen
        final double centerYOnScreen = viewportBox.localToGlobal(Offset(0, viewportBox.size.height / 2)).dy;

        // 只量日期分隔栏（每天一个），不再遍历 _itemContexts（包含展开日 48 个
        // 时间槽 + 全部记录卡）：弹道滚动时这个方法逐帧执行，全量
        // findRenderObject/localToGlobal 会直接拖慢滚动。分隔栏滚出缓存区的
        // 超长展开日再由完整 item 列表兜底一次。
        final visibleDayOffset = _resolveVisibleDayOffset(centerYOnScreen);
        if (visibleDayOffset != null) {
          final visibleDate = _indexToDate(visibleDayOffset);

          final selectedDate = ref.read(selectedDateProvider);
          if (!_isSameDay(selectedDate, visibleDate) &&
              (_lastVisibleDate == null || !_isSameDay(_lastVisibleDate!, visibleDate))) {
            _lastVisibleDate = visibleDate;
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

  /// 求视口中心线所在日期（dayOffset）。优先用分隔栏锚点；中心落在超长展开日、
  /// 分隔栏已滚出挂载范围时，回退到完整 item 列表（item index 本身含 dayOffset）。
  int? _resolveVisibleDayOffset(double centerYOnScreen) {
    final dividerIndex = _closestIndexAbove(centerYOnScreen, _dividerContexts);
    if (dividerIndex != null) {
      return dividerIndex ~/ _itemsPerDay;
    }
    final itemIndex = _closestIndexAbove(centerYOnScreen, _itemContexts);
    return itemIndex == null ? null : itemIndex ~/ _itemsPerDay;
  }

  /// 找出中心线上方最近的一个挂载 item，返回它的 index。
  int? _closestIndexAbove(double centerYOnScreen, Map<int, BuildContext> contexts) {
    int? closest;
    double minDistance = double.infinity;
    for (final entry in contexts.entries) {
      final ctx = entry.value;
      if (!ctx.mounted) continue;
      final RenderBox? itemBox = ctx.findRenderObject() as RenderBox?;
      if (itemBox == null || !itemBox.hasSize) continue;
      final double itemTop = itemBox.localToGlobal(Offset.zero).dy;
      if (itemTop <= centerYOnScreen) {
        final distance = centerYOnScreen - itemTop;
        if (distance < minDistance) {
          minDistance = distance;
          closest = entry.key;
        }
      }
    }
    return closest;
  }

  double _calculateDaysHeight(DateTime startDate, int daysCount) {
    final allRecords = ref.read(diaryListProvider).valueOrNull;
    final recordsByDate = allRecords != null ? _buildRecordsByDate(allRecords) : null;
    return calculateDiaryDaysHeight(
      startDate: startDate,
      daysCount: daysCount,
      isExpanded: _isDateExpanded,
      recordCountForDate: recordsByDate == null
          ? null
          : (date) => (recordsByDate[_dateKey(date)] ?? const <DiaryRecord>[]).length,
    );
  }

  void _shiftWindowBackward() {
    if (_isShiftingWindow) return;
    _isShiftingWindow = true;

    final prevOffset = _scrollController.offset;
    final newStartDate = _windowStartDate.subtract(const Duration(days: _shiftDays));
    final shiftHeight = _calculateDaysHeight(newStartDate, _shiftDays);
    _windowStartDate = newStartDate;
    _shiftTargetOffset = prevOffset + shiftHeight;
    _itemContexts.clear();
    _dividerContexts.clear();
    _itemHeights.clear();

    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _shiftTargetOffset != null) {
        _scrollController.jumpTo(_shiftTargetOffset!.clamp(0.0, _scrollController.position.maxScrollExtent));
        _shiftTargetOffset = null;
      }
      if (mounted) {
        setState(() {
          _isShiftingWindow = false;
          _lastShiftTimestamp = DateTime.now().millisecondsSinceEpoch;
        });
      }
    });
  }

  void _shiftWindowForward() {
    if (_isShiftingWindow) return;
    _isShiftingWindow = true;

    final prevOffset = _scrollController.offset;
    final removedHeight = _calculateDaysHeight(_windowStartDate, _shiftDays);
    _windowStartDate = _windowStartDate.add(const Duration(days: _shiftDays));
    _shiftTargetOffset = prevOffset - removedHeight;
    _itemContexts.clear();
    _dividerContexts.clear();
    _itemHeights.clear();

    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _shiftTargetOffset != null) {
        _scrollController.jumpTo(_shiftTargetOffset!.clamp(0.0, _scrollController.position.maxScrollExtent));
        _shiftTargetOffset = null;
      }
      if (mounted) {
        setState(() {
          _isShiftingWindow = false;
          _lastShiftTimestamp = DateTime.now().millisecondsSinceEpoch;
        });
      }
    });
  }

  DateTime _indexToDate(int dayOffset) {
    return diaryDateForDayOffset(_windowStartDate, dayOffset);
  }

  int _dateToDayOffset(DateTime date) {
    return diaryDayOffset(date, _windowStartDate);
  }

  String _formatDateTitle(DateTime date) => formatDiaryDateTitle(date);

  String _formatDividerDate(DateTime date) => formatDiaryDividerDate(date);

  bool _isToday(DateTime date) => isTodayDate(date, _today);

  bool _isSameDay(DateTime a, DateTime b) => isSameCalendarDay(a, b);

  void _goToDate(DateTime date, {bool expand = true}) {
    if (_isScrollingFromList) return;

    if (expand) {
      _expandDate(date);
    }
    ref.read(selectedDateProvider.notifier).state = date;

    final dayOffset = _dateToDayOffset(date);

    if (dayOffset < 0 || dayOffset >= _windowDays) {
      _ensureDateInWindow(date);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goToDate(date, expand: expand);
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

    // 将目标日期尽量居中放置在 120 天窗口的中部（第 60 天）
    final newStartDiff = (diff - 60).clamp(-365, 365 - _windowDays);

    _windowStartDate = _today.add(Duration(days: newStartDiff));
    _itemContexts.clear();
    _dividerContexts.clear();
    _itemHeights.clear();

    setState(() {});
  }

  /// 日期标色可选色板。
  static const List<({String name, Color color})> _dateColorOptions = [
    (name: '红色', color: Color(0xFFFF3B30)),
    (name: '绿色', color: Color(0xFF34C759)),
    (name: '蓝色', color: Color(0xFF007AFF)),
    (name: '橙色', color: Color(0xFFFF9500)),
    (name: '紫色', color: Color(0xFFAF52DE)),
  ];

  /// 长按日期分隔条或顶栏日期标题：直接展开标色菜单，并保留批量管理入口。
  void _showDateActionMenu(DateTime date, {GlobalKey? anchorKey, BuildContext? anchorContext}) {
    final colorMarks = ref.read(diaryColorMarkProvider).valueOrNull ?? const <DateColorMark>[];
    final currentMark = colorMarks.where((m) => _isSameDay(m.date, date)).firstOrNull;
    final currentColor = currentMark != null ? _hexToColor(context, currentMark.color) : null;
    final items = <ActionMenuItem>[
      for (final option in _dateColorOptions)
        ActionMenuItem(
          iconWidget: Icon(
            currentColor?.toARGB32() == option.color.toARGB32() ? Icons.check_circle_rounded : Icons.circle,
            size: 20,
            color: option.color,
          ),
          label: option.name,
          onTap: () => _applyDateColorMark(date, option.color),
        ),
      if (currentMark != null)
        ActionMenuItem(
          icon: Icons.format_color_reset_outlined,
          label: '清除颜色',
          onTap: () => _applyDateColorMark(date, null),
        ),
      ActionMenuItem(icon: Icons.list_alt_rounded, label: '批量管理', onTap: _navigateToBatchManage),
    ];

    HapticFeedback.lightImpact();
    if (anchorContext != null) {
      ActionMenu.showForContext(context: context, anchorContext: anchorContext, items: items);
      return;
    }
    ActionMenu.show(context: context, key: anchorKey ?? _topBarDateKey, items: items);
  }

  /// 写入或清除某一天的颜色标记。
  void _applyDateColorMark(DateTime date, Color? color) {
    final colorMarks = ref.read(diaryColorMarkProvider).valueOrNull ?? const <DateColorMark>[];
    final currentMark = colorMarks.where((m) => _isSameDay(m.date, date)).firstOrNull;
    final notifier = ref.read(diaryColorMarkProvider.notifier);

    if (color == null) {
      if (currentMark != null) {
        notifier.removeMarkByDate(date);
      }
      return;
    }

    notifier.setMark(
      DateColorMark(
        // 新建时生成唯一 id：沿用空串会让多个未标色日期互相覆盖。
        id: currentMark?.id ?? const Uuid().v4(),
        date: date,
        color: '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
      ),
    );
  }

  void _showDatePicker() async {
    final selectedDate = ref.read(selectedDateProvider);
    final colorMarks = ref.read(diaryColorMarkProvider).valueOrNull ?? [];
    final result = await AppMotion.showDialog<DateTime>(
      context: context,
      builder: (context) => CustomDatePickerDialog(
        initialDate: selectedDate,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        colorMarks: colorMarks,
      ),
    );
    if (result != null) {
      _goToDate(result, expand: true);
    }
  }

  void _navigateToSearch() {
    Navigator.of(context).push(AppMotion.fadeRoute(const SearchView()));
  }

  void _navigateToBatchManage() {
    context.push('/diary/batch');
  }

  /// 记完一条后的轻量庆祝：悬浮钮行上方浮现胶囊，短暂停留后播退场再移除。
  ///
  /// 满档与破纪录才配流光描边和彩带（分级规格见 [resolveCheerLevel]），平时保持极轻；
  /// 1 秒内连记多条只展示最后一次，避免胶囊排队刷屏。
  void _showCheer({required String title, String? sub, required CheerLevel level}) {
    // 面板还开着（尤其正在播「弹窗变卡片」）时先压住：胶囊会被面板挡住，
    // 彩带层又会盖住飞行。等路由彻底结束再由 _flushPendingCheer 播。
    if (_recordSheetOpen) {
      _cheerSeq++;
      _pendingCheer = CheerEvent(id: _cheerSeq, title: title, sub: sub, level: level);
      return;
    }
    _cheerTimer?.cancel();
    _cheerExitTimer?.cancel();
    _cheerSeq++;
    setState(() {
      _cheerEvent = CheerEvent(id: _cheerSeq, title: title, sub: sub, level: level);
      _cheerLeaving = false;
    });
    if (level.isCheer) {
      _showCheerBurst(_cheerEvent!);
    }
    _cheerTimer = Timer(Duration(milliseconds: level.dwellMs), () {
      if (!mounted) {
        return;
      }
      // 只置「该走了」，实际移除等胶囊自己把退场播完，避免动画被腰斩。
      setState(() => _cheerLeaving = true);
      _cheerExitTimer = Timer(const Duration(milliseconds: 400), _dismissCheer);
    });
  }

  /// 面板关掉后把入队的庆祝补播出来；等一帧让落位/收尾动画先站稳。
  void _flushPendingCheer() {
    final cheer = _pendingCheer;
    if (cheer == null) return;
    _pendingCheer = null;
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _showCheer(title: cheer.title, sub: cheer.sub, level: cheer.level);
    });
  }

  /// 退场播完的回调，兼作兜底超时的收口。
  ///
  /// 两条路径都进这里、谁先到谁生效：胶囊被父级抢先卸载时 onDismissed 送达不了，
  /// 没有兜底那条，胶囊会永久挂在屏幕上。
  void _dismissCheer() {
    _cheerTimer?.cancel();
    _cheerExitTimer?.cancel();
    _removeCheerBurst();
    if (!mounted) {
      return;
    }
    setState(() {
      _cheerEvent = null;
      _cheerLeaving = false;
    });
  }

  /// 彩带迸发层挂到 Overlay，而不是塞进 body。
  ///
  /// 两个原因：一是 body 是 Stack，彩带要压过左下角的记录按钮与右侧两个悬浮钮，
  /// 而爆点恰好贴着它们；二是为了提层把这 600 行 body 再包一层会让本次改动淹没在
  /// 重排 diff 里（本文件按 120 行宽手写排版，不能靠 dart format 兜底）。
  /// Toast 在本项目里就是同一套 OverlayEntry。
  ///
  /// 播完由 [CheerBurstOverlay.onFinished] 自行摘除；连记多条时先摘再挂，
  /// 保证每次爆发都是新的一组粒子。
  void _showCheerBurst(CheerEvent event) {
    _removeCheerBurst();
    final entry = OverlayEntry(
      // 这层铺满整屏，不吃手势就会把时间线滚动和两个 FAB 的点击全吞掉。
      builder: (context) => IgnorePointer(
        child: CheerBurstOverlay(level: event.level, seed: event.id, onFinished: _removeCheerBurst),
      ),
    );
    Overlay.of(context).insert(entry);
    _cheerBurstEntry = entry;
  }

  void _removeCheerBurst() {
    final entry = _cheerBurstEntry;
    if (entry == null) {
      return;
    }
    _cheerBurstEntry = null;
    try {
      entry.remove();
    } catch (_) {
      // 页面被抢先销毁时宿主 Overlay 已不在，与 dispose 里 Toast.dismiss 同一处理方式。
    }
  }

  /// 正在播放退场动画的记录集合
  final Set<String> _deletingRecordIds = {};

  /// 正在播放入场动画的记录集合（记录面板刚写下的那几条）。
  final Set<String> _insertingRecordIds = {};

  /// 记录面板是否已经升起，防外部快捷入口连发导致面板叠层。
  bool _recordSheetOpen = false;

  /// 入场动画播完后撤标记的兜底定时器。
  Timer? _insertClearTimer;

  /// 记录面板把「刚写下的记录 id」交过来时开始播入场动画。
  ///
  /// 标记要撤：ListView 回收再重建（来回滚动）会重新构造这个包装器，
  /// 不撤的话每次滚回来卡片都会重播一遍入场动画。
  void _handleJustInserted(List<String> recordIds) {
    if (recordIds.isEmpty) {
      return;
    }
    setState(() => _insertingRecordIds.addAll(recordIds));
    _insertClearTimer?.cancel();
    _insertClearTimer = Timer(_kInsertRevealDelay + _kInsertDuration + const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(_insertingRecordIds.clear);
    });
  }

  void _handleDelete(DiaryRecord record) {
    // 运动健康日结汇总卡片不可被删除
    final bs = record.bodyState;
    if (bs != null && bs['source'] == 'mi_fitness' && bs['type'] == 'daily_summary') {
      Toast.info(context, '运动健康日结由系统同步，不可删除');
      return;
    }

    HapticFeedback.heavyImpact();
    _clearUndoForRecord(record.id);
    setState(() {
      _deletingRecordIds.add(record.id);
    });

    // 播放 200ms 折叠与淡出退场动画后，真正从数据库与列表移除
    Future.delayed(AppDurations.normal, () {
      if (!mounted) return;
      ref.read(diaryListProvider.notifier).deleteDiary(record.id);
      setState(() {
        _deletingRecordIds.remove(record.id);
      });
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
    });
  }

  void _handleEdit(DiaryRecord record) {
    // 运动健康日结汇总卡片为系统只读卡片，点击/编辑统一跳转至对应日期的小米健康看板
    final bs = record.bodyState;
    if (bs != null && bs['source'] == 'mi_fitness' && bs['type'] == 'daily_summary') {
      final dateStr = bs['date'] as String?;
      final targetDate = dateStr != null ? DateTime.tryParse(dateStr) : null;
      context.push('/settings/mi-fitness', extra: targetDate ?? record.time);
      return;
    }

    _clearUndoForRecord(record.id);
    Toast.dismiss();
    context.push('/diary/editor', extra: record);
  }

  /// 取运动健康日结卡所属日期；非日结卡返回 null。
  ///
  /// 用 `bodyState['date']` 而不是记录时间：日结卡固定在当天 23:00，
  /// 跨时区/拖拽调时后记录时间可能与数据日期不一致。
  DateTime? _healthSummaryDate(DiaryRecord record) {
    final bs = record.bodyState;
    if (bs == null || bs['source'] != 'mi_fitness' || bs['type'] != 'daily_summary') {
      return null;
    }
    return DateTime.tryParse(bs['date'] as String? ?? '');
  }

  /// 原地更新今天的运动健康日结卡。
  ///
  /// 卡片一旦生成，用户想刷新当天步数/睡眠时不必再跳设置页：直接按日同步，
  /// 服务层会更新同一条日结记录并经事件总线触发表格刷新。
  Future<void> _handleUpdateHealthSummary(String recordId, DateTime date) async {
    if (_updatingHealthSummaryId != null) return;
    setState(() => _updatingHealthSummaryId = recordId);

    HealthSyncResult result;
    try {
      result = await ref.read(healthSyncServiceProvider).syncDate(date);
    } catch (e) {
      result = HealthSyncResult(success: false, errorMessage: '同步异常：$e');
    }
    if (!mounted) return;
    setState(() => _updatingHealthSummaryId = null);

    if (!result.success) {
      Toast.error(context, result.errorMessage ?? '更新失败');
      return;
    }
    // 成功路径由 HealthSyncService 直接更新记录并触发 WorkspaceEventBus，
    // diaryListProvider 会自动重查；这里不再额外全表刷新，避免重复读库。
    if (result.newTimelineCards == 0) {
      Toast.info(context, '今日暂无新的健康数据');
    } else {
      Toast.success(context, '已更新今日健康数据');
    }
  }

  /// 「给小Q」：把该条流水记录引用给悬浮小Q（修改这条事件、针对它提问均可），
  /// 记录 id 与当天文件路径在发送时由引用块注入，这里只带摘录与时间展示
  void _quoteRecordToQ(DiaryRecord record) {
    HapticFeedback.lightImpact();
    final excerpt = record.content.trim().isNotEmpty ? record.content.trim() : record.title.trim();
    ref
        .read(floatingQProvider.notifier)
        .openWithQuote(
          QTextQuote(
            source: QQuoteSource.diary,
            sourceId: record.id,
            sourceTitle: record.title.trim().isNotEmpty ? record.title.trim() : '一条流水记录',
            quotedText: excerpt.length > 500 ? '${excerpt.substring(0, 500)}…' : excerpt,
            locationDesc: DateFormat('MM-dd HH:mm').format(record.startTime ?? record.time),
          ),
        );
  }

  Future<void> _handleAiExtract(DiaryRecord record) async {
    if (_isBatchExtracting) return;
    if (_extractingRecordIds.isNotEmpty) {
      if (_extractingRecordIds.contains(record.id)) {
        _cancelTokens.remove(record.id)?.cancel();
        if (mounted) setState(() => _extractingRecordIds.remove(record.id));
      }
      return;
    }
    final contentText = record.content.trim();
    if (contentText.isEmpty && record.photos.isEmpty) return;

    // 未配置模型：入口已统一提示，这里只做兜底
    if (!await AiRoleService.instance.hasUsableConfigForRole('timelineOptimization')) {
      if (mounted) {
        await showNoModelConfiguredDialog(context, scene: 'AI 提取');
      }
      return;
    }
    if (!mounted) return;

    final token = CancelToken();
    _cancelTokens[record.id] = token;
    setState(() {
      _extractingRecordIds.add(record.id);
    });

    AiExtractResult? result;
    try {
      result = await extractExistingRecord(
        ref: ref,
        context: context,
        content: contentText,
        photos: record.photos,
        recordTime: record.time,
        startTime: record.startTime,
        endTime: record.endTime,
        cancelToken: token,
      );
    } on VisionUnsupportedException catch (e) {
      if (mounted) {
        setState(() => _extractingRecordIds.remove(record.id));
        await showVisionUnsupportedDialog(context, modelName: e.modelName, scene: 'AI 提取');
      }
      return;
    }

    if (result != null && mounted) {
      final updated = _buildExtractedRecord(record, result);
      // Store pre-extract record and create undo controller
      _undoRecords[record.id] = record;
      _bumpUndoRecordsVersion();
      _createUndoController(record.id);

      await ref.read(diaryListProvider.notifier).updateDiary(updated);
      if (mounted) {
        Toast.success(context, '优化完成');
        _undoControllers[record.id]?.forward(from: 0);
      }
    }

    _cancelTokens.remove(record.id);
    if (mounted) {
      setState(() => _extractingRecordIds.remove(record.id));
    }
  }

  /// 把 AI 提取结果套用到记录上，得到待落库的新记录。
  ///
  /// 单条与批量共用同一套字段合并规则：标签优先取 AI 返回的 tagEntries，
  /// 其次回退到命中的快捷标签；时间偏移以记录自身日期为基准换算。
  DiaryRecord _buildExtractedRecord(DiaryRecord record, AiExtractResult result) {
    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
    final foundShortcut = findShortcutById(result.shortcutId, shortcuts);

    List<String> newTags = List.from(record.tags);
    String newDisplayTag = record.displayTag;
    DateTime? newStartTime = record.startTime;
    DateTime? newEndTime = record.endTime;
    DateTime newTime = record.time;
    String newContent = record.content;
    if (result.notes.isNotEmpty && record.photos.isNotEmpty) {
      final trimmedNotes = result.notes.trim();
      if (newContent.isEmpty) {
        newContent = trimmedNotes;
      } else if (!newContent.contains(trimmedNotes)) {
        newContent = '$newContent\n$trimmedNotes';
      }
    }
    Map<String, dynamic>? newBodyState = record.bodyState != null
        ? Map.from(record.bodyState!)
        : null; // ignore: prefer_final_locals
    final List<TagEntry> newTagEntries = result.tagEntries.isNotEmpty ? result.tagEntries : record.tagEntries;

    if (result.tagEntries.isNotEmpty) {
      newTags = result.tagEntries.map((e) => e.name).toList();
      newDisplayTag = result.tagEntries.first.name;
      newBodyState = Map<String, dynamic>.from(result.tagEntries.first.fields);
    } else if (foundShortcut != null) {
      if (!newTags.contains(foundShortcut.name)) {
        newTags = [foundShortcut.name, ...newTags.where((t) => t != newDisplayTag)];
      }
      newDisplayTag = foundShortcut.name;
    }

    if (result.time.isNotEmpty) {
      final baseDate = DateTime(record.time.year, record.time.month, record.time.day);
      if (result.time['start'] != null) {
        final parts = (result.time['start'] as String).split(':');
        if (parts.length >= 2) {
          final hour = int.tryParse(parts[0]) ?? record.time.hour;
          final minute = int.tryParse(parts[1]) ?? record.time.minute;
          final startOffset = result.time['startOffset'] as int? ?? 0;
          final dt = baseDate.add(Duration(days: startOffset, hours: hour, minutes: minute));
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
          newEndTime = baseDate.add(Duration(days: endOffset, hours: hour, minutes: minute));
        }
      } else {
        newEndTime = null;
      }
    }

    return record.copyWith(
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
    // 箭头下标按「时间线顺序」计，删除前先取同一顺序下的位置
    final removedIndex = _batchReviewOrderedIds.indexOf(recordId);
    final controller = _undoControllers.remove(recordId);
    controller?.stop();
    controller?.dispose();
    _undoRecords.remove(recordId);
    _bumpUndoRecordsVersion();
    _batchExtractedRecordIds.remove(recordId);
    _batchExtractOrder.remove(recordId);
    _invalidateBatchReviewOrder();
    if (removedIndex >= 0) {
      _batchReviewIndex = resolveBatchReviewIndexAfterRemoval(
        currentIndex: _batchReviewIndex,
        removedIndex: removedIndex,
        remainingCount: _batchExtractedRecordIds.length,
      );
    }
    if (_batchReviewHighlightId == recordId) {
      _batchReviewHighlightTimer?.cancel();
      _batchReviewHighlightId = null;
    }
    if (_batchExtractedRecordIds.isEmpty && !_isBatchExtracting) {
      _showBatchConfirmButton = false;
      _batchReviewIndex = -1;
    }
    if (mounted) setState(() {});
  }

  /// Create an undo countdown controller for a record
  void _createUndoController(String recordId) {
    // Dispose existing if any
    _undoControllers[recordId]?.dispose();

    final controller = AnimationController(vsync: this, duration: _undoWindow);
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
          if (preRecord != null && currentRecord != null && currentRecord.time != preRecord.time) {
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
      // 停止：先置取消标记（worker 不再领新任务），再把在途请求逐条取消。
      // 并发下最多有 3 条请求同时在飞，只取消一个 token 会让另外两条继续跑完。
      setState(() {
        _batchExtractCancelled = true;
      });
      for (final token in _cancelTokens.values) {
        token.cancel();
      }
      _cancelTokens.clear();
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
      Toast.info(context, '没有可优化的记录');
      return;
    }

    final items = <ActionMenuItem>[];

    if (untaggedToday > 0) {
      items.add(
        ActionMenuItem(
          icon: Icons.today,
          label: '提取今日（$untaggedToday 条）',
          onTap: () => _startBatchExtract(allDates: false),
        ),
      );
    }

    if (untaggedAll > untaggedToday) {
      items.add(
        ActionMenuItem(
          icon: Icons.date_range,
          label: '提取全部（$untaggedAll 条）',
          onTap: () => _startBatchExtract(allDates: true),
        ),
      );
    }

    if (items.length == 1) {
      // If only one option, just execute it directly
      items.first.onTap();
    } else {
      ActionMenu.show(context: context, key: _smartExtractFabKey, items: items);
    }
  }

  /// Start batch extraction of untagged records
  Future<void> _startBatchExtract({required bool allDates}) async {
    final allRecords = ref.read(diaryListProvider).valueOrNull;
    if (allRecords == null) return;

    if (!await AiRoleService.instance.hasUsableConfigForRole('timelineOptimization')) {
      if (mounted) {
        await showNoModelConfiguredDialog(context, scene: 'AI 批量提取');
      }
      return;
    }

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
        Toast.info(context, allDates ? '没有可提取的记录' : '当天没有可提取的记录');
      }
      return;
    }

    // 按时间线实际展示顺序排序（跨天记录以归属日期 + 展示时间为准）
    untaggedRecords.sort((a, b) {
      final dateCompare = a.getEffectiveDate().compareTo(b.getEffectiveDate());
      if (dateCompare != 0) return dateCompare;
      return a.getDisplayTime().compareTo(b.getDisplayTime());
    });

    // 箭头导航要按时间线顺序走（用户在列表里看到的上下关系），
    // 与「先跑哪条」无关，所以在重排领取顺序之前先记下这份序号
    final timelineOrder = <String, int>{for (var i = 0; i < untaggedRecords.length; i++) untaggedRecords[i].id: i};

    // 视口内的记录提到最前：并发按序领取任务，先跑的 3 条就是用户眼前这几条，
    // 点完立刻能看到身边卡片依次亮起，而不是屏幕外的记录先跑完、原地半天没反应。
    // 稳定遍历保留组内的时间线顺序。
    final inViewport = <DiaryRecord>[];
    final offscreen = <DiaryRecord>[];
    for (final r in untaggedRecords) {
      (_isRecordInViewport(r) ? inViewport : offscreen).add(r);
    }
    untaggedRecords
      ..clear()
      ..addAll(inViewport)
      ..addAll(offscreen);

    setState(() {
      _isBatchExtracting = true;
      _batchExtractTotal = untaggedRecords.length;
      _batchExtractCompleted = 0;
      _batchExtractSucceeded = 0;
      _batchExtractFailed = 0;
      _batchExtractCancelled = false;
      _showBatchConfirmButton = false;
      _batchExtractedRecordIds.clear();
      _batchExtractOrder.clear();
      _invalidateBatchReviewOrder();
      _batchReviewIndex = -1;
      _batchReviewHighlightId = null;
    });
    _batchReviewHighlightTimer?.cancel();

    if (mounted) {
      Toast.info(context, '开始提取 ${untaggedRecords.length} 条${allDates ? '（全部日期）' : ''}');
    }

    // 并发后不再逐条滚动定位：3 个 worker 各自滚动会互相打断，而且「提取全部」
    // 时把用户拽到最老的一条也很突兀。进度统一交给 FAB 的进度环汇报，
    // 用户留在原地就能看到身边卡片依次亮起。
    // 每个并发槽一个独立 AiService 实例：AiService 的 config / baseUrl / 全局
    // header 都是实例字段，共用单例会让并发请求互相覆写（endpoint 与凭证串台）。
    // 密钥池 ApiKeyPool 仍是进程级单例，逐请求 round-robin 取 Key 的语义不变。
    final services = List<AiService>.generate(kBatchExtractConcurrency, (_) => AiService());

    await runWithConcurrency<DiaryRecord>(
      items: untaggedRecords,
      concurrency: kBatchExtractConcurrency,
      shouldStop: () => _batchExtractCancelled || !mounted,
      onError: (error, stackTrace, index) {
        LoggerService.instance.logAI(
          '批量提取任务异常（第 ${index + 1} 条）: $error',
          level: LogLevel.error,
          details: stackTrace.toString(),
        );
        // 异常路径也要推进进度环，否则它会永远差这一条停在那里
        if (mounted) {
          setState(() {
            _batchExtractFailed++;
            _batchExtractCompleted++;
          });
        }
      },
      task: (record, index, worker) async {
        // 错开各槽的首发时刻：3 条请求同毫秒打出去，单 Key 厂商容易撞并发限流
        if (index < kBatchExtractConcurrency && worker > 0) {
          await Future.delayed(Duration(milliseconds: 150 * worker));
          if (_batchExtractCancelled || !mounted) return;
        }

        // 记录可能在排队期间被用户手动打标/删除，取最新快照再判断
        final allRecords = ref.read(diaryListProvider).valueOrNull;
        DiaryRecord? latest;
        if (allRecords != null) {
          for (final r in allRecords) {
            if (r.id == record.id) {
              latest = r;
              break;
            }
          }
          // 列表可读但找不到这条 = 批量期间已被删除：必须跳过。
          // 若回退成旧快照继续提取，最后的 repo.update 会把已软删的行写活。
          if (latest == null) {
            if (mounted) setState(() => _batchExtractCompleted++);
            return;
          }
        }
        final currentRecord = latest ?? record;
        if (currentRecord.displayTag.isNotEmpty && currentRecord.displayTag != '记录') {
          // 跳过也要推进进度环，否则「已处理条数」会永远差这一条
          if (mounted) setState(() => _batchExtractCompleted++);
          return;
        }

        _batchExtractOrder[record.id] = timelineOrder[record.id] ?? index;
        _invalidateBatchReviewOrder();
        if (mounted) {
          setState(() => _extractingRecordIds.add(record.id));
        }

        final token = CancelToken();
        _cancelTokens[record.id] = token;

        AiExtractResult? result;
        try {
          result = await extractExistingRecord(
            ref: ref,
            context: context,
            content: currentRecord.content.trim(),
            photos: currentRecord.photos,
            recordTime: currentRecord.time,
            startTime: currentRecord.startTime,
            endTime: currentRecord.endTime,
            cancelToken: token,
            service: services[worker],
            // 并发下逐条弹 Toast 会互相覆盖，失败统一在收尾汇总
            silent: true,
          );
        } on VisionUnsupportedException catch (e) {
          LoggerService.instance.logAI('批量提取跳过：模型「${e.modelName}」不支持图片输入', level: LogLevel.warning);
          result = null;
        } finally {
          _cancelTokens.remove(record.id);
          if (mounted) {
            setState(() => _extractingRecordIds.remove(record.id));
          }
        }

        if (!mounted) return;
        if (result == null) {
          setState(() {
            // 用户主动停止导致的取消不算失败，不污染收尾提示
            if (!_batchExtractCancelled) _batchExtractFailed++;
            _batchExtractCompleted++;
          });
          return;
        }

        final updated = _buildExtractedRecord(currentRecord, result);

        // 写库串行化：SQLite 并发写会撞 database is locked，且列表状态是
        // 「读全表 → 替换一项 → 写回」，并发提交会互相覆盖丢更新
        try {
          await _diaryWriteLock.run(
            () => ref.read(diaryListProvider.notifier).updateDiary(updated, updateWidgets: false),
          );
        } catch (e, stackTrace) {
          // 写库失败：undo 快照与「已优化」标记都还没写，界面不会谎报成功
          LoggerService.instance.logAI('批量提取结果落库失败: $e', level: LogLevel.error, details: stackTrace.toString());
          if (mounted) {
            setState(() {
              _batchExtractFailed++;
              _batchExtractCompleted++;
            });
          }
          return;
        }
        if (!mounted) return;

        _undoRecords[record.id] = currentRecord;
        _bumpUndoRecordsVersion();
        _batchExtractedRecordIds.add(record.id);
        _invalidateBatchReviewOrder();

        setState(() {
          _batchExtractCompleted++;
          _batchExtractSucceeded++;
          // 每提取完一条就让底部栏先浮出来：用户能立刻用箭头回看已优化的记录，
          // 不必等整批跑完。锚点保持 -1（按时间线末尾解析），并发下完成顺序与
          // 时间线顺序无关，钉死某个下标会在后续记录插入时指向错位。
          if (_batchExtractedRecordIds.isNotEmpty) {
            _showBatchConfirmButton = true;
          }
        });
      },
    );

    if (mounted) {
      final cancelled = _batchExtractCancelled;
      final failed = _batchExtractFailed;
      final succeeded = _batchExtractSucceeded;
      final handled = _batchExtractCompleted;
      setState(() {
        _isBatchExtracting = false;
        _batchExtractCancelled = false;
        if (_batchExtractedRecordIds.isNotEmpty) {
          _showBatchConfirmButton = true;
          // 批量过程中若用户已用箭头手动定位过，收尾时不要把他拽回末尾
          if (_batchReviewIndex < 0) {
            _batchReviewIndex = _batchReviewOrderedIds.length - 1;
          }
        }
      });
      if (cancelled) {
        Toast.info(context, '已停止提取（$handled/$_batchExtractTotal）');
      } else if (failed > 0) {
        Toast.warning(context, '提取完成 $succeeded 条，$failed 条未成功');
      } else if (succeeded == 0) {
        // 全部是被手动打标后跳过的：说「提取完成 N 条」会让人以为白干一场
        Toast.info(context, '没有需要提取的记录');
      } else {
        Toast.success(context, '提取完成（$succeeded 条）');
      }
    }

    // 批量提取流程整体结束后，统一触发一次原生桌面小组件数据刷新
    WidgetUtils.updateHomeWidgets();
  }

  /// Long press on smart extract button to select model
  Future<void> _handleSmartExtractLongPress() async {
    if (_isBatchExtracting) return;
    final displayName = await showTimelineModelSelector(context, ref);
    if (displayName != null && mounted) {
      Toast.success(context, '已切换：$displayName', duration: const Duration(seconds: 1));
    }
  }

  /// 时间线"每日日记"悬浮按钮：位于智能提取按钮左侧。
  /// 当天已写日记时呈实心书本态，未写时呈描边记录态
  Widget _buildJournalFAB(ThemeData theme) {
    return Consumer(
      builder: (context, ref, _) {
        final selectedDate = ref.watch(selectedDateProvider);
        final note = ref.watch(journalByDateProvider(selectedDate)).valueOrNull;
        final hasJournal = note != null && note.content.trim().isNotEmpty;

        return PressableScale(
          onTap: _handleJournalTap,
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppDurations.medium),
            curve: AppCurves.emphasized,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: hasJournal ? theme.colorScheme.tertiary : theme.colorScheme.surface,
              shape: BoxShape.circle,
              border: hasJournal ? null : Border.all(color: theme.colorScheme.outlineVariant, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(
              hasJournal ? Icons.menu_book : Icons.edit_note,
              size: 20,
              color: hasJournal ? theme.colorScheme.onTertiary : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }

  /// 升起「记录事件」面板。
  ///
  /// 草稿活在 `diaryComposeDraftProvider` 里而不是面板 State 里，所以这里不需要
  /// 传递任何东西：时间线上选好的时间、上次没填完的内容，面板自己会读。
  ///
  /// 页面在台前时把记录按钮的 Rect 交给面板做容器变形起点；发送成功后还要
  /// 负责把时间线滚到新记录、量出卡片落点，让面板本身飞过去。
  Future<void> _openRecordSheet({
    WidgetAction? action,
    RecordFabAnchor? originAnchor,
    RecordFabAnchor? Function()? readAnchor,
  }) async {
    // 面板是模态路由，遮罩挡住了底下的按钮，正常点不到第二次；
    // 但快捷入口（悬浮球 / 小组件）是外部信号，可能连发两次。
    if (_recordSheetOpen) {
      return;
    }
    _recordSheetOpen = true;
    HapticFeedback.lightImpact();

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // IndexedStack 里其他 tab 的页面不可见，按钮位置没有意义，直接走整卡淡入。
    // 行内加号显式传入自己的锚点，走同一个变形入口。
    final anchor = originAnchor ?? (TickerMode.valuesOf(context).enabled ? _recordFabAnchor() : null);
    final useMorph = anchor != null && !reduceMotion;
    if (useMorph) {
      setState(() => _recordFabHidden = true);
    }

    try {
      await DiaryRecordSheet.show(
        context,
        action: action,
        originAnchor: useMorph ? anchor : null,
        // 从行内加号打开时，收尾目标可能随选择变化而不在原位，交给调用方决定。
        readAnchor: useMorph ? (readAnchor ?? _recordFabAnchor) : null,
        onSaved: useMorph ? _prepareRecordCardMorph : null,
      );
    } finally {
      _recordSheetOpen = false;
      if (mounted) {
        setState(() {
          _recordFabHidden = false;
          // 飞行被返回键/异常打断时，卡片不能永远藏着。
          _hiddenMorphRecordId = null;
        });
        _flushPendingCheer();
      }
    }
  }

  /// 点时间线行内的记录加号：以该按钮为起点升起记录面板。
  ///
  /// 面板读的是同一份 [diaryInputTimeProvider]，所以这里不需要再传时间；
  /// 只把按钮 Rect 交过去，让容器从线末端长出来。
  void _handleTimelineRecordTap(Rect? rect) {
    final selection = ref.read(diaryInputTimeProvider);
    if (selection == null) {
      return;
    }
    final anchorRect = rect;
    if (anchorRect == null) {
      _openRecordSheet();
      return;
    }
    _openRecordSheet(
      originAnchor: RecordFabAnchor(
        rect: anchorRect,
        selection: selection,
        hasDraft: !ref.read(diaryComposeDraftProvider).isEmpty,
        compact: true,
      ),
      readAnchor: () {
        final current = ref.read(diaryInputTimeProvider);
        // 保存成功后选择被清空、行内加号也随之消失；时间若被改到别处，
        // 原按钮也早已不在原位。两种情况都交回左下角常驻记录钮收尾，
        // 避免幽灵落在一个已经不存在的按钮上。
        if (current == null || !_isSameTimelineSelection(current, selection)) {
          return _recordFabAnchor();
        }
        return RecordFabAnchor(
          rect: anchorRect,
          selection: current,
          hasDraft: !ref.read(diaryComposeDraftProvider).isEmpty,
          compact: true,
        );
      },
    );
  }

  /// 两次时间选择是否完全一致（日期、起止时间都要相同）。
  bool _isSameTimelineSelection(TimelineTimeSelectEvent a, TimelineTimeSelectEvent b) {
    bool sameTime(TimeOfDay? x, TimeOfDay? y) {
      if (x == null || y == null) {
        return x == null && y == null;
      }
      return x.hour == y.hour && x.minute == y.minute;
    }

    bool sameDate(DateTime x, DateTime y) => x.year == y.year && x.month == y.month && x.day == y.day;

    return sameDate(a.date, b.date) &&
        sameTime(a.time, b.time) &&
        sameTime(a.endTime, b.endTime) &&
        (a.endTime == null || sameDate(a.endDate ?? a.date, b.endDate ?? b.date));
  }

  RecordFabAnchor? _recordFabAnchor() {
    final box = _recordFabKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) {
      return null;
    }
    return RecordFabAnchor(
      rect: box.localToGlobal(Offset.zero) & box.size,
      selection: ref.read(diaryInputTimeProvider),
      hasDraft: !ref.read(diaryComposeDraftProvider).isEmpty,
    );
  }

  /// 面板保存后：把时间线滚到新记录、量出卡片 Rect，作为「弹窗变卡片」的落点。
  ///
  /// 只对单条记录做（固定事件一次多条时落点不唯一）。量不到、卡片不在视口里
  /// 就返回 null，面板退回原来的插入动画。
  Future<RecordCardMorphTarget?> _prepareRecordCardMorph(List<String> recordIds) async {
    if (recordIds.length != 1 || !_recordSheetOpen) {
      return null;
    }
    final id = recordIds.first;
    // 等 provider 更新后的第一帧，确认新卡片已经进了 ListView 的构建范围。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_recordSheetOpen) {
      return null;
    }

    final allRecords = ref.read(diaryListProvider).valueOrNull ?? const <DiaryRecord>[];
    final record = allRecords.where((r) => r.id == id).firstOrNull;
    if (record == null) {
      return null;
    }

    // 只跳不飘：面板还压在上面，不要让目标卡片在飞行途中继续移动。
    _scrollToTime(record.getDisplayTime(), smooth: false, recordsByDate: _buildRecordsByDate(allRecords));

    Rect? rect;
    for (var attempt = 0; attempt < 4 && rect == null; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      rect = _recordCardRect(id);
      if (rect == null) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    if (rect == null || !mounted || !_recordSheetOpen) {
      return null;
    }

    // 目标必须在时间线视口里，否则盖板会飞到屏幕外（被列表裁掉的卡片）。
    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox != null && viewportBox.attached && viewportBox.hasSize) {
      final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
      if (!viewportRect.overlaps(rect)) {
        return null;
      }
    }

    setState(() => _hiddenMorphRecordId = id);
    // 隐藏只改透明度、不改布局；等这一帧落定再开始飞。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_recordSheetOpen) {
      if (mounted) {
        setState(() => _hiddenMorphRecordId = null);
      }
      return null;
    }

    return RecordCardMorphTarget(
      initialRect: rect,
      readRect: () => _recordCardRect(id),
      onLanded: () => _handleMorphLanded(id),
    );
  }

  /// 盖板落到新卡片上：揭开真实卡片，并给一圈很淡的主色柔光。
  void _handleMorphLanded(String recordId) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (_hiddenMorphRecordId == recordId) {
        _hiddenMorphRecordId = null;
      }
      _glowOnlyRecordId = recordId;
      _insertingRecordIds.add(recordId);
    });
    _glowClearTimer?.cancel();
    _glowClearTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _insertingRecordIds.remove(recordId);
        if (_glowOnlyRecordId == recordId) {
          _glowOnlyRecordId = null;
        }
      });
    });
  }

  Future<void> _handleJournalTap() async {
    final selectedDate = ref.read(selectedDateProvider);
    await Navigator.of(context).push(AppMotion.fadeRoute(JournalEditorView(date: selectedDate)));
    // 编辑器内部保存时会失效缓存，这里兜底返回后刷新按钮状态
    ref.invalidate(journalByDateProvider(selectedDate));
  }

  /// Build the smart extract floating action button
  ///
  /// 工作中态与小Q发送按钮保持一致：极淡描边底 + 细圆环 + 圆心停止方块，
  /// 尺寸固定 44，点击即中止当前批量提取。
  ///
  /// 并发提取后圆环改为**确定进度**：串行时代每提一条都会滚动一次，用户能从
  /// 列表位移感知进度；并发后不再滚动，进度只能靠这里汇报，否则点击「全部提取」
  /// 后界面几乎静止，看起来像没反应。
  Widget _buildSmartExtractFAB(ThemeData theme) {
    // 提取中保留停止按钮：底部栏首条优化后就会浮出，但此时整批仍在跑，
    // 用户需要这个按钮能随时中止。
    if (_showBatchConfirmButton && !_isBatchExtracting) return const SizedBox.shrink();

    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    // 主题色与画布过近时，实心钮补一圈细描边立住边界；工作态的环与停止块同步切到高对比同色系前景色
    // 工作态的环/停止块画在极淡的强调色底上，同色系背景里 primary 会糊掉，统一走可读强调色
    final workingAccent = theme.accentInk;
    final progress = _batchExtractTotal > 0 ? (_batchExtractCompleted / _batchExtractTotal).clamp(0.0, 1.0) : 0.0;

    return PressableScale(
      key: _smartExtractFabKey,
      onTap: _handleSmartExtractTap,
      onLongPress: _handleSmartExtractLongPress,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppDurations.medium),
        curve: AppCurves.emphasized,
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _isBatchExtracting ? workingAccent.withValues(alpha: isDark ? 0.14 : 0.10) : primary,
          shape: BoxShape.circle,
          border: _isBatchExtracting
              ? Border.all(color: workingAccent.withValues(alpha: isDark ? 0.28 : 0.22), width: 0.9)
              : (theme.accentNeedsOutline ? Border.all(color: theme.colorScheme.outlineVariant, width: 1.2) : null),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: AppMotion.duration(context, AppDurations.fast),
          switchInCurve: AppCurves.emphasized,
          switchOutCurve: AppCurves.exit,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: Tween<double>(begin: 0.86, end: 1).animate(animation), child: child),
          ),
          child: _isBatchExtracting
              ? Stack(
                  key: const ValueKey('batch_progress'),
                  alignment: Alignment.center,
                  children: [
                    // 进度弧用 TweenAnimationBuilder 平滑推进：并发下多条几乎同时
                    // 完成，直接跳值会让弧线一顿一顿地蹦
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: progress),
                      duration: AppMotion.duration(context, AppDurations.fast),
                      curve: AppCurves.emphasized,
                      builder: (context, value, _) =>
                          LoadingRing(size: 32, strokeWidth: 1.3, color: theme.accentInk, progress: value),
                    ),
                    Container(
                      width: 9.5,
                      height: 9.5,
                      decoration: BoxDecoration(color: workingAccent, borderRadius: BorderRadius.circular(2.0)),
                    ),
                  ],
                )
              : Icon(
                  Icons.auto_fix_high,
                  key: const ValueKey('batch_idle'),
                  size: 20,
                  color: theme.colorScheme.onPrimary,
                ),
        ),
      ),
    );
  }

  Future<void> _handleAiExtractModelSelect(DiaryRecord record) async {
    final displayName = await showTimelineModelSelector(context, ref);
    if (displayName != null && mounted) {
      Toast.success(context, '已切换：$displayName', duration: const Duration(seconds: 1));
    }
  }

  void _confirmBatchExtract() {
    _batchReviewHighlightTimer?.cancel();
    setState(() {
      for (final id in _batchExtractedRecordIds) {
        _undoRecords.remove(id);
        final controller = _undoControllers.remove(id);
        controller?.stop();
        controller?.dispose();
      }
      _bumpUndoRecordsVersion();
      _batchExtractedRecordIds.clear();
      _batchExtractOrder.clear();
      _invalidateBatchReviewOrder();
      _showBatchConfirmButton = false;
      _batchReviewIndex = -1;
      _batchReviewHighlightId = null;
    });
    Toast.success(context, '已保存');
  }

  /// 跳到上一条 / 下一条已优化记录，并短暂高亮目标卡片。
  Future<void> _jumpToBatchReview(int targetIndex) async {
    // 并发提取的完成顺序与时间线顺序不一致，跳转必须按时间线顺序
    final ids = _batchReviewOrderedIds;
    if (targetIndex < 0 || targetIndex >= ids.length) return;

    final recordId = ids[targetIndex];
    final allRecords = ref.read(diaryListProvider).valueOrNull ?? const <DiaryRecord>[];
    DiaryRecord? record;
    for (final r in allRecords) {
      if (r.id == recordId) {
        record = r;
        break;
      }
    }
    // 记录可能刚被撤回/删除，等下一次重建时箭头状态会自然收紧
    if (record == null) return;

    HapticFeedback.selectionClick();
    setState(() => _batchReviewIndex = targetIndex);

    // 批量提取期间列表仍按提取前的时间分组，用 undo 快照才能定位到卡片真实位置
    final displayRecord = _undoRecords[recordId] ?? record;
    await _scrollToRecordCard(displayRecord);
    // 连点上/下时只让最后一次跳转高亮，避免旧滚动结束后闪到别的卡片
    if (!mounted || !_showBatchConfirmButton || _batchReviewIndex != targetIndex) return;
    if (_recordCardKeys[recordId]?.currentContext == null) {
      // 超出时间线可回溯窗口的记录不会渲染，提示后仍可用箭头继续查看其余记录
      Toast.info(context, '该记录早于时间线可查看范围，已跳过定位');
      return;
    }
    _highlightBatchReviewRecord(recordId);
  }

  void _highlightBatchReviewRecord(String recordId) {
    _batchReviewHighlightTimer?.cancel();
    setState(() => _batchReviewHighlightId = recordId);
    _batchReviewHighlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() {
        if (_batchReviewHighlightId == recordId) {
          _batchReviewHighlightId = null;
        }
      });
    });
  }

  /// 单枚圆形箭头按钮。
  ///
  /// 上/下箭头从原来的连体胶囊拆成两个独立圆钮：各自带浮起的圆形底与细描边，
  /// 中间留出间距，既避免误触相邻箭头，也把可点区域放大到易按的尺寸。
  Widget _buildBatchReviewArrow({
    required ThemeData theme,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return IconButton(
      onPressed: enabled ? onTap : null,
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.6 : 0.85),
        foregroundColor: scheme.onSurfaceVariant,
        disabledBackgroundColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.28 : 0.38),
        disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.5), width: 1),
        shape: const CircleBorder(),
      ),
    );
  }

  Widget _buildBatchConfirmPanel(ThemeData theme) {
    final total = _batchExtractedRecordIds.length;
    final position = resolveBatchReviewPosition(count: total, currentIndex: _batchReviewIndex);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3), width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, color: theme.colorScheme.onSurfaceVariant, size: 18),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      '已优化 $total 条',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                    ),
                  ),
                  // 只有一条时无处可跳，直接收起箭头组，避免两个禁用按钮占位
                  if (total > 1) ...[
                    const SizedBox(width: 10),
                    _buildBatchReviewArrow(
                      theme: theme,
                      icon: Icons.keyboard_arrow_up_rounded,
                      tooltip: '上一条已优化记录',
                      enabled: position.canGoPrevious,
                      onTap: () => _jumpToBatchReview(position.index - 1),
                    ),
                    const SizedBox(width: 10),
                    _buildBatchReviewArrow(
                      theme: theme,
                      icon: Icons.keyboard_arrow_down_rounded,
                      tooltip: '下一条已优化记录',
                      enabled: position.canGoNext,
                      onTap: () => _jumpToBatchReview(position.index + 1),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _confirmBatchExtract,
              style: FilledButton.styleFrom(
                elevation: 0,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 悬浮球 / 桌面小组件的快捷记录入口（/quick_record?action=…）。
    // 记录面板不再常驻，这个动作要由页面接住再带着它把面板升起来。
    ref.listen<WidgetAction?>(pendingWidgetActionProvider, (previous, next) {
      if (next == null) {
        return;
      }
      ref.read(pendingWidgetActionProvider.notifier).state = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openRecordSheet(action: next);
      });
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

    // 记录面板刚写下的记录：交给时间线播一次入场动画，然后立刻清空信号。
    ref.listen<List<String>>(diaryJustInsertedProvider, (previous, next) {
      if (next.isEmpty) {
        return;
      }
      ref.read(diaryJustInsertedProvider.notifier).state = const [];
      _handleJustInserted(next);
    });

    // 今日完整度庆祝：该不该弹、弹哪一档都收在 resolveCheerLevel 里，
    // 页面只管按档位取文案与强度 —— 冷启动误弹这类问题因此能在纯单测里锁住。
    ref.listen(diaryProgressProvider, (prev, next) {
      final level = resolveCheerLevel(prev, next);
      if (level == null || next == null) {
        return;
      }
      if (level.isCheer) {
        HapticFeedback.mediumImpact();
      }
      final title = switch (level) {
        CheerLevel.full => '今日完整！',
        CheerLevel.record => '新纪录！第${next.todayCount}条',
        CheerLevel.plain => '今日第${next.todayCount}条',
      };
      final sub = switch (level) {
        CheerLevel.full => '共${next.todayCount}条，太棒了',
        CheerLevel.record => null,
        CheerLevel.plain => '再记${next.remaining}条就完整了',
      };
      _showCheer(title: title, sub: sub, level: level);
    });

    final theme = Theme.of(context);
    final diaryListAsync = ref.watch(diaryListProvider);
    // 只有已绑定小米运动健康的用户才补日结空位卡，避免给不使用该功能的用户制造噪音
    final healthBound = ref.watch(healthBindingStatusProvider).valueOrNull ?? false;
    final selectEvent = ref.watch(diaryInputTimeProvider);
    final timelineRecordAnchor = _resolveTimelineRecordAnchor(selectEvent);

    if (diaryListAsync is AsyncData && !_hasPerformedInitialScroll) {
      _hasPerformedInitialScroll = true;
      final allRecords = diaryListAsync.value ?? const [];
      final recordsByDate = _buildRecordsByDate(allRecords);
      final media = MediaQuery.of(context);
      final viewportHeight = (media.size.height - media.padding.top - media.padding.bottom - _timelineChromeHeight)
          .clamp(1.0, double.infinity);
      _prepareInitialTimelineScroll(recordsByDate, viewportHeight);

      // 首帧先按估算位置布局，等 RenderBox 可用后再做一次像素级校准；
      // 校准完成前用加载态盖住时间线，用户第一眼看到的就是当前时刻。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToCurrentTime(
          smooth: false,
          recordsByDate: recordsByDate,
          onSettled: () {
            if (!mounted) return;
            setState(() => _initialTimelineSettled = true);
          },
        );
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
              final colorMarks = ref.watch(diaryColorMarkProvider).valueOrNull ?? [];
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
                          onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: GestureDetector(
                            onTap: _showDatePicker,
                            onLongPress: () => _showDateActionMenu(selectedDate, anchorKey: _topBarDateKey),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  FittedBox(
                                    key: _topBarDateKey,
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
                                  const SizedBox(height: 4),
                                  Container(
                                    width: 24,
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: currentColorMark != null
                                          ? _hexToColor(context, currentColorMark.color)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(1.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
                          child: Container(width: 2, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                        ),
                        GestureDetector(
                          key: _viewportKey,
                          onLongPressStart: _handleDragStart,
                          onLongPressMoveUpdate: _handleDragUpdate,
                          onLongPressEnd: _handleDragEnd,
                          onLongPressCancel: _handleDragCancel,
                          child: CustomScrollView(
                            scrollCacheExtent: const ScrollCacheExtent.pixels(600),
                            controller: _scrollController,
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  // 底部让开悬浮按钮：记录钮压在最上面一层，内容不能藏在它下面
                                  _fabBottom + 56,
                                ),
                                sliver: SliverMainAxisGroup(
                                  slivers: _buildTimelineSlivers(
                                    theme: theme,
                                    recordsByDate: recordsByDate,
                                    selectEvent: selectEvent,
                                    timelineRecordAnchor: timelineRecordAnchor,
                                    healthBound: healthBound,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                  // 数据库在 runApp 前就已打开，这里通常只经历一两帧。画加载圈会因弧线
                  // 还没展开而只露出一个「点」，看起来更像故障，首屏直接留空更干净。
                  loading: () => const SizedBox.shrink(),
                  error: (e, _) => AppErrorState(
                    error: e,
                    action: '加载记录失败',
                    // 时间线区域只是 Stack 的一层，悬浮钮仍在兄弟节点，用紧凑态避免整屏替换
                    compact: true,
                    onRetry: () => ref.invalidate(diaryListProvider),
                  ),
                ),
                // 首屏定位完成前，用画布色盖住时间线的预布局与校准，避免看到列表跳动。
                // 不放加载圈：校准只差一两帧，圈来不及展开只会露出一个点，反而像故障。
                // 放在 FAB 之前：只遮时间线，悬浮钮保持稳定，不会跟着闪一下。
                if (diaryListAsync is AsyncData && !_initialTimelineSettled)
                  Positioned.fill(child: ColoredBox(color: theme.scaffoldBackgroundColor)),
                // 每日日记 FAB（智能提取按钮左侧）
                Positioned(right: 72, bottom: _fabBottom, child: _buildJournalFAB(theme)),
                // Smart Extract FAB
                Positioned(right: 16, bottom: _fabBottom, child: _buildSmartExtractFAB(theme)),
                // 记录按钮：左下角，与右侧两钮同高对称。
                // 时间线上选中时间后它会横向展开成胶囊，把选中的时间段直接顶在按钮上。
                Positioned(
                  left: 16,
                  bottom: _fabBottom,
                  child: IgnorePointer(
                    ignoring: _recordFabHidden,
                    child: AnimatedOpacity(
                      // 面板打开期间按钮本身已经变成面板，先淡出；关闭退场结束
                      // 后再回来。
                      opacity: _recordFabHidden ? 0 : 1,
                      // 只有「打开」方向做 90ms 淡出：它的作用是把按钮让给变形容器，
                      // 慢一点也不露馅。关闭方向必须瞬时换回：
                      // 退场最后一帧的幽灵按钮和真实按钮像素完全一致（同一套配色、
                      // 圆角、排版，容器也正好落在按钮 Rect 上），同一帧直接换回来才
                      // 是无缝的；若在这里再让 1 从 0 爬到 1，幽灵先被路由一起撤掉，
                      // 就会空出一拍再亮起来 —— 圆形态下按钮本体和背景同色，看不出来，
                      // 胶囊态下时间文字是高对比的，就成了肉眼可见的「闪一下」。
                      duration: MediaQuery.disableAnimationsOf(context) || !_recordFabHidden
                          ? Duration.zero
                          : const Duration(milliseconds: 90),
                      curve: Curves.easeOutCubic,
                      child: DiaryRecordFab(key: _recordFabKey, onTap: _openRecordSheet),
                    ),
                  ),
                ),
                // 记完即时庆祝胶囊：按钮行上方居中浮现，不挡时间线主体。
                if (_cheerEvent != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: _fabBottom + 56,
                    child: Center(
                      child: RecordCheerToast(event: _cheerEvent!, leaving: _cheerLeaving, onDismissed: _dismissCheer),
                    ),
                  ),
              ],
            ),
          ),
          // 批量结果确认栏：用高度动画进出，避免抽完最后一条时视口突然缩一截
          AppCollapsible(
            expanded: _showBatchConfirmButton,
            rise: 0,
            child: _showBatchConfirmButton ? _buildBatchConfirmPanel(theme) : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// 底部两个圆钮的落点。
  ///
  /// 原来底部压着常驻输入栏，12 这个写死值够用；输入栏撤掉后按钮直接贴屏幕底，
  /// 必须让 home indicator 的安全区，否则在全面屏上会被系统手势条压住。
  double get _fabBottom => MediaQuery.paddingOf(context).bottom + 12;

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
    // 先判断是否按在记录卡片左侧的圆形节点把手上；命中则进入「拖动调时」，
    // 不启动时间轴区间选择。卡片本体的长按仍由 DiaryItem 内部手势弹出操作菜单。
    final dragRecord = _findRecordAtHandle(details.globalPosition);
    if (dragRecord != null) {
      _startRecordTimeDrag(dragRecord, details);
      return;
    }

    final index = _pointToItemIndex(details.globalPosition);
    if (index != -1 && index % _itemsPerDay != 0) {
      final dayOffset = index ~/ _itemsPerDay;
      final date = _indexToDate(dayOffset);
      if (!_isDateExpanded(date)) return;

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
    if (_cardDrag != null) {
      _updateRecordTimeDrag(details.globalPosition);
      return;
    }

    _lastDragPosition = details.globalPosition;
    final index = _pointToItemIndex(details.globalPosition);
    if (index != -1 && index % _itemsPerDay != 0) {
      final dayOffset = index ~/ _itemsPerDay;
      final date = _indexToDate(dayOffset);
      // 只有区间真的换了节点才重建：拖动期间手指每移动一像素都会回调，
      // 而同一个 30 分钟节点常常横跨几十次回调，无脑 setState 等于把整页
      // （含 5880 槽位的时间线）按手指采样率重建。
      if (_isDateExpanded(date) && index != _dragEndIndex) {
        setState(() {
          _dragEndIndex = index;
        });
      }
    }
  }

  void _handleDragEnd(LongPressEndDetails details) {
    if (_cardDrag != null) {
      _endRecordTimeDrag();
      return;
    }

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

  /// 手势被系统或其它识别器取消时的兜底清理。
  ///
  /// 长按识别器在被打断时不一定回调 onLongPressEnd；不清理会留下
  /// 跟随浮层和自动滚动定时器，页面看起来会「卡住」。
  /// 取消属于非正常松手，直接丢弃本次拖动，不落库。
  void _handleDragCancel() {
    _stopAutoScrollTimer();
    _lastDragPosition = null;
    if (_cardDrag != null) {
      _removeCardDragOverlay();
      _cardDrag = null;
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (_dragStartIndex != null || _dragEndIndex != null) {
      setState(() {
        _dragStartIndex = null;
        _dragEndIndex = null;
      });
    }
  }

  /// 为每条记录复用同一个把手 Key；记录被 ListView 回收后再次构建仍能命中。
  GlobalKey _handleKeyFor(String recordId) {
    return _recordHandleKeys.putIfAbsent(recordId, () => GlobalKey());
  }

  /// 将 120 天窗口按「正文是否挂载」切分为少量 Sliver 分段，并绑定展开/收起过渡动画。
  List<Widget> _buildTimelineSlivers({
    required ThemeData theme,
    required Map<String, List<DiaryRecord>> recordsByDate,
    required TimelineTimeSelectEvent? selectEvent,
    required DateTime? timelineRecordAnchor,
    required bool healthBound,
  }) {
    final nowDateTime = DateTime.now();
    final now = TimeOfDay(hour: nowDateTime.hour, minute: nowDateTime.minute);
    _currentMinute = now;
    final selectionStart = selectEvent != null
        ? DateTime(
            selectEvent.date.year,
            selectEvent.date.month,
            selectEvent.date.day,
            selectEvent.time.hour,
            selectEvent.time.minute,
          )
        : null;
    final selectionEnd = (selectEvent != null && selectEvent.endTime != null)
        ? DateTime(
            (selectEvent.endDate ?? selectEvent.date).year,
            (selectEvent.endDate ?? selectEvent.date).month,
            (selectEvent.endDate ?? selectEvent.date).day,
            selectEvent.endTime!.hour,
            selectEvent.endTime!.minute,
          )
        : null;

    final segments = buildDiaryTimelineSegments(
      windowStartDate: _windowStartDate,
      daysCount: _windowDays,
      hasBody: (date) => _isDateExpanded(date) || _dayAnimations.containsKey(_dateKey(date)),
    );

    final slivers = <Widget>[];
    for (final segment in segments) {
      final runStartDate = _indexToDate(segment.startDayOffset);
      final runKey = _dateKey(runStartDate);
      slivers.add(
        SliverFixedExtentList.builder(
          key: ValueKey('div_run_$runKey'),
          itemExtent: kDiaryTimelineDividerHeight,
          itemCount: segment.dividerCount,
          addAutomaticKeepAlives: false,
          itemBuilder: (context, indexInRun) {
            final dayOffset = segment.startDayOffset + indexInRun;
            final date = _indexToDate(dayOffset);
            final globalIndex = dayOffset * _itemsPerDay;
            return TimelineItemWrapper(
              index: globalIndex,
              onMount: (index, ctx) {
                _itemContexts[index] = ctx;
                _dividerContexts[index] = ctx;
              },
              onUnmount: (index, ctx) {
                if (identical(_itemContexts[index], ctx)) {
                  _itemContexts.remove(index);
                }
                if (identical(_dividerContexts[index], ctx)) {
                  _dividerContexts.remove(index);
                }
              },
              onHeightChange: (index, height) => _itemHeights[index] = height,
              child: _buildDateDivider(theme: theme, date: date, recordsByDate: recordsByDate),
            );
          },
        ),
      );

      if (segment.hasExpandedBody) {
        final bodyDayOffset = segment.endDayOffset;
        final bodyDate = _indexToDate(bodyDayOffset);
        final bodyDateKey = _dateKey(bodyDate);
        final anim = _dayAnimations[bodyDateKey];
        final dayNodes = _cachedDayNodesByDate[bodyDateKey] ?? const <int, List<DiaryRecord>>{};
        final hasDailyHealthSummary = _cachedDatesWithHealthSummary.contains(bodyDateKey);
        final isBodyExpanded = _isDateExpanded(bodyDate);

        slivers.add(
          SliverDayCollapsible(
            key: ValueKey('day_body_$bodyDateKey'),
            sizeAnimation: anim?.sizeAnimation,
            opacityAnimation: anim?.opacityAnimation,
            isExpanding: anim?.isExpanding ?? true,
            sliver: SliverList.builder(
              itemCount: _itemsPerDay - 1,
              addAutomaticKeepAlives: false,
              itemBuilder: (context, nodeIndex) {
                final globalIndex = bodyDayOffset * _itemsPerDay + 1 + nodeIndex;
                return TimelineItemWrapper(
                  index: globalIndex,
                  onMount: (index, ctx) => _itemContexts[index] = ctx,
                  onUnmount: (index, ctx) {
                    if (identical(_itemContexts[index], ctx)) {
                      _itemContexts.remove(index);
                    }
                  },
                  onHeightChange: (index, height) {
                    // 收起动画进行中节点已失活，避免把旧高度重新写入估算表
                    if (isBodyExpanded) {
                      _itemHeights[index] = height;
                    }
                  },
                  child: _buildTimelineNodeItem(
                    nodeIndex: nodeIndex,
                    globalIndex: globalIndex,
                    date: bodyDate,
                    dateKey: bodyDateKey,
                    now: now,
                    selectEvent: selectEvent,
                    selectionStart: selectionStart,
                    selectionEnd: selectionEnd,
                    timelineRecordAnchor: timelineRecordAnchor,
                    healthBound: healthBound,
                    dayNodes: dayNodes,
                    hasDailyHealthSummary: hasDailyHealthSummary,
                  ),
                );
              },
            ),
          ),
        );
      }
    }
    return slivers;
  }

  /// 构建单个日期分隔栏：稳态下用静态旋转图标，过渡期间与正文幕布共用同一动画控制器。
  Widget _buildDateDivider({
    required ThemeData theme,
    required DateTime date,
    required Map<String, List<DiaryRecord>> recordsByDate,
  }) {
    final isExpanded = _isDateExpanded(date);
    final dateKey = _dateKey(date);
    final anim = _dayAnimations[dateKey];
    final dayRecords = recordsByDate[dateKey] ?? const [];
    final isToday = _isToday(date);
    final arrowIcon = Icon(
      Icons.keyboard_arrow_down_rounded,
      size: 18,
      color: isToday ? theme.accentInk : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
    );

    return Container(
      key: ValueKey('div_$dateKey'),
      height: kDiaryTimelineDividerHeight,
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      child: Row(
        children: [
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
          Builder(
            builder: (anchorContext) {
              return InkWell(
                onTap: () => _toggleDateExpanded(date),
                onLongPress: () => _showDateActionMenu(date, anchorContext: anchorContext),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatDividerDate(date),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: isToday ? theme.accentInk : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      _DateColorDot(date: date),
                      if (!isExpanded && dayRecords.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: (isToday ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${dayRecords.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: isToday ? theme.accentInk : theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      if (anim != null)
                        RotationTransition(turns: anim.arrowTurns, child: arrowIcon)
                      else
                        Transform.rotate(angle: isExpanded ? 0.0 : -math.pi / 2, child: arrowIcon),
                    ],
                  ),
                ),
              );
            },
          ),
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
        ],
      ),
    );
  }

  /// 构建单个半小时时间槽及其名下的记录卡片。
  Widget _buildTimelineNodeItem({
    required int nodeIndex,
    required int globalIndex,
    required DateTime date,
    required String dateKey,
    required TimeOfDay now,
    required TimelineTimeSelectEvent? selectEvent,
    required DateTime? selectionStart,
    required DateTime? selectionEnd,
    required DateTime? timelineRecordAnchor,
    required bool healthBound,
    required Map<int, List<DiaryRecord>> dayNodes,
    required bool hasDailyHealthSummary,
  }) {
    final time = TimeOfDay(hour: nodeIndex ~/ 2, minute: (nodeIndex % 2) * 30);
    final nodeStartDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final recordsInInterval = dayNodes[nodeIndex] ?? const <DiaryRecord>[];
    final isToday = _isToday(date);

    final slot = resolveDiaryTimelineSlot(
      slotStart: nodeStartDateTime,
      nodeIndex: nodeIndex,
      now: DateTime(_today.year, _today.month, _today.day, now.hour, now.minute),
      isToday: isToday,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd,
    );

    bool isDraggedSelected = false;
    if (_dragStartIndex != null && _dragEndIndex != null) {
      final start = math.min(_dragStartIndex!, _dragEndIndex!);
      final end = math.max(_dragStartIndex!, _dragEndIndex!);
      isDraggedSelected = globalIndex >= start && globalIndex <= end;
    }

    final bool finalIsSelected = isDraggedSelected || slot.isStandardNodeSelected;
    final bool isMultiSelect = isDraggedSelected || (selectEvent != null && selectEvent.endTime != null);

    final dedicatedStart = slot.dedicatedSelectedStart;
    final dedicatedStartTime = dedicatedStart != null
        ? TimeOfDay(hour: dedicatedStart.hour, minute: dedicatedStart.minute)
        : null;
    final dedicatedSelectedNow = slot.dedicatedSelectedCurrentTime;
    final dedicatedSelectedNowTime = dedicatedSelectedNow != null
        ? TimeOfDay(hour: dedicatedSelectedNow.hour, minute: dedicatedSelectedNow.minute)
        : null;
    final dedicatedEnd = slot.dedicatedSelectedEnd;
    final dedicatedEndTime = dedicatedEnd != null
        ? TimeOfDay(hour: dedicatedEnd.hour, minute: dedicatedEnd.minute)
        : null;
    final dedicatedNow = slot.dedicatedCurrentTime;
    final dedicatedNowTime = dedicatedNow != null
        ? TimeOfDay(hour: dedicatedNow.hour, minute: dedicatedNow.minute)
        : null;

    final nowMinutes = now.hour * 60 + now.minute;
    final slotMinutes = nodeIndex * 30;
    final isNowInThisInterval = nodeIndex == 47
        ? nowMinutes >= slotMinutes
        : (nowMinutes >= slotMinutes && nowMinutes < slotMinutes + 30);

    // 23:00 是日结槽位：当天没有真实日结卡时补一张可同步的空位卡。
    // 只在这一行读取预计算标记，避免每个半小时节点重复扫全天记录。
    final showHealthPlaceholder =
        nodeIndex == 47 &&
        shouldShowHealthDailyPlaceholder(
          date: date,
          today: _today,
          healthBound: healthBound,
          hasDailySummary: hasDailyHealthSummary,
        );

    return Column(
      key: (isNowInThisInterval && isToday) ? _currentTimeNodeKey : null,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EmptyTimeNode(
          key: ValueKey('n_${dateKey}_$nodeIndex'),
          time: time,
          isSelected: finalIsSelected,
          isMultiSelect: isMultiSelect,
          isDraggedSelected: isDraggedSelected,
          isCurrentTime: slot.isStandardNodeCurrentTime,
          onTap: () => _handleNodeTap(date, time),
          onDoubleTap: () => _handleNodeDoubleTap(date, time),
          onRecordTap: timelineRecordAnchor == nodeStartDateTime ? _handleTimelineRecordTap : null,
        ),
        if (dedicatedStartTime != null)
          _SelectedTimeNode(
            time: dedicatedStartTime,
            isCurrentTime: isToday && now.hour == dedicatedStartTime.hour && now.minute == dedicatedStartTime.minute,
            onTap: () => _handleNodeTap(date, dedicatedStartTime),
            onDoubleTap: () => _handleNodeDoubleTap(date, dedicatedStartTime),
            onRecordTap: timelineRecordAnchor == dedicatedStart ? _handleTimelineRecordTap : null,
          ),
        if (dedicatedSelectedNowTime != null)
          _SelectedTimeNode(
            time: dedicatedSelectedNowTime,
            isCurrentTime: true,
            onTap: () => _handleNodeTap(date, dedicatedSelectedNowTime),
            onDoubleTap: () => _handleNodeDoubleTap(date, dedicatedSelectedNowTime),
            onRecordTap: timelineRecordAnchor == dedicatedSelectedNow ? _handleTimelineRecordTap : null,
          ),
        if (dedicatedEndTime != null)
          _SelectedTimeNode(
            time: dedicatedEndTime,
            isCurrentTime: isToday && now.hour == dedicatedEndTime.hour && now.minute == dedicatedEndTime.minute,
            onTap: () => _handleNodeTap(date, dedicatedEndTime),
            onDoubleTap: () => _handleNodeDoubleTap(date, dedicatedEndTime),
            onRecordTap: timelineRecordAnchor == dedicatedEnd ? _handleTimelineRecordTap : null,
          ),
        if (dedicatedNowTime != null)
          _CurrentTimeNode(
            time: dedicatedNowTime,
            onTap: () => _handleNodeTap(date, dedicatedNowTime),
            onDoubleTap: () => _handleNodeDoubleTap(date, dedicatedNowTime),
          ),
        if (showHealthPlaceholder) HealthDailyPlaceholderCard(date: date, isToday: isToday),
        ...recordsInInterval.map((record) {
          final healthDate = _healthSummaryDate(record);
          final canUpdateHealth = healthBound && healthDate != null && isSameCalendarDay(healthDate, _today);
          return RepaintBoundary(
            child: Opacity(
              // 发送后飞行期间先藏起来，等盖板落位再揭开；
              // 只改透明度，卡片仍占位，目标 Rect 可以照量。
              opacity: _hiddenMorphRecordId == record.id ? 0 : 1,
              child: _InsertingItemWrapper(
                isInserting: _insertingRecordIds.contains(record.id),
                // 飞行落位只补一圈辉光，不再从 0 长高。
                animateSize: _glowOnlyRecordId != record.id,
                child: _CollapsingItemWrapper(
                  isCollapsing: _deletingRecordIds.contains(record.id),
                  // 提取完成后标签/字段变多时，卡片高度平滑过渡，
                  // 避免下方列表内容瞬间跳位；裁切只作用于动画期间的新内容，
                  // 右侧提取钮的圆形实际落在卡片内边距内，不受影响。
                  child: AnimatedSize(
                    key: ValueKey('card_size_${record.id}'),
                    duration: AppMotion.duration(context, AppDurations.normal),
                    curve: AppCurves.standard,
                    alignment: Alignment.topCenter,
                    child: DiaryItem(
                      record: record,
                      cardKey: _recordCardKeyFor(record.id),
                      timeDragHandleKey: _handleKeyFor(record.id),
                      isTimeDragging: _cardDrag?.record.id == record.id,
                      onTap: () => _handleEdit(record),
                      onEdit: _handleEdit,
                      onDelete: _handleDelete,
                      onQuoteToQ: _quoteRecordToQ,
                      onBatchManage: _navigateToBatchManage,
                      onAiExtract: () => _handleAiExtract(record),
                      onAiExtractLongPress: () => _handleAiExtractModelSelect(record),
                      isExtracting: _extractingRecordIds.contains(record.id),
                      onUndo: () => _undoExtract(record),
                      isUndoable: _undoRecords.containsKey(record.id),
                      undoAnimation: _undoControllers[record.id],
                      isReviewHighlighted: _batchReviewHighlightId == record.id,
                      onHealthSync: canUpdateHealth ? () => _handleUpdateHealthSummary(record.id, healthDate) : null,
                      isHealthSyncing: _updatingHealthSummaryId == record.id,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  /// 卡片本体的 Key；同一条记录跨 ListView 回收/重建仍是同一个。
  GlobalKey _recordCardKeyFor(String recordId) {
    return _recordCardKeys.putIfAbsent(recordId, () => GlobalKey());
  }

  /// 卡片当前的全局 Rect（发送后飞行落点用）。
  Rect? _recordCardRect(String recordId) {
    final box = _recordCardKeys[recordId]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 判断长按位置是否落在某条记录的左侧节点把手上。
  ///
  /// 只遍历已构建（含缓存区）的把手，列表很长时也不会全表扫描；
  /// 顺带清掉已卸载记录的 Key，避免长时间使用后缓存随历史记录无限增长。
  DiaryRecord? _findRecordAtHandle(Offset globalPosition) {
    String? hitId;
    final staleIds = <String>[];
    for (final entry in _recordHandleKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null || !ctx.mounted) {
        staleIds.add(entry.key);
        continue;
      }
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        continue;
      }
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(globalPosition)) {
        hitId = entry.key;
        break;
      }
    }
    for (final id in staleIds) {
      _recordHandleKeys.remove(id);
    }
    if (hitId == null) {
      return null;
    }

    final records = ref.read(diaryListProvider).valueOrNull ?? const [];
    for (final record in records) {
      if (record.id == hitId) {
        // 系统同步的健康记录会在下次同步时被覆盖，不提供手动拖拽调时。
        return isSystemSyncedHealthRecord(record) ? null : record;
      }
    }
    return null;
  }

  void _startRecordTimeDrag(DiaryRecord record, LongPressStartDetails details) {
    if (_cardDrag != null || _deletingRecordIds.contains(record.id)) {
      return;
    }

    final handleBox = _recordHandleKeys[record.id]?.currentContext?.findRenderObject() as RenderBox?;
    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (handleBox == null || !handleBox.hasSize || viewportBox == null || !viewportBox.hasSize) {
      return;
    }

    final handleRect = handleBox.localToGlobal(Offset.zero) & handleBox.size;
    final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    // 卡片左边界正好接在 48px 宽的节点栏右侧；右侧留白 = 列表 16 + 卡片 12。
    final cardLeft = handleRect.right;
    final cardWidth = viewportRect.right - 28 - cardLeft;
    if (cardWidth < 160) {
      return;
    }

    _lastDragPosition = details.globalPosition;
    _cardDrag = _RecordTimeDragState(
      record: record,
      startGlobalY: details.globalPosition.dy,
      startScrollOffset: _scrollController.hasClients ? _scrollController.offset : 0,
      grabOffsetY: (details.globalPosition.dy - handleRect.top).clamp(0.0, handleRect.height),
      cardLeft: cardLeft,
      cardWidth: cardWidth,
      // 时间轴竖线位于列表内容 left + 39，宽 2px，中心取 +40。
      axisX: viewportRect.left + 40,
      proxyTop: handleRect.top,
      topLimit: viewportRect.top + 8,
      bottomLimit: viewportRect.bottom - 132,
      shift: resolveTimelineTimeShift(record: record, contentDeltaPx: 0, pixelsPerMinute: _dragPixelsPerMinute),
    );
    HapticFeedback.mediumImpact();
    setState(() {});
    _showCardDragOverlay();
    _startAutoScrollTimer();
  }

  void _updateRecordTimeDrag(Offset globalPosition) {
    _applyRecordDragAt(globalPosition);
  }

  /// 按当前手指位置重算目标时间并刷新浮层；自动滚动时也会走到这里。
  void _applyRecordDragAt(Offset globalPosition) {
    final drag = _cardDrag;
    if (drag == null) {
      return;
    }
    _lastDragPosition = globalPosition;
    final scrollOffset = _scrollController.hasClients ? _scrollController.offset : drag.startScrollOffset;
    // 内容坐标系位移 = 手指位移 + 列表滚动量：手指不动、列表滚动时时间也应继续变化。
    final contentDelta = (globalPosition.dy - drag.startGlobalY) + (scrollOffset - drag.startScrollOffset);
    final shift = resolveTimelineTimeShift(
      record: drag.record,
      contentDeltaPx: contentDelta,
      pixelsPerMinute: _dragPixelsPerMinute,
    );
    final changed = shift.deltaMinutes != drag.shift.deltaMinutes;
    drag
      ..proxyTop = globalPosition.dy - drag.grabOffsetY
      ..shift = shift;
    if (changed) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastDragHapticMs >= 50) {
        _lastDragHapticMs = nowMs;
        HapticFeedback.selectionClick();
      }
    }
    _cardDragOverlay?.markNeedsBuild();
  }

  void _endRecordTimeDrag() {
    _stopAutoScrollTimer();
    _lastDragPosition = null;

    final drag = _cardDrag;
    _removeCardDragOverlay();
    _cardDrag = null;
    if (drag == null) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    if (!drag.shift.isChanged) {
      return;
    }

    HapticFeedback.mediumImpact();
    final before = drag.record;
    final after = before.copyWith(
      time: drag.shift.time,
      startTime: drag.shift.startTime,
      endTime: drag.shift.endTime,
      updatedAt: DateTime.now(),
    );
    _saveDraggedRecordTime(before, after);
  }

  Future<void> _saveDraggedRecordTime(DiaryRecord before, DiaryRecord after) async {
    try {
      await ref.read(diaryListProvider.notifier).updateDiary(after);
      if (!mounted) {
        return;
      }
      final label = formatTimelineDragTimeLabel(after.startTime ?? after.time, end: after.endTime);
      Toast.show(
        context,
        '已调整到 $label',
        type: ToastType.success,
        duration: const Duration(seconds: 4),
        actionLabel: '撤销',
        onAction: () {
          ref.read(diaryListProvider.notifier).updateDiary(before);
        },
      );
    } catch (e, stackTrace) {
      LoggerService.instance.error('拖动调整记录时间失败: $e', category: LogCategory.database, stackTrace: stackTrace);
      if (mounted) {
        Toast.error(context, '调整时间失败');
      }
    }
  }

  void _showCardDragOverlay() {
    _removeCardDragOverlay();
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(builder: (overlayContext) => _buildCardDragOverlay(Theme.of(overlayContext)));
    overlay.insert(entry);
    _cardDragOverlay = entry;
  }

  void _removeCardDragOverlay() {
    final entry = _cardDragOverlay;
    if (entry == null) {
      return;
    }
    _cardDragOverlay = null;
    try {
      entry.remove();
    } catch (_) {
      // 页面销毁时宿主 Overlay 可能已不可用，与彩带层的处理方式一致。
    }
  }

  /// 拖动浮层：跟手卡片 + 时间轴落点提示。
  Widget _buildCardDragOverlay(ThemeData theme) {
    final drag = _cardDrag;
    if (drag == null) {
      return const SizedBox.shrink();
    }

    final shift = drag.shift;
    final tagColor = TagColors.of(drag.record.displayTag);
    final maxTop = math.max(drag.topLimit, drag.bottomLimit);
    final top = math.min(math.max(drag.proxyTop, drag.topLimit), maxTop);
    final indicatorY = top + 23;
    final targetLabel = formatTimelineDragTimeLabel(shift.startTime ?? shift.time, end: shift.endTime);
    final originalLabel = formatTimelineDragTimeLabel(
      drag.record.startTime ?? drag.record.time,
      end: drag.record.endTime,
    );
    final delta = shift.deltaMinutes;
    final deltaLabel = delta == 0 ? null : (delta > 0 ? '+$delta 分钟' : '$delta 分钟');

    return IgnorePointer(
      child: Stack(
        children: [
          // 落点提示：轴线圆点 + 连到卡片的细线，让浮层和当前时间轴锚在一起。
          Positioned(
            left: drag.axisX - 1,
            top: indicatorY - 1,
            width: math.max(0.0, drag.cardLeft - drag.axisX + 1),
            child: Container(height: 2, color: theme.accentInk.withValues(alpha: 0.35)),
          ),
          Positioned(
            left: drag.axisX - 4,
            top: indicatorY - 4,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: theme.accentInk,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: theme.accentInk.withValues(alpha: 0.35), blurRadius: 6)],
              ),
            ),
          ),
          Positioned(
            left: drag.cardLeft,
            top: top,
            width: drag.cardWidth,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tagColor.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 24, offset: const Offset(0, 10)),
                  BoxShadow(color: tagColor.withValues(alpha: 0.14), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Builder(
                        builder: (context) {
                          // 标签色淡底小圆：前景压深到可读，保留标签色相
                          final ink = AppContrast.inkOnTint(tagColor, theme.colorScheme.surface, 0.12);
                          return Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(color: tagColor.withValues(alpha: 0.12), shape: BoxShape.circle),
                            child: Icon(Icons.schedule_rounded, size: 15, color: ink),
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '调整到 ',
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                              TextSpan(
                                text: targetLabel,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: theme.accentInk,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (deltaLabel != null)
                                TextSpan(
                                  text: '  $deltaLabel',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.accentInk.withValues(alpha: 0.75),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(Icons.drag_indicator_rounded, size: 18, color: theme.colorScheme.outline),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _dragPreviewText(drag.record),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '松开生效 · 原 $originalLabel',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _dragPreviewText(DiaryRecord record) {
    return diaryDragPreviewText(content: record.content, title: record.title, photoCount: record.photos.length);
  }

  void _startAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (_lastDragPosition == null || !mounted || !_scrollController.hasClients) {
        return;
      }

      final renderBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
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
      } else if (localPos.dy > viewportHeight - threshold && localPos.dy <= viewportHeight) {
        // 向下滚动 (越靠近边缘，滚动速度越快)
        final ratio = (localPos.dy - (viewportHeight - threshold)) / threshold;
        scrollDelta = maxSpeed * ratio;
      }

      if (scrollDelta != 0.0) {
        final currentOffset = _scrollController.offset;
        final targetOffset = (currentOffset + scrollDelta).clamp(0.0, _scrollController.position.maxScrollExtent);

        if (targetOffset != currentOffset) {
          _scrollController.jumpTo(targetOffset);

          if (_cardDrag != null) {
            // 卡片拖动：列表滚动改变内容坐标，立即重算目标时间并刷新浮层。
            _applyRecordDragAt(_lastDragPosition!);
            return;
          }

          // 列表发生滚动后，手指下方的节点发生改变，动态更新选择范围！
          final index = _pointToItemIndex(_lastDragPosition!);
          if (index != -1 && index % _itemsPerDay != 0 && index != _dragEndIndex) {
            final dayOffset = index ~/ _itemsPerDay;
            final date = _indexToDate(dayOffset);
            if (_isDateExpanded(date)) {
              setState(() {
                _dragEndIndex = index;
              });
            }
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

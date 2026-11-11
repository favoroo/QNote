import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/utils/schema_formatter.dart';
import 'package:qnote_flutter/widgets/diary/ai_extract_helper.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/diary/model_selection_dialog.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/fixed_event_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/vision_capability_probe.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/providers/image_repository_provider.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';
import 'package:qnote_flutter/widgets/diary/edit_tag_time_sheet.dart';
import 'package:qnote_flutter/widgets/diary/diary_record_fab.dart';

part 'diary_record_sheet_parts.dart';

/// 记录面板的动效时长与曲线。
///
/// 有按钮锚点时走真正的容器变形：面板的 Rect、圆角、底色、描边、阴影和按钮
/// 用同一条时间线；没有锚点（外部快捷入口 / 减弱动效）时退回整卡缩放淡入。
/// 发送后还有第二段独立动画：面板先变空白盖板，再飞到新卡片的位置落下。
const Duration _kMorphEnterDuration = Duration(milliseconds: 460);
const Duration _kMorphExitDuration = Duration(milliseconds: 320);
const Duration _kCardFlightDuration = Duration(milliseconds: 480);
const Duration _kCardLandingExitDuration = Duration(milliseconds: 240);
const Curve _kMorphEnterCurve = Curves.easeInOutCubicEmphasized;
const Curve _kMorphExitCurve = Curves.easeInCubic;
const Curve _kCardFlightCurve = Curves.easeInOutCubicEmphasized;

/// 无锚点时的退路：整卡缩放上浮。
const Duration _kDialogEnterDuration = Duration(milliseconds: 360);
const Duration _kDialogExitDuration = Duration(milliseconds: 180);
const Curve _kDialogEnterCurve = Cubic(0.05, 0.7, 0.1, 1);
const Curve _kDialogExitCurve = Curves.easeInCubic;

/// 面板卡片圆角与时间线卡片圆角：容器变形的两端。
const double _kSheetRadius = 24;
const double _kTimelineCardRadius = 16;

/// 打开面板时记录按钮的位置与状态，作为容器变形的起点。
class RecordFabAnchor {
  const RecordFabAnchor({
    required this.rect,
    this.selection,
    this.hasDraft = false,
  });

  /// 按钮在屏幕上的全局 Rect；选中时间时是胶囊宽度。
  final Rect rect;

  /// 按钮上当前选中的时间；为空表示纯加号圆钮。
  final TimelineTimeSelectEvent? selection;

  /// 是否有未保存草稿（按钮右上角的小圆点）。
  final bool hasDraft;
}

/// 发送后「面板变成新卡片」的落位目标。
class RecordCardMorphTarget {
  const RecordCardMorphTarget({
    required this.initialRect,
    required this.readRect,
    required this.onLanded,
  });

  /// 首次量到的目标 Rect；列表/键盘继续变化时由 [readRect] 给实时值。
  final Rect initialRect;

  /// 每帧读取目标卡片的最新全局 Rect；卡片被 ListView 回收时返回 null。
  final Rect? Function() readRect;

  /// 盖板落位那一刻回调：页面在这里揭开真实卡片并播放柔光。
  final VoidCallback onLanded;
}

/// 「记录事件」面板：时间线左下角记录按钮弹出的填写面板。
///
/// 由原来的常驻底部输入条改造而来 —— 常驻一条厚重的输入栏会长期压掉时间线一大块。
/// 现在以居中悬浮卡片的形式出现：不贴屏幕底边，键盘弹起时整张卡片上移，
/// 视线不需要在屏幕上下两端来回跳。
///
/// 弹层有两条路径：
/// - 从时间线记录按钮打开时，按钮本身以容器变形的形式长大成卡片（见
///   [_RecordDialogTransition]），关闭时再原路收回按钮；
/// - 外部快捷入口 / 减弱动效时退回整卡缩放上浮，内容再错峰晚一拍落位。
///
/// 结构自上而下就是记录的填写顺序：确认时间 → 挑标签 → 补固定事件/字段 → 写正文发送。
/// 固定事件与标签字段常驻可见，不做二级折叠：睡眠、记账这类必填项一旦被藏起来，
/// 保存校验就会卡在一个用户看不见的表单上。
class DiaryRecordSheet extends ConsumerStatefulWidget {
  const DiaryRecordSheet({
    super.key,
    this.initialAction,
    this.surfaceKey,
    this.focusAfterEntrance = false,
    this.entryDelay = Duration.zero,
    this.onSaved,
  });

  /// 由悬浮球 / 桌面小组件带进来的动作（记录、拍照、相册），面板起来后自动执行。
  final WidgetAction? initialAction;

  /// 卡片外框的 Key。路由用它逐帧测量弹窗的最终 Rect，驱动容器变形。
  final GlobalKey? surfaceKey;

  /// 变形入场期间先不聚焦：键盘若在容器还没落定前弹起，会把卡片顶走。
  final bool focusAfterEntrance;

  /// 内容错峰入场的延迟：变形时等容器先让出空间，内容再亮。
  final Duration entryDelay;

  /// 保存成功后的回调（参数是真正落库的记录 id）。
  ///
  /// 页面趁发送键上的 ✓ 还在播时把时间线滚到新记录、量好卡片 Rect，
  /// 返回「弹窗变卡片」的落位目标；返回 null 就按原来的插入动画收尾。
  final Future<RecordCardMorphTarget?> Function(List<String> recordIds)? onSaved;

  /// 弹出记录面板。
  ///
  /// 草稿存在 [diaryComposeDraftProvider] 里而不是面板 State 里，所以误触遮罩、
  /// 点右上角关闭都不会丢字，重新打开接着填。
  static Future<void> show(
    BuildContext context, {
    WidgetAction? action,
    RecordFabAnchor? originAnchor,
    RecordFabAnchor? Function()? readAnchor,
    Future<RecordCardMorphTarget?> Function(List<String> recordIds)? onSaved,
  }) async {
    // 挂到根 Navigator：日记页在底部导航的分支里，用默认的嵌套 Navigator
    // 会让卡片被压在导航栏上方，遮罩也盖不住导航栏（还能顺手切走 tab）。
    final navigator = Navigator.of(context, rootNavigator: true);
    // 和 showDialog 一样把当前主题抓进路由：面板挂在根 Navigator 上，
    // 页面级 Theme 覆盖不会因为换了导航器而丢掉。
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final useMorph = originAnchor != null && !reduceMotion;
    final surfaceKey = GlobalKey();

    final route = _RecordDialogRoute(
      surfaceKey: surfaceKey,
      theme: theme,
      originAnchor: originAnchor,
      readAnchor: readAnchor,
      useMorph: useMorph,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      // 变形路径的遮罩画在页面里，和容器用同一条时间线；路由自带的半透明
      // barrier 会和它叠成两层，也会让出场时长失去单独控制。
      barrierColor: useMorph ? Colors.transparent : Colors.black.withValues(alpha: 0.4),
      reduceMotion: reduceMotion,
      pageBuilder: (_, _, _) => themes.wrap(
        // showDialog 的 useSafeArea 默认会包一层 SafeArea，换成自定义路由
        // 后要自己补上，否则刘海/Home Indicator 区域会被卡片压到。
        SafeArea(
          child: DiaryRecordSheet(
            initialAction: action,
            surfaceKey: surfaceKey,
            focusAfterEntrance: useMorph,
            entryDelay: useMorph ? const Duration(milliseconds: 180) : Duration.zero,
            onSaved: onSaved,
          ),
        ),
      ),
    );
    navigator.push<void>(route);
    // 等退场动画真正播完再返回：页面要在这之后才把按钮放出来，
    // 否则按钮会在卡片还没缩回去时提前从底下冒出来。
    await route.done;
  }

  @override
  ConsumerState<DiaryRecordSheet> createState() => _DiaryRecordSheetState();
}

class _DiaryRecordSheetState extends ConsumerState<DiaryRecordSheet>
    with TickerProviderStateMixin {
  /// 保存成功后在发送键上短暂显示 ✓，让「已记下」这件事有个落地感。
  bool _savedOk = false;

  /// 面板内容的错峰入场（头部 → 中段 → 底部依次浮现）。
  ///
  /// 只补「内容第一次亮出来」的那一段：面板本身由路由的容器变形负责，
  /// 这一层让内容比容器晚一点点、错开一点点落位，看起来是「卡片先长出来，
  /// 内容才坐定」，而不是一整块贴图平移。
  late final AnimationController _entryController;

  /// 变形容器长大到差不多时再亮内容；外部入口不需要延迟。
  Timer? _entryStartTimer;

  /// 变形入场期间延后聚焦，避免键盘先把卡片顶走。
  Timer? _focusTimer;

  /// ✓ 的停留时长。没有飞行目标时，页面侧 `_kInsertRevealDelay` 与它对齐：
  /// 记录先入库、时间线先播插入动画，面板要等这段时间过去再让路；
  /// 走「弹窗变卡片」时，✓ 结束后直接进入 480ms 飞行，不再等插入动画。
  static const Duration _savedFeedbackDuration = Duration(milliseconds: 320);

  bool _isExtracting = false;
  // 发送重入保护：防止压缩完成瞬间/弹窗渲染前一帧内的双击重复提交
  bool _isSending = false;
  // 压缩等待弹窗标志：防重复弹窗，也防弹窗孤儿
  bool _waitingForCompression = false;
  CancelToken? _cancelToken;
  _ExtractPhase _extractPhase = _ExtractPhase.idle;

  late DiaryComposeDraft _draft;
  String? _activeFormTagId;
  // 支持多选：按选中顺序保存固定事件模板 ID（用于备注换行拼接）
  final Set<String> _selectedFixedEventIds = <String>{};

  DiaryComposeDraft? _preExtractDraft;
  String? _preExtractText;
  late AnimationController _undoController;
  bool _canUndo = false;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final Map<String, Future<String>> _compressingTasks = {};
  final ScrollController _shortcutScrollController = ScrollController();

  final Map<String, TextEditingController> _formControllers = {};

  TextEditingController _getFormController(
    String fieldId,
    String initialValue, {
    String? tagId,
  }) {
    final key = tagId != null ? '${tagId}_$fieldId' : fieldId;
    if (!_formControllers.containsKey(key)) {
      _formControllers[key] = TextEditingController(text: initialValue);
    } else {
      final controller = _formControllers[key]!;
      if (controller.text != initialValue) {
        controller.value = controller.value.copyWith(
          text: initialValue,
          selection: TextSelection.collapsed(offset: initialValue.length),
        );
      }
    }
    return _formControllers[key]!;
  }

  OverlayEntry? _modelMenuOverlay;

  @override
  void initState() {
    super.initState();
    // 接着上次没填完的草稿继续：面板关掉不丢字，是模态弹层的基本礼貌。
    var restored = ref.read(diaryComposeDraftProvider);
    // 面板关闭期间在时间线上选的时间不会流进草稿（监听随面板一起卸载了），
    // 打开时先对齐一次，否则头部显示的是草稿里那份旧时间，和左下角胶囊对不上。
    final selection = ref.read(diaryInputTimeProvider);
    if (selection != null) {
      restored = _draftWithSelection(
        restored,
        selection,
        selectedDate: ref.read(selectedDateProvider),
      );
    }
    _draft = restored;
    _textController.text = _draft.inputText;
    _textController.addListener(_onTextChanged);
    _undoController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _undoController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _canUndo = false;
        });
        _preExtractDraft = null;
        _preExtractText = null;
      }
    });
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    // 等一帧再播：面板刚 insert 时还没有尺寸，立刻 forward 会让错峰动画
    // 跑在首帧布局之前，看起来像是内容「闪」出来的。容器变形时再晚一拍，
    // 等按钮先长出一块空间，内容再亮。
    if (widget.entryDelay > Duration.zero) {
      _entryStartTimer = Timer(widget.entryDelay, _startEntryReveal);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startEntryReveal());
    }
    // 打开即聚焦：记录面板的主路径是打字，让键盘先到位。
    // 变形入场时等卡片基本落定再聚焦，否则键盘会在飞行途中把目标 Rect 顶走。
    if (widget.focusAfterEntrance) {
      _focusTimer = Timer(const Duration(milliseconds: 280), () {
        if (mounted) _textFocusNode.requestFocus();
      });
    } else {
      _textFocusNode.requestFocus();
    }
    final action = widget.initialAction;
    if (action != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleWidgetAction(action);
      });
    }
  }

  /// 内容错峰入场的起点；减弱动效直接落终态。
  void _startEntryReveal() {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entryController.value = 1;
    } else {
      _entryController.forward();
    }
  }

  /// 把时间线上的选择换算成草稿的起止时间与跨天偏移。
  ///
  /// 面板开着时由监听走 [_updateActiveDraft]；面板关着时那条监听不存在，
  /// 所以打开面板要先用这个纯换算对齐一次草稿。
  ///
  /// 草稿里存的是相对当前选中日期的天数偏移而不是绝对日期，
  /// 这样用户把时间线切到别的日期时，草稿不会跟着漂到今天。
  DiaryComposeDraft _draftWithSelection(
    DiaryComposeDraft base,
    TimelineTimeSelectEvent event, {
    required DateTime selectedDate,
  }) {
    final baseDay = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );
    int offsetOf(DateTime date) =>
        DateTime(date.year, date.month, date.day).difference(baseDay).inDays;

    return base.copyWith(
      startTime: event.time,
      startOffset: offsetOf(event.date),
      clearStartOffset: false,
      clearEndTime: event.endTime == null,
      endTime: event.endTime,
      // endDate 为空表示结束时间落在开始那天（时间线区间选择就是这么表达的），
      // 所以取开始日的偏移；留空会沿用草稿里上一段的旧偏移，跨天会算错。
      endOffset: event.endDate == null
          ? offsetOf(event.date)
          : offsetOf(event.endDate!),
      clearEndOffset: event.endTime == null,
    );
  }

  @override
  void dispose() {
    _entryStartTimer?.cancel();
    _focusTimer?.cancel();
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _shortcutScrollController.dispose();
    _undoController.dispose();
    _entryController.dispose();
    _removeModelMenuOverlay();
    for (final c in _formControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTextChanged() {
    _updateActiveDraft(inputText: _textController.text);
  }

  DiaryComposeDraft get _activeDraft => _draft;

  void _updateActiveDraft({
    String? inputText,
    List<TagEntry>? tagEntries,
    List<String>? selectedPhotos,
    TimeOfDay? startTime,
    bool clearEndTime = false,
    TimeOfDay? endTime,
    int? startOffset,
    bool clearStartOffset = false,
    int? endOffset,
    bool clearEndOffset = false,
  }) {
    setState(() {
      final active = _draft;
      var nextTagEntries = tagEntries ?? List<TagEntry>.from(active.tagEntries);
      var nextStartTime = startTime ?? active.startTime;
      final nextStartOffset = clearStartOffset
          ? null
          : (startOffset ?? active.startOffset);

      TimeOfDay? nextEndTime =
          endTime ?? (clearEndTime ? null : active.endTime);
      int? nextEndOffset =
          endOffset ?? (clearEndOffset ? null : active.endOffset);
      var nextClearEndTime = clearEndTime;
      var nextClearEndOffset = clearEndOffset;

      final sleepEntry = nextTagEntries
          .where((e) => e.id == 'sleep')
          .firstOrNull;
      if (sleepEntry != null) {
        final sleepFields = Map<String, dynamic>.from(sleepEntry.fields);

        if (tagEntries != null &&
            sleepFields.containsKey('fallAsleepTime') &&
            sleepFields['fallAsleepTime'] != null) {
          final timeStr = sleepFields['fallAsleepTime'] as String;
          final parts = timeStr.split(':');
          if (parts.length >= 2) {
            final h = int.tryParse(parts[0]) ?? 0;
            final m = int.tryParse(parts[1]) ?? 0;
            if (startTime == null) {
              nextStartTime = TimeOfDay(hour: h, minute: m);
            }
          }
        }

        if (tagEntries != null) {
          final durationVal = sleepFields['duration'];
          if (durationVal != null) {
            final double? durationHours = double.tryParse(
              durationVal.toString(),
            );
            if (durationHours != null) {
              final startMinutes =
                  nextStartTime.hour * 60 + nextStartTime.minute;
              final durationMinutes = (durationHours * 60).toInt();
              final totalMinutes = startMinutes + durationMinutes;

              final endHour = (totalMinutes ~/ 60) % 24;
              final endMinute = totalMinutes % 60;
              final daysOffset = totalMinutes ~/ 1440;

              nextEndTime = TimeOfDay(hour: endHour, minute: endMinute);
              nextEndOffset = (nextStartOffset ?? 0) + daysOffset;
              nextClearEndTime = false;
              nextClearEndOffset = false;
            } else {
              nextEndTime = null;
              nextEndOffset = null;
              nextClearEndTime = true;
              nextClearEndOffset = true;
            }
          } else if (nextEndTime != null) {
            final startMin = nextStartTime.hour * 60 + nextStartTime.minute;
            final endMin = nextEndTime.hour * 60 + nextEndTime.minute;
            var diffMin = endMin - startMin;
            if (diffMin < 0) {
              diffMin += 1440;
            }
            sleepFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
          }
        } else {
          if (nextEndTime != null) {
            final startMin = nextStartTime.hour * 60 + nextStartTime.minute;
            final endMin = nextEndTime.hour * 60 + nextEndTime.minute;
            var diffMin = endMin - startMin;
            if (diffMin < 0) {
              diffMin += 1440;
            }
            final durationHours = diffMin / 60.0;
            final existingDuration = sleepFields['duration'];
            final existingHours = existingDuration != null
                ? double.tryParse(existingDuration.toString())
                : null;
            if (existingHours == null ||
                (existingHours - durationHours).abs() > 0.001) {
              sleepFields['duration'] = durationHours.toStringAsFixed(1);
            }
          }
        }

        sleepFields['fallAsleepTime'] =
            '${nextStartTime.hour.toString().padLeft(2, '0')}:${nextStartTime.minute.toString().padLeft(2, '0')}';

        nextTagEntries = nextTagEntries.map((e) {
          if (e.id == 'sleep') return e.copyWith(fields: sleepFields);
          return e;
        }).toList();
      }

      // activity 联动：外部时间变化时（如改时间选择器、点固定事件），反算 duration 回写 fields
      final activityEntry = nextTagEntries.where((e) => e.id == 'activity').firstOrNull;
      if (activityEntry != null) {
        final activityFields = Map<String, dynamic>.from(activityEntry.fields);
        if (nextEndTime != null) {
          final startMin = nextStartTime.hour * 60 + nextStartTime.minute;
          final endMin = nextEndTime.hour * 60 + nextEndTime.minute;
          var diffMin = endMin - startMin;
          if (diffMin < 0) diffMin += 1440;
          // 跨天时用 endOffset 修正：负的 endOffset 表示前一天，需补足时长
          final offDiff = (nextEndOffset ?? nextStartOffset ?? 0) - (nextStartOffset ?? 0);
          diffMin += offDiff * 1440;
          if (diffMin >= 0) {
            activityFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
          }
        } else {
          activityFields.remove('duration');
        }
        nextTagEntries = nextTagEntries.map((e) {
          if (e.id == 'activity') return e.copyWith(fields: activityFields);
          return e;
        }).toList();
      }

      _draft = active.copyWith(
        inputText: inputText,
        tagEntries: nextTagEntries,
        selectedPhotos: selectedPhotos,
        startTime: nextStartTime,
        clearEndTime: nextClearEndTime,
        endTime: nextEndTime,
        startOffset: nextStartOffset,
        clearStartOffset: clearStartOffset,
        endOffset: nextEndOffset,
        clearEndOffset: nextClearEndOffset,
      );

      if (_activeFormTagId != null &&
          !_draft.tagEntries.any((e) => e.id == _activeFormTagId)) {
        _activeFormTagId = _draft.tagEntries.isNotEmpty
            ? _draft.tagEntries.first.id
            : null;
      }
    });

    // 草稿写回 Provider：面板可能被遮罩/下滑关掉，草稿不能随 State 一起蒸发。
    // 只在这里写、不在每个 setState 里写，是因为本方法是草稿变更的唯一漏斗。
    ref.read(diaryComposeDraftProvider.notifier).set(_draft);

    final activeDraft = _draft;
    final newTime = activeDraft.startTime;
    final currentTime = ref.read(currentInputTimeProvider);
    if (currentTime.hour != newTime.hour ||
        currentTime.minute != newTime.minute) {
      ref.read(currentInputTimeProvider.notifier).state = newTime;
    }

    final selectedDate = ref.read(selectedDateProvider);
    final targetDate = _calculateStartDateTime(activeDraft, selectedDate);
    final targetEndDate = activeDraft.endTime != null
        ? _calculateEndDateTime(activeDraft, selectedDate)
        : null;
    final currentTimeline = ref.read(diaryInputTimeProvider);

    if (currentTimeline != null) {
      final bool timeMatches =
          currentTimeline.time.hour == activeDraft.startTime.hour &&
          currentTimeline.time.minute == activeDraft.startTime.minute &&
          ((currentTimeline.endTime == null && activeDraft.endTime == null) ||
              (currentTimeline.endTime != null &&
                  activeDraft.endTime != null &&
                  currentTimeline.endTime!.hour == activeDraft.endTime!.hour &&
                  currentTimeline.endTime!.minute ==
                      activeDraft.endTime!.minute));

      final bool dateMatches =
          currentTimeline.date.year == targetDate.year &&
          currentTimeline.date.month == targetDate.month &&
          currentTimeline.date.day == targetDate.day &&
          ((currentTimeline.endDate == null && targetEndDate == null) ||
              (currentTimeline.endDate != null &&
                  targetEndDate != null &&
                  currentTimeline.endDate!.year == targetEndDate.year &&
                  currentTimeline.endDate!.month == targetEndDate.month &&
                  currentTimeline.endDate!.day == targetEndDate.day));

      if (!timeMatches || !dateMatches) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref
              .read(diaryInputTimeProvider.notifier)
              .state = TimelineTimeSelectEvent(
            activeDraft.startTime,
            endTime: activeDraft.endTime,
            date: targetDate,
            endDate: targetEndDate,
          );
        });
      }
    }
  }

  void _clearCurrentDraft() {
    _formControllers.clear();
    _undoController.stop();
    ref.read(diaryInputTimeProvider.notifier).state = null;
    ref.read(diaryComposeDraftProvider.notifier).reset();
    setState(() {
      _draft = DiaryComposeDraft(
        id: const Uuid().v4(),
        startTime: TimeOfDay.now(),
        endTime: null,
        startOffset: null,
        endOffset: null,
      );
      _textController.text = '';
      _canUndo = false;
      _preExtractDraft = null;
      _preExtractText = null;
      _activeFormTagId = null;
      _selectedFixedEventIds.clear();
    });
  }

  void _selectShortcut(ShortcutConfig? config) async {
    _formControllers.clear();
    if (config == null) {
      _activeFormTagId = null;
      _updateActiveDraft(tagEntries: []);
      return;
    }

    final currentEntries = List<TagEntry>.from(_activeDraft.tagEntries);
    final existingIndex = currentEntries.indexWhere((e) => e.id == config.id);

    if (existingIndex >= 0) {
      currentEntries.removeAt(existingIndex);
      if (_activeFormTagId == config.id) {
        _activeFormTagId = currentEntries.isNotEmpty
            ? currentEntries.first.id
            : null;
      }
      _updateActiveDraft(tagEntries: currentEntries);
      return;
    }

    currentEntries.add(TagEntry(id: config.id, name: config.name, fields: {}));
    if (config.hasPopup) {
      _activeFormTagId = config.id;
    }

    if (config.id == 'sleep') {
      final timelineSelect = ref.read(diaryInputTimeProvider);
      if (timelineSelect != null) {
        final startTimeStr =
            '${timelineSelect.time.hour.toString().padLeft(2, '0')}:${timelineSelect.time.minute.toString().padLeft(2, '0')}';

        double? durationHours;
        if (timelineSelect.endTime != null) {
          final startMin =
              timelineSelect.time.hour * 60 + timelineSelect.time.minute;
          final endMin =
              timelineSelect.endTime!.hour * 60 +
              timelineSelect.endTime!.minute;
          var diffMin = endMin - startMin;
          if (diffMin < 0) {
            diffMin += 1440;
          }
          durationHours = diffMin / 60.0;
        }

        final selectedDate = ref.read(selectedDateProvider);
        final startLocalDate = DateTime(
          timelineSelect.date.year,
          timelineSelect.date.month,
          timelineSelect.date.day,
        );
        final startOffset = startLocalDate
            .difference(
              DateTime(selectedDate.year, selectedDate.month, selectedDate.day),
            )
            .inDays;

        final initialFields = <String, dynamic>{'fallAsleepTime': startTimeStr};
        if (durationHours != null) {
          initialFields['duration'] = durationHours.toStringAsFixed(1);
        }

        currentEntries.last = currentEntries.last.copyWith(
          fields: initialFields,
        );
        _updateActiveDraft(
          tagEntries: currentEntries,
          startTime: timelineSelect.time,
          endTime: timelineSelect.endTime,
          startOffset: startOffset,
        );
        return;
      }

      try {
        final repo = ref.read(diaryRepositoryProvider);
        final sleepRecords = await repo.getByTag('睡眠');
        if (sleepRecords.isNotEmpty) {
          final lastSleep = sleepRecords.first;
          if (lastSleep.startTime != null) {
            final lastStartTime = TimeOfDay(
              hour: lastSleep.startTime!.hour,
              minute: lastSleep.startTime!.minute,
            );

            final logicalDate = DateTime(
              lastSleep.time.year,
              lastSleep.time.month,
              lastSleep.time.day,
            );
            final startLocalDate = DateTime(
              lastSleep.startTime!.year,
              lastSleep.startTime!.month,
              lastSleep.startTime!.day,
            );
            final offset = startLocalDate.difference(logicalDate).inDays;

            final lastFallAsleepTime =
                '${lastStartTime.hour.toString().padLeft(2, '0')}:${lastStartTime.minute.toString().padLeft(2, '0')}';

            currentEntries.last = currentEntries.last.copyWith(
              fields: {'fallAsleepTime': lastFallAsleepTime},
            );
            _updateActiveDraft(
              tagEntries: currentEntries,
              startTime: lastStartTime,
              startOffset: offset,
            );

            final selectedDate = ref.read(selectedDateProvider);
            final targetDate = DateTime(
              selectedDate.year,
              selectedDate.month,
              selectedDate.day,
            ).add(Duration(days: offset));
            ref.read(diaryInputTimeProvider.notifier).state =
                TimelineTimeSelectEvent(lastStartTime, date: targetDate);
            return;
          }
        }

        currentEntries.last = currentEntries.last.copyWith(
          fields: {'fallAsleepTime': '22:00'},
        );
        _updateActiveDraft(
          tagEntries: currentEntries,
          startTime: const TimeOfDay(hour: 22, minute: 0),
          startOffset: -1,
        );

        final selectedDate = ref.read(selectedDateProvider);
        final targetDate = DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
        ).add(const Duration(days: -1));
        ref
            .read(diaryInputTimeProvider.notifier)
            .state = TimelineTimeSelectEvent(
          const TimeOfDay(hour: 22, minute: 0),
          date: targetDate,
        );
        return;
      } catch (e) {
        LoggerService.instance.logAI('加载上次睡眠记录失败: $e');
        currentEntries.last = currentEntries.last.copyWith(
          fields: {'fallAsleepTime': '22:00'},
        );
        _updateActiveDraft(
          tagEntries: currentEntries,
          startTime: const TimeOfDay(hour: 22, minute: 0),
          startOffset: -1,
        );

        final selectedDate2 = ref.read(selectedDateProvider);
        final targetDate2 = DateTime(
          selectedDate2.year,
          selectedDate2.month,
          selectedDate2.day,
        ).add(const Duration(days: -1));
        ref
            .read(diaryInputTimeProvider.notifier)
            .state = TimelineTimeSelectEvent(
          const TimeOfDay(hour: 22, minute: 0),
          date: targetDate2,
        );
        return;
      }
    }

    _updateActiveDraft(tagEntries: currentEntries);
  }

  /// 判断指定固定事件模板在目标日期是否已经添加过（当天已存在对应日记记录）
  bool _isFixedEventAddedOnDate(
    FixedEventTemplate template,
    DateTime date,
    List<DiaryRecord> records,
  ) {
    final targetDate = DateTime(date.year, date.month, date.day);
    return records.any((r) {
      if (r.isDeleted) return false;
      if (!r.belongsToDate(targetDate)) return false;

      // 1. 优先比对 bodyState 中的固定事件元数据
      final fixedId = r.bodyState?['fixed_event_id'] as String?;
      if (fixedId != null && fixedId.isNotEmpty) {
        return fixedId == template.id;
      }
      final fixedName = r.bodyState?['fixed_event_name'] as String?;
      if (fixedName != null && fixedName.isNotEmpty) {
        return fixedName == template.name;
      }

      // 2. 兼容历史/现有记录：通过 title 或 displayTag 比对
      return r.title == template.name || r.displayTag == template.name;
    });
  }

  /// 选择固定事件模板，自动填充时间、内容和标签（含字段值）
  /// 支持多选：再次点击已选中模板则取消；多个模板的备注换行拼接显示；同一天已添加过的事件不可再次添加
  void _selectFixedEvent(FixedEventTemplate template) {
    final isDeselecting = _selectedFixedEventIds.contains(template.id);
    final selectedDate = ref.read(selectedDateProvider);
    final allRecords = ref.read(diaryListProvider).valueOrNull ?? [];

    // 若今日已添加该固定事件，拦截选中并给予提示
    if (!isDeselecting && _isFixedEventAddedOnDate(template, selectedDate, allRecords)) {
      if (_selectedFixedEventIds.contains(template.id)) {
        setState(() {
          _selectedFixedEventIds.remove(template.id);
        });
      }
      Toast.info(context, '「${template.name}」今日已添加');
      return;
    }

    setState(() {
      if (isDeselecting) {
        _selectedFixedEventIds.remove(template.id);
      } else {
        _selectedFixedEventIds.add(template.id);
      }
    });

    // 取出当前所有可用的固定事件模板，用于按选中顺序拼接备注与时间
    final allTemplates = ref.read(fixedEventListProvider).valueOrNull ?? [];

    // 取消选中：移除该模板关联的标签
    if (isDeselecting) {
      final currentEntries = List<TagEntry>.from(_activeDraft.tagEntries);
      if (template.tags.isNotEmpty) {
        currentEntries.removeWhere((e) => template.tags.contains(e.id));
      }
      _applyFixedEventsSelection(allTemplates, currentEntries);
      Toast.success(context, '已取消：${template.name}', duration: const Duration(seconds: 1));
      return;
    }

    // 选中：把该模板关联的标签加入草稿（去重）
    final currentEntries = List<TagEntry>.from(_activeDraft.tagEntries);
    if (template.tags.isNotEmpty) {
      final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
      for (final tagId in template.tags) {
        try {
          final config = shortcuts.firstWhere((s) => s.id == tagId);
          if (!currentEntries.any((e) => e.id == config.id)) {
            final presetFields = template.tagFields[tagId] ?? {};
            currentEntries.add(
              TagEntry(id: config.id, name: config.name, fields: Map<String, dynamic>.from(presetFields)),
            );
          }
        } catch (_) {}
      }
    }
    _applyFixedEventsSelection(allTemplates, currentEntries);

    // 显示提示
    Toast.success(context, '已填充：${template.name} (${template.formattedTimeRange})', duration: const Duration(seconds: 1));
  }

  /// 根据当前选中的固定事件集合，统一刷新草稿的时间与备注
  /// - 时间：用"最后选中"的模板时间（时间点模式无结束时间）
  /// - 备注：所有选中模板的备注按选中顺序换行拼接（未填备注时默认使用事件标题）
  void _applyFixedEventsSelection(List<FixedEventTemplate> allTemplates, List<TagEntry> tagEntries) {
    if (_selectedFixedEventIds.isEmpty) {
      _textController.text = '';
      _updateActiveDraft(
        inputText: '',
        tagEntries: tagEntries,
        clearEndTime: true,
      );
      ref.read(diaryInputTimeProvider.notifier).state = null;
      return;
    }

    // 按选中顺序找到对应的模板
    final selectedTemplates = <FixedEventTemplate>[];
    for (final t in allTemplates) {
      if (_selectedFixedEventIds.contains(t.id)) {
        selectedTemplates.add(t);
      }
    }
    // 时间用最后选中模板的第一个时间段的开始/结束时间
    final last = selectedTemplates.last;
    final firstPeriod = last.timePeriods.isNotEmpty 
        ? last.timePeriods.first 
        : TimePeriod(startTime: last.startTime, endTime: last.endTime);

    final startParts = firstPeriod.startTime.split(':');
    final startTime = TimeOfDay(
      hour: int.tryParse(startParts[0]) ?? last.startHour,
      minute: startParts.length > 1 ? int.tryParse(startParts[1]) ?? last.startMinute : 0,
    );
    final TimeOfDay? endTime = last.isTimePoint || firstPeriod.endTime.isEmpty
        ? null
        : () {
            final endParts = firstPeriod.endTime.split(':');
            return TimeOfDay(
              hour: int.tryParse(endParts[0]) ?? last.endHour,
              minute: endParts.length > 1 ? int.tryParse(endParts[1]) ?? last.endMinute : 0,
            );
          }();

    // 备注换行拼接（未填备注时默认使用事件标题）
    final contents = selectedTemplates
        .map((t) => t.effectiveContent)
        .where((c) => c.isNotEmpty)
        .toList();
    final mergedText = contents.join('\n');

    _textController.text = mergedText;
    _textController.selection = TextSelection.fromPosition(
      TextPosition(offset: mergedText.length),
    );

    _updateActiveDraft(
      startTime: startTime,
      endTime: endTime,
      clearEndTime: last.isTimePoint,
      inputText: mergedText,
      tagEntries: tagEntries,
      clearStartOffset: true,
      clearEndOffset: true,
    );

    // 更新时间选择 Provider（使用 _calculateStartDateTime 确保与 _updateActiveDraft 一致）
    final selectedDate = ref.read(selectedDateProvider);
    final targetDate = _calculateStartDateTime(_draft, selectedDate);
    final targetEndDate = _calculateEndDateTime(_draft, selectedDate);
    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
      startTime,
      endTime: endTime,
      date: targetDate,
      endDate: targetEndDate,
    );
  }

  void _updateFormValue(String key, dynamic value, {String? tagId}) {
    final effectiveTagId = tagId ?? _activeFormTagId;
    if (effectiveTagId == null) return;

    final entry = _activeDraft.tagEntries
        .where((e) => e.id == effectiveTagId)
        .firstOrNull;
    if (entry == null) return;

    final newFields = Map<String, dynamic>.from(entry.fields);
    if (value == null) {
      newFields.remove(key);
    } else {
      newFields[key] = value;
    }

    var newTagEntries = _activeDraft.tagEntries.map((e) {
      if (e.id == effectiveTagId) return e.copyWith(fields: newFields);
      return e;
    }).toList();

    if (effectiveTagId == 'sleep') {
      if (key == 'fallAsleepTime' && value != null) {
        final timeStr = value as String;
        final parts = timeStr.split(':');
        if (parts.length >= 2) {
          final h = int.tryParse(parts[0]) ?? 0;
          final m = int.tryParse(parts[1]) ?? 0;
          final newStartTime = TimeOfDay(hour: h, minute: m);

          if (_activeDraft.endTime != null) {
            final startMin = h * 60 + m;
            final endMin =
                _activeDraft.endTime!.hour * 60 + _activeDraft.endTime!.minute;
            var diffMin = endMin - startMin;
            if (diffMin < 0) diffMin += 1440;
            newFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
            newTagEntries = newTagEntries.map((e) {
              if (e.id == 'sleep') return e.copyWith(fields: newFields);
              return e;
            }).toList();
          }

          _updateActiveDraft(
            tagEntries: newTagEntries,
            startTime: newStartTime,
          );
          return;
        }
      }

      if (key == 'duration' && value != null) {
        final double? durationHours = double.tryParse(value.toString());
        if (durationHours != null) {
          final startTime = _activeDraft.startTime;
          final startMinutes = startTime.hour * 60 + startTime.minute;
          final durationMinutes = (durationHours * 60).toInt();
          final totalMinutes = startMinutes + durationMinutes;
          final endHour = (totalMinutes ~/ 60) % 24;
          final endMinute = totalMinutes % 60;
          final daysOffset = totalMinutes ~/ 1440;

          _updateActiveDraft(
            tagEntries: newTagEntries,
            endTime: TimeOfDay(hour: endHour, minute: endMinute),
            endOffset: (_activeDraft.startOffset ?? 0) + daysOffset,
          );
          return;
        }
      }
    }

    if (effectiveTagId == 'activity') {
      if (key == 'duration' && value != null) {
        final double? durationHours = double.tryParse(value.toString());
        if (durationHours != null) {
          final startTime = _activeDraft.startTime;
          final startMinutes = startTime.hour * 60 + startTime.minute;
          final durationMinutes = (durationHours * 60).toInt();
          final totalMinutes = startMinutes + durationMinutes;
          final endHour = (totalMinutes ~/ 60) % 24;
          final endMinute = totalMinutes % 60;
          final daysOffset = totalMinutes ~/ 1440;

          _updateActiveDraft(
            tagEntries: newTagEntries,
            endTime: TimeOfDay(hour: endHour, minute: endMinute),
            endOffset: (_activeDraft.startOffset ?? 0) + daysOffset,
          );
          return;
        }
      }
    }

    _updateActiveDraft(tagEntries: newTagEntries);
  }

  /// 悬浮球 / 桌面小组件带进来的动作。
  void _handleWidgetAction(WidgetAction action) {
    _textFocusNode.requestFocus();
    switch (action) {
      case WidgetAction.input:
      case WidgetAction.send:
        break;
      case WidgetAction.photo:
        _pickImageFromGallery();
        break;
      case WidgetAction.camera:
        _pickImageFromCamera();
        break;
    }
  }

  Future<void> _pickImageFromGallery() async {
    if (_activeDraft.selectedPhotos.length >= 3) return;
    try {
      final remaining = 3 - _activeDraft.selectedPhotos.length;
      final images = await GalleryHelper.pickMultiImages(
        context,
        maxAssets: remaining,
      );
      if (images.isEmpty) return;
      final paths = <String>[];
      for (final xFile in images) {
        final tempPath = xFile.path;
        paths.add(tempPath);
        
        // 启动异步压缩保存任务
        final Future<String> compressFuture =
            ref.read(imageRepositoryProvider).saveImage(
          File(tempPath),
          subfolder: 'diary',
        );
        _compressingTasks[tempPath] = compressFuture;
        
        compressFuture.then((savedPath) {
          if (!mounted) return;
          setState(() {
            _compressingTasks.remove(tempPath);
            final photos = List<String>.from(_draft.selectedPhotos);
            final index = photos.indexOf(tempPath);
            if (index != -1) {
              photos[index] = savedPath;
              _updateActiveDraft(selectedPhotos: photos);
            } else {
              ref.read(imageRepositoryProvider).deleteImage(savedPath);
            }
          });
        }).catchError((e) {
          if (!mounted) return;
          setState(() {
            _compressingTasks.remove(tempPath);
            final photos = List<String>.from(_draft.selectedPhotos);
            photos.remove(tempPath);
            _updateActiveDraft(selectedPhotos: photos);
          });
          debugPrint('Error compressing image: $e');
        });
      }
      
      // 立即秒显本地临时路径
      _updateActiveDraft(
        selectedPhotos: [..._activeDraft.selectedPhotos, ...paths],
      );
    } catch (_) {}
  }

  Future<void> _pickImageFromCamera() async {
    if (_activeDraft.selectedPhotos.length >= 3) return;
    try {
      // 与编辑页一致先在原生层降采样，避免全尺寸原图进入压缩流程
      final xFile = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 80,
      );
      if (xFile == null) return;
      
      final tempPath = xFile.path;
      
      // 立即秒显本地临时路径
      _updateActiveDraft(
        selectedPhotos: [..._activeDraft.selectedPhotos, tempPath],
      );
      
      // 启动异步压缩保存任务
      final Future<String> compressFuture =
          ref.read(imageRepositoryProvider).saveImage(
        File(tempPath),
        subfolder: 'diary',
      );
      _compressingTasks[tempPath] = compressFuture;
      
      compressFuture.then((savedPath) {
        if (!mounted) return;
        setState(() {
          _compressingTasks.remove(tempPath);
          final photos = List<String>.from(_draft.selectedPhotos);
          final index = photos.indexOf(tempPath);
          if (index != -1) {
            photos[index] = savedPath;
            _updateActiveDraft(selectedPhotos: photos);
          } else {
            ref.read(imageRepositoryProvider).deleteImage(savedPath);
          }
        });
      }).catchError((e) {
        if (!mounted) return;
        setState(() {
          _compressingTasks.remove(tempPath);
          final photos = List<String>.from(_draft.selectedPhotos);
          photos.remove(tempPath);
          _updateActiveDraft(selectedPhotos: photos);
        });
        debugPrint('Error compressing image: $e');
      });
    } catch (_) {}
  }

  void _removePhoto(int index) {
    final photos = List<String>.from(_activeDraft.selectedPhotos);
    photos.removeAt(index);
    _updateActiveDraft(selectedPhotos: photos);
  }

  Future<void> _pickStartTime() async {
    final result = await showTimePickerDialog(
      context: context,
      initialTime: _calculateStartDateTime(
        _activeDraft,
        ref.read(selectedDateProvider),
      ),
      title: '开始时间',
    );
    if (result != null) {
      final selectedDate = ref.read(selectedDateProvider);
      final offset = DateTime(result.year, result.month, result.day)
          .difference(
            DateTime(selectedDate.year, selectedDate.month, selectedDate.day),
          )
          .inDays;
      final newTime = TimeOfDay(hour: result.hour, minute: result.minute);
      _updateActiveDraft(startTime: newTime, startOffset: offset);

      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        newTime,
        endTime: _activeDraft.endTime,
        date: DateTime(result.year, result.month, result.day),
        endDate: _activeDraft.endTime != null
            ? _calculateEndDateTime(_activeDraft, selectedDate)
            : null,
      );
    }
  }

  Future<void> _pickEndTime() async {
    final initialDate = _activeDraft.endTime != null
        ? _calculateEndDateTime(_activeDraft, ref.read(selectedDateProvider))!
        : _calculateStartDateTime(
            _activeDraft,
            ref.read(selectedDateProvider),
          ).add(const Duration(hours: 1));

    final result = await showTimePickerDialog(
      context: context,
      initialTime: initialDate,
      title: '结束时间',
    );
    if (result != null) {
      final selectedDate = ref.read(selectedDateProvider);
      final offset = DateTime(result.year, result.month, result.day)
          .difference(
            DateTime(selectedDate.year, selectedDate.month, selectedDate.day),
          )
          .inDays;
      final newEndTime = TimeOfDay(hour: result.hour, minute: result.minute);
      _updateActiveDraft(endTime: newEndTime, endOffset: offset);

      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        _activeDraft.startTime,
        endTime: newEndTime,
        date: _calculateStartDateTime(_activeDraft, selectedDate),
        endDate: DateTime(result.year, result.month, result.day),
      );
    }
  }

  void _clearEndTime() {
    // Just set the provider to null - the ref.listen callback in build()
    // will handle resetting draft times (startTime, endTime, offsets).
    // Do NOT call _updateActiveDraft first, as it would schedule a
    // postFrameCallback that restores the provider to non-null.
    ref.read(diaryInputTimeProvider.notifier).state = null;
    // 同时清除固定事件的选中状态
    setState(() {
      _selectedFixedEventIds.clear();
    });
  }

  Future<void> _handleAiExtract() async {
    if (_isExtracting) {
      _cancelToken?.cancel();
      _cancelToken = null;
      return;
    }
    final draft = _activeDraft;

    final aiTempsAsync = ref.read(aiTemperaturesProvider);
    final extractImages =
        aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isExtractButtonEnabled =
        draft.inputText.trim().isNotEmpty ||
        (extractImages && draft.selectedPhotos.isNotEmpty);
    if (!isExtractButtonEnabled) return;

    if (!await AiRoleService.instance.hasUsableConfigForRole('timelineOptimization')) {
      if (mounted) {
        await showNoModelConfiguredDialog(context, scene: '时间线 AI 提取');
      }
      return;
    }

    setState(() {
      _isExtracting = true;
      _extractPhase = _ExtractPhase.sending;
    });

    _cancelToken = CancelToken();

    try {
      final aiService = ref.read(aiServiceProvider);
      final roleConfig = await AiRoleService.instance.getEffectiveConfigForRole(
        'timelineOptimization',
      );
      final roleSettings = await AiRoleService.instance.getSettingsForRole(
        'timelineOptimization',
      );
      // 要发图而绑定模型看不了图时，内置识图兜底已下线：明确让用户换模型，
      // 而不是把图片塞给一个看不见画面的模型（它会照常 200 并编造内容）。
      // 能力未知时先自动实测一次：新加的视觉模型不该被默认拦下
      final sendingImage = extractImages && draft.selectedPhotos.isNotEmpty;
      if (sendingImage && !await VisionCapabilityProbe.ensure(roleConfig)) {
        if (mounted) {
          setState(() {
            _isExtracting = false;
            _extractPhase = _ExtractPhase.idle;
          });
          await showVisionUnsupportedDialog(
            context,
            modelName: roleConfig.modelName,
            scene: '快捷记录的图片提取',
          );
        }
        return;
      }
      aiService.updateConfig(
        roleConfig,
        temperature: roleSettings.temperature,
        maxTokens: roleSettings.maxTokens,
      );

      final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
      final schemaStr = formatCompressedSchema(shortcuts);

      final selectedDate = ref.read(selectedDateProvider);
      final draftTime = _calculateStartDateTime(draft, selectedDate);
      final draftEndTime = _calculateEndDateTime(draft, selectedDate);

      // Get user-selected time range
      final selectEvent = ref.read(diaryInputTimeProvider);
      String? userSelectedTimeStr;
      if (selectEvent != null) {
        final baseDate = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
        String formatSingle(DateTime dt) {
          final dtDate = DateTime(dt.year, dt.month, dt.day);
          final offset = dtDate.difference(baseDate).inDays;
          final prefix = offset < 0 ? '-' : '';
          final timeStr = DateFormat('HH:mm').format(dt);
          return '$prefix$timeStr';
        }

        userSelectedTimeStr = formatSingle(draftTime);
        if (draftEndTime != null) {
          userSelectedTimeStr = '$userSelectedTimeStr~${formatSingle(draftEndTime)}';
        }
      }

      final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      final now = DateTime.now();
      final contextMap = <String, dynamic>{
        'today': {
          'date': DateFormat('yyyy-MM-dd').format(now),
          'time': DateFormat('HH:mm').format(now),
          'weekday': weekdays[now.weekday - 1],
        },
        'recordDate': DateFormat('yyyy-MM-dd').format(draftTime),
      };
      if (userSelectedTimeStr != null) {
        contextMap['userSelectedTime'] = userSelectedTimeStr;
      }

      setState(() => _extractPhase = _ExtractPhase.waiting);

      List<Map<String, dynamic>> results;
      final bool shouldSendImage =
          extractImages && draft.selectedPhotos.isNotEmpty;
      String? base64;
      if (shouldSendImage) {
        base64 = await ref
            .read(imageRepositoryProvider)
            .getBase64Image(draft.selectedPhotos.first);
      }

      results = await aiService.extractUnified(
        text: draft.inputText.isNotEmpty ? draft.inputText : null,
        imageBase64: base64,
        mimeType: shouldSendImage ? ImageRepository.getMimeType(draft.selectedPhotos.first) : null,
        schema: schemaStr,
        contextStr: contextMap.toString(),
        cancelToken: _cancelToken,
      );

      if (results.isNotEmpty) {
        final savedDraft = _draft;
        final savedText = _textController.text;

        final newTagEntries = <TagEntry>[];
        String combinedNotes = '';
        TimeOfDay? parsedStartTime;
        TimeOfDay? parsedEndTime;
        int? parsedStartOffset;
        int? parsedEndOffset;

        final firstResult = results.first;
        final firstTime = firstResult['time'];
        if (firstTime == null || (firstTime is Map && firstTime.isEmpty)) {
          // No time extracted at all, preserve user selection!
          parsedStartTime = draft.startTime;
          parsedEndTime = draft.endTime;
          parsedStartOffset = draft.startOffset;
          parsedEndOffset = draft.endOffset;
        } else {
          // Time extracted, use the extracted values (could be null for end time)
          final timeMap = Map<String, dynamic>.from(firstTime as Map);
          if (timeMap['start'] != null) {
            final parts = (timeMap['start'] as String).split(':');
            if (parts.length >= 2) {
              parsedStartTime = TimeOfDay(
                hour: int.tryParse(parts[0]) ?? draft.startTime.hour,
                minute: int.tryParse(parts[1]) ?? draft.startTime.minute,
              );
            }
          }
          if (timeMap['end'] != null) {
            final parts = (timeMap['end'] as String).split(':');
            if (parts.length >= 2) {
              parsedEndTime = TimeOfDay(
                hour: int.tryParse(parts[0]) ?? 0,
                minute: int.tryParse(parts[1]) ?? 0,
              );
            }
          }
          parsedStartOffset = timeMap['startOffset'] as int?;
          parsedEndOffset = timeMap['endOffset'] as int?;
        }

        for (int i = 0; i < results.length; i++) {
          final result = results[i];
          ShortcutConfig? foundShortcut;
          if (result['shortcutId'] != null) {
            foundShortcut = findShortcutById(result['shortcutId'] as String?, shortcuts);
          }

          TimeOfDay? itemTime;
          TimeOfDay? itemEndTime;
          int? itemStartOffset;
          int? itemEndOffset;

          if (result['time'] != null && (result['time'] as Map).isNotEmpty) {
            final timeMap = Map<String, dynamic>.from(result['time'] as Map);
            if (timeMap['start'] != null) {
              final parts = (timeMap['start'] as String).split(':');
              if (parts.length >= 2) {
                itemTime = TimeOfDay(
                  hour: int.tryParse(parts[0]) ?? 0,
                  minute: int.tryParse(parts[1]) ?? 0,
                );
              }
            }
            if (timeMap['end'] != null) {
              final parts = (timeMap['end'] as String).split(':');
              if (parts.length >= 2) {
                itemEndTime = TimeOfDay(
                  hour: int.tryParse(parts[0]) ?? 0,
                  minute: int.tryParse(parts[1]) ?? 0,
                );
              }
            }
            if (timeMap['startOffset'] != null) {
              itemStartOffset = timeMap['startOffset'] as int;
            }
            if (timeMap['endOffset'] != null) {
              itemEndOffset = timeMap['endOffset'] as int;
            }
          }

          final fields = normalizeExtractedFields(
            Map<String, dynamic>.from(result['fields'] as Map? ?? {}),
            foundShortcut,
          );

          if (foundShortcut?.id == 'sleep') {
            double durationHours = 8.0;
            final rawDuration = fields['duration'];
            if (rawDuration != null) {
              final parsed = double.tryParse(rawDuration.toString());
              if (parsed != null && parsed > 0) {
                durationHours = parsed > 24 ? parsed / 60.0 : parsed;
              }
            }

            if (result['time'] == null || (result['time'] as Map).isEmpty) {
              final selectEvent = ref.read(diaryInputTimeProvider);
              if (selectEvent != null) {
                itemTime = draft.startTime;
                itemEndTime = draft.endTime;
                itemStartOffset = draft.startOffset;
                itemEndOffset = draft.endOffset;
              } else {
                itemTime = const TimeOfDay(hour: 22, minute: 30);
                itemStartOffset = -1;
                const startMinutes = 22 * 60 + 30;
                final durationMinutes = (durationHours * 60).toInt();
                final totalMinutes = startMinutes + durationMinutes;
                final endHour = (totalMinutes ~/ 60) % 24;
                final endMinute = totalMinutes % 60;
                final daysOffset = totalMinutes ~/ 1440;
                itemEndTime = TimeOfDay(hour: endHour, minute: endMinute);
                itemEndOffset = -1 + daysOffset;
              }
            } else {
              if (result['time']['start'] == null &&
                  result['time']['end'] != null) {
                final endMin = itemEndTime!.hour * 60 + itemEndTime.minute;
                final durationMinutes = (durationHours * 60).toInt();
                var startMin = endMin - durationMinutes;
                var daysOffset = 0;
                while (startMin < 0) {
                  startMin += 1440;
                  daysOffset -= 1;
                }
                itemTime = TimeOfDay(
                  hour: startMin ~/ 60,
                  minute: startMin % 60,
                );
                itemStartOffset = (itemEndOffset ?? 0) + daysOffset;
              } else if (result['time']['start'] != null &&
                  result['time']['end'] == null) {
                final startMin = itemTime!.hour * 60 + itemTime.minute;
                final durationMinutes = (durationHours * 60).toInt();
                final totalMinutes = startMin + durationMinutes;
                final endHour = (totalMinutes ~/ 60) % 24;
                final endMinute = totalMinutes % 60;
                final daysOffset = totalMinutes ~/ 1440;
                itemEndTime = TimeOfDay(hour: endHour, minute: endMinute);
                itemEndOffset = (itemStartOffset ?? 0) + daysOffset;
              } else if (result['time']['start'] == null &&
                  result['time']['end'] == null) {
                final selectEvent = ref.read(diaryInputTimeProvider);
                if (selectEvent != null) {
                  itemTime = draft.startTime;
                  itemEndTime = draft.endTime;
                  itemStartOffset = draft.startOffset;
                  itemEndOffset = draft.endOffset;
                } else {
                  itemTime = const TimeOfDay(hour: 22, minute: 30);
                  itemStartOffset = -1;
                  const startMinutes = 22 * 60 + 30;
                  final durationMinutes = (durationHours * 60).toInt();
                  final totalMinutes = startMinutes + durationMinutes;
                  final endHour = (totalMinutes ~/ 60) % 24;
                  final endMinute = totalMinutes % 60;
                  final daysOffset = totalMinutes ~/ 1440;
                  itemEndTime = TimeOfDay(hour: endHour, minute: endMinute);
                  itemEndOffset = -1 + daysOffset;
                }
              }
              if (itemStartOffset == null || itemEndOffset == null) {
                if (itemEndTime != null && itemTime != null) {
                  final startMin = itemTime.hour * 60 + itemTime.minute;
                  final endMin = itemEndTime.hour * 60 + itemEndTime.minute;
                  if (endMin < startMin) {
                    itemStartOffset ??= -1;
                    itemEndOffset ??= 0;
                  } else {
                    itemStartOffset ??= 0;
                    itemEndOffset ??= 0;
                  }
                } else {
                  itemStartOffset ??= 0;
                }
              }
            }

            fields['duration'] = durationHours;
            if (itemTime != null) {
              fields['fallAsleepTime'] =
                  '${itemTime.hour.toString().padLeft(2, '0')}:${itemTime.minute.toString().padLeft(2, '0')}';
            }
          }

          String? timeStr;
          if (result['time'] != null) {
            final timeMap = Map<String, dynamic>.from(result['time'] as Map);
            final parts = <String>[];
            if (timeMap['start'] != null) {
              final prefix =
                  timeMap['startOffset'] != null &&
                      (timeMap['startOffset'] as int) < 0
                  ? '-'
                  : '';
              parts.add('$prefix${timeMap['start']}');
            }
            if (timeMap['end'] != null) {
              final prefix =
                  timeMap['endOffset'] != null &&
                      (timeMap['endOffset'] as int) < 0
                  ? '-'
                  : '';
              parts.add('$prefix${timeMap['end']}');
            }
            timeStr = parts.isNotEmpty ? parts.join('~') : null;
          }

          final fallbackShortcut = findShortcutById('other', shortcuts);
          final singleTagEntry = TagEntry(
            id: foundShortcut?.id ?? result['shortcutId'] ?? 'other',
            name: foundShortcut?.name ?? fallbackShortcut?.name ?? '其他',
            fields: fields,
            time: timeStr,
          );
          newTagEntries.add(singleTagEntry);

          if (i == 0 && foundShortcut?.id == 'sleep') {
            parsedStartTime = itemTime;
            parsedEndTime = itemEndTime;
            parsedStartOffset = itemStartOffset;
            parsedEndOffset = itemEndOffset;
          }

          final extractedNotes = result['notes']?.toString();
          if (extractedNotes != null && extractedNotes.isNotEmpty && draft.selectedPhotos.isNotEmpty) {
            if (combinedNotes.isEmpty) {
              combinedNotes = extractedNotes;
            } else if (!combinedNotes.contains(extractedNotes)) {
              combinedNotes += '\n$extractedNotes';
            }
          }
        }

        if (combinedNotes.isNotEmpty && draft.inputText.isNotEmpty) {
          if (combinedNotes.startsWith('图：') ||
              combinedNotes.startsWith('图:')) {
            combinedNotes = '${draft.inputText}\n$combinedNotes';
          } else if (!draft.inputText.contains(combinedNotes)) {
            combinedNotes = '${draft.inputText}\n$combinedNotes';
          } else {
            combinedNotes = draft.inputText;
          }
        } else if (combinedNotes.isEmpty) {
          combinedNotes = draft.inputText;
        }

        final mergedDraft = DiaryComposeDraft(
          id: const Uuid().v4(),
          inputText: combinedNotes,
          selectedPhotos: draft.selectedPhotos,
          startTime: parsedStartTime ?? draft.startTime,
          endTime: parsedEndTime,
          startOffset: parsedStartOffset,
          endOffset: parsedEndOffset,
          tagEntries: newTagEntries,
        );

        setState(() {
          _draft = mergedDraft;
          _textController.text = mergedDraft.inputText;
          _extractPhase = _ExtractPhase.idle;
          _canUndo = true;
          _preExtractDraft = savedDraft;
          _preExtractText = savedText;
          _activeFormTagId = mergedDraft.tagEntries.isNotEmpty
              ? mergedDraft.tagEntries.first.id
              : null;
        });

        _undoController.forward(from: 0);

        final selectedDate = ref.read(selectedDateProvider);
        final targetDate = _calculateStartDateTime(mergedDraft, selectedDate);
        final targetEndDate = mergedDraft.endTime != null
            ? _calculateEndDateTime(mergedDraft, selectedDate)
            : null;
        ref
            .read(diaryInputTimeProvider.notifier)
            .state = TimelineTimeSelectEvent(
          mergedDraft.startTime,
          endTime: mergedDraft.endTime,
          date: targetDate,
          endDate: targetEndDate,
        );
      } else {
        if (mounted) {
          Toast.warning(context, '未提取到信息');
        }
        setState(() {
          _extractPhase = _ExtractPhase.idle;
        });
      }
    } catch (e, stackTrace) {
      if (e is DioException && CancelToken.isCancel(e)) {
        if (mounted) {
          Toast.info(context, '已停止提取');
          setState(() {
            _extractPhase = _ExtractPhase.idle;
          });
        }
        return;
      }

      String errorMessage = '提取失败';

      if (e is DioException) {
        if (e.type == DioExceptionType.connectionError) {
          errorMessage = '网络连接失败，请检查网络配置';
        } else if (e.type == DioExceptionType.connectionTimeout) {
          errorMessage = '连接超时，请重试';
        } else if (e.response?.statusCode == 401) {
          errorMessage = 'API密钥无效，请检查AI配置';
        } else if (e.response?.statusCode == 403) {
          errorMessage = '访问被拒绝，可能是CORS限制或权限问题';
        } else if (e.response?.statusCode == 404) {
          final respStr = e.response?.data?.toString() ?? '';
          if (respStr.contains('model') || respStr.contains('route')) {
            errorMessage = 'AI模型已下线或不存在，请切换模型';
          } else {
            errorMessage = '请求的AI服务地址不存在(404)，请检查Base URL';
          }
        } else if (e.response?.statusCode == 429) {
          errorMessage = 'AI服务调用频次超限，请重试';
        }
      } else if (e is ArgumentError &&
          e.message.toString().contains('apiKey')) {
        errorMessage = 'AI配置不完整，请完善密钥和地址';
      }

      LoggerService.instance.logAI(
        '时间线提取失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );

      if (mounted) {
        Toast.error(context, errorMessage);
      }

      setState(() {
        _extractPhase = _ExtractPhase.error;
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _extractPhase = _ExtractPhase.idle;
          });
        }
      });
    } finally {
      _cancelToken = null;
      setState(() => _isExtracting = false);
    }
  }

  void _undoExtract() {
    if (!_canUndo || _preExtractDraft == null) return;

    _undoController.stop();
    _formControllers.clear();

    final selectedDate = ref.read(selectedDateProvider);
    final restoredDraft = _preExtractDraft!;

    setState(() {
      _draft = restoredDraft;
      _textController.text = _preExtractText ?? '';
      _canUndo = false;
      _preExtractDraft = null;
      _preExtractText = null;
      _activeFormTagId = _draft.tagEntries.isNotEmpty
          ? _draft.tagEntries.first.id
          : null;
    });

    final targetDate = _calculateStartDateTime(restoredDraft, selectedDate);
    final targetEndDate = restoredDraft.endTime != null
        ? _calculateEndDateTime(restoredDraft, selectedDate)
        : null;
    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
      restoredDraft.startTime,
      endTime: restoredDraft.endTime,
      date: targetDate,
      endDate: targetEndDate,
    );
  }

  void _showModelMenu() async {
    FocusScope.of(context).unfocus();
    final displayName = await showTimelineModelSelector(context, ref);
    if (displayName != null && mounted) {
      Toast.success(
        context,
        '已切换：$displayName',
        duration: const Duration(seconds: 1),
      );
    }
  }


  void _removeModelMenuOverlay() {
    _modelMenuOverlay?.remove();
    _modelMenuOverlay = null;
  }

  bool _validateDraft(DiaryComposeDraft draft) {
    for (final entry in draft.tagEntries) {
      if (entry.id == 'consumption' && entry.fields['amount'] == null) {
        Toast.warning(context, '请输入金额');
        return false;
      }
      if (entry.id == 'sleep' && entry.fields['duration'] == null) {
        Toast.warning(context, '请输入睡眠时长');
        return false;
      }
    }
    return true;
  }

  Future<void> _waitForCompressing() async {
    if (_compressingTasks.isEmpty || _waitingForCompression) return;
    _waitingForCompression = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在处理图片...'),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      // 超时兜底：压缩任务若因系统回收 isolate 而永不完成，
      // 不能让不可关闭的弹窗把界面钉死在黑色遮罩上
      await Future.wait(_compressingTasks.values).timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('Error waiting for compression: $e');
    }
    _waitingForCompression = false;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleSend() async {
    if (_isSending) return;
    _isSending = true;
    try {
      await _doHandleSend();
    } finally {
      _isSending = false;
    }
  }

  Future<void> _doHandleSend() async {
    await _waitForCompressing();
    if (!mounted) return;
    final draft = _draft;
    if (!_validateDraft(draft)) return;

    final notifier = ref.read(diaryListProvider.notifier);
    final selectedDate = ref.read(selectedDateProvider);
    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];

    final isEmpty =
        draft.inputText.trim().isEmpty &&
        draft.tagEntries.isEmpty &&
        draft.selectedPhotos.isEmpty;
    if (isEmpty) return;

    final now = DateTime.now();

    // 如果选了固定事件模板，则针对每个模板的每个时间段，分别生成一条日记记录
    if (_selectedFixedEventIds.isNotEmpty) {
      final allTemplates = ref.read(fixedEventListProvider).valueOrNull ?? [];
      final selectedTemplates = allTemplates.where((t) => _selectedFixedEventIds.contains(t.id)).toList();

      // 防重复提交校验：同一天内同一个固定事件只能添加一次
      final allRecords = ref.read(diaryListProvider).valueOrNull ?? [];
      final templatesToAdd = <FixedEventTemplate>[];
      final alreadyAddedTemplates = <FixedEventTemplate>[];

      for (final t in selectedTemplates) {
        if (_isFixedEventAddedOnDate(t, selectedDate, allRecords)) {
          alreadyAddedTemplates.add(t);
        } else {
          templatesToAdd.add(t);
        }
      }

      if (alreadyAddedTemplates.isNotEmpty) {
        final names = alreadyAddedTemplates.map((t) => '「${t.name}」').join('、');
        if (templatesToAdd.isEmpty) {
          Toast.warning(context, '$names 今日已添加');
          setState(() {
            _selectedFixedEventIds.clear();
          });
          return;
        } else {
          Toast.info(context, '$names 今日已添加，已自动跳过');
        }
      }

      final defaultMergedText = templatesToAdd
          .map((t) => t.effectiveContent)
          .where((c) => c.isNotEmpty)
          .join('\n');
      final isUserCustomizedText = draft.inputText.isNotEmpty &&
          draft.inputText.trim() != defaultMergedText.trim();

      // 一个固定事件模板会按时间段展开成多条记录，逐条收集 id 才能让它们都播插入动画
      final insertedIds = <String>[];
      for (final template in templatesToAdd) {
        // 找到与该模板关联的标签在草稿中的 entries
        final templateTagEntries = <TagEntry>[];
        for (final entry in draft.tagEntries) {
          if (template.tags.contains(entry.id)) {
            templateTagEntries.add(entry);
          }
        }

        for (final period in template.timePeriods) {
          final partsStart = period.startTime.split(':');
          final sh = int.tryParse(partsStart[0]) ?? 8;
          final sm = partsStart.length > 1 ? int.tryParse(partsStart[1]) ?? 0 : 0;

          final startDt = DateTime(
            selectedDate.year,
            selectedDate.month,
            selectedDate.day,
            sh,
            sm,
          );

          DateTime? endDt;
          if (!template.isTimePoint && period.endTime.isNotEmpty) {
            final partsEnd = period.endTime.split(':');
            final eh = int.tryParse(partsEnd[0]) ?? 12;
            final em = partsEnd.length > 1 ? int.tryParse(partsEnd[1]) ?? 0 : 0;
            endDt = DateTime(
              selectedDate.year,
              selectedDate.month,
              selectedDate.day,
              eh,
              em,
            );
            if (endDt.isBefore(startDt)) {
              endDt = endDt.add(const Duration(days: 1));
            }
          }

          // 同步标签 entries 里的时长/时间等参数
          final syncedTagEntries = templateTagEntries.map((e) {
            final fields = Map<String, dynamic>.from(e.fields);
            if (e.id == 'sleep') {
              fields['fallAsleepTime'] = period.startTime;
              if (endDt != null) {
                final diffMin = endDt.difference(startDt).inMinutes;
                fields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
              } else {
                fields.remove('duration');
              }
            } else if (e.id == 'activity') {
              if (endDt != null) {
                final diffMin = endDt.difference(startDt).inMinutes;
                fields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
              } else {
                fields.remove('duration');
              }
            }

            int? endH;
            int? endM;
            int endOff = 0;
            if (endDt != null) {
              endH = endDt.hour;
              endM = endDt.minute;
              endOff = endDt.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays;
            }
            final startOff = startDt.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays;

            final updated = e.copyWith(
              fields: fields,
              startHour: sh,
              startMinute: sm,
              startOffset: startOff,
              endHour: endH,
              endMinute: endM,
              endOffset: endOff,
              clearEndTime: endDt == null,
            );
            return updated.copyWith(time: updated.formattedTime);
          }).toList();

          // 组织记录内容
          final popupEntries = <TagEntry>[];
          final popupConfigs = <ShortcutConfig>[];
          for (final entry in syncedTagEntries) {
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

          String recordContent = '';
          if (popupEntries.isNotEmpty) {
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
                  .where((s) => s != null)
                  .join('，');
              final fullDetails = categoryPrefix.isNotEmpty ? '$categoryPrefix$details' : details;
              if (fullDetails.isNotEmpty) detailParts.add(fullDetails);
            }
            final allDetails = detailParts.join('；');

            // 备注：若用户手动编辑了输入框文字则以输入为准，否则使用模板备注（若未填则默认使用标题名称）
            final baseText = isUserCustomizedText
                ? draft.inputText
                : template.effectiveContent;
            recordContent = '$allDetails${baseText.isNotEmpty ? '\n备注：$baseText' : ''}';
          } else {
            recordContent = isUserCustomizedText
                ? draft.inputText
                : template.effectiveContent;
          }

          final recordTags = template.tags.isNotEmpty
              ? template.tags
                  .map((tid) => shortcuts
                      .where((s) => s.id == tid)
                      .firstOrNull
                      ?.name ??
                      tid)
                  .toList()
              : <String>[];

          Map<String, dynamic> recordBodyState = {};
          if (syncedTagEntries.isNotEmpty) {
            recordBodyState = Map<String, dynamic>.from(syncedTagEntries.first.fields);
          }
          // 标记固定事件模板元信息，方便精准识别与排重
          recordBodyState['fixed_event_id'] = template.id;
          recordBodyState['fixed_event_name'] = template.name;

          final record = DiaryRecord(
            id: const Uuid().v4(),
            title: template.name,
            time: startDt,
            startTime: startDt,
            endTime: endDt,
            tags: recordTags,
            displayTag: recordTags.isNotEmpty ? recordTags.first : template.name,
            content: recordContent,
            bodyState: recordBodyState,
            tagEntries: syncedTagEntries,
            photos: draft.selectedPhotos.isNotEmpty ? draft.selectedPhotos : [],
            createdAt: now,
            updatedAt: now,
          );

          final saved = await notifier.addDiary(
            title: record.title,
            content: record.content,
            tags: record.tags,
            time: record.time,
            startTime: record.startTime,
            endTime: record.endTime,
            displayTag: record.displayTag,
            bodyState: record.bodyState,
            tagEntries: record.tagEntries,
            photos: record.photos,
          );
          // 必须用落库后返回的 id：addDiary 内部会重新生成 id，
          // 拿本地 record.id 去播报，页面永远匹配不到那条卡片。
          insertedIds.add(saved.id);
        }
      }

      ref.read(diaryInputTimeProvider.notifier).state = null;
      ref.read(currentInputTimeProvider.notifier).state = TimeOfDay.now();
      _undoController.stop();
      _resetDraftState();
      _announceInserted(insertedIds);
      await _showSavedFeedbackAndPop();
      return;
    }

    final selectEvent = ref.read(diaryInputTimeProvider);
    final TimeOfDay eventTime = selectEvent == null
        ? TimeOfDay.now()
        : draft.startTime;

    var startDateTime = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      eventTime.hour,
      eventTime.minute,
    );
    if (draft.startOffset != null) {
      startDateTime = startDateTime.add(Duration(days: draft.startOffset!));
    }

    var endDateTime = _calculateEndDateTime(draft, selectedDate);

    final sleepEntry = draft.tagEntries
        .where((e) => e.id == 'sleep')
        .firstOrNull;
    if (sleepEntry != null) {
      final durationVal = sleepEntry.fields['duration'];
      if (durationVal != null) {
        final double? durationHours = double.tryParse(durationVal.toString());
        if (durationHours != null) {
          endDateTime = startDateTime.add(
            Duration(minutes: (durationHours * 60).toInt()),
          );
        }
      }
    }

    String content = '';
    List<String> tags = [];
    Map<String, dynamic>? bodyState;
    final List<TagEntry> tagEntries = List.from(draft.tagEntries);

    // Sync sleep tag time with draft time if present
    final sleepIndex = tagEntries.indexWhere((e) => e.id == 'sleep' || e.name == '睡眠');
    if (sleepIndex != -1) {
      final sleepEntryItem = tagEntries[sleepIndex];
      // Only sync if sleep tag has time or user explicitly selected a record time
      if (sleepEntryItem.hasTime || ref.read(diaryInputTimeProvider) != null) {
        int? endHour;
        int? endMinute;
        int? endOffset;
        if (draft.endTime != null) {
          endHour = draft.endTime!.hour;
          endMinute = draft.endTime!.minute;
          endOffset = draft.endOffset ?? 0;
        }
        
        final updatedSleep = sleepEntryItem.copyWith(
          startHour: draft.startTime.hour,
          startMinute: draft.startTime.minute,
          startOffset: draft.startOffset ?? 0,
          endHour: endHour,
          endMinute: endMinute,
          endOffset: endOffset,
          clearEndTime: draft.endTime == null,
        );
        tagEntries[sleepIndex] = updatedSleep.copyWith(time: updatedSleep.formattedTime);
      }
    } else if (tagEntries.length == 1) {
      // 单标签场景：若标签自带时间（如AI提取或用户设置过时分），同步草稿中的起止时分，保持模型与记录一致
      final singleEntry = tagEntries.first;
      if (singleEntry.hasTime || draft.endTime != null || ref.read(diaryInputTimeProvider) != null) {
        int? endHour;
        int? endMinute;
        int? endOffset;
        if (draft.endTime != null) {
          endHour = draft.endTime!.hour;
          endMinute = draft.endTime!.minute;
          endOffset = draft.endOffset ?? 0;
        }
        
        final updatedSingle = singleEntry.copyWith(
          startHour: draft.startTime.hour,
          startMinute: draft.startTime.minute,
          startOffset: draft.startOffset ?? 0,
          endHour: endHour,
          endMinute: endMinute,
          endOffset: endOffset,
          clearEndTime: draft.endTime == null,
        );
        tagEntries[0] = updatedSingle.copyWith(time: updatedSingle.formattedTime);
      }
    }

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

    if (popupEntries.isNotEmpty) {
      final detailParts = <String>[];

      for (int pi = 0; pi < popupEntries.length; pi++) {
        final entry = popupEntries[pi];
        final config = popupConfigs[pi];

        List<ShortcutField> fieldsToProcess = config.fields;
        final Map<String, dynamic> entryFields = Map<String, dynamic>.from(
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
            .where((s) => s != null)
            .join('，');

        final fullDetails = categoryPrefix.isNotEmpty
            ? '$categoryPrefix$details'
            : details;
        if (fullDetails.isNotEmpty) detailParts.add(fullDetails);

        if (config.id == 'health') {
          final symptomVal = entryFields['symptom'];
          String symptomName;
          if (symptomVal is List && symptomVal.isNotEmpty) {
            symptomName = symptomVal.join('、');
          } else if (symptomVal != null && symptomVal.toString().isNotEmpty) {
            symptomName = symptomVal.toString();
          } else {
            symptomName = '不适';
          }
          bodyState = {
            'name': symptomName,
            'severity': entryFields['severity'] ?? '轻微',
            'medication': entryFields['medication'],
            'notes': draft.inputText,
          };
        } else {
          bodyState ??= entryFields;
        }
      }

      final allDetails = detailParts.join('；');
      content =
          '$allDetails${draft.inputText.isNotEmpty ? '\n备注：${draft.inputText}' : ''}';
    } else {
      content = draft.inputText;
    }

    if (tagEntries.isNotEmpty) {
      tags = tagEntries.map((e) => e.name).toList();
      bodyState ??= Map<String, dynamic>.from(tagEntries.first.fields);
    }

    final record = DiaryRecord(
      id: const Uuid().v4(),
      title: tags.isNotEmpty ? tags.first : '记录',
      time: startDateTime,
      startTime: startDateTime,
      endTime: endDateTime,
      tags: tags,
      displayTag: tags.isNotEmpty ? tags.first : '记录',
      content: content,
      bodyState: bodyState,
      tagEntries: tagEntries,
      photos: draft.selectedPhotos.isNotEmpty ? draft.selectedPhotos : [],
      createdAt: now,
      updatedAt: now,
    );

    final saved = await notifier.addDiary(
      title: record.title,
      content: record.content,
      tags: record.tags,
      time: record.time,
      startTime: record.startTime,
      endTime: record.endTime,
      displayTag: record.displayTag,
      bodyState: record.bodyState,
      tagEntries: record.tagEntries,
      photos: record.photos,
    );

    ref.read(diaryInputTimeProvider.notifier).state = null;
    ref.read(currentInputTimeProvider.notifier).state = TimeOfDay.now();
    _undoController.stop();
    _resetDraftState();

    // 页面趁 ✓ 还在播的时候把时间线滚到新记录并量好卡片 Rect；
    // 拿得到目标就让面板本身飞过去，拿不到就退回原来的插入动画。
    final morphFuture = widget.onSaved == null
        ? null
        : widget.onSaved!(<String>[saved.id]);
    _beginSavedFeedback();

    RecordCardMorphTarget? morph;
    if (morphFuture != null) {
      morph = await morphFuture;
    }
    if (!mounted) return;

    if (morph == null) {
      // 使用新记录的显示时间（可能为 startTime 或 endTime），保证精准滚到新事件位置
      ref.read(diaryScrollToTimeProvider.notifier).state = record.getDisplayTime();
      _announceInserted(<String>[saved.id]);
    }

    await Future<void>.delayed(_savedFeedbackDuration);
    if (!mounted) return;

    if (morph != null) {
      final route = ModalRoute.of(context);
      if (route is _RecordDialogRoute && route.startCardMorph(morph)) {
        // 路由会在盖板落位后自己 pop，这里不能再 pop
        return;
      }
      // 路由不支持飞行（理论上不会发生）：补一次插入信号，按普通路径收尾。
      _announceInserted(<String>[saved.id]);
    }

    Navigator.of(context).maybePop();
    // 兜底：万一 pop 没生效（比如宿主把面板换成了别的关闭方式），
    // ✓ 不能永远挂在按钮上。
    if (mounted) {
      setState(() => _savedOk = false);
    }
  }

  /// 保存成功后清空草稿：Provider 里的那份也要清，否则下次打开面板会「复活」已保存的内容。
  void _resetDraftState() {
    ref.read(diaryComposeDraftProvider.notifier).reset();
    setState(() {
      _draft = DiaryComposeDraft(id: const Uuid().v4(), startTime: TimeOfDay.now());
      _textController.text = '';
      _canUndo = false;
      _preExtractDraft = null;
      _preExtractText = null;
      _activeFormTagId = null;
      _selectedFixedEventIds.clear();
    });
  }

  /// 保存成功的即时反馈：收起键盘，在发送键上亮 ✓。
  void _beginSavedFeedback() {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() => _savedOk = true);
  }

  /// 没有「弹窗变卡片」目标时的收尾：✓ 播完再收起面板。
  ///
  /// 页面侧 `_kInsertRevealDelay`（440ms）与它对齐：320ms 的 ✓ + 180ms 退场，
  /// 新卡片会在面板完全消失前 60ms 开始升起，形成一次交接。走「飞向卡片」时
  /// 由路由在盖板落位后自己 pop，不经过这里。
  Future<void> _showSavedFeedbackAndPop() async {
    _beginSavedFeedback();
    await Future<void>.delayed(_savedFeedbackDuration);
    if (!mounted) {
      return;
    }
    Navigator.of(context).maybePop();
    // 兜底：万一 pop 没生效（比如宿主把面板换成了别的关闭方式），
    // ✓ 不能永远挂在按钮上。
    if (mounted) {
      setState(() => _savedOk = false);
    }
  }

  /// 把刚写下的记录 id 交给时间线，让新卡片播一次入场动画。
  void _announceInserted(List<String> recordIds) {
    if (recordIds.isEmpty) {
      return;
    }
    ref.read(diaryJustInsertedProvider.notifier).state = recordIds;
  }

  DateTime _calculateStartDateTime(DiaryComposeDraft draft, DateTime selectedDate) {
    var start = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      draft.startTime.hour,
      draft.startTime.minute,
    );
    if (draft.startOffset != null) {
      start = start.add(Duration(days: draft.startOffset!));
    }
    return start;
  }

  DateTime? _calculateEndDateTime(DiaryComposeDraft draft, DateTime selectedDate) {
    if (draft.endTime == null) return null;
    var end = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      draft.endTime!.hour,
      draft.endTime!.minute,
    );
    if (draft.endOffset != null) {
      end = end.add(Duration(days: draft.endOffset!));
    }
    return end;
  }

  /// 时间胶囊上的时间文案。
  ///
  /// 时间线顶部已经显示当前选中的日期，所以同一天时只写时分；
  /// 只有跨天补记（offset ≠ 0）才补上月-日，避免把「11-11 09:58」这种冗余前缀
  /// 塞进头部最显眼的位置。
  String _formatTime(DateTime selectedDate, TimeOfDay time, {int? offset}) {
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    if (offset == null || offset == 0) {
      return timeStr;
    }
    final date = selectedDate.add(Duration(days: offset));
    return '${DateFormat('MM-dd').format(date)} $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final selectedDate = ref.watch(selectedDateProvider);

    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      if (previous != null &&
          (previous.year != next.year ||
              previous.month != next.month ||
              previous.day != next.day)) {
        if (_selectedFixedEventIds.isNotEmpty) {
          final allRecords = ref.read(diaryListProvider).valueOrNull ?? [];
          final allTemplates = ref.read(fixedEventListProvider).valueOrNull ?? [];
          final toRemove = <String>[];
          for (final id in _selectedFixedEventIds) {
            final template = allTemplates.where((t) => t.id == id).firstOrNull;
            if (template != null && _isFixedEventAddedOnDate(template, next, allRecords)) {
              toRemove.add(id);
            }
          }
          if (toRemove.isNotEmpty) {
            setState(() {
              _selectedFixedEventIds.removeWhere((id) => toRemove.contains(id));
            });
            _applyFixedEventsSelection(
              allTemplates,
              List<TagEntry>.from(_activeDraft.tagEntries),
            );
          }
        }
      }
    });
    ref.listen<TimelineTimeSelectEvent?>(diaryInputTimeProvider, (
      previous,
      next,
    ) {
      if (next != null) {
        // 与面板打开时的对齐走同一个换算，避免「开着面板调时间」和
        // 「关着面板选好再打开」两条路径给出不同的跨天偏移。
        final aligned = _draftWithSelection(
          _draft,
          next,
          selectedDate: ref.read(selectedDateProvider),
        );
        _updateActiveDraft(
          startTime: aligned.startTime,
          endTime: aligned.endTime,
          clearEndTime: next.endTime == null,
          startOffset: aligned.startOffset,
          endOffset: aligned.endOffset,
          clearStartOffset: false,
          clearEndOffset: next.endTime == null,
        );
      } else {
        _updateActiveDraft(
          startTime: TimeOfDay.now(),
          clearEndTime: true,
          clearStartOffset: true,
          clearEndOffset: true,
        );
      }
    });

    final theme = Theme.of(context);
    final shortcuts = ref.watch(shortcutListProvider);

    return _SheetSurface(
      surfaceKey: widget.surfaceKey,
      child: _buildSheetContent(theme, shortcuts, selectedDate),
    );
  }

  /// 卡片内容：头部（时间 + 关闭）→ 标签 → 固定事件/字段 → 附件与 AI → 正文与发送。
  ///
  /// 只有中间那段跟着内容滚：时间、关闭、输入和发送始终钉在卡片里。
  /// 键盘把卡片压矮时先让字段表单让位，发送键不会被挤出屏幕。
  Widget _buildSheetContent(
    ThemeData theme,
    AsyncValue<List<ShortcutConfig>> shortcuts,
    DateTime selectedDate,
  ) {
    final fixedEvents = ref.watch(fixedEventListProvider);
    final allRecords = ref.watch(diaryListProvider).valueOrNull ?? [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Reveal(
          controller: _entryController,
          begin: 0,
          child: _buildHeader(theme, selectedDate),
        ),
        _Reveal(
          controller: _entryController,
          begin: 0.08,
          child: _buildShortcutRow(theme, shortcuts),
        ),
        Flexible(
          child: _Reveal(
            controller: _entryController,
            begin: 0.16,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildFixedEventRow(theme, fixedEvents, selectedDate, allRecords),
                  _buildFormFieldsArea(theme),
                ],
              ),
            ),
          ),
        ),
        _Reveal(
          controller: _entryController,
          begin: 0.24,
          child: _buildMediaRow(theme),
        ),
        if (_activeDraft.selectedPhotos.isNotEmpty)
          _Reveal(
            controller: _entryController,
            begin: 0.24,
            child: _buildPhotoPreview(theme),
          ),
        _Reveal(
          controller: _entryController,
          begin: 0.32,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: _buildInputAndActions(theme),
          ),
        ),
      ],
    );
  }

  /// 头部：时间胶囊组在左，圆形关闭键在右。
  ///
  /// 时间是这条记录的锚点，给最大的字号和实心底色；保存动作已经交给输入行末尾的
  /// 发送键，这里只留「退出」，不再和发送键抢决策。
  Widget _buildHeader(ThemeData theme, DateTime selectedDate) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
      child: Row(
        children: [
          Expanded(child: _buildTimeRangeEditor(theme, selectedDate)),
          const SizedBox(width: 10),
          _buildCloseButton(theme),
        ],
      ),
    );
  }

  Widget _buildCloseButton(ThemeData theme) {
    return Semantics(
      button: true,
      label: '关闭',
      child: GestureDetector(
        onTap: _isSending ? null : () => Navigator.of(context).maybePop(),
        behavior: HitTestBehavior.opaque,
        child: Container(
          key: const ValueKey('record-close'),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.close_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 发送键的可用性：必填校验 + 草稿是否为空 + 图片是否还在压缩。
  bool get _isSaveDisabled {
    final draft = _activeDraft;
    final consumptionEntry = draft.tagEntries
        .where((e) => e.id == 'consumption')
        .firstOrNull;
    final sleepEntry = draft.tagEntries
        .where((e) => e.id == 'sleep')
        .firstOrNull;
    final isValidationError =
        (consumptionEntry != null &&
            consumptionEntry.fields['amount'] == null) ||
        (sleepEntry != null && sleepEntry.fields['duration'] == null);
    return isValidationError || draft.isEmpty || _compressingTasks.isNotEmpty;
  }

  Future<void> _editInputBarTagTime(TagEntry entry) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EditTagTimeSheet(entry: entry),
    );

    if (result != null) {
      final currentEntries = List<TagEntry>.from(_activeDraft.tagEntries);
      final newEntries = currentEntries.map((e) {
        if (e.id == entry.id || e.name == entry.name) {
          if (result['clear'] == true) {
            final updatedFields = Map<String, dynamic>.from(e.fields);
            if (e.id == 'sleep' || e.name == '睡眠') {
              updatedFields.remove('fallAsleepTime');
              updatedFields.remove('duration');
              _updateActiveDraft(
                clearEndTime: true,
              );
            }
            return e.copyWith(
              clearStartTime: true,
              clearEndTime: true,
              fields: updatedFields,
            );
          }

          final startHour = result['startHour'] as int?;
          final startMinute = result['startMinute'] as int?;
          final startOffset = result['startOffset'] as int?;
          final endHour = result['endHour'] as int?;
          final endMinute = result['endMinute'] as int?;
          final endOffset = result['endOffset'] as int?;

          final Map<String, dynamic> updatedFields = Map<String, dynamic>.from(e.fields);
          if (e.id == 'sleep' || e.name == '睡眠') {
            if (startHour != null && startMinute != null) {
              updatedFields['fallAsleepTime'] =
                  '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}';
              
              final startDt = TimeOfDay(hour: startHour, minute: startMinute);

              if (endHour != null && endMinute != null) {
                final endDt = TimeOfDay(hour: endHour, minute: endMinute);
                final startMin = startHour * 60 + startMinute;
                final endMin = endHour * 60 + endMinute;
                var diffMin = endMin - startMin;
                if (diffMin < 0 || endOffset == 1) {
                  diffMin += 1440;
                }
                final newDuration = (diffMin / 60.0 * 10).round() / 10.0;
                updatedFields['duration'] = newDuration.toStringAsFixed(1);
                
                _updateActiveDraft(
                  startTime: startDt,
                  endTime: endDt,
                  startOffset: startOffset,
                  endOffset: endOffset,
                );
              } else {
                updatedFields.remove('duration');
                _updateActiveDraft(
                  startTime: startDt,
                  clearEndTime: true,
                  startOffset: startOffset,
                  endOffset: 0,
                );
              }
            }
          }

          return e.copyWith(
            fields: updatedFields,
            startHour: startHour,
            startMinute: startMinute,
            startOffset: startOffset,
            endHour: endHour,
            endMinute: endMinute,
            endOffset: endOffset,
            clearEndTime: endHour == null,
          );
        }
        return e;
      }).toList();

      _updateActiveDraft(tagEntries: newEntries);
    }
  }

  /// 构建固定事件按钮行
  Widget _buildFixedEventRow(
    ThemeData theme,
    AsyncValue<List<FixedEventTemplate>> fixedEvents,
    DateTime selectedDate,
    List<DiaryRecord> allRecords,
  ) {
    return fixedEvents.when(
      data: (templates) {
        if (templates.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: templates.map((template) {
                      final isAddedToday = _isFixedEventAddedOnDate(template, selectedDate, allRecords);
                      final isSelected = _selectedFixedEventIds.contains(template.id) && !isAddedToday;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => _selectFixedEvent(template),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeInOut,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? theme.colorScheme.primary
                                  : isAddedToday
                                      ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
                                      : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected
                                    ? Colors.transparent
                                    : isAddedToday
                                        ? theme.colorScheme.outlineVariant.withValues(alpha: 0.3)
                                        : theme.colorScheme.outlineVariant,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : isAddedToday
                                          ? Icons.check_circle_outlined
                                          : Icons.schedule,
                                  size: 12,
                                  color: isSelected
                                      ? theme.colorScheme.onPrimary
                                      : isAddedToday
                                          ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
                                          : theme.colorScheme.onSurface,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  template.name,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: isSelected
                                        ? theme.colorScheme.onPrimary
                                        : isAddedToday
                                            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
                                            : theme.colorScheme.onSurface,
                                  ),
                                ),
                                if (isAddedToday) ...[
                                  const SizedBox(width: 3),
                                  Text(
                                    '已添加',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontSize: 9,
                                      fontWeight: FontWeight.normal,
                                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildFormFieldsArea(ThemeData theme) {
    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
    final visibleEntries = <MapEntry<TagEntry, ShortcutConfig?>>[];

    for (final entry in _activeDraft.tagEntries) {
      final config = shortcuts.where(
        (s) => s.id == entry.id || s.name == entry.name,
      ).firstOrNull;
      visibleEntries.add(MapEntry(entry, config));
    }

    if (visibleEntries.isEmpty) return const SizedBox.shrink();

    // 外层已经是滚动区，这里不能再套 scroll + 限高：手机上会变成里外两层都能滚，
    // 手指落在表单上时不知道该滚哪一个。
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: visibleEntries.map((pair) {
            return _buildTagFormSection(theme, pair.value, pair.key);
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildTagFormSection(
    ThemeData theme,
    ShortcutConfig? config,
    TagEntry entry,
  ) {
    final colorScheme = theme.colorScheme;
    final hasFields = config != null && config.hasPopup;
    List<ShortcutField> fieldsToProcess = config?.fields ?? [];
    if (config != null && config.categories != null && config.categories!.isNotEmpty) {
      final currentCategory = config.categories!.firstWhere(
        (c) => c.id == entry.fields['_category'],
        orElse: () => config.categories!.first,
      );
      fieldsToProcess = currentCategory.fields;
    }

    final tagName = config?.name ?? entry.name;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    tagName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _editInputBarTagTime(entry),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.access_time,
                          size: 11,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          entry.hasTime ? entry.displayTime! : '添加时间',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                        if (entry.hasTime) ...[
                          const SizedBox(width: 2),
                          Icon(
                            Icons.edit,
                            size: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    if (config != null) {
                      _selectShortcut(config);
                    } else {
                      final currentEntries = List<TagEntry>.from(_activeDraft.tagEntries);
                      currentEntries.removeWhere((e) => e.name == entry.name);
                      _updateActiveDraft(tagEntries: currentEntries);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (hasFields) ...[
              const SizedBox(height: 8),
              if (config.categories != null && config.categories!.isNotEmpty)
                _buildCategorySelector(theme, config, entry.id),
              ...fieldsToProcess.map(
                (field) => _buildFieldWidget(theme, field, entry.id),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategorySelector(
    ThemeData theme,
    ShortcutConfig config,
    String tagId,
  ) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: config.categories!.map((category) {
            final isSelected =
                (formValues['_category'] ?? config.categories!.first.id) ==
                category.id;
            return Expanded(
              child: GestureDetector(
                onTap: () =>
                    _updateFormValue('_category', category.id, tagId: tagId),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? theme.colorScheme.surface : null,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 4,
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    category.name,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFieldWidget(ThemeData theme, ShortcutField field, String tagId) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              field.label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          ),
          _buildFieldInput(theme, field, tagId),
        ],
      ),
    );
  }

  Widget _buildFieldInput(ThemeData theme, ShortcutField field, String tagId) {
    switch (field.type) {
      case 'select':
        return _buildSelectChips(theme, field, tagId);
      case 'multi-select':
        return _buildMultiSelectChips(theme, field, tagId);
      case 'input':
        return _buildTextField(theme, field, tagId);
      case 'number':
        return _buildNumberField(theme, field, tagId);
      case 'time':
        return _buildTimeField(theme, field, tagId);
      case 'water-amount':
        return _buildWaterAmountField(theme, field, tagId);
      default:
        return _buildTextField(theme, field, tagId);
    }
  }

  Widget _buildSelectChips(ThemeData theme, ShortcutField field, String tagId) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    final currentValue = formValues[field.id];
    final isCustomValue = currentValue != null &&
        currentValue is String &&
        !field.options.contains(currentValue);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ...field.options.map((opt) {
              final isSelected = currentValue == opt;
              return GestureDetector(
                onTap: () => _updateFormValue(
                    field.id, isSelected ? null : opt,
                    tagId: tagId),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    opt,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              );
            }),
            if (isCustomValue)
              GestureDetector(
                onTap: () =>
                    _updateFormValue(field.id, null, tagId: tagId),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        currentValue,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onTertiary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.close,
                        size: 14,
                        color: theme.colorScheme.onTertiary,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (field.allowCustom) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: TextField(
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.3),
                hintText: '自定义...',
                hintStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                isDense: true,
              ),
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  _updateFormValue(field.id, val.trim(), tagId: tagId);
                }
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMultiSelectChips(
    ThemeData theme,
    ShortcutField field,
    String tagId,
  ) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    final currentList = (formValues[field.id] as List?)?.cast<String>() ?? [];
    final customValues =
        currentList.where((v) => !field.options.contains(v)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ...field.options.map((opt) {
              final isSelected = currentList.contains(opt);
              return GestureDetector(
                onTap: () {
                  final newList = List<String>.from(currentList);
                  if (isSelected) {
                    newList.remove(opt);
                  } else {
                    newList.add(opt);
                  }
                  _updateFormValue(
                    field.id,
                    newList.isEmpty ? null : newList,
                    tagId: tagId,
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    opt,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: isSelected
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              );
            }),
            ...customValues.map((val) {
              return GestureDetector(
                onTap: () {
                  final newList = List<String>.from(currentList);
                  newList.remove(val);
                  _updateFormValue(
                    field.id,
                    newList.isEmpty ? null : newList,
                    tagId: tagId,
                  );
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        val,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onTertiary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.close,
                        size: 14,
                        color: theme.colorScheme.onTertiary,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
        if (field.allowCustom) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: TextField(
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.3),
                hintText: '自定义（回车添加）...',
                hintStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                isDense: true,
              ),
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  final newList = List<String>.from(currentList);
                  for (final item in val.trim().split(RegExp(r'[,，、]'))) {
                    final trimmed = item.trim();
                    if (trimmed.isNotEmpty && !newList.contains(trimmed)) {
                      newList.add(trimmed);
                    }
                  }
                  _updateFormValue(
                    field.id,
                    newList.isEmpty ? null : newList,
                    tagId: tagId,
                  );
                }
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTextField(ThemeData theme, ShortcutField field, String tagId) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    final currentValue = formValues[field.id]?.toString() ?? '';
    final controller = _getFormController(field.id, currentValue, tagId: tagId);
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest,
          hintText: '请输入${field.label}...',
          hintStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          isDense: true,
        ),
        onChanged: (val) =>
            _updateFormValue(field.id, val.isEmpty ? null : val, tagId: tagId),
      ),
    );
  }

  Widget _buildNumberField(ThemeData theme, ShortcutField field, String tagId) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    final currentValue = formValues[field.id]?.toString() ?? '';
    final controller = _getFormController(field.id, currentValue, tagId: tagId);
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(),
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest,
          hintText: '请输入${field.label}...',
          hintStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          isDense: true,
        ),
        onChanged: (val) =>
            _updateFormValue(field.id, val.isEmpty ? null : val, tagId: tagId),
      ),
    );
  }

  Widget _buildTimeField(ThemeData theme, ShortcutField field, String tagId) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    final currentValue = formValues[field.id] as String?;
    final isSleepTime = field.id == 'fallAsleepTime';

    final timeButton = GestureDetector(
      onTap: () async {
        int hour = 0, minute = 0;
        if (currentValue != null) {
          final parts = currentValue.split(':');
          if (parts.length >= 2) {
            hour = int.tryParse(parts[0]) ?? 0;
            minute = int.tryParse(parts[1]) ?? 0;
          }
        }
        final result = await showTimeScrollPicker(
          context: context,
          initialHour: hour,
          initialMinute: minute,
        );
        if (result != null) {
          _updateFormValue(
            field.id,
            '${result.hour.toString().padLeft(2, '0')}:${result.minute.toString().padLeft(2, '0')}',
            tagId: tagId,
          );
        }
      },
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.access_time, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              currentValue ?? '选择${field.label}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: currentValue != null
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );

    if (isSleepTime) {
      final currentOffset = _activeDraft.startOffset ?? 0;
      return Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDayTab(theme, '昨天', -1, currentOffset == -1),
              const SizedBox(width: 4),
              _buildDayTab(theme, '今天', 0, currentOffset == 0),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(child: timeButton),
        ],
      );
    }

    return timeButton;
  }

  Widget _buildDayTab(
    ThemeData theme,
    String label,
    int value,
    bool isSelected,
  ) {
    return GestureDetector(
      onTap: () {
        _updateActiveDraft(startOffset: value);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.3)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildWaterAmountField(
    ThemeData theme,
    ShortcutField field,
    String tagId,
  ) {
    final formValues = _activeDraft.getFormValuesFor(tagId);
    final currentValue = (formValues[field.id] as int?) ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              '${currentValue}ml',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: currentValue > 0
                  ? () => _updateFormValue(
                      field.id,
                      currentValue - 100,
                      tagId: tagId,
                    )
                  : null,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            IconButton(
              onPressed: currentValue < 2000
                  ? () => _updateFormValue(
                      field.id,
                      currentValue + 100,
                      tagId: tagId,
                    )
                  : null,
              icon: const Icon(Icons.add_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        Slider(
          value: currentValue.toDouble(),
          min: 0,
          max: 2000,
          divisions: 20,
          onChanged: (val) =>
              _updateFormValue(field.id, val.toInt(), tagId: tagId),
        ),
      ],
    );
  }

  Widget _buildShortcutRow(
    ThemeData theme,
    AsyncValue<List<ShortcutConfig>> shortcuts,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: _shortcutScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: shortcuts.when(
                  data: (list) => list.where((s) => s.isVisible).map<Widget>((config) {
                    final isSelected = _activeDraft.tagEntries.any(
                      (e) => e.id == config.id,
                    );
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => _selectShortcut(config),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          height: 32,
                          constraints: const BoxConstraints(minWidth: 32),
                          padding: EdgeInsets.symmetric(
                            horizontal: isSelected ? 12 : 0,
                          ),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.transparent
                                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _getShortcutIcon(config.name),
                                  size: 16,
                                  color: isSelected
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                                if (isSelected) const SizedBox(width: 4),
                                if (isSelected)
                                  Text(
                                    config.name,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.onPrimary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                  loading: () => <Widget>[
                    const SizedBox(
                      width: 60,
                      height: 32,
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  ],
                  error: (_, _) => <Widget>[],
                ),
              ),
            ),
          ),
          // 「更多字段」开关已撤掉：固定事件与标签字段现在常驻在下方滚动区，
          // 不再有需要主动展开的第二级。
        ],
      ),
    );
  }

  IconData _getShortcutIcon(String name) {
    switch (name) {
      case '睡眠':
        return Icons.bedtime_outlined;
      case '饮食':
        return Icons.restaurant_menu_outlined;
      case '活动':
        return Icons.bolt_rounded;
      case '健康':
        return Icons.favorite_outline;
      case '记账':
        return Icons.wallet_rounded;
      default:
        return Icons.apps;
    }
  }

  /// 时间编辑组：开始时间胶囊、结束时间胶囊（或「+ 结束时间」）。
  ///
  /// 用内容宽而不是等分半行：两个时间都很短，等分会把它们撑成两条大色块，
  /// 和下面的标签、附件钮不成比例，也把「关闭」挤到很远的地方。
  /// 跨天补记会带上 MM-dd 前缀，宽度不够时这一行自己横向滚动，不会溢出。
  Widget _buildTimeRangeEditor(ThemeData theme, DateTime selectedDate) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTimePill(
            theme,
            onTap: _pickStartTime,
            label: _formatTime(
              selectedDate,
              _activeDraft.startTime,
              offset: _activeDraft.startOffset,
            ),
          ),
          if (_activeDraft.endTime != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '–',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _buildTimePill(
              theme,
              onTap: _pickEndTime,
              onClear: _clearEndTime,
              label: _formatTime(
                selectedDate,
                _activeDraft.endTime!,
                offset: _activeDraft.endOffset,
              ),
            ),
          ] else ...[
            const SizedBox(width: 8),
            _buildAddEndPill(theme),
          ],
        ],
      ),
    );
  }

  /// 时间药丸。传 [onClear] 时右侧多一个 ×，用来取消结束时间。
  Widget _buildTimePill(
    ThemeData theme, {
    required VoidCallback onTap,
    required String label,
    VoidCallback? onClear,
  }) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: EdgeInsets.only(left: 12, right: onClear == null ? 12 : 2),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.access_time_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 5),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
                // 等宽数字：调时间时胶囊宽度不会跟着数字跳动
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
            ),
            if (onClear != null)
              GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
                  child: Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: scheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 未设置结束时间时的「+ 结束时间」：描边而不是实心，
  /// 一眼能分出「已经确定的值」和「还可以补的值」。
  Widget _buildAddEndPill(ThemeData theme) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: _pickEndTime,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: scheme.outlineVariant, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 4),
            Text(
              '结束时间',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 附件与 AI 工具栏：相册、相机在左，AI 提取靠右。
  ///
  /// 提取从输入行挪到这里，是为了把输入行末尾那个最顺手的位置让给发送键 ——
  /// 「写完就发」是主路径，「写完再让 AI 拆成结构化字段」是支路，不该占主路的位置。
  Widget _buildMediaRow(ThemeData theme) {
    final canAddPhoto = _activeDraft.selectedPhotos.length < 3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
      child: Row(
        children: [
          _buildMediaButton(
            theme,
            icon: Icons.image_outlined,
            onTap: canAddPhoto ? _pickImageFromGallery : null,
            badge: _activeDraft.selectedPhotos.length,
          ),
          const SizedBox(width: 8),
          _buildMediaButton(
            theme,
            icon: Icons.camera_alt_outlined,
            onTap: canAddPhoto ? _pickImageFromCamera : null,
          ),
          const Spacer(),
          _buildAiExtractButton(theme),
        ],
      ),
    );
  }

  Widget _buildMediaButton(
    ThemeData theme, {
    required IconData icon,
    VoidCallback? onTap,
    int badge = 0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: onTap == null ? 0.45 : 1,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              if (badge > 0)
                Positioned(
                  top: 3,
                  right: 3,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$badge',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// AI 提取钮：纯图标，和相册 / 相机同一排、同样大小。
  ///
  /// 不写字：这一行都是图标动作，多一个文字胶囊会把「附件」和「AI」读成两种控件，
  /// 也把行宽撑开。语义靠 ✨ 本身和长按换模型承载。
  Widget _buildAiExtractButton(ThemeData theme) {
    final scheme = theme.colorScheme;
    final draft = _activeDraft;
    final aiTempsAsync = ref.watch(aiTemperaturesProvider);
    final extractImages =
        aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isExtractButtonEnabled =
        draft.inputText.trim().isNotEmpty ||
        (extractImages && draft.selectedPhotos.isNotEmpty);

    // 撤销态和提取态都算「可点」：撤销自然能点，提取中再点一次是停止。
    final enabled = _canUndo || _isExtracting || isExtractButtonEnabled;

    return Semantics(
      button: true,
      label: _canUndo ? '撤销提取' : 'AI 提取',
      child: GestureDetector(
        key: const ValueKey('record-ai-extract'),
        onTap: _canUndo ? _undoExtract : _handleAiExtract,
        onLongPress: _canUndo ? null : _showModelMenu,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _canUndo
                  ? scheme.error.withValues(alpha: 0.12)
                  : scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: _canUndo
                ? AnimatedBuilder(
                    animation: _undoController,
                    builder: (context, child) => SizedBox(
                      width: 22,
                      height: 22,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CustomPaint(
                            painter: _UndoCountdownPainter(
                              progress: _undoController.value,
                              color: scheme.error,
                            ),
                            size: const Size(22, 22),
                          ),
                          child!,
                        ],
                      ),
                    ),
                    child: Icon(
                      Icons.undo_rounded,
                      size: 14,
                      color: scheme.error,
                    ),
                  )
                : _isExtracting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _extractPhase == _ExtractPhase.sending
                          ? scheme.primary
                          : scheme.tertiary,
                    ),
                  )
                : Icon(
                    Icons.auto_awesome,
                    size: 20,
                    color: scheme.primary,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoPreview(ThemeData theme) {
    final aiTempsAsync = ref.watch(aiTemperaturesProvider);
    final extractImages =
        aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isImageExtracting = _isExtracting && extractImages;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _activeDraft.selectedPhotos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final path = _activeDraft.selectedPhotos[index];
            final isCompressing = _compressingTasks.containsKey(path);
            return Stack(
              children: [
                GestureDetector(
                  onTap: () =>
                      _showFullImage(path),
                  child: AnimatedGradientBorder(
                    isAnimating: isImageExtracting,
                    borderRadius: 12,
                    strokeWidth: 2,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        children: [
                          UnifiedImage(
                            imagePath: path,
                            width: 56,
                            height: 56,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          if (isCompressing)
                            Container(
                              width: 56,
                              height: 56,
                              color: Colors.black.withValues(alpha: 0.4),
                              child: const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _removePhoto(index),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(12),
                          bottomLeft: Radius.circular(8),
                        ),
                      ),
                      child: const Center(
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showFullImage(String path) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: UnifiedImage(imagePath: path, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close, color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 输入行：正文 + 发送键。
  ///
  /// 发送是这条动线的终点，占住输入框右侧最顺手的位置；AI 提取挪到上一行工具栏，
  /// 不再和「写完就发」抢这个位置。
  Widget _buildInputAndActions(ThemeData theme) {
    final draft = _activeDraft;
    // 输入框里的红色 × 是否出现，取决于「有没有东西可清」：时间线上的选时也算。
    final timeSelect = ref.watch(diaryInputTimeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AnimatedGradientBorder(
              isAnimating: _isExtracting,
              borderRadius: 24,
              strokeWidth: 2,
              child: Container(
                constraints: const BoxConstraints(maxHeight: 140),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    TextField(
                      controller: _textController,
                      focusNode: _textFocusNode,
                      minLines: 1,
                      maxLines: 5,
                      style: theme.textTheme.bodyMedium,
                      decoration: InputDecoration(
                        filled: false,
                        hintText: draft.tagEntries.isNotEmpty
                            ? '记录${draft.tagEntries.map((e) => e.name).join('、')}...'
                            : '记录此刻...',
                        hintStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.6,
                          ),
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          top: 12,
                          bottom: 12,
                          right: 42,
                        ),
                      ),
                      onSubmitted: (_) {
                        if (!_isSaveDisabled) _handleSend();
                      },
                    ),
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _textController,
                            builder: (context, value, _) {
                          final hasText = value.text.isNotEmpty;
                          final hasTags = draft.tagEntries.isNotEmpty;
                          final hasPhotos = draft.selectedPhotos.isNotEmpty;
                          final hasTimeline =
                              timeSelect != null || draft.endTime != null;
                          if (!hasText &&
                              !hasTags &&
                              !hasPhotos &&
                              !hasTimeline) {
                            return const SizedBox.shrink();
                          }
                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: _clearCurrentDraft,
                              behavior: HitTestBehavior.opaque,
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Container(
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.85),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.red.withValues(
                                            alpha: 0.25,
                                          ),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.close,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ),
                          );
                        },
                      ),
                        ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _buildSendButton(theme),
        ],
      ),
    );
  }

  /// 发送键：草稿为空或必填未通过时禁用，保存成功后短暂变成 ✓ 再收起卡片。
  Widget _buildSendButton(ThemeData theme) {
    final scheme = theme.colorScheme;
    final canSend = !_isSaveDisabled && !_isSending;

    return SizedBox(
      width: 46,
      height: 46,
      child: FilledButton(
        key: const ValueKey('record-send'),
        onPressed: canSend ? _handleSend : null,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          elevation: 0,
          shape: const CircleBorder(),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.surfaceContainerHighest.withValues(
            alpha: 0.7,
          ),
          disabledForegroundColor: scheme.onSurfaceVariant.withValues(
            alpha: 0.45,
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutBack,
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: _savedOk
              ? const Icon(
                  Icons.check_rounded,
                  key: ValueKey('saved'),
                  size: 22,
                )
              : _isSending
              ? SizedBox(
                  key: const ValueKey('sending'),
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              : const Icon(
                  Icons.arrow_upward_rounded,
                  key: ValueKey('send'),
                  size: 22,
                ),
        ),
      ),
    );
  }
}

enum _ExtractPhase { idle, sending, waiting, error }

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';
import 'package:qnote_flutter/widgets/diary/edit_tag_time_sheet.dart';

class _Draft {
  final String id;
  String inputText;
  List<TagEntry> tagEntries;
  List<String> selectedPhotos;
  TimeOfDay startTime;
  TimeOfDay? endTime;
  int? startOffset;
  int? endOffset;

  _Draft({
    required this.id,
    this.inputText = '',
    this.tagEntries = const [],
    this.selectedPhotos = const [],
    TimeOfDay? startTime,
    this.endTime,
    this.startOffset,
    this.endOffset,
  }) : startTime = startTime ?? TimeOfDay.now();

  Map<String, dynamic> getFormValuesFor(String tagId) {
    final entry = tagEntries.where((e) => e.id == tagId).firstOrNull;
    return entry != null ? Map<String, dynamic>.from(entry.fields) : {};
  }

  _Draft copyWith({
    String? id,
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
    return _Draft(
      id: id ?? this.id,
      inputText: inputText ?? this.inputText,
      tagEntries: tagEntries ?? this.tagEntries,
      selectedPhotos: selectedPhotos ?? this.selectedPhotos,
      startTime: startTime ?? this.startTime,
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      startOffset: clearStartOffset ? null : (startOffset ?? this.startOffset),
      endOffset: clearEndOffset ? null : (endOffset ?? this.endOffset),
    );
  }

  _Draft updateTagEntryFields(String tagId, Map<String, dynamic> fields) {
    final newEntries = tagEntries.map((e) {
      if (e.id == tagId) return e.copyWith(fields: fields);
      return e;
    }).toList();
    return copyWith(tagEntries: newEntries);
  }
}

class DiaryInputBar extends ConsumerStatefulWidget {
  final VoidCallback? onClose;

  const DiaryInputBar({super.key, this.onClose});

  @override
  ConsumerState<DiaryInputBar> createState() => _DiaryInputBarState();
}

class _DiaryInputBarState extends ConsumerState<DiaryInputBar>
    with TickerProviderStateMixin {
  bool _isExpanded = true;
  bool _isExtracting = false;
  CancelToken? _cancelToken;
  _ExtractPhase _extractPhase = _ExtractPhase.idle;

  late _Draft _draft;
  String? _activeFormTagId;

  _Draft? _preExtractDraft;
  String? _preExtractText;
  late AnimationController _undoController;
  bool _canUndo = false;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final ImageRepository _imageRepo = ImageRepository();
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
    _draft = _Draft(id: const Uuid().v4());
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
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _shortcutScrollController.dispose();
    _undoController.dispose();
    _removeModelMenuOverlay();
    for (final c in _formControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTextChanged() {
    _updateActiveDraft(inputText: _textController.text);
  }

  _Draft get _activeDraft => _draft;

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
      var nextStartOffset = clearStartOffset
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
        var sleepFields = Map<String, dynamic>.from(sleepEntry.fields);

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
    setState(() {
      _draft = _Draft(
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

  void _updateFormValue(String key, dynamic value, {String? tagId}) {
    final effectiveTagId = tagId ?? _activeFormTagId;
    if (effectiveTagId == null) return;

    final entry = _activeDraft.tagEntries
        .where((e) => e.id == effectiveTagId)
        .firstOrNull;
    if (entry == null) return;

    var newFields = Map<String, dynamic>.from(entry.fields);
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

    _updateActiveDraft(tagEntries: newTagEntries);
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
        final savedPath = await _imageRepo.saveImage(
          File(xFile.path),
          subfolder: 'diary',
        );
        paths.add(savedPath);
      }
      _updateActiveDraft(
        selectedPhotos: [..._activeDraft.selectedPhotos, ...paths],
      );
    } catch (_) {}
  }

  Future<void> _pickImageFromCamera() async {
    if (_activeDraft.selectedPhotos.length >= 3) return;
    try {
      final xFile = await _imagePicker.pickImage(source: ImageSource.camera);
      if (xFile == null) return;
      final savedPath = await _imageRepo.saveImage(
        File(xFile.path),
        subfolder: 'diary',
      );
      _updateActiveDraft(
        selectedPhotos: [..._activeDraft.selectedPhotos, savedPath],
      );
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
      title: '设定开始时间',
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
      title: '设定结束时间',
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
      aiService.updateConfig(roleConfig);

      final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
      final schemaContext = shortcuts.map((s) {
        final root = <String, dynamic>{'id': s.id, 'name': s.name};
        if (s.fields.isNotEmpty) {
          root['fields'] = s.fields
              .map(
                (f) => {
                  'id': f.id,
                  'name': f.label,
                  'type': f.type,
                  if (f.options.isNotEmpty) 'options': f.options,
                  if (f.allowCustom) 'allowCustom': true,
                },
              )
              .toList();
        }
        if (s.hasPopup && s.categories != null && s.categories!.isNotEmpty) {
          root['categories'] = s.categories!
              .map(
                (c) => {
                  'id': c.id,
                  'name': c.name,
                  'fields': c.fields
                      .map(
                        (f) => {
                          'id': f.id,
                          'name': f.label,
                          'type': f.type,
                          if (f.options.isNotEmpty) 'options': f.options,
                          if (f.allowCustom) 'allowCustom': true,
                        },
                      )
                      .toList(),
                },
              )
              .toList();
        }
        return root;
      }).toList();

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
        base64 = await _imageRepo.getBase64Image(draft.selectedPhotos.first);
      }

      results = await aiService.extractUnified(
        text: draft.inputText.isNotEmpty ? draft.inputText : null,
        imageBase64: base64,
        mimeType: 'image/jpeg',
        schema: schemaContext.toString(),
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
            try {
              foundShortcut = shortcuts.firstWhere(
                (s) => s.id == result['shortcutId'],
              );
            } catch (_) {}
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

          final fields = Map<String, dynamic>.from(
            result['fields'] as Map? ?? {},
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
                final startMinutes = 22 * 60 + 30;
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
                  final startMinutes = 22 * 60 + 30;
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

          final singleTagEntry = TagEntry(
            id: foundShortcut?.id ?? result['shortcutId'] ?? 'other',
            name: foundShortcut?.name ?? '其他',
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
          if (extractedNotes != null && extractedNotes.isNotEmpty) {
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

        final mergedDraft = _Draft(
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
          Toast.warning(context, '未提取到有用信息');
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
          errorMessage = '网络连接失败，请检查网络或API配置';
        } else if (e.type == DioExceptionType.connectionTimeout) {
          errorMessage = '连接超时，请稍后重试';
        } else if (e.response?.statusCode == 401) {
          errorMessage = 'API密钥无效，请检查AI配置';
        } else if (e.response?.statusCode == 403) {
          errorMessage = '访问被拒绝，可能是CORS限制或权限问题';
        }
      } else if (e is ArgumentError &&
          e.message.toString().contains('apiKey')) {
        errorMessage = 'AI配置不完整，请在设置中完善API密钥 and 地址';
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

    List<AiConfig> configs = [];
    try {
      configs = await ref.read(aiConfigListProvider.future);
    } catch (e) {
      LoggerService.instance.logAI('加载模型配置失败: $e');
    }

    if (!mounted) return;

    if (configs.isEmpty) {
      Toast.warning(context, '无可用模型');
      return;
    }

    final roles = await AiRoleService.instance.getRoles();
    final currentModelId = roles.timelineOptimization;

    if (!mounted) return;

    final selectedConfig = await showDialog<AiConfig>(
      context: context,
      builder: (context) =>
          _ModelSelectionDialog(configs: configs, selectedId: currentModelId),
    );

    if (selectedConfig != null && mounted) {
      await AiRoleService.instance.saveRoles(
        roles.copyWith(timelineOptimization: selectedConfig.id),
      );
      Toast.success(
        context,
        '已切换：${selectedConfig.name}',
        duration: const Duration(seconds: 1),
      );
    }
  }

  void _removeModelMenuOverlay() {
    _modelMenuOverlay?.remove();
    _modelMenuOverlay = null;
  }

  bool _validateDraft(_Draft draft) {
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

  Future<void> _handleSend() async {
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
    List<TagEntry> tagEntries = List.from(draft.tagEntries);

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
        } else
          bodyState ??= entryFields;
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

    final now = DateTime.now();
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

    await notifier.addDiary(
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
    setState(() {
      _draft = _Draft(id: const Uuid().v4(), startTime: TimeOfDay.now());
      _textController.text = '';
      _canUndo = false;
      _preExtractDraft = null;
      _preExtractText = null;
      _activeFormTagId = null;
    });

    if (mounted) {
      FocusScope.of(context).unfocus();
    }

    // 使用新记录的显示时间（可能为 startTime 或 endTime），以保证精准滚动到新发送的事件位置
    ref.read(diaryScrollToTimeProvider.notifier).state = record.getDisplayTime();
  }

  DateTime _calculateStartDateTime(_Draft draft, DateTime selectedDate) {
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

  DateTime? _calculateEndDateTime(_Draft draft, DateTime selectedDate) {
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

  String _formatTime(DateTime selectedDate, TimeOfDay time, {int? offset}) {
    final date = offset != null
        ? selectedDate.add(Duration(days: offset))
        : selectedDate;
    final dateStr = DateFormat('MM-dd').format(date);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return '$dateStr $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final selectedDate = ref.watch(selectedDateProvider);
    ref.listen<TimelineTimeSelectEvent?>(diaryInputTimeProvider, (
      previous,
      next,
    ) {
      if (next != null) {
        final selectedDate = ref.read(selectedDateProvider);
        final startDay = DateTime(
          next.date.year,
          next.date.month,
          next.date.day,
        );
        final baseDay = DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
        );
        final startOffset = startDay.difference(baseDay).inDays;

        int? endOffset;
        if (next.endDate != null) {
          final endDay = DateTime(
            next.endDate!.year,
            next.endDate!.month,
            next.endDate!.day,
          );
          endOffset = endDay.difference(baseDay).inDays;
        }

        _updateActiveDraft(
          startTime: next.time,
          endTime: next.endTime,
          clearEndTime: next.endTime == null,
          startOffset: startOffset,
          endOffset: endOffset,
          clearStartOffset: false,
          clearEndOffset: next.endTime == null,
        );
        if (!_isExpanded) {
          setState(() => _isExpanded = true);
        }
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

    return Container(
      constraints: const BoxConstraints(maxHeight: 680),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 30,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedCrossFade(
        alignment: Alignment.bottomCenter,
        firstChild: _buildCollapsedContent(theme),
        secondChild: _buildExpandedContent(theme, shortcuts, selectedDate),
        crossFadeState: _isExpanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 300),
        sizeCurve: Curves.easeInOut,
      ),
    );
  }

  Widget _buildCollapsedContent(ThemeData theme) {
    return GestureDetector(
      onTap: () => setState(() => _isExpanded = true),
      child: SafeArea(
        bottom: false,
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '展开记录菜单',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.colorScheme.primaryContainer,
                      theme.colorScheme.surfaceContainerHighest,
                    ],
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.3,
                    ),
                  ),
                ),
                child: Icon(
                  Icons.keyboard_arrow_up,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedContent(
    ThemeData theme,
    AsyncValue<List<ShortcutConfig>> shortcuts,
    DateTime selectedDate,
  ) {
    return SafeArea(
      top: false,
      bottom: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          Flexible(child: _buildFormFieldsArea(theme)),
          _buildShortcutRow(theme, shortcuts),
          _buildTimeAndImageRow(theme, selectedDate),
          if (_activeDraft.selectedPhotos.isNotEmpty) _buildPhotoPreview(theme),
          _buildInputAndActions(theme),
        ],
      ),
    );
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

          Map<String, dynamic> updatedFields = Map<String, dynamic>.from(e.fields);
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

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 360),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: visibleEntries.map((pair) {
              return _buildTagFormSection(theme, pair.value, pair.key);
            }).toList(),
          ),
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
                          entry.hasTime ? entry.formattedTime! : '添加时间',
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
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 2),
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
                      padding: const EdgeInsets.only(right: 4),
                      child: GestureDetector(
                        onTap: () => _selectShortcut(config),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.transparent
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _getShortcutIcon(config.name),
                                size: 14,
                                color: isSelected
                                    ? theme.colorScheme.onPrimary
                                    : theme.colorScheme.onSurface,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                config.name,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isSelected
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                  loading: () => <Widget>[
                    const SizedBox(
                      width: 60,
                      height: 28,
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
          GestureDetector(
            onTap: () {
              setState(() => _isExpanded = false);
              widget.onClose?.call();
            },
            child: Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primaryContainer,
                    theme.colorScheme.surfaceContainerHighest,
                  ],
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.3,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Icon(
                Icons.keyboard_arrow_down,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
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

  Widget _buildTimeAndImageRow(ThemeData theme, DateTime selectedDate) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _pickStartTime,
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.08,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.15,
                          ),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.access_time_rounded,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _formatTime(
                                  selectedDate,
                                  _activeDraft.startTime,
                                  offset: _activeDraft.startOffset,
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_activeDraft.endTime != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '-',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 8),
                Expanded(
                  child: _activeDraft.endTime != null
                      ? Container(
                          height: 36,
                          padding: const EdgeInsets.only(left: 8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.15,
                              ),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: _pickEndTime,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.access_time_rounded,
                                        size: 14,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _formatTime(
                                              selectedDate,
                                              _activeDraft.endTime!,
                                              offset: _activeDraft.endOffset,
                                            ),
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                  color:
                                                      theme.colorScheme.primary,
                                                  fontSize: 12,
                                                ),
                                            maxLines: 1,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: _clearEndTime,
                                behavior: HitTestBehavior.opaque,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    6,
                                    8,
                                    10,
                                    8,
                                  ),
                                  child: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : CustomPaint(
                          painter: DashedRectPainter(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.3,
                            ),
                            strokeWidth: 1.2,
                            borderRadius: 12,
                          ),
                          child: GestureDetector(
                            onTap: _pickEndTime,
                            child: Container(
                              height: 36,
                              color: Colors.transparent,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add,
                                    size: 14,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '结束时间',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _activeDraft.selectedPhotos.length < 3
                ? _pickImageFromGallery
                : null,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  if (_activeDraft.selectedPhotos.isNotEmpty)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${_activeDraft.selectedPhotos.length}',
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
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _activeDraft.selectedPhotos.length < 3
                ? _pickImageFromCamera
                : null,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.camera_alt_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoPreview(ThemeData theme) {
    final aiTempsAsync = ref.watch(aiTemperaturesProvider);
    final extractImages =
        aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isImageExtracting = _isExtracting && extractImages;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _activeDraft.selectedPhotos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            return Stack(
              children: [
                GestureDetector(
                  onTap: () =>
                      _showFullImage(_activeDraft.selectedPhotos[index]),
                  child: AnimatedGradientBorder(
                    isAnimating: isImageExtracting,
                    borderRadius: 12,
                    strokeWidth: 2,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: UnifiedImage(
                        imagePath: _activeDraft.selectedPhotos[index],
                        width: 56,
                        height: 56,
                        borderRadius: BorderRadius.circular(12),
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

  Widget _buildInputAndActions(ThemeData theme) {
    final draft = _activeDraft;
    final timeSelect = ref.watch(diaryInputTimeProvider);
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
    final isEmpty =
        draft.inputText.trim().isEmpty &&
        draft.tagEntries.isEmpty &&
        draft.selectedPhotos.isEmpty;
    final isDisabled = isValidationError || isEmpty;

    final aiTempsAsync = ref.watch(aiTemperaturesProvider);
    final extractImages =
        aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isExtractButtonEnabled =
        draft.inputText.trim().isNotEmpty ||
        (extractImages && draft.selectedPhotos.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
                            : '记录当前...',
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
                        if (!isDisabled) _handleSend();
                      },
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
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
                                  width: 20,
                                  height: 20,
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
                                      size: 12,
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
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _canUndo ? _undoExtract : _handleAiExtract,
            onLongPress: _canUndo ? null : _showModelMenu,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _canUndo
                    ? theme.colorScheme.error.withValues(alpha: 0.08)
                    : theme.colorScheme.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _canUndo
                  ? AnimatedBuilder(
                      animation: _undoController,
                      builder: (context, child) {
                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: CustomPaint(
                                painter: _UndoCountdownPainter(
                                  progress: _undoController.value,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                            child!,
                          ],
                        );
                      },
                      child: Icon(
                        Icons.undo,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                    )
                  : _isExtracting
                  ? Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _extractPhase == _ExtractPhase.sending
                              ? theme.colorScheme.primary
                              : theme.colorScheme.tertiary,
                        ),
                      ),
                    )
                  : Center(
                      child: Icon(
                        Icons.auto_awesome,
                        size: 20,
                        color: isExtractButtonEnabled
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.4,
                              ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: isDisabled ? null : _handleSend,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isDisabled
                    ? theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      )
                    : theme.colorScheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  Icons.send_rounded,
                  size: 20,
                  color: isDisabled
                      ? theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.3,
                        )
                      : theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ExtractPhase { idle, sending, waiting, error }

class _ModelSelectionDialog extends StatelessWidget {
  final List<AiConfig> configs;
  final String? selectedId;

  const _ModelSelectionDialog({required this.configs, this.selectedId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      backgroundColor: colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '选择模型',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: configs.map<Widget>((config) {
                    final isSelected = config.id == selectedId;
                    return _ModelItem(
                      config: config,
                      isSelected: isSelected,
                      onTap: () => Navigator.pop(context, config),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelItem extends StatelessWidget {
  final AiConfig config;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModelItem({
    required this.config,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: isSelected
          ? colorScheme.primary.withValues(alpha: 0.05)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      config.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${config.provider} / ${config.modelName}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UndoCountdownPainter extends CustomPainter {
  final double progress;
  final Color color;

  _UndoCountdownPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 4) / 2;

    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    final sweepAngle = (1.0 - progress) * 2 * 3.141592653589793;
    if (sweepAngle > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -3.141592653589793 / 2,
        sweepAngle,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UndoCountdownPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class DashedRectPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double borderRadius;
  final double dashWidth;
  final double dashSpace;

  DashedRectPainter({
    required this.color,
    this.strokeWidth = 1.0,
    this.borderRadius = 0.0,
    this.dashWidth = 5.0,
    this.dashSpace = 3.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            strokeWidth / 2,
            strokeWidth / 2,
            size.width - strokeWidth,
            size.height - strokeWidth,
          ),
          Radius.circular(borderRadius),
        ),
      );

    final dashedPath = Path();
    for (final metric in path.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        dashedPath.addPath(
          metric.extractPath(distance, distance + dashWidth),
          Offset.zero,
        );
        distance += dashWidth + dashSpace;
      }
    }

    canvas.drawPath(dashedPath, paint);
  }

  @override
  bool shouldRepaint(covariant DashedRectPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.borderRadius != borderRadius;
  }
}

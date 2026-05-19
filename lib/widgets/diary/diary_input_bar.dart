import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';

class _Draft {
  final String id;
  String inputText;
  ShortcutConfig? selectedShortcut;
  Map<String, dynamic> formValues;
  List<String> selectedPhotos;
  TimeOfDay startTime;
  TimeOfDay? endTime;
  int? startOffset;
  int? endOffset;

  _Draft({
    required this.id,
    this.inputText = '',
    this.selectedShortcut,
    this.formValues = const {},
    this.selectedPhotos = const [],
    TimeOfDay? startTime,
    this.endTime,
    this.startOffset,
    this.endOffset,
  }) : startTime = startTime ?? TimeOfDay.now();

  _Draft copyWith({
    String? id,
    String? inputText,
    ShortcutConfig? selectedShortcut,
    bool clearShortcut = false,
    Map<String, dynamic>? formValues,
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
      selectedShortcut: clearShortcut ? null : (selectedShortcut ?? this.selectedShortcut),
      formValues: formValues ?? this.formValues,
      selectedPhotos: selectedPhotos ?? this.selectedPhotos,
      startTime: startTime ?? this.startTime,
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      startOffset: clearStartOffset ? null : (startOffset ?? this.startOffset),
      endOffset: clearEndOffset ? null : (endOffset ?? this.endOffset),
    );
  }
}

class DiaryInputBar extends ConsumerStatefulWidget {
  final VoidCallback? onClose;

  const DiaryInputBar({super.key, this.onClose});

  @override
  ConsumerState<DiaryInputBar> createState() => _DiaryInputBarState();
}

class _DiaryInputBarState extends ConsumerState<DiaryInputBar> {
  bool _isExpanded = true;
  bool _isExtracting = false;
  _ExtractPhase _extractPhase = _ExtractPhase.idle;

  List<_Draft> _drafts = [];
  int _activeDraftIndex = 0;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final ImageRepository _imageRepo = ImageRepository();
  final ScrollController _shortcutScrollController = ScrollController();

  final Map<String, TextEditingController> _formControllers = {};

  TextEditingController _getFormController(String fieldId, String initialValue) {
    if (!_formControllers.containsKey(fieldId)) {
      _formControllers[fieldId] = TextEditingController(text: initialValue);
    } else {
      final controller = _formControllers[fieldId]!;
      if (controller.text != initialValue) {
        controller.value = controller.value.copyWith(
          text: initialValue,
          selection: TextSelection.collapsed(offset: initialValue.length),
        );
      }
    }
    return _formControllers[fieldId]!;
  }

  OverlayEntry? _modelMenuOverlay;

  @override
  void initState() {
    super.initState();
    _drafts = [_Draft(id: const Uuid().v4())];
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _shortcutScrollController.dispose();
    _removeModelMenuOverlay();
    for (final c in _formControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTextChanged() {
    _updateActiveDraft(inputText: _textController.text);
  }

  _Draft get _activeDraft => _drafts[_activeDraftIndex];

  void _updateActiveDraft({
    String? inputText,
    ShortcutConfig? selectedShortcut,
    bool clearShortcut = false,
    Map<String, dynamic>? formValues,
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
      final active = _drafts[_activeDraftIndex];
      final nextShortcut = clearShortcut ? null : (selectedShortcut ?? active.selectedShortcut);
      var nextFormValues = formValues ?? Map<String, dynamic>.from(active.formValues);
      var nextStartTime = startTime ?? active.startTime;
      var nextStartOffset = clearStartOffset ? null : (startOffset ?? active.startOffset);
      
      TimeOfDay? nextEndTime = endTime ?? (clearEndTime ? null : active.endTime);
      int? nextEndOffset = endOffset ?? (clearEndOffset ? null : active.endOffset);
      var nextClearEndTime = clearEndTime;
      var nextClearEndOffset = clearEndOffset;

      if (nextShortcut?.id == 'sleep') {
        // Enforce bidirectional synchronization!
        // 1. If formValues passed in a new fallAsleepTime:
        if (formValues != null && formValues.containsKey('fallAsleepTime') && formValues['fallAsleepTime'] != null) {
          final timeStr = formValues['fallAsleepTime'] as String;
          final parts = timeStr.split(':');
          if (parts.length >= 2) {
            final h = int.tryParse(parts[0]) ?? 0;
            final m = int.tryParse(parts[1]) ?? 0;
            nextStartTime = TimeOfDay(hour: h, minute: m);
          }
        }

        // 2. Compute endTime and endOffset dynamically based on duration if duration was updated in formValues
        final durationVal = nextFormValues['duration'];
        if (formValues != null && formValues.containsKey('duration') && durationVal != null) {
          final double? durationHours = double.tryParse(durationVal.toString());
          if (durationHours != null) {
            final startMinutes = nextStartTime.hour * 60 + nextStartTime.minute;
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
        }
        // 3. Otherwise, if endTime was updated (e.g. from bottom settings or timeline), dynamically compute duration
        else if (nextEndTime != null) {
          final startMin = nextStartTime.hour * 60 + nextStartTime.minute;
          final endMin = nextEndTime.hour * 60 + nextEndTime.minute;
          var diffMin = endMin - startMin;
          if (diffMin < 0) {
            diffMin += 1440;
          }
          final durationHours = diffMin / 60.0;
          nextFormValues['duration'] = durationHours.toStringAsFixed(1);
        }

        // 4. Always synchronize formValues['fallAsleepTime'] to match nextStartTime
        nextFormValues['fallAsleepTime'] = '${nextStartTime.hour.toString().padLeft(2, '0')}:${nextStartTime.minute.toString().padLeft(2, '0')}';
      }

      _drafts[_activeDraftIndex] = active.copyWith(
        inputText: inputText,
        selectedShortcut: nextShortcut,
        clearShortcut: clearShortcut,
        formValues: nextFormValues,
        selectedPhotos: selectedPhotos,
        startTime: nextStartTime,
        clearEndTime: nextClearEndTime,
        endTime: nextEndTime,
        startOffset: nextStartOffset,
        clearStartOffset: clearStartOffset,
        endOffset: nextEndOffset,
        clearEndOffset: nextClearEndOffset,
      );
    });

    final activeDraft = _drafts[_activeDraftIndex];
    final newTime = activeDraft.startTime;
    final currentTime = ref.read(currentInputTimeProvider);
    if (currentTime.hour != newTime.hour || currentTime.minute != newTime.minute) {
      ref.read(currentInputTimeProvider.notifier).state = newTime;
    }

    // Bidirectional sync to the timeline selection provider!
    final selectedDate = ref.read(selectedDateProvider);
    final targetDate = _calculateStartDateTime(activeDraft, selectedDate);
    final targetEndDate = activeDraft.endTime != null ? _calculateEndDateTime(activeDraft, selectedDate) : null;
    final currentTimeline = ref.read(diaryInputTimeProvider);

    // Only automatically sync back to diaryInputTimeProvider if it is NOT null.
    // If it is null, we do not want to force-select a node on the timeline.
    if (currentTimeline != null) {
      final bool timeMatches =
          currentTimeline.time.hour == activeDraft.startTime.hour &&
          currentTimeline.time.minute == activeDraft.startTime.minute &&
          ((currentTimeline.endTime == null && activeDraft.endTime == null) ||
              (currentTimeline.endTime != null &&
                  activeDraft.endTime != null &&
                  currentTimeline.endTime!.hour == activeDraft.endTime!.hour &&
                  currentTimeline.endTime!.minute == activeDraft.endTime!.minute));

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
          ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
            activeDraft.startTime,
            endTime: activeDraft.endTime,
            date: targetDate,
            endDate: targetEndDate,
          );
        });
      }
    }
  }

  void _switchDraft(int index) {
    if (index == _activeDraftIndex) return;
    _formControllers.clear();
    setState(() {
      _activeDraftIndex = index;
      _textController.text = _activeDraft.inputText;
    });
    final newTime = _activeDraft.startTime;
    final currentTime = ref.read(currentInputTimeProvider);
    if (currentTime.hour != newTime.hour || currentTime.minute != newTime.minute) {
      ref.read(currentInputTimeProvider.notifier).state = newTime;
    }
  }

  void _addDraft() {
    if (_drafts.length >= 5) return;
    final currentTimeline = ref.read(diaryInputTimeProvider);
    final selectedDate = ref.read(selectedDateProvider);
    setState(() {
      final newDraft = _Draft(
        id: const Uuid().v4(),
        startTime: currentTimeline?.time,
        endTime: currentTimeline?.endTime,
        startOffset: currentTimeline != null
            ? currentTimeline.date.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays
            : null,
        endOffset: (currentTimeline != null && currentTimeline.endDate != null)
            ? currentTimeline.endDate!.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays
            : null,
      );
      _drafts.add(newDraft);
      _activeDraftIndex = _drafts.length - 1;
      _textController.text = '';
    });
    _textFocusNode.requestFocus();
  }

  void _removeDraft(int index) {
    if (_drafts.length <= 1) return;
    setState(() {
      _drafts.removeAt(index);
      if (_activeDraftIndex >= _drafts.length) {
        _activeDraftIndex = _drafts.length - 1;
      } else if (_activeDraftIndex > index) {
        _activeDraftIndex--;
      }
      _textController.text = _activeDraft.inputText;
    });
  }

  void _clearCurrentDraft() {
    _formControllers.clear();
    final currentTimeline = ref.read(diaryInputTimeProvider);
    final selectedDate = ref.read(selectedDateProvider);
    setState(() {
      _drafts[_activeDraftIndex] = _Draft(
        id: const Uuid().v4(),
        startTime: currentTimeline?.time,
        endTime: currentTimeline?.endTime,
        startOffset: currentTimeline != null
            ? currentTimeline.date.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays
            : null,
        endOffset: (currentTimeline != null && currentTimeline.endDate != null)
            ? currentTimeline.endDate!.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays
            : null,
      );
      _textController.text = '';
    });
  }

  void _selectShortcut(ShortcutConfig? config) async {
    _formControllers.clear();
    if (_activeDraft.selectedShortcut?.id == config?.id) {
      _updateActiveDraft(clearShortcut: true, formValues: {});
    } else {
      if (config?.id == 'sleep') {
        // 1. Check if the user already has a time selection on the timeline
        final timelineSelect = ref.read(diaryInputTimeProvider);
        if (timelineSelect != null) {
          final startTimeStr = '${timelineSelect.time.hour.toString().padLeft(2, '0')}:${timelineSelect.time.minute.toString().padLeft(2, '0')}';
          
          double? durationHours;
          if (timelineSelect.endTime != null) {
            final startMin = timelineSelect.time.hour * 60 + timelineSelect.time.minute;
            final endMin = timelineSelect.endTime!.hour * 60 + timelineSelect.endTime!.minute;
            var diffMin = endMin - startMin;
            if (diffMin < 0) {
              diffMin += 1440; // Handles overnight sleep correctly
            }
            durationHours = diffMin / 60.0;
          }

          final selectedDate = ref.read(selectedDateProvider);
          final startLocalDate = DateTime(timelineSelect.date.year, timelineSelect.date.month, timelineSelect.date.day);
          final startOffset = startLocalDate.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays;

          final initialFormValues = <String, dynamic>{
            'fallAsleepTime': startTimeStr,
          };
          if (durationHours != null) {
            initialFormValues['duration'] = durationHours.toStringAsFixed(1);
          }

          _updateActiveDraft(
            selectedShortcut: config,
            clearShortcut: false,
            startTime: timelineSelect.time,
            endTime: timelineSelect.endTime,
            startOffset: startOffset,
            formValues: initialFormValues,
          );
          return;
        }

        // 2. If no timeline selection, fallback to history or defaults
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
              
              final logicalDate = DateTime(lastSleep.time.year, lastSleep.time.month, lastSleep.time.day);
              final startLocalDate = DateTime(lastSleep.startTime!.year, lastSleep.startTime!.month, lastSleep.startTime!.day);
              final offset = startLocalDate.difference(logicalDate).inDays;

              final lastFallAsleepTime = '${lastStartTime.hour.toString().padLeft(2, '0')}:${lastStartTime.minute.toString().padLeft(2, '0')}';

              _updateActiveDraft(
                selectedShortcut: config,
                clearShortcut: false,
                startTime: lastStartTime,
                startOffset: offset,
                formValues: {
                  'fallAsleepTime': lastFallAsleepTime,
                },
              );

              // Explicitly sync to timeline selection
              final selectedDate = ref.read(selectedDateProvider);
              final targetDate = DateTime(
                selectedDate.year,
                selectedDate.month,
                selectedDate.day,
              ).add(Duration(days: offset));
              ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
                lastStartTime,
                date: targetDate,
              );
              return;
            }
          }
          
          // No history records found: Default to yesterday 22:00
          _updateActiveDraft(
            selectedShortcut: config,
            clearShortcut: false,
            startTime: const TimeOfDay(hour: 22, minute: 0),
            startOffset: -1,
            formValues: {
              'fallAsleepTime': '22:00',
            },
          );

          // Explicitly sync to timeline selection
          final selectedDate = ref.read(selectedDateProvider);
          final targetDate = DateTime(
            selectedDate.year,
            selectedDate.month,
            selectedDate.day,
          ).add(const Duration(days: -1));
          ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
            const TimeOfDay(hour: 22, minute: 0),
            date: targetDate,
          );
          return;
        } catch (e) {
          LoggerService.instance.logAI('加载上次睡眠记录失败: $e');
          // If query fails: Default to yesterday 22:00
          _updateActiveDraft(
            selectedShortcut: config,
            clearShortcut: false,
            startTime: const TimeOfDay(hour: 22, minute: 0),
            startOffset: -1,
            formValues: {
              'fallAsleepTime': '22:00',
            },
          );

          // Explicitly sync to timeline selection
          final selectedDate = ref.read(selectedDateProvider);
          final targetDate = DateTime(
            selectedDate.year,
            selectedDate.month,
            selectedDate.day,
          ).add(const Duration(days: -1));
          ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
            const TimeOfDay(hour: 22, minute: 0),
            date: targetDate,
          );
          return;
        }
      }

      _updateActiveDraft(
        selectedShortcut: config,
        clearShortcut: config == null,
        formValues: {},
      );
    }
  }

  void _updateFormValue(String key, dynamic value) {
    final newValues = Map<String, dynamic>.from(_activeDraft.formValues);
    if (value == null) {
      newValues.remove(key);
    } else {
      newValues[key] = value;
    }
    _updateActiveDraft(formValues: newValues);
  }

  Future<void> _pickImageFromGallery() async {
    if (_activeDraft.selectedPhotos.length >= 3) return;
    try {
      final remaining = 3 - _activeDraft.selectedPhotos.length;
      final images = await GalleryHelper.pickMultiImages(context, maxAssets: remaining);
      if (images.isEmpty) return;
      final paths = <String>[];
      for (final xFile in images) {
        final savedPath = await _imageRepo.saveImage(File(xFile.path), subfolder: 'diary');
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
      final savedPath = await _imageRepo.saveImage(File(xFile.path), subfolder: 'diary');
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
      initialTime: _calculateStartDateTime(_activeDraft, ref.read(selectedDateProvider)),
      title: '设定开始时间',
    );
    if (result != null) {
      final selectedDate = ref.read(selectedDateProvider);
      final offset = DateTime(result.year, result.month, result.day)
          .difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day))
          .inDays;
      final newTime = TimeOfDay(hour: result.hour, minute: result.minute);
      _updateActiveDraft(
        startTime: newTime,
        startOffset: offset,
      );
      
      // Explicitly update timeline selection when user manually picks a time
      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        newTime,
        endTime: _activeDraft.endTime,
        date: DateTime(result.year, result.month, result.day),
        endDate: _activeDraft.endTime != null ? _calculateEndDateTime(_activeDraft, selectedDate) : null,
      );
    }
  }

  Future<void> _pickEndTime() async {
    final initialDate = _activeDraft.endTime != null
        ? _calculateEndDateTime(_activeDraft, ref.read(selectedDateProvider))!
        : _calculateStartDateTime(_activeDraft, ref.read(selectedDateProvider)).add(const Duration(hours: 1));

    final result = await showTimePickerDialog(
      context: context,
      initialTime: initialDate,
      title: '设定结束时间',
    );
    if (result != null) {
      final selectedDate = ref.read(selectedDateProvider);
      final offset = DateTime(result.year, result.month, result.day)
          .difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day))
          .inDays;
      final newEndTime = TimeOfDay(hour: result.hour, minute: result.minute);
      _updateActiveDraft(
        endTime: newEndTime,
        endOffset: offset,
      );

      // Explicitly update timeline selection when user manually picks end time
      ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
        _activeDraft.startTime,
        endTime: newEndTime,
        date: _calculateStartDateTime(_activeDraft, selectedDate),
        endDate: DateTime(result.year, result.month, result.day),
      );
    }
  }

  void _clearEndTime() {
    _updateActiveDraft(clearEndTime: true, clearEndOffset: true);
    
    // Explicitly update timeline selection to clear end time
    final selectedDate = ref.read(selectedDateProvider);
    ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
      _activeDraft.startTime,
      endTime: null,
      date: _calculateStartDateTime(_activeDraft, selectedDate),
      endDate: null,
    );
  }

  Future<void> _handleAiExtract() async {
    if (_isExtracting) return;
    final draft = _activeDraft;

    final aiTempsAsync = ref.read(aiTemperaturesProvider);
    final extractImages = aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isExtractButtonEnabled = draft.inputText.trim().isNotEmpty || (extractImages && draft.selectedPhotos.isNotEmpty);
    if (!isExtractButtonEnabled) return;

    setState(() {
      _isExtracting = true;
      _extractPhase = _ExtractPhase.sending;
    });

    try {
      final aiService = ref.read(aiServiceProvider);
      final roleConfig = await AiRoleService.instance.getEffectiveConfigForRole('timelineOptimization');
      aiService.updateConfig(roleConfig);

      final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
      final schemaContext = shortcuts.map((s) {
        final root = <String, dynamic>{'id': s.id, 'name': s.name};
        if (s.hasPopup) {
          if (s.fields.isNotEmpty) {
            root['fields'] = s.fields.map((f) => {'id': f.id, 'type': f.type, if (f.options.isNotEmpty) 'options': f.options}).toList();
          }
          if (s.categories != null && s.categories!.isNotEmpty) {
            root['categories'] = s.categories!.map((c) => {'id': c.id, 'name': c.name, 'fields': c.fields.map((f) => {'id': f.id, 'type': f.type, if (f.options.isNotEmpty) 'options': f.options}).toList()}).toList();
          }
        }
        return root;
      }).toList();

      final now = DateTime.now();
      final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      final contextStr = {
        'date': DateFormat('yyyy-MM-dd').format(now),
        'time': DateFormat('HH:mm').format(now),
        'weekday': weekdays[now.weekday - 1],
      };

      setState(() => _extractPhase = _ExtractPhase.waiting);

      List<Map<String, dynamic>> results;
      final bool shouldSendImage = extractImages && draft.selectedPhotos.isNotEmpty;
      if (shouldSendImage) {
        final base64 = await _imageRepo.getBase64Image(draft.selectedPhotos.first);
        results = await aiService.extractGlobalImageInfo(
          imageBase64: base64,
          mimeType: 'image/jpeg',
          prompt: draft.inputText.isNotEmpty ? draft.inputText : '请提取图片中的所有可能记录事件。',
          schema: schemaContext.toString(),
          contextStr: contextStr.toString(),
        );
      } else {
        results = await aiService.extractDiaryStructure(
          text: draft.inputText,
          schemaContext: schemaContext.toString(),
          contextStr: contextStr.toString(),
        );
      }

      if (results.isNotEmpty) {
        final newDrafts = <_Draft>[];
        for (int i = 0; i < results.length; i++) {
          final result = results[i];
          ShortcutConfig? foundShortcut;
          if (result['shortcutId'] != null) {
            try {
              foundShortcut = shortcuts.firstWhere((s) => s.id == result['shortcutId']);
            } catch (_) {}
          }

          TimeOfDay parsedTime = TimeOfDay.now();
          TimeOfDay? parsedEndTime;
          int? parsedStartOffset;
          int? parsedEndOffset;

          if (result['time'] != null) {
            final timeMap = result['time'] as Map<String, dynamic>;
            if (timeMap['start'] != null) {
              final parts = (timeMap['start'] as String).split(':');
              if (parts.length >= 2) {
                parsedTime = TimeOfDay(hour: int.tryParse(parts[0]) ?? 0, minute: int.tryParse(parts[1]) ?? 0);
              }
            }
            if (timeMap['end'] != null) {
              final parts = (timeMap['end'] as String).split(':');
              if (parts.length >= 2) {
                parsedEndTime = TimeOfDay(hour: int.tryParse(parts[0]) ?? 0, minute: int.tryParse(parts[1]) ?? 0);
              }
            }
            if (timeMap['startOffset'] != null) {
              parsedStartOffset = timeMap['startOffset'] as int;
            }
            if (timeMap['endOffset'] != null) {
              parsedEndOffset = timeMap['endOffset'] as int;
            }
          }

          final fields = Map<String, dynamic>.from(result['fields'] as Map? ?? {});

          if (foundShortcut?.id == 'sleep') {
            if (parsedEndTime != null && parsedStartOffset == null && parsedEndOffset == null) {
              final startMin = parsedTime.hour * 60 + parsedTime.minute;
              final endMin = parsedEndTime.hour * 60 + parsedEndTime.minute;
              if (endMin < startMin) {
                parsedStartOffset = -1;
                parsedEndOffset = 0;
              }
            }
            fields['fallAsleepTime'] = '${parsedTime.hour.toString().padLeft(2, '0')}:${parsedTime.minute.toString().padLeft(2, '0')}';
          }

          newDrafts.add(_Draft(
            id: const Uuid().v4(),
            inputText: result['notes'] as String? ?? '',
            selectedShortcut: foundShortcut,
            formValues: fields,
            selectedPhotos: i == 0 ? draft.selectedPhotos : [],
            startTime: parsedTime,
            endTime: parsedEndTime,
            startOffset: parsedStartOffset,
            endOffset: parsedEndOffset,
          ));
        }

        setState(() {
          _drafts = newDrafts;
          _activeDraftIndex = 0;
          _textController.text = _drafts[0].inputText;
          _extractPhase = _ExtractPhase.idle;
        });

        // Explicitly sync the AI-extracted time of the first draft to the timeline selection
        final firstDraft = newDrafts[0];
        final selectedDate = ref.read(selectedDateProvider);
        final targetDate = _calculateStartDateTime(firstDraft, selectedDate);
        final targetEndDate = firstDraft.endTime != null ? _calculateEndDateTime(firstDraft, selectedDate) : null;
        ref.read(diaryInputTimeProvider.notifier).state = TimelineTimeSelectEvent(
          firstDraft.startTime,
          endTime: firstDraft.endTime,
          date: targetDate,
          endDate: targetEndDate,
        );
      }
    } catch (e, stackTrace) {
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
      } else if (e is ArgumentError && e.message.toString().contains('apiKey')) {
        errorMessage = 'AI配置不完整，请在设置中完善API密钥和地址';
      }
      
      LoggerService.instance.logAI(
        '时间线提取失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
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
      setState(() => _isExtracting = false);
    }
  }

  void _showModelMenu() async {
    // 收起软键盘并清除焦点，防止弹窗关闭后键盘再次自动弹出
    FocusScope.of(context).unfocus();

    List<AiConfig> configs = [];
    try {
      configs = await ref.read(aiConfigListProvider.future);
    } catch (e) {
      LoggerService.instance.logAI('加载模型配置失败: $e');
    }

    if (!mounted) return;

    if (configs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('暂无模型配置')));
      return;
    }

    final roles = await AiRoleService.instance.getRoles();
    final currentModelId = roles.timelineOptimization;

    if (!mounted) return;

    final selectedConfig = await showDialog<AiConfig>(
      context: context,
      builder: (context) => _ModelSelectionDialog(
        configs: configs,
        selectedId: currentModelId,
      ),
    );

    if (selectedConfig != null && mounted) {
      await AiRoleService.instance.saveRoles(
        roles.copyWith(timelineOptimization: selectedConfig.id),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已切换模型：${selectedConfig.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _removeModelMenuOverlay() {
    _modelMenuOverlay?.remove();
    _modelMenuOverlay = null;
  }

  bool _validateDraft(_Draft draft) {
    if (draft.selectedShortcut != null && draft.selectedShortcut!.hasPopup) {
      if (draft.selectedShortcut!.id == 'consumption' && draft.formValues['amount'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入金额')));
        return false;
      }
      if (draft.selectedShortcut!.id == 'sleep' && draft.formValues['duration'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入睡眠时长')));
        return false;
      }
    }
    return true;
  }

  Future<void> _handleSend() async {
    for (final draft in _drafts) {
      if (!_validateDraft(draft)) return;
    }

    final notifier = ref.read(diaryListProvider.notifier);
    final selectedDate = ref.read(selectedDateProvider);
    DateTime? firstSentTime;

    for (final draft in _drafts) {
      final isEmpty = draft.inputText.trim().isEmpty && draft.selectedShortcut == null && draft.selectedPhotos.isEmpty;
      if (isEmpty) continue;

      // If no timeline node is selected, use the current time (TimeOfDay.now()) at the exact moment of sending.
      final selectEvent = ref.read(diaryInputTimeProvider);
      final TimeOfDay eventTime = selectEvent == null ? TimeOfDay.now() : draft.startTime;

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

      if (firstSentTime == null) {
        firstSentTime = startDateTime;
      }
      var endDateTime = _calculateEndDateTime(draft, selectedDate);

      if (draft.selectedShortcut?.id == 'sleep') {
        final durationVal = draft.formValues['duration'];
        if (durationVal != null) {
          final double? durationHours = double.tryParse(durationVal.toString());
          if (durationHours != null) {
            endDateTime = startDateTime.add(Duration(minutes: (durationHours * 60).toInt()));
          }
        }
      }

      String content = '';
      List<String> tags = [];
      Map<String, dynamic>? bodyState;

      if (draft.selectedShortcut != null && draft.selectedShortcut!.hasPopup) {
        List<ShortcutField> fieldsToProcess = draft.selectedShortcut!.fields;
        Map<String, dynamic> finalFormValues = Map.from(draft.formValues);
        String categoryPrefix = '';

        if (draft.selectedShortcut!.categories != null && draft.selectedShortcut!.categories!.isNotEmpty) {
          final currentCategory = draft.selectedShortcut!.categories!.firstWhere(
            (c) => c.id == draft.formValues['_category'],
            orElse: () => draft.selectedShortcut!.categories!.first,
          );
          fieldsToProcess = currentCategory.fields;
          categoryPrefix = '${currentCategory.name} - ';
        }

        final details = fieldsToProcess.map((f) {
          final val = finalFormValues[f.id];
          if (val == null) return null;
          if (val is List) return '${f.label}：${val.join('、')}';
          return '${f.label}：$val';
        }).where((s) => s != null).join('，');

        final fullDetails = categoryPrefix.isNotEmpty ? '$categoryPrefix$details' : details;
        content = '$fullDetails${draft.inputText.isNotEmpty ? '\n备注：${draft.inputText}' : ''}';
        tags = [draft.selectedShortcut!.name];

        if (draft.selectedShortcut!.id == 'body') {
          bodyState = {
            'name': finalFormValues['symptom'] ?? '未知症状',
            'severity': finalFormValues['severity'] ?? '轻微',
            'duration': '未知',
            'notes': draft.inputText,
          };
        }
      } else {
        content = draft.inputText;
        tags = draft.selectedShortcut != null ? [draft.selectedShortcut!.name] : [];
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
        photos: record.photos,
      );
    }

    final currentTimeline = ref.read(diaryInputTimeProvider);
    setState(() {
      _drafts = [
        _Draft(
          id: const Uuid().v4(),
          startTime: currentTimeline?.time,
          endTime: currentTimeline?.endTime,
          startOffset: currentTimeline != null
              ? currentTimeline.date.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays
              : null,
          endOffset: (currentTimeline != null && currentTimeline.endDate != null)
              ? currentTimeline.endDate!.difference(DateTime(selectedDate.year, selectedDate.month, selectedDate.day)).inDays
              : null,
        )
      ];
      _activeDraftIndex = 0;
      _textController.text = '';
    });

    if (mounted) {
      FocusScope.of(context).unfocus();
    }

    if (firstSentTime != null) {
      ref.read(diaryScrollToTimeProvider.notifier).state = firstSentTime;
    }
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

  String _formatTime(TimeOfDay time, {int? offset}) {
    final now = ref.read(selectedDateProvider);
    final date = offset != null ? now.add(Duration(days: offset)) : now;
    final dateStr = DateFormat('MM-dd').format(date);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return '$dateStr $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TimelineTimeSelectEvent?>(diaryInputTimeProvider, (previous, next) {
      if (next != null) {
        final selectedDate = ref.read(selectedDateProvider);
        final startDay = DateTime(next.date.year, next.date.month, next.date.day);
        final baseDay = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
        final startOffset = startDay.difference(baseDay).inDays;

        int? endOffset;
        if (next.endDate != null) {
          final endDay = DateTime(next.endDate!.year, next.endDate!.month, next.endDate!.day);
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
        // If next is null, timeline selection was cleared/deselected.
        // Reset the draft time back to TimeOfDay.now() and clear offsets & end times.
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
        secondChild: _buildExpandedContent(theme, shortcuts),
        crossFadeState: _isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 300),
        sizeCurve: Curves.easeInOut,
      ),
    );
  }

  Widget _buildCollapsedContent(ThemeData theme) {
    return GestureDetector(
      onTap: () => setState(() => _isExpanded = true),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
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

  Widget _buildExpandedContent(ThemeData theme, AsyncValue<List<ShortcutConfig>> shortcuts) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          Flexible(
            child: _buildFormFieldsArea(theme),
          ),
          _buildDraftTabs(theme),
          _buildShortcutRow(theme, shortcuts),
          _buildTimeAndImageRow(theme),
          if (_activeDraft.selectedPhotos.isNotEmpty) _buildPhotoPreview(theme),
          _buildInputAndActions(theme),
        ],
      ),
    );
  }

  Widget _buildFormFieldsArea(ThemeData theme) {
    final shortcut = _activeDraft.selectedShortcut;
    final showFields = shortcut != null && shortcut.hasPopup;

    List<ShortcutField> fieldsToProcess = [];
    if (showFields) {
      fieldsToProcess = shortcut.fields;
      if (shortcut.categories != null && shortcut.categories!.isNotEmpty) {
        final currentCategory = shortcut.categories!.firstWhere(
          (c) => c.id == _activeDraft.formValues['_category'],
          orElse: () => shortcut.categories!.first,
        );
        fieldsToProcess = currentCategory.fields;
      }
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: showFields
          ? Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (shortcut.categories != null && shortcut.categories!.isNotEmpty)
                          _buildCategorySelector(theme, shortcut),
                        ...fieldsToProcess.map((field) => _buildFieldWidget(theme, field)),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 12,
                    child: GestureDetector(
                      onTap: () => _selectShortcut(null),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildCategorySelector(ThemeData theme, ShortcutConfig shortcut) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: shortcut.categories!.map((category) {
            final isSelected = (_activeDraft.formValues['_category'] ?? shortcut.categories!.first.id) == category.id;
            return Expanded(
              child: GestureDetector(
                onTap: () => _updateFormValue('_category', category.id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? theme.colorScheme.surface : null,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: isSelected
                        ? [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)]
                        : null,
                  ),
                  child: Text(
                    category.name,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
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

  Widget _buildFieldWidget(ThemeData theme, ShortcutField field) {
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
          _buildFieldInput(theme, field),
        ],
      ),
    );
  }

  Widget _buildFieldInput(ThemeData theme, ShortcutField field) {
    switch (field.type) {
      case 'select':
        return _buildSelectChips(theme, field);
      case 'multi-select':
        return _buildMultiSelectChips(theme, field);
      case 'input':
        return _buildTextField(theme, field);
      case 'number':
        return _buildNumberField(theme, field);
      case 'time':
        return _buildTimeField(theme, field);
      case 'water-amount':
        return _buildWaterAmountField(theme, field);
      default:
        return _buildTextField(theme, field);
    }
  }

  Widget _buildSelectChips(ThemeData theme, ShortcutField field) {
    final currentValue = _activeDraft.formValues[field.id];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: field.options.map((opt) {
        final isSelected = currentValue == opt;
        return GestureDetector(
          onTap: () => _updateFormValue(field.id, isSelected ? null : opt),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              opt,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMultiSelectChips(ThemeData theme, ShortcutField field) {
    final currentList = (_activeDraft.formValues[field.id] as List?)?.cast<String>() ?? [];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: field.options.map((opt) {
        final isSelected = currentList.contains(opt);
        return GestureDetector(
          onTap: () {
            final newList = List<String>.from(currentList);
            if (isSelected) {
              newList.remove(opt);
            } else {
              newList.add(opt);
            }
            _updateFormValue(field.id, newList.isEmpty ? null : newList);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              opt,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTextField(ThemeData theme, ShortcutField field) {
    final currentValue = _activeDraft.formValues[field.id]?.toString() ?? '';
    final controller = _getFormController(field.id, currentValue);
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest,
          hintText: '请输入${field.label}...',
          hintStyle: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          isDense: true,
        ),
        onChanged: (val) => _updateFormValue(field.id, val.isEmpty ? null : val),
      ),
    );
  }

  Widget _buildNumberField(ThemeData theme, ShortcutField field) {
    final currentValue = _activeDraft.formValues[field.id]?.toString() ?? '';
    final controller = _getFormController(field.id, currentValue);
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
          hintStyle: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          isDense: true,
        ),
        onChanged: (val) => _updateFormValue(field.id, val.isEmpty ? null : val),
      ),
    );
  }

  Widget _buildTimeField(ThemeData theme, ShortcutField field) {
    final currentValue = _activeDraft.formValues[field.id] as String?;
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
          _updateFormValue(field.id, '${result.hour.toString().padLeft(2, '0')}:${result.minute.toString().padLeft(2, '0')}');
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
                color: currentValue != null ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
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

  Widget _buildDayTab(ThemeData theme, String label, int value, bool isSelected) {
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
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildWaterAmountField(ThemeData theme, ShortcutField field) {
    final currentValue = (_activeDraft.formValues[field.id] as int?) ?? 0;
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
              onPressed: currentValue > 0 ? () => _updateFormValue(field.id, currentValue - 100) : null,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            IconButton(
              onPressed: currentValue < 2000 ? () => _updateFormValue(field.id, currentValue + 100) : null,
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
          onChanged: (val) => _updateFormValue(field.id, val.toInt()),
        ),
      ],
    );
  }

  Widget _buildDraftTabs(ThemeData theme) {
    final showTabs = _drafts.length > 1 || _activeDraft.selectedShortcut != null;
    if (!showTabs) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...List.generate(_drafts.length, (idx) {
                    final draft = _drafts[idx];
                    final isActive = idx == _activeDraftIndex;
                    final shouldShow = _drafts.length > 1 || draft.selectedShortcut != null;
                    if (!shouldShow) return const SizedBox.shrink();

                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isActive ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: () => _switchDraft(idx),
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: 8,
                                  top: 4,
                                  bottom: 4,
                                  right: isActive && _drafts.length > 1 ? 4 : 8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${idx + 1}',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                                      ),
                                    ),
                                    if (draft.selectedShortcut != null) ...[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Text(
                                          '|',
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: isActive ? theme.colorScheme.onPrimary.withValues(alpha: 0.4) : theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        draft.selectedShortcut!.name,
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (isActive && _drafts.length > 1)
                              GestureDetector(
                                onTap: () => _removeDraft(idx),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    Icons.close,
                                    size: 12,
                                    color: theme.colorScheme.onPrimary.withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                  if (_drafts.length < 5)
                    GestureDetector(
                      onTap: _addDraft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 12, color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              '新增',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutRow(ThemeData theme, AsyncValue<List<ShortcutConfig>> shortcuts) {
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
                  data: (list) => list.map<Widget>((config) {
                    final isSelected = _activeDraft.selectedShortcut?.id == config.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: GestureDetector(
                        onTap: () => _selectShortcut(config),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
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
                                color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                config.name,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                  loading: () => <Widget>[const SizedBox(width: 60, height: 28, child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))],
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
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)],
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
      case '记账':
        return Icons.wallet_rounded;
      default:
        return Icons.apps;
    }
  }

  Widget _buildTimeAndImageRow(ThemeData theme) {
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
                        color: theme.colorScheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(alpha: 0.15),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.access_time_rounded, size: 14, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _formatTime(_activeDraft.startTime, offset: _activeDraft.startOffset),
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
                const SizedBox(width: 8),
                Expanded(
                  child: _activeDraft.endTime != null
                      ? Container(
                          height: 36,
                          padding: const EdgeInsets.only(left: 8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(alpha: 0.15),
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
                                      Icon(Icons.access_time_rounded, size: 14, color: theme.colorScheme.primary),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _formatTime(_activeDraft.endTime!, offset: _activeDraft.endOffset),
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
                              GestureDetector(
                                onTap: _clearEndTime,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
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
                            color: theme.colorScheme.primary.withValues(alpha: 0.3),
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
                                  Icon(Icons.add, size: 14, color: theme.colorScheme.primary),
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
            onTap: _activeDraft.selectedPhotos.length < 3 ? _pickImageFromGallery : null,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(Icons.image_outlined, size: 20, color: theme.colorScheme.primary),
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
            onTap: _activeDraft.selectedPhotos.length < 3 ? _pickImageFromCamera : null,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.camera_alt_outlined, size: 20, color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoPreview(ThemeData theme) {
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
                  onTap: () => _showFullImage(_activeDraft.selectedPhotos[index]),
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
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _removePhoto(index),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(12),
                          bottomLeft: Radius.circular(8),
                        ),
                      ),
                      child: const Icon(Icons.close, size: 12, color: Colors.white),
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
                child: UnifiedImage(
                  imagePath: path,
                  fit: BoxFit.contain,
                ),
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
    final isValidationError = (draft.selectedShortcut?.id == 'consumption' && draft.formValues['amount'] == null) ||
        (draft.selectedShortcut?.id == 'sleep' && draft.formValues['duration'] == null);
    final isEmpty = draft.inputText.trim().isEmpty && draft.selectedShortcut == null && draft.selectedPhotos.isEmpty;
    final isDisabled = isValidationError || isEmpty;

    final aiTempsAsync = ref.watch(aiTemperaturesProvider);
    final extractImages = aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final isExtractButtonEnabled = draft.inputText.trim().isNotEmpty || (extractImages && draft.selectedPhotos.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 140),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                      hintText: draft.selectedShortcut != null ? '记录${draft.selectedShortcut!.name}...' : '记录当前...',
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
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
                        final hasShortcut = draft.selectedShortcut != null;
                        final hasPhotos = draft.selectedPhotos.isNotEmpty;
                        if (!hasText && !hasShortcut && !hasPhotos) return const SizedBox.shrink();
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: _clearCurrentDraft,
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.85),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.red.withValues(alpha: 0.25),
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
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _handleAiExtract,
            onLongPress: _showModelMenu,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _isExtracting
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
                            : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
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
                    ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                    : theme.colorScheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  Icons.send_rounded,
                  size: 20,
                  color: isDisabled
                      ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)
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

  const _ModelSelectionDialog({
    required this.configs,
    this.selectedId,
  });

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
      color: isSelected ? colorScheme.primary.withValues(alpha: 0.05) : Colors.transparent,
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
                    color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
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
                        color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${config.provider} / ${config.modelName}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
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
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2, size.width - strokeWidth, size.height - strokeWidth),
        Radius.circular(borderRadius),
      ));

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

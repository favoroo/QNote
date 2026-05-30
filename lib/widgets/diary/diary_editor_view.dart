import 'dart:io';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/widgets/diary/ai_extract_helper.dart';
import 'package:qnote_flutter/widgets/diary/edit_tag_time_sheet.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';
import 'package:qnote_flutter/widgets/tag_picker.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

class DiaryEditorView extends ConsumerStatefulWidget {
  final DiaryRecord record;

  const DiaryEditorView({super.key, required this.record});

  @override
  ConsumerState<DiaryEditorView> createState() => _DiaryEditorViewState();
}

class _DiaryEditorViewState extends ConsumerState<DiaryEditorView> {
  late TextEditingController _contentController;
  late DateTime _time;
  late DateTime? _startTime;
  late DateTime? _endTime;
  late List<String> _tags;
  late String _displayTag;
  late List<String> _photos;
  late List<String> _newlyUploadedPaths;
  late List<String> _removedPaths;
  late List<TagEntry> _tagEntries;
  bool _isExtracting = false;
  CancelToken? _cancelToken;
  final Map<String, Future<String>> _compressingTasks = {};

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

  void _updateFormValue(String tagId, String fieldKey, dynamic value) {
    setState(() {
      _tagEntries = _tagEntries.map((entry) {
        if (entry.id == tagId) {
          var newFields = Map<String, dynamic>.from(entry.fields);
          if (value == null) {
            newFields.remove(fieldKey);
          } else {
            newFields[fieldKey] = value;
          }

          if (tagId == 'sleep') {
            if (fieldKey == 'fallAsleepTime' && value != null) {
              final timeStr = value as String;
              final parts = timeStr.split(':');
              if (parts.length >= 2) {
                final h = int.tryParse(parts[0]) ?? 0;
                final m = int.tryParse(parts[1]) ?? 0;
                final currentStart = _startTime ?? _time;
                final newStart = DateTime(
                  currentStart.year,
                  currentStart.month,
                  currentStart.day,
                  h,
                  m,
                );
                _startTime = newStart;

                if (_endTime != null) {
                  final diffMin = _endTime!.difference(newStart).inMinutes;
                  newFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
                }

                final baseDate = DateTime(_time.year, _time.month, _time.day);
                final startOffset = DateTime(newStart.year, newStart.month, newStart.day).difference(baseDate).inDays;

                int? endHour;
                int? endMinute;
                int? endOffset;
                if (_endTime != null) {
                  endHour = _endTime!.hour;
                  endMinute = _endTime!.minute;
                  endOffset = DateTime(_endTime!.year, _endTime!.month, _endTime!.day).difference(baseDate).inDays;
                }

                entry = entry.copyWith(
                  startHour: h,
                  startMinute: m,
                  startOffset: startOffset,
                  endHour: endHour,
                  endMinute: endMinute,
                  endOffset: endOffset,
                  clearEndTime: _endTime == null,
                );
                entry = entry.copyWith(time: entry.formattedTime);
              }
            }

            if (fieldKey == 'duration' && value != null) {
              final double? durationHours = double.tryParse(value.toString());
              if (durationHours != null) {
                final currentStart = _startTime ?? _time;
                final newEnd = currentStart.add(
                  Duration(minutes: (durationHours * 60).toInt()),
                );
                _endTime = newEnd;

                final baseDate = DateTime(_time.year, _time.month, _time.day);
                final startOffset = DateTime(currentStart.year, currentStart.month, currentStart.day).difference(baseDate).inDays;
                final endOffset = DateTime(newEnd.year, newEnd.month, newEnd.day).difference(baseDate).inDays;

                entry = entry.copyWith(
                  startHour: currentStart.hour,
                  startMinute: currentStart.minute,
                  startOffset: startOffset,
                  endHour: newEnd.hour,
                  endMinute: newEnd.minute,
                  endOffset: endOffset,
                );
                entry = entry.copyWith(time: entry.formattedTime);
              }
            }
          }

          return entry.copyWith(fields: newFields);
        }
        return entry;
      }).toList();
    });
  }

  String _parseUserRemarks(String content, List<TagEntry> tagEntries) {
    if (content.contains('\n备注：')) {
      final parts = content.split('\n备注：');
      if (parts.length > 1) {
        return parts.sublist(1).join('\n备注：');
      }
    }

    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
    final hasPopupFields = tagEntries.any((entry) {
      final sc = shortcuts
          .where((s) => s.id == entry.id || s.name == entry.name)
          .firstOrNull;
      return sc != null && sc.hasPopup;
    });

    if (!hasPopupFields) {
      return content;
    }

    if (content.contains('：') || content.contains(':')) {
      return '';
    }
    return content;
  }

  @override
  void initState() {
    super.initState();
    final r = widget.record;
    _time = r.time;
    _startTime = r.startTime;
    _endTime = r.endTime;
    _tags = List.from(r.tags);
    _displayTag = r.displayTag;
    _photos = List.from(r.photos);
    _newlyUploadedPaths = [];
    _removedPaths = [];
    _tagEntries = List.from(r.tagEntries);
    _contentController = TextEditingController(
      text: _parseUserRemarks(r.content, _tagEntries),
    );
  }

  @override
  void dispose() {
    _contentController.dispose();
    for (final c in _formControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int _getStartOffset() {
    final start = _startTime ?? _time;
    final baseDate = DateTime(_time.year, _time.month, _time.day);
    final startDate = DateTime(start.year, start.month, start.day);
    return startDate.difference(baseDate).inDays;
  }

  Future<void> _pickTime() async {
    final result = await showTimePickerDialog(
      context: context,
      initialTime: _startTime ?? _time,
      mode: TimePickerMode.dateTime,
    );
    if (result != null) {
      setState(() {
        _time = result;
        _startTime = result;

        _tagEntries = _tagEntries.map((entry) {
          if (entry.id == 'sleep' || entry.name == '睡眠') {
            final newFields = Map<String, dynamic>.from(entry.fields);
            newFields['fallAsleepTime'] =
                '${result.hour.toString().padLeft(2, '0')}:${result.minute.toString().padLeft(2, '0')}';
            
            final baseDate = DateTime(_time.year, _time.month, _time.day);
            final startOffset = DateTime(result.year, result.month, result.day).difference(baseDate).inDays;
            
            int? endHour;
            int? endMinute;
            int? endOffset;

            if (_endTime != null) {
              final diffMin = _endTime!.difference(result).inMinutes;
              newFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
              
              endHour = _endTime!.hour;
              endMinute = _endTime!.minute;
              endOffset = DateTime(_endTime!.year, _endTime!.month, _endTime!.day).difference(baseDate).inDays;
            }
            
            return entry.copyWith(
              fields: newFields,
              startHour: result.hour,
              startMinute: result.minute,
              startOffset: startOffset,
              endHour: endHour,
              endMinute: endMinute,
              endOffset: endOffset,
            );
          }
          return entry;
        }).toList();
      });
    }
  }

  Future<void> _pickEndTime() async {
    final result = await showTimePickerDialog(
      context: context,
      initialTime: _endTime ?? _startTime ?? _time,
      mode: TimePickerMode.dateTime,
    );
    if (result != null) {
      setState(() {
        _endTime = result;

        _tagEntries = _tagEntries.map((entry) {
          if (entry.id == 'sleep' || entry.name == '睡眠') {
            final newFields = Map<String, dynamic>.from(entry.fields);
            final start = _startTime ?? _time;
            final diffMin = result.difference(start).inMinutes;
            newFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
            
            final baseDate = DateTime(_time.year, _time.month, _time.day);
            final startOffset = DateTime(start.year, start.month, start.day).difference(baseDate).inDays;
            final endOffset = DateTime(result.year, result.month, result.day).difference(baseDate).inDays;
            
            return entry.copyWith(
              fields: newFields,
              startHour: start.hour,
              startMinute: start.minute,
              startOffset: startOffset,
              endHour: result.hour,
              endMinute: result.minute,
              endOffset: endOffset,
            );
          }
          return entry;
        }).toList();
      });
    }
  }

  Future<void> _editTagTime(TagEntry entry) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => EditTagTimeSheet(entry: entry),
    );

    if (result != null) {
      if (result['clear'] == true) {
        setState(() {
          _tagEntries = _tagEntries.map((e) {
            if (e.id == entry.id || e.name == entry.name) {
              final updatedFields = Map<String, dynamic>.from(e.fields);
              if (e.id == 'sleep' || e.name == '睡眠') {
                updatedFields.remove('fallAsleepTime');
                updatedFields.remove('duration');
                _startTime = null;
                _endTime = null;
              }
              return e.copyWith(
                clearStartTime: true,
                clearEndTime: true,
                fields: updatedFields,
              );
            }
            return e;
          }).toList();
        });
        return;
      }

      final startHour = result['startHour'] as int?;
      final startMinute = result['startMinute'] as int?;
      final startOffset = result['startOffset'] as int?;
      final endHour = result['endHour'] as int?;
      final endMinute = result['endMinute'] as int?;
      final endOffset = result['endOffset'] as int?;

      setState(() {
        _tagEntries = _tagEntries.map((e) {
          if (e.id == entry.id || e.name == entry.name) {
            Map<String, dynamic> updatedFields = Map<String, dynamic>.from(e.fields);
            if (e.id == 'sleep' || e.name == '睡眠') {
              if (startHour != null && startMinute != null) {
                updatedFields['fallAsleepTime'] =
                    '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}';
                
                final baseDate = DateTime(_time.year, _time.month, _time.day);
                final startDate = baseDate.add(Duration(days: startOffset ?? 0));
                final startDt = DateTime(
                  startDate.year,
                  startDate.month,
                  startDate.day,
                  startHour,
                  startMinute,
                );

                if (endHour != null && endMinute != null) {
                  final endDate = baseDate.add(Duration(days: endOffset ?? 0));
                  final endDt = DateTime(
                    endDate.year,
                    endDate.month,
                    endDate.day,
                    endHour,
                    endMinute,
                  );
                  final diffMin = endDt.difference(startDt).inMinutes;
                  final newDuration = (diffMin / 60.0 * 10).round() / 10.0;
                  updatedFields['duration'] = newDuration.toStringAsFixed(1);
                  
                  _startTime = startDt;
                  _endTime = endDt;
                } else {
                  updatedFields.remove('duration');
                  _startTime = startDt;
                  _endTime = null;
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
      });
    }
  }

  Future<void> _pickTags() async {
    final shortcuts = ref.read(shortcutListProvider);
    final availableTags =
        shortcuts.valueOrNull?.where((s) => s.isVisible).map((s) => s.name).toList() ?? [];
    final result = await showTagPickerDialog(
      context: context,
      availableTags: availableTags,
      selectedTags: _tags,
    );
    if (result != null) {
      setState(() {
        _tags = result;
        if (result.isNotEmpty) {
          _displayTag = result.first;
        } else {
          _displayTag = '记录';
        }

        final currentEntriesMap = {for (final e in _tagEntries) e.name: e};
        final newEntries = <TagEntry>[];
        for (final name in result) {
          if (currentEntriesMap.containsKey(name)) {
            newEntries.add(currentEntriesMap[name]!);
          } else {
            final sc = shortcuts.valueOrNull
                ?.where((s) => s.name == name)
                .firstOrNull;
            final entryId = sc?.id ?? name;
            final initialFields = <String, dynamic>{};
            if (sc?.id == 'sleep') {
              final start = _startTime ?? _time;
              initialFields['fallAsleepTime'] =
                  '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
              if (_endTime != null) {
                final diffMin = _endTime!.difference(start).inMinutes;
                initialFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
              }
            }
            newEntries.add(
              TagEntry(id: entryId, name: name, fields: initialFields),
            );
          }
        }
        _tagEntries = newEntries;
      });
    }
  }

  void _toggleShortcut(ShortcutConfig config) {
    setState(() {
      final name = config.name;
      if (_tags.contains(name)) {
        _tags.remove(name);
        _tagEntries = _tagEntries
            .where((e) => e.id != config.id && e.name != name)
            .toList();
      } else {
        _tags.add(name);

        final initialFields = <String, dynamic>{};
        if (config.id == 'sleep') {
          final start = _startTime ?? _time;
          initialFields['fallAsleepTime'] =
              '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
          if (_endTime != null) {
            final diffMin = _endTime!.difference(start).inMinutes;
            initialFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
          }
        }

        _tagEntries.add(
          TagEntry(id: config.id, name: name, fields: initialFields),
        );
      }

      if (_tags.isNotEmpty) {
        _displayTag = _tags.first;
      } else {
        _displayTag = '记录';
      }
    });
  }

  Future<void> _addPhoto(ImageSource source) async {
    if (_photos.length >= 3) return;
    final XFile? xFile;
    if (source == ImageSource.camera) {
      final picker = ImagePicker();
      xFile = await picker.pickImage(
        source: source,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 80,
      );
    } else {
      xFile = await GalleryHelper.pickSingleImage(context);
    }
    if (xFile == null) return;

    final tempPath = xFile.path;

    // 立即更新 UI，将临时路径加入到 _photos，实现“秒显”
    setState(() {
      _photos.add(tempPath);
    });

    final imageRepo = ImageRepository();
    // 启动异步任务
    final Future<String> compressFuture = imageRepo.saveImage(
      File(tempPath),
      subfolder: 'diary',
    );
    
    _compressingTasks[tempPath] = compressFuture;
    
    try {
      final savedPath = await compressFuture;
      
      if (!mounted) return;
      
      setState(() {
        _compressingTasks.remove(tempPath);
        // 如果用户在压缩期间没有删除该图片，就把临时路径替换为压缩保存后的永久路径
        final index = _photos.indexOf(tempPath);
        if (index != -1) {
          _photos[index] = savedPath;
          _newlyUploadedPaths.add(savedPath);
        } else {
          // 如果用户已经删除了它，就把新保存的永久图片文件删除，防止垃圾文件堆积
          imageRepo.deleteImage(savedPath);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _compressingTasks.remove(tempPath);
        _photos.remove(tempPath);
      });
      Toast.error(context, '图片处理失败：$e');
    }
  }

  void _removePhoto(int index) {
    final removed = _photos.removeAt(index);
    if (_newlyUploadedPaths.contains(removed)) {
      _newlyUploadedPaths.remove(removed);
      ImageRepository().deleteImage(removed);
    } else {
      _removedPaths.add(removed);
    }
    setState(() {});
  }

  void _previewPhoto(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullScreenImageView(imagePath: _photos[index]),
      ),
    );
  }

  Future<void> _waitForCompressing() async {
    if (_compressingTasks.isNotEmpty) {
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
                  Text('正在处理图片，请稍候...'),
                ],
              ),
            ),
          ),
        ),
      );
      try {
        await Future.wait(_compressingTasks.values);
      } catch (e) {
        debugPrint('Error waiting for compression: $e');
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _save() async {
    await _waitForCompressing();
    if (!mounted) return;

    // Ensure sleep tag time is in sync with record time on save (only if sleepEntry has time or _startTime is set)
    final sleepIndex = _tagEntries.indexWhere((e) => e.id == 'sleep' || e.name == '睡眠');
    if (sleepIndex != -1) {
      final sleepEntry = _tagEntries[sleepIndex];
      if (sleepEntry.hasTime || _startTime != null) {
        final start = _startTime ?? _time;
        final baseDate = DateTime(_time.year, _time.month, _time.day);
        final startOffset = DateTime(start.year, start.month, start.day).difference(baseDate).inDays;
        
        int? endHour;
        int? endMinute;
        int? endOffset;
        if (_endTime != null) {
          endHour = _endTime!.hour;
          endMinute = _endTime!.minute;
          endOffset = DateTime(_endTime!.year, _endTime!.month, _endTime!.day).difference(baseDate).inDays;
        }
        
        final updatedSleep = sleepEntry.copyWith(
          startHour: start.hour,
          startMinute: start.minute,
          startOffset: startOffset,
          endHour: endHour,
          endMinute: endMinute,
          endOffset: endOffset,
          clearEndTime: _endTime == null,
        );
        
        _tagEntries[sleepIndex] = updatedSleep.copyWith(time: updatedSleep.formattedTime);
      }
    }

    for (final path in _removedPaths) {
      await ImageRepository().deleteImage(path);
    }

    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];

    // Dynamically calculate bodyState based on the selected tag entries
    Map<String, dynamic>? bodyState;
    for (final entry in _tagEntries) {
      try {
        final config = shortcuts.firstWhere(
          (s) => s.id == entry.id || s.name == entry.name,
        );
        if (config.hasPopup) {
          if (config.id == 'health') {
            final symptomVal = entry.fields['symptom'];
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
              'severity': entry.fields['severity'] ?? '轻微',
              'medication': entry.fields['medication'],
              'notes': _contentController.text,
            };
          } else
            bodyState ??= Map<String, dynamic>.from(entry.fields);
        }
      } catch (_) {}
    }

    if (_tagEntries.isNotEmpty && bodyState == null) {
      bodyState = Map<String, dynamic>.from(_tagEntries.first.fields);
    }

    String content = '';
    final popupEntries = <TagEntry>[];
    final popupConfigs = <ShortcutConfig>[];

    for (final entry in _tagEntries) {
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
      }

      final allDetails = detailParts.join('；');
      final remarksText = _contentController.text.trim();
      content =
          '$allDetails${remarksText.isNotEmpty ? '\n备注：$remarksText' : ''}';
    } else {
      content = _contentController.text;
    }

    final updated = widget.record.copyWith(
      time: _time,
      startTime: _startTime,
      endTime: _endTime,
      tags: _tags,
      displayTag: _displayTag,
      content: content,
      photos: _photos,
      bodyState: bodyState,
      tagEntries: _tagEntries,
      updatedAt: DateTime.now(),
    );
    await ref.read(diaryListProvider.notifier).updateDiary(updated);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('删除后可在回收站恢复，确定要删除这条记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      for (final path in _newlyUploadedPaths) {
        await ImageRepository().deleteImage(path);
      }
      await ref.read(diaryListProvider.notifier).deleteDiary(widget.record.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _handleBack() {
    for (final path in _newlyUploadedPaths) {
      ImageRepository().deleteImage(path);
    }
    Navigator.of(context).pop();
  }

  String _mergeNotesWithContent(String notes, String originalContent) {
    if (notes.isEmpty) return originalContent;
    if (originalContent.isEmpty) return notes;
    if (notes.startsWith('图：') || notes.startsWith('图:')) {
      return '$originalContent\n$notes';
    }
    if (!originalContent.contains(notes)) {
      return '$originalContent\n$notes';
    }
    return originalContent;
  }

  Future<void> _handleAiExtract() async {
    if (_isExtracting) {
      _cancelToken?.cancel();
      _cancelToken = null;
      return;
    }
    final contentText = _contentController.text.trim();
    if (contentText.isEmpty && _photos.isEmpty) return;

    setState(() => _isExtracting = true);

    _cancelToken = CancelToken();
    final result = await extractExistingRecord(
      ref: ref,
      context: context,
      content: contentText,
      photos: _photos,
      recordTime: _time,
      startTime: _startTime,
      endTime: _endTime,
      onLoadingChanged: (loading) {
        if (mounted) setState(() => _isExtracting = loading);
      },
      cancelToken: _cancelToken,
    );

    if (result != null && mounted) {
      final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
      final foundShortcut = findShortcutById(result.shortcutId, shortcuts);

      _formControllers.clear();

      if (result.tagEntries.isNotEmpty) {
        final newContent = _photos.isNotEmpty
            ? _mergeNotesWithContent(
                result.notes,
                _contentController.text,
              )
            : _contentController.text;
        setState(() {
          _tagEntries = result.tagEntries;
          _tags = result.tagEntries.map((e) => e.name).toList();
          _displayTag = result.tagEntries.first.name;
          _contentController.text = newContent;
        });
      } else if (foundShortcut != null) {
        final newContent = _photos.isNotEmpty
            ? _mergeNotesWithContent(
                result.notes,
                _contentController.text,
              )
            : _contentController.text;
        setState(() {
          if (!_tags.contains(foundShortcut.name)) {
            _tags = [
              foundShortcut.name,
              ..._tags.where((t) => t != _displayTag),
            ];
          }
          _displayTag = foundShortcut.name;
          _contentController.text = newContent;
        });
      }

      if (result.time.isNotEmpty) {
        final baseDate = DateTime(_time.year, _time.month, _time.day);
        if (result.time['start'] != null) {
          final parts = (result.time['start'] as String).split(':');
          if (parts.length >= 2) {
            final hour = int.tryParse(parts[0]) ?? _time.hour;
            final minute = int.tryParse(parts[1]) ?? _time.minute;
            final startOffset = result.time['startOffset'] as int? ?? 0;
            final dt = baseDate.add(
              Duration(days: startOffset, hours: hour, minutes: minute),
            );
            setState(() {
              _time = dt;
              _startTime = dt;
            });
          }
        }
        if (result.time['end'] != null) {
          final parts = (result.time['end'] as String).split(':');
          if (parts.length >= 2) {
            final hour = int.tryParse(parts[0]) ?? 0;
            final minute = int.tryParse(parts[1]) ?? 0;
            final endOffset = result.time['endOffset'] as int? ?? 0;
            setState(() {
              _endTime = baseDate.add(
                Duration(days: endOffset, hours: hour, minutes: minute),
              );
            });
          }
        } else {
          setState(() {
            _endTime = null;
          });
        }
      }

      Toast.success(context, '优化完成');
    }

    _cancelToken = null;
    setState(() => _isExtracting = false);
  }

  Future<void> _showModelMenu() async {
    List<AiConfig> configs = [];
    try {
      configs = await ref.read(aiConfigListProvider.future);
    } catch (_) {}

    if (!mounted || configs.isEmpty) {
      Toast.warning(context, '无可用模型');
      return;
    }

    final roles = await AiRoleService.instance.getRoles();
    final currentModelId = roles.timelineOptimization;
    if (!mounted) return;

    final selectedConfig = await showDialog<AiConfig>(
      context: context,
      builder: (context) =>
          _ExtractModelDialog(configs: configs, selectedId: currentModelId),
    );

    if (selectedConfig != null && mounted) {
      await AiRoleService.instance.saveRoles(
        roles.copyWith(timelineOptimization: selectedConfig.id),
      );
      if (mounted) {
        Toast.success(
          context,
          '已切换：${selectedConfig.name}',
          duration: const Duration(seconds: 1),
        );
      }
    }
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          title: const Text('编辑记录'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: Icon(Icons.delete_outline, color: colorScheme.error),
              onPressed: _delete,
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTimeSection(theme, colorScheme),
                    const SizedBox(height: 24),
                    _buildTagSection(theme, colorScheme),
                    const SizedBox(height: 24),
                    _buildContentSection(theme, colorScheme),
                    const SizedBox(height: 24),
                    _buildPhotosSection(theme, colorScheme),
                  ],
                ),
              ),
            ),
            _buildBottomBar(colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '记录时间',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            GestureDetector(
              onTap: _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                height: 44,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule, size: 16, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _formatDateTime(_startTime ?? _time),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (_endTime != null)
              GestureDetector(
                onTap: _pickEndTime,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _formatDateTime(_endTime!),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: _pickEndTime,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.3,
                    ),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.2),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '结束时间',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTagSection(ThemeData theme, ColorScheme colorScheme) {
    final tagIcons = <String, IconData>{
      '睡眠': Icons.nightlight_round,
      '饮食': Icons.restaurant,
      '活动': Icons.directions_run,
      '记账': Icons.account_balance_wallet,
    };
    final tagColors = <String, Color>{
      '睡眠': const Color(0xFF6366F1),
      '饮食': const Color(0xFFF59E0B),
      '活动': const Color(0xFF10B981),
      '记账': const Color(0xFFEF4444),
    };

    final shortcuts = ref.watch(shortcutListProvider).valueOrNull ?? [];
    final shortcutNames = shortcuts.map((s) => s.name).toSet();
    final customTags = _tags.where((t) => !shortcutNames.contains(t)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '分类标签',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ...shortcuts.where((s) => s.isVisible).map((config) {
              final isSelected = _tags.contains(config.name);
              final color = tagColors[config.name] ?? colorScheme.primary;
              final icon = tagIcons[config.name] ?? Icons.label;

              return ChoiceChip(
                label: Text(config.name),
                avatar: Icon(
                  icon,
                  size: 14,
                  color: isSelected
                      ? Colors.white
                      : colorScheme.onSurfaceVariant,
                ),
                selected: isSelected,
                selectedColor: color,
                backgroundColor: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                checkmarkColor: Colors.white,
                showCheckmark: false,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: isSelected
                        ? Colors.transparent
                        : colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                onSelected: (_) => _toggleShortcut(config),
              );
            }),
            ...customTags.map((tagName) {
              return Chip(
                label: Text(tagName),
                avatar: Icon(
                  Icons.label,
                  size: 14,
                  color: colorScheme.onPrimary,
                ),
                backgroundColor: colorScheme.primary,
                labelStyle: TextStyle(
                  color: colorScheme.onPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                deleteIcon: Icon(
                  Icons.close,
                  size: 14,
                  color: colorScheme.onPrimary,
                ),
                onDeleted: () {
                  setState(() {
                    _tags.remove(tagName);
                    _tagEntries = _tagEntries
                        .where((e) => e.name != tagName)
                        .toList();
                    if (_tags.isNotEmpty) {
                      _displayTag = _tags.first;
                    } else {
                      _displayTag = '记录';
                    }
                  });
                },
              );
            }),
            ActionChip(
              label: const Text('添加其他'),
              avatar: const Icon(Icons.add, size: 14),
              onPressed: _pickTags,
              labelStyle: const TextStyle(fontSize: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
        if (_tagEntries.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._tagEntries.map((entry) {
            final color = tagColors[entry.name] ?? colorScheme.primary;
            final icon = tagIcons[entry.name] ?? Icons.label;

            final sc = shortcuts
                .where((s) => s.id == entry.id || s.name == entry.name)
                .firstOrNull;
            final hasFields = sc != null && sc.hasPopup;

            List<ShortcutField> fieldsToProcess = sc?.fields ?? [];
            if (sc != null &&
                sc.categories != null &&
                sc.categories!.isNotEmpty) {
              final currentCategory = sc.categories!.firstWhere(
                (c) => c.id == entry.fields['_category'],
                orElse: () => sc.categories!.first,
              );
              fieldsToProcess = currentCategory.fields;
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 14, color: color),
                              const SizedBox(width: 6),
                              Text(
                                entry.name,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _editTagTime(entry),
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
                            setState(() {
                              _tagEntries = _tagEntries
                                  .where((e) => e.id != entry.id)
                                  .toList();
                              _tags = _tagEntries.map((e) => e.name).toList();
                              _displayTag = _tagEntries.isNotEmpty
                                  ? _tagEntries.first.name
                                  : '记录';
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: colorScheme.error.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (hasFields) ...[
                      if (sc.categories != null && sc.categories!.isNotEmpty)
                        _buildCategorySelector(theme, sc, entry.id),
                      ...fieldsToProcess.map(
                        (field) => _buildFieldWidget(theme, field, entry.id),
                      ),
                    ] else if (entry.fields.isNotEmpty) ...[
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: entry.fields.entries
                            .where((f) => !f.key.startsWith('_'))
                            .map((f) {
                              return Text(
                                '${f.key}: ${f.value}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              );
                            })
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _buildCategorySelector(
    ThemeData theme,
    ShortcutConfig config,
    String tagId,
  ) {
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
                onTap: () => _updateFormValue(tagId, '_category', category.id),
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
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
                onTap: () =>
                    _updateFormValue(tagId, field.id, isSelected ? null : opt),
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
                    _updateFormValue(tagId, field.id, null),
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
                  _updateFormValue(tagId, field.id, val.trim());
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
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
                      tagId, field.id, newList.isEmpty ? null : newList);
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
                      tagId, field.id, newList.isEmpty ? null : newList);
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
                      tagId, field.id, newList.isEmpty ? null : newList);
                }
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTextField(ThemeData theme, ShortcutField field, String tagId) {
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
            _updateFormValue(tagId, field.id, val.isEmpty ? null : val),
      ),
    );
  }

  Widget _buildNumberField(ThemeData theme, ShortcutField field, String tagId) {
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
            _updateFormValue(tagId, field.id, val.isEmpty ? null : val),
      ),
    );
  }

  Widget _buildTimeField(ThemeData theme, ShortcutField field, String tagId) {
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
            tagId,
            field.id,
            '${result.hour.toString().padLeft(2, '0')}:${result.minute.toString().padLeft(2, '0')}',
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
      final currentOffset = _getStartOffset();
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
        final base = DateTime(_time.year, _time.month, _time.day);
        final start = _startTime ?? _time;
        final newStart = DateTime(
          base.year,
          base.month,
          base.day,
          start.hour,
          start.minute,
        ).add(Duration(days: value));
        setState(() {
          _startTime = newStart;
          _tagEntries = _tagEntries.map((entry) {
            if (entry.id == 'sleep') {
              final newFields = Map<String, dynamic>.from(entry.fields);
              if (_endTime != null) {
                final diffMin = _endTime!.difference(newStart).inMinutes;
                newFields['duration'] = (diffMin / 60.0).toStringAsFixed(1);
              }
              return entry.copyWith(fields: newFields);
            }
            return entry;
          }).toList();
        });
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
    final entry = _tagEntries.where((e) => e.id == tagId).firstOrNull;
    final formValues = entry != null
        ? Map<String, dynamic>.from(entry.fields)
        : {};
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
                  ? () => _updateFormValue(tagId, field.id, currentValue - 100)
                  : null,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            IconButton(
              onPressed: currentValue < 2000
                  ? () => _updateFormValue(tagId, field.id, currentValue + 100)
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
          onChanged: (val) => _updateFormValue(tagId, field.id, val.toInt()),
        ),
      ],
    );
  }

  Widget _buildContentSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        const SizedBox(height: 16),
        Text(
          '内容',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _contentController,
          maxLines: null,
          minLines: 5,
          decoration: InputDecoration(
            hintText: '在此输入详细记录内容...',
            border: InputBorder.none,
            filled: false,
          ),
          style: theme.textTheme.bodyLarge,
        ),
      ],
    );
  }

  Widget _buildPhotosSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              '照片 (最多3张)',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _photos.length + (_photos.length < 3 ? 2 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index < _photos.length) {
                return _buildPhotoItem(index, colorScheme);
              }
              final isGallery = index == _photos.length;
              return _buildAddPhotoButton(
                icon: isGallery ? Icons.photo_library : Icons.camera_alt,
                label: isGallery ? '图库' : '拍照',
                source: isGallery ? ImageSource.gallery : ImageSource.camera,
                colorScheme: colorScheme,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoItem(int index, ColorScheme colorScheme) {
    final path = _photos[index];
    final isCompressing = _compressingTasks.containsKey(path);
    return GestureDetector(
      onTap: () => _previewPhoto(index),
      child: Stack(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  UnifiedImage(
                    imagePath: path,
                    width: 80,
                    height: 80,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  if (isCompressing)
                    Container(
                      color: Colors.black.withValues(alpha: 0.4),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
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
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () => _removePhoto(index),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddPhotoButton({
    required IconData icon,
    required String label,
    required ImageSource source,
    required ColorScheme colorScheme,
  }) {
    return GestureDetector(
      onTap: () => _addPhoto(source),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant,
            style: BorderStyle.solid,
          ),
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme colorScheme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: _handleAiExtract,
              onLongPress: _isExtracting ? null : _showModelMenu,
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: _isExtracting
                        ? colorScheme.outlineVariant
                        : colorScheme.primary.withValues(alpha: 0.5),
                  ),
                  color: _isExtracting
                      ? colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.3,
                        )
                      : colorScheme.primary.withValues(alpha: 0.06),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isExtracting)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      )
                    else
                      Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      _isExtracting ? '优化中...' : '智能优化',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  child: const Text(
                    '保存修改',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenImageView extends StatelessWidget {
  final String imagePath;

  const _FullScreenImageView({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          child: UnifiedImage(imagePath: imagePath, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _ExtractModelDialog extends StatelessWidget {
  final List<AiConfig> configs;
  final String? selectedId;

  const _ExtractModelDialog({required this.configs, this.selectedId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
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
                ),
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: configs
                      .map(
                        (config) => _ExtractModelItem(
                          config: config,
                          isSelected: config.id == selectedId,
                          onTap: () => Navigator.pop(context, config),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtractModelItem extends StatelessWidget {
  final AiConfig config;
  final bool isSelected;
  final VoidCallback onTap;

  const _ExtractModelItem({
    required this.config,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.smart_toy,
              size: 20,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    config.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  Text(
                    config.modelName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                size: 20,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}


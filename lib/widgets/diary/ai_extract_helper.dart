import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/core/utils/schema_formatter.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';

class AiExtractResult {
  final String? shortcutId;
  final Map<String, dynamic> time;
  final Map<String, dynamic> fields;
  final String notes;
  final List<TagEntry> tagEntries;

  const AiExtractResult({
    this.shortcutId,
    required this.time,
    required this.fields,
    required this.notes,
    this.tagEntries = const [],
  });
}

Future<AiExtractResult?> extractExistingRecord({
  required WidgetRef ref,
  required BuildContext context,
  required String content,
  required List<String> photos,
  required DateTime recordTime,
  DateTime? startTime,
  DateTime? endTime,
  void Function(bool)? onLoadingChanged,
  CancelToken? cancelToken,
}) async {
  onLoadingChanged?.call(true);
  try {
    final aiService = ref.read(aiServiceProvider);
    final roleConfig = await AiRoleService.instance.getEffectiveConfigForRole('timelineOptimization');
    final roleSettings = await AiRoleService.instance.getSettingsForRole('timelineOptimization');
    aiService.updateConfig(
      roleConfig,
      temperature: roleSettings.temperature,
      maxTokens: roleSettings.maxTokens,
    );

    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
    final visibleShortcuts = shortcuts.where((s) => s.isVisible).toList();
    final schemaStr = formatCompressedSchema(visibleShortcuts);

    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final now = DateTime.now();

    String? userSelectedTimeStr;
    if (startTime != null || endTime != null) {
      final baseDate = DateTime(recordTime.year, recordTime.month, recordTime.day);
      String formatSingle(DateTime dt) {
        final dtDate = DateTime(dt.year, dt.month, dt.day);
        final offset = dtDate.difference(baseDate).inDays;
        final prefix = offset < 0 ? '-' : '';
        final timeStr = DateFormat('HH:mm').format(dt);
        return '$prefix$timeStr';
      }

      if (startTime != null && endTime != null) {
        userSelectedTimeStr = '${formatSingle(startTime)}~${formatSingle(endTime)}';
      } else if (startTime != null) {
        userSelectedTimeStr = formatSingle(startTime);
      } else if (endTime != null) {
        userSelectedTimeStr = formatSingle(endTime);
      }
    }

    final contextMap = <String, dynamic>{
      'today': {
        'date': DateFormat('yyyy-MM-dd').format(now),
        'time': DateFormat('HH:mm').format(now),
        'weekday': weekdays[now.weekday - 1],
      },
      'recordDate': DateFormat('yyyy-MM-dd').format(recordTime),
    };
    if (userSelectedTimeStr != null) {
      contextMap['userSelectedTime'] = userSelectedTimeStr;
    }

    final aiTempsAsync = ref.read(aiTemperaturesProvider);
    final extractImages = aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final bool shouldSendImage = extractImages && photos.isNotEmpty;

    String? imageBase64;
    if (shouldSendImage) {
      final imageRepo = ImageRepository();
      imageBase64 = await imageRepo.getBase64Image(photos.first);
    }

    final results = await aiService.extractUnified(
      text: content.isNotEmpty ? content : null,
      imageBase64: imageBase64,
      mimeType: shouldSendImage ? ImageRepository.getMimeType(photos.first) : null,
      schema: schemaStr,
      contextStr: contextMap.toString(),
      cancelToken: cancelToken,
    );

    if (results.isNotEmpty) {
      final tagEntriesList = <TagEntry>[];
      for (final result in results) {
        final shortcutId = result['shortcutId'] as String?;
        final foundShortcut = findShortcutById(shortcutId, shortcuts);
        final fields = normalizeExtractedFields(
          Map<String, dynamic>.from(result['fields'] as Map? ?? {}),
          foundShortcut,
        );
        final timeRaw = result['time'];
        String? timeStr;
        int? startHour;
        int? startMinute;
        int? startOffset;
        int? endHour;
        int? endMinute;
        int? endOffset;

        if (timeRaw is Map && timeRaw.isNotEmpty) {
          final parts = <String>[];
          if (timeRaw['start'] != null) {
            final prefix = timeRaw['startOffset'] != null && (timeRaw['startOffset'] as int) < 0 ? '-' : '';
            parts.add('$prefix${timeRaw['start']}');

            final tParts = (timeRaw['start'] as String).split(':');
            if (tParts.length == 2) {
              startHour = int.tryParse(tParts[0]);
              startMinute = int.tryParse(tParts[1]);
            }
            startOffset = timeRaw['startOffset'] as int?;
          }
          if (timeRaw['end'] != null) {
            final prefix = timeRaw['endOffset'] != null && (timeRaw['endOffset'] as int) < 0 ? '-' : '';
            parts.add('$prefix${timeRaw['end']}');

            final tParts = (timeRaw['end'] as String).split(':');
            if (tParts.length == 2) {
              endHour = int.tryParse(tParts[0]);
              endMinute = int.tryParse(tParts[1]);
            }
            endOffset = timeRaw['endOffset'] as int?;
          }
          timeStr = parts.isNotEmpty ? parts.join('~') : null;
        }
        // 查找不到时，回退到 'other' 快捷标签的名称
        final fallbackShortcut = findShortcutById('other', shortcuts);
        tagEntriesList.add(TagEntry(
          id: foundShortcut?.id ?? shortcutId ?? 'other',
          name: foundShortcut?.name ?? fallbackShortcut?.name ?? '其他',
          fields: fields,
          time: timeStr,
          startHour: startHour,
          startMinute: startMinute,
          startOffset: startOffset,
          endHour: endHour,
          endMinute: endMinute,
          endOffset: endOffset,
        ));
      }

      // 合并 AI 返回的完全重复标签（相同 shortcut + 相同字段值），避免同一类型出现多次
      final mergedTagEntries = _mergeDuplicateTagEntries(tagEntriesList);

      final firstResult = results.first;
      final firstFields = Map<String, dynamic>.from(firstResult['fields'] as Map? ?? {});
      final firstShortcutId = firstResult['shortcutId'] as String?;
      final firstShortcut = findShortcutById(firstShortcutId, shortcuts);

      return AiExtractResult(
        shortcutId: firstShortcutId,
        time: Map<String, dynamic>.from(firstResult['time'] as Map? ?? {}),
        fields: firstFields,
        notes: cleanExtractedNotes(firstResult['notes'] as String? ?? '', firstFields, firstShortcut),
        tagEntries: mergedTagEntries,
      );
    }
    if (context.mounted) {
      Toast.warning(context, '未提取到有用信息');
    }
    return null;
  } on DioException catch (e) {
    if (CancelToken.isCancel(e)) {
      if (context.mounted) {
        Toast.info(context, '已停止提取');
      }
      return null;
    }
    String errorMessage = '提取失败';
    if (e.type == DioExceptionType.connectionError) {
      errorMessage = '网络连接失败，请检查网络或API配置';
    } else if (e.type == DioExceptionType.connectionTimeout) {
      errorMessage = '连接超时，请稍后重试';
    } else if (e.response?.statusCode == 401) {
      errorMessage = 'API密钥无效，请检查AI配置';
    } else if (e.response?.statusCode == 403) {
      errorMessage = '访问被拒绝，可能是CORS限制或权限问题';
    } else if (e.response?.statusCode == 404) {
      final respStr = e.response?.data?.toString() ?? '';
      if (respStr.contains('model') || respStr.contains('route')) {
        errorMessage = '当前AI模型已下线或不存在，请在设置中切换模型';
      } else {
        errorMessage = '请求的AI服务地址不存在(404)，请检查Base URL';
      }
    } else if (e.response?.statusCode == 429) {
      errorMessage = 'AI服务调用频次超限，请稍后重试';
    }
    if (context.mounted) {
      Toast.error(context, errorMessage);
    }
    return null;
  } catch (e, stackTrace) {
    String errorMessage = '提取失败';
    if (e is ArgumentError && e.message.toString().contains('apiKey')) {
      errorMessage = 'AI配置不完整，请在设置中完善API密钥和地址';
    }
    LoggerService.instance.logAI('记录智能优化失败: $e', level: LogLevel.error, details: stackTrace.toString());
    if (context.mounted) {
      Toast.error(context, errorMessage);
    }
    return null;
  } finally {
    onLoadingChanged?.call(false);
  }
}

ShortcutConfig? findShortcutById(String? shortcutId, List<ShortcutConfig> shortcuts) {
  if (shortcutId == null || shortcutId.isEmpty) return null;
  // 优先精确匹配 id 或 name
  for (final s in shortcuts) {
    if (s.id == shortcutId || s.name == shortcutId) return s;
  }
  // 大小写不敏感兜底匹配
  final lowerId = shortcutId.toLowerCase();
  for (final s in shortcuts) {
    if (s.id.toLowerCase() == lowerId || s.name.toLowerCase() == lowerId) return s;
  }
  // 记录警告日志，便于排查 AI 返回的 id 与实际快捷标签不匹配的问题
  LoggerService.instance.logAI(
    '快捷标签匹配失败: id="$shortcutId" 在已配置的标签列表中未找到（可用: ${shortcuts.map((s) => '${s.id}(${s.name})').join(', ')}）',
    level: LogLevel.warning,
  );
  return null;
}

String cleanExtractedNotes(String rawNotes, Map<String, dynamic> fields, ShortcutConfig? shortcut) {
  if (rawNotes.trim().isEmpty) return '';

  String normalizeKey(String key) {
    return key.trim().toLowerCase().replaceAll(RegExp(r'[\s\(\)（）_]+'), '');
  }

  final normalizedKeysToClean = <String>{};
  final valuesToClean = <String>{};

  // Add field IDs and values
  for (final entry in fields.entries) {
    normalizedKeysToClean.add(normalizeKey(entry.key));
    final val = entry.value;
    if (val != null) {
      final valStr = val.toString().trim();
      valuesToClean.add(valStr);
      if (val is double && valStr.endsWith('.0')) {
        valuesToClean.add(val.toInt().toString());
      } else if (val is num) {
        final d = val.toDouble();
        if (d == d.toInt()) {
          valuesToClean.add(d.toInt().toString());
        }
      }
    }
  }

  // Add shortcut fields and categories fields/labels
  if (shortcut != null) {
    for (final f in shortcut.fields) {
      normalizedKeysToClean.add(normalizeKey(f.id));
      normalizedKeysToClean.add(normalizeKey(f.label));
    }
    if (shortcut.categories != null) {
      for (final cat in shortcut.categories!) {
        for (final f in cat.fields) {
          normalizedKeysToClean.add(normalizeKey(f.id));
          normalizedKeysToClean.add(normalizeKey(f.label));
        }
      }
    }
  }

  // Also add some common keys/labels that might be returned by AI
  normalizedKeysToClean.add('备注');
  normalizedKeysToClean.add('notes');
  normalizedKeysToClean.add('note');
  normalizedKeysToClean.add('remark');
  normalizedKeysToClean.add('remarks');

  final rawLines = rawNotes.split('\n');
  final cleanLines = <String>[];

  for (final line in rawLines) {
    String current = line.trim();
    if (current.isEmpty) continue;

    // Strip "备注：" or "备注:" prefix
    while (current.startsWith('备注：') || current.startsWith('备注:')) {
      final idx = current.indexOf(RegExp(r'[:：]'));
      if (idx != -1) {
        current = current.substring(idx + 1).trim();
      } else {
        break;
      }
    }

    if (current.isEmpty) continue;

    // Split current line by comma delimiters to check individual segments
    final segments = current.split(RegExp(r'[，,、]'));
    final cleanSegments = <String>[];

    for (final seg in segments) {
      final trimmedSeg = seg.trim();
      if (trimmedSeg.isEmpty) continue;

      if (trimmedSeg.contains(':') || trimmedSeg.contains('：')) {
        final parts = trimmedSeg.split(RegExp(r'[:：]'));
        if (parts.length >= 2) {
          final key = parts[0].trim();
          final val = parts.sublist(1).join(':').trim();
          final normKey = normalizeKey(key);
          final normVal = val.toLowerCase();

          // If the key matches standard clean keys, or the value matches standard clean values, skip it
          if (normalizedKeysToClean.contains(normKey) ||
              valuesToClean.contains(val) ||
              valuesToClean.contains(normVal)) {
            continue;
          }
        }
      } else {
        // Plain text segment
        final normSeg = normalizeKey(trimmedSeg);
        if (normalizedKeysToClean.contains(normSeg) || valuesToClean.contains(trimmedSeg)) {
          continue;
        }
      }
      cleanSegments.add(trimmedSeg);
    }

    if (cleanSegments.isNotEmpty) {
      cleanLines.add(cleanSegments.join('，'));
    }
  }

  return cleanLines.join('\n');
}

/// 合并 AI 返回的完全重复标签。
///
/// 当 shortcut id 与 fields 内容完全一致时视为重复，只保留第一个；
/// 字段值不同（如 type=学习 vs type=工作）则保留为独立标签。
List<TagEntry> _mergeDuplicateTagEntries(List<TagEntry> entries) {
  final seen = <String>{};
  final merged = <TagEntry>[];
  for (final entry in entries) {
    final key = '${entry.id}:${jsonEncode(entry.fields)}';
    if (seen.add(key)) {
      merged.add(entry);
    }
  }
  return merged;
}

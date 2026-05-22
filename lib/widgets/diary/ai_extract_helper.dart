import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';

class AiExtractResult {
  final String? shortcutId;
  final Map<String, dynamic> time;
  final Map<String, dynamic> fields;
  final String notes;

  const AiExtractResult({
    this.shortcutId,
    required this.time,
    required this.fields,
    required this.notes,
  });
}

Future<AiExtractResult?> extractExistingRecord({
  required WidgetRef ref,
  required BuildContext context,
  required String content,
  required List<String> photos,
  required DateTime recordTime,
  void Function(bool)? onLoadingChanged,
}) async {
  onLoadingChanged?.call(true);
  try {
    final aiService = ref.read(aiServiceProvider);
    final roleConfig = await AiRoleService.instance.getEffectiveConfigForRole('timelineOptimization');
    aiService.updateConfig(roleConfig);

    final shortcuts = ref.read(shortcutListProvider).valueOrNull ?? [];
    final schemaContext = shortcuts.map((s) {
      final root = <String, dynamic>{'id': s.id, 'name': s.name};
      if (s.hasPopup) {
        if (s.fields.isNotEmpty) {
          root['fields'] = s.fields.map((f) => {
            'id': f.id,
            'name': f.label,
            'type': f.type,
            if (f.options.isNotEmpty) 'options': f.options
          }).toList();
        }
        if (s.categories != null && s.categories!.isNotEmpty) {
          root['categories'] = s.categories!.map((c) => {
            'id': c.id,
            'name': c.name,
            'fields': c.fields.map((f) => {
              'id': f.id,
              'name': f.label,
              'type': f.type,
              if (f.options.isNotEmpty) 'options': f.options
            }).toList()
          }).toList();
        }
      }
      return root;
    }).toList();

    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final contextStr = {
      'date': DateFormat('yyyy-MM-dd').format(recordTime),
      'time': DateFormat('HH:mm').format(recordTime),
      'weekday': weekdays[recordTime.weekday - 1],
    };

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
      mimeType: 'image/jpeg',
      schema: schemaContext.toString(),
      contextStr: contextStr.toString(),
    );

    if (results.isNotEmpty) {
      final result = results.first;
      final fields = Map<String, dynamic>.from(result['fields'] as Map? ?? {});
      final shortcutId = result['shortcutId'] as String?;
      final foundShortcut = findShortcutById(shortcutId, shortcuts);
      return AiExtractResult(
        shortcutId: shortcutId,
        time: Map<String, dynamic>.from(result['time'] as Map? ?? {}),
        fields: fields,
        notes: cleanExtractedNotes(result['notes'] as String? ?? '', fields, foundShortcut),
      );
    }
    return null;
  } on DioException catch (e) {
    String errorMessage = '提取失败';
    if (e.type == DioExceptionType.connectionError) {
      errorMessage = '网络连接失败，请检查网络或API配置';
    } else if (e.type == DioExceptionType.connectionTimeout) {
      errorMessage = '连接超时，请稍后重试';
    } else if (e.response?.statusCode == 401) {
      errorMessage = 'API密钥无效，请检查AI配置';
    } else if (e.response?.statusCode == 403) {
      errorMessage = '访问被拒绝，可能是CORS限制或权限问题';
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
  if (shortcutId == null) return null;
  try {
    return shortcuts.firstWhere((s) => s.id == shortcutId);
  } catch (_) {
    return null;
  }
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

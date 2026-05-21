import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/config/defaults.dart';

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

    final now = DateTime.now();
    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final contextStr = {
      'date': DateFormat('yyyy-MM-dd').format(now),
      'time': DateFormat('HH:mm').format(now),
      'weekday': weekdays[now.weekday - 1],
    };

    final aiTempsAsync = ref.read(aiTemperaturesProvider);
    final extractImages = aiTempsAsync.valueOrNull?.timelineOptimization.extractImages ?? false;
    final bool shouldSendImage = extractImages && photos.isNotEmpty;

    List<Map<String, dynamic>> results;
    if (shouldSendImage) {
      final imageRepo = ImageRepository();
      final base64 = await imageRepo.getBase64Image(photos.first);
      results = await aiService.extractGlobalImageInfo(
        imageBase64: base64,
        mimeType: 'image/jpeg',
        prompt: content.isNotEmpty ? content : '请提取图片中的所有可能记录事件。',
        schema: schemaContext.toString(),
        contextStr: contextStr.toString(),
      );
    } else {
      results = await aiService.extractDiaryStructure(
        text: content,
        schemaContext: schemaContext.toString(),
        contextStr: contextStr.toString(),
      );
    }

    if (results.isNotEmpty) {
      final result = results.first;
      return AiExtractResult(
        shortcutId: result['shortcutId'] as String?,
        time: Map<String, dynamic>.from(result['time'] as Map? ?? {}),
        fields: Map<String, dynamic>.from(result['fields'] as Map? ?? {}),
        notes: result['notes'] as String? ?? '',
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage), duration: const Duration(seconds: 3), behavior: SnackBarBehavior.floating),
      );
    }
    return null;
  } catch (e, stackTrace) {
    String errorMessage = '提取失败';
    if (e is ArgumentError && e.message.toString().contains('apiKey')) {
      errorMessage = 'AI配置不完整，请在设置中完善API密钥和地址';
    }
    LoggerService.instance.logAI('记录智能优化失败: $e', level: LogLevel.error, details: stackTrace.toString());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage), duration: const Duration(seconds: 3), behavior: SnackBarBehavior.floating),
      );
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

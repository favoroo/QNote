import 'dart:async';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/free_model_config.dart';

/// 免费模型执行器
///
/// 封装"主模型失败自动切换"的重试逻辑。
/// - 非流式调用：按顺序尝试模型，全部失败才抛异常
/// - 流式调用：在首个 chunk 接收前可切换；首个 chunk 后不再切换
class FreeModelExecutor {
  /// 非流式调用：按顺序尝试模型，全部失败才抛异常
  static Future<String> chatWithFallback({
    required AiService aiService,
    required List<FreeModelConfig> models,
    required String? preferredId,
    required List<ChatMessage> messages,
    double? temperature,
    int? maxTokens,
  }) async {
    final ordered =
        FreeModelService.instance.getOrderedModels(models, preferredId);
    if (ordered.isEmpty) {
      throw Exception('免费模型列表为空，请先更新');
    }

    Object? lastError;
    for (int i = 0; i < ordered.length; i++) {
      final model = ordered[i];
      try {
        LoggerService.instance.logAI(
          '免费模型调用 [${i + 1}/${ordered.length}]: ${model.displayName}',
        );
        final config = FreeModelService.instance.toAiConfig(model);
        aiService.updateConfig(config,
            temperature: temperature, maxTokens: maxTokens);
        final result = await aiService.chat(messages);
        LoggerService.instance.logAI(
          '免费模型调用成功: ${model.displayName}',
        );
        return result;
      } catch (e) {
        lastError = e;
        LoggerService.instance.logAI(
          '免费模型调用失败: ${model.displayName}',
          details: e.toString(),
          level: LogLevel.warning,
        );
        // 继续尝试下一个模型
      }
    }
    throw Exception('所有免费模型调用失败: $lastError');
  }

  /// 流式调用：在首个 chunk 接收前可切换；首个 chunk 后不再切换
  ///
  /// 使用 StreamIterator 区分连接阶段和流式阶段：
  /// - 第一次 moveNext() 失败 = 连接阶段失败，可切换到下一个模型
  /// - 后续 moveNext() 失败 = 流式阶段失败，不切换，直接抛异常
  static Stream<String> chatStreamWithFallback({
    required AiService aiService,
    required List<FreeModelConfig> models,
    required String? preferredId,
    required List<ChatMessage> messages,
    double? temperature,
    int? maxTokens,
  }) async* {
    final ordered =
        FreeModelService.instance.getOrderedModels(models, preferredId);
    if (ordered.isEmpty) {
      throw Exception('免费模型列表为空，请先更新');
    }

    Object? lastError;
    for (int i = 0; i < ordered.length; i++) {
      final model = ordered[i];
      LoggerService.instance.logAI(
        '免费模型流式调用 [${i + 1}/${ordered.length}]: ${model.displayName}',
      );
      final config = FreeModelService.instance.toAiConfig(model);
      aiService.updateConfig(config,
          temperature: temperature, maxTokens: maxTokens);

      final stream = aiService.chatStream(messages);
      final iterator = StreamIterator(stream);

      // 阶段1：尝试建立连接并获取第一个 chunk
      bool hasFirstChunk;
      try {
        hasFirstChunk = await iterator.moveNext();
      } catch (e) {
        lastError = e;
        LoggerService.instance.logAI(
          '免费模型流式连接失败: ${model.displayName}',
          details: e.toString(),
          level: LogLevel.warning,
        );
        await iterator.cancel();
        continue; // 连接阶段失败，切换到下一个模型
      }

      // 阶段2：连接成功，开始消费流
      try {
        while (hasFirstChunk) {
          yield iterator.current;
          hasFirstChunk = await iterator.moveNext();
        }
        LoggerService.instance.logAI(
          '免费模型流式调用成功: ${model.displayName}',
        );
        return; // 成功完成，退出
      } catch (e) {
        // 流式阶段失败，不切换，直接抛异常
        LoggerService.instance.logAI(
          '免费模型流式中断: ${model.displayName}',
          details: e.toString(),
          level: LogLevel.warning,
        );
        await iterator.cancel();
        rethrow;
      }
    }
    throw Exception('所有免费模型流式连接失败: $lastError');
  }
}

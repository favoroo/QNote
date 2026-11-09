import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

import 'package:dio/dio.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';

/// 识图能力自动探测
///
/// [ModelVisionCapability] 的判定是同步查表：只有手动检测过或模型名命中视觉
/// 关键词时才算「支持」。这会让新加的视觉模型在第一次发图时被拦下，哪怕它其实
/// 看得见——用户还得专门去设置页点一次「识图检测」。
///
/// 这里补上「先实测、再落盘」：能力未知时先发一张「白底黑字 11」的探测图，
/// 按回答是否包含 11 决定支不支持；探测本身失败（网络/额度/鉴权/端点异常）
/// 不落盘并放行，交给真实请求暴露真正的错误，避免一次抖动被永久记成「不支持」。
class VisionCapabilityProbe {
  VisionCapabilityProbe._();

  /// 同一模型的并发探测合并成一次请求（提取按钮连点、多入口并发时省配额）
  static final Map<String, Future<bool>> _inflight = {};

  /// 测试桩：替换真实的 `AiService.checkImageRecognition`，避免单测发网络请求
  @visibleForTesting
  static Future<bool> Function(AiConfig config, String imageBase64)? checkerOverride;

  /// 确保给出该配置能否接收图片输入
  ///
  /// 返回 `true` 表示可以继续把图片交给该模型；`false` 表示已实测确认看不了图。
  static Future<bool> ensure(AiConfig config) {
    final modelName = config.modelName.trim();
    if (modelName.isEmpty) return Future.value(false);

    final probed = ModelVisionCapability.probedResult(modelName);
    if (probed != null) return Future.value(probed);
    if (ModelVisionCapability.hasVisionNameHint(modelName)) {
      return Future.value(true);
    }

    final key = modelName.toLowerCase();
    final running = _inflight[key];
    if (running != null) return running;

    final future = _probe(config);
    _inflight[key] = future;
    return future.whenComplete(() => _inflight.remove(key));
  }

  /// 生成「白底黑字 11」的探测图：数字短、对比强，模型看得见就一定能答对
  static Future<String> generateProbeImageBase64() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, 100, 100));
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 100, 100),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '11',
        style: TextStyle(
          color: ui.Color(0xFF000000),
          fontSize: 60,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, const ui.Offset(10, 10));
    textPainter.dispose();
    final image = await recorder.endRecording().toImage(100, 100);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('探测图编码失败');
    }
    return base64Encode(bytes.buffer.asUint8List());
  }

  static Future<bool> _probe(AiConfig config) async {
    final checker = checkerOverride ?? _checkWithNewService;
    final String imageBase64;
    try {
      // 测试桩不校验图片内容，跳过画布编码，避免单测依赖渲染引擎
      imageBase64 = checkerOverride != null ? '' : await generateProbeImageBase64();
    } catch (e) {
      // 探测图都画不出来（极端环境）：不能据此判断模型能力，放行真实请求
      _logInconclusive(config, '生成探测图失败', e, null);
      return true;
    }

    try {
      final capable = await checker(config, imageBase64);
      await _record(config.modelName, capable);
      LoggerService.instance.logAI(
        '识图能力自动探测 [${config.modelName}]：${capable ? '支持' : '不支持'}',
      );
      return capable;
    } catch (e, stackTrace) {
      if (_isDefinitiveRejection(e)) {
        await _record(config.modelName, false);
        LoggerService.instance.logAI(
          '识图能力自动探测 [${config.modelName}]：服务端拒绝图片输入，记为不支持',
          level: LogLevel.warning,
        );
        return false;
      }
      _logInconclusive(config, '探测请求未成功', e, stackTrace);
      return true;
    }
  }

  static Future<bool> _checkWithNewService(AiConfig config, String imageBase64) {
    // 必须新建实例：共享 `aiServiceProvider` 实例的配置会被 updateConfig 改掉，
    // 正在进行的对话/提取会串台（describe_image 工具同样出于这个原因新建实例）
    return AiService().checkImageRecognition(config, imageBase64);
  }

  /// 服务端是否**明确拒绝**了带图请求
  ///
  /// 只有 415，或 400/422 且错误体提到图片/视觉，才算「该模型不支持图片输入」的
  /// 证据；超时、断网、401/403/429/404/5xx 都只是这次请求没成，不能给能力下结论。
  static bool _isDefinitiveRejection(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status == 415) return true;
    if (status != 400 && status != 422) return false;
    final body = error.response?.data?.toString().toLowerCase() ?? '';
    return const [
      'image',
      'vision',
      'multimodal',
      'modality',
      '图片',
      '视觉',
      '识图',
    ].any(body.contains);
  }

  static Future<void> _record(String modelName, bool capable) async {
    try {
      await ModelVisionCapability.recordProbeResult(modelName, capable);
    } catch (e, stackTrace) {
      // 落盘失败不影响本次判定，下次使用会再测一次
      LoggerService.instance.logAI(
        '识图能力结论落盘失败 [$modelName]：$e',
        level: LogLevel.warning,
        details: stackTrace.toString(),
      );
    }
  }

  static void _logInconclusive(
    AiConfig config,
    String reason,
    Object error,
    StackTrace? stackTrace,
  ) {
    LoggerService.instance.logAI(
      '识图能力自动探测未得出结论 [$reason] [${config.modelName}]，本次放行：$error',
      level: LogLevel.warning,
      details: stackTrace?.toString(),
    );
  }

  /// 清空测试桩与在途请求（仅测试用）
  @visibleForTesting
  static void resetForTest() {
    checkerOverride = null;
    _inflight.clear();
  }
}

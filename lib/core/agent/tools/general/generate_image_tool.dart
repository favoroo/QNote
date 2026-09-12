import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';

/// 生图工具：让小Q 具备 AI 文生图能力
///
/// 按「AI配置 → 角色绑定 → 生图模型」自动路由到内置生图后端：
/// - Gemini 生图（gemini-3.1-flash-image）：网关 `chat/completions`，图片以 data URI 附在消息里；
/// - SenseNova 生图（sensenova-u1.5-lite）：商汤日日新 `images/generations`，显式 `watermark: false` 生成无水印图。
///
/// 生成结果统一保存（原生端落盘 `images/ai/` 子目录，Web 端直接使用 data URI），
/// 把路径回传给模型，由模型用 write_file / edit_file 放到笔记、时间线、日记等指定位置；
/// 解析逻辑收敛在 [parseChatImages] / [parseGenerationImages] 静态纯函数中，便于单测。
class GenerateImageTool extends AgentTool {
  final ImageRepository _imageRepo = ImageRepository();

  /// AI 生成的图片统一存放到 images/ai/ 子目录
  static const String _subfolder = 'ai';

  /// 生图耗时明显高于普通请求（10~60s），接收超时放宽到 3 分钟
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 180);

  /// 提示词长度上限，防止异常长输入拖慢生图请求
  static const int _promptMaxLength = 2000;

  @override
  String get name => 'generate_image';

  @override
  String get description =>
      '根据文字描述生成一张图片（AI 文生图）。适用于用户想"画一张/生成一张/配一张图"的场景，'
      '如生成插画、照片风格的图片、配图等。调用成功后图片会保存到本地并返回文件路径，'
      '随后可用 write_file / edit_file 把路径放到指定位置：'
      '时间线时间块内写「- 图片: <路径>」，笔记/日记正文写「![image](<路径>)」；'
      '仅在对话中展示时无需写文件。本工具不支持图片编辑与图生图；'
      '需要查看已有图片请用 view_image，需要搜索网络图片请用 web_search。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': '图片描述提示词。写具体、有画面感的描述（主体 + 场景 + 风格 + 光线等），'
                '中文英文均可，建议 20~200 字。',
          },
          'size': {
            'type': 'string',
            'description': '图片尺寸，格式 "宽x高"，默认 "1024x1024"。仅 SenseNova 生图后端生效，'
                '常用值：1024x1024（方形）、1152x864（横版）、864x1152（竖版）。',
          },
        },
        'required': ['prompt'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final prompt = (arguments['prompt']?.toString() ?? '').trim();
    if (prompt.isEmpty) {
      return ToolResult.error('prompt 不能为空，请提供图片的文字描述');
    }
    final effectivePrompt = prompt.length > _promptMaxLength
        ? prompt.substring(0, _promptMaxLength)
        : prompt;
    final size = (arguments['size']?.toString() ?? '').trim();

    AiConfig config;
    try {
      config = await AiRoleService.instance.getImageGenerationModelConfig();
    } catch (e) {
      return ToolResult.error('读取生图模型配置失败：$e；请如实告知用户生图功能暂不可用');
    }

    onProgress?.call('正在调用 ${config.name} 生成图片…');
    LoggerService.instance.logAI(
      '小Q生图工具发起请求',
      details: 'model=${config.modelName}, backend=${_isSenseNovaBackend(config) ? 'sensenova' : 'gemini'}, '
          'prompt=${effectivePrompt.length}字',
    );

    final dio = Dio()
      ..options.connectTimeout = _connectTimeout
      ..options.receiveTimeout = _receiveTimeout
      ..options.headers = {
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
      };

    try {
      final refs = _isSenseNovaBackend(config)
          ? await _requestSenseNova(dio, config, effectivePrompt, size)
          : await _requestGemini(dio, config, effectivePrompt);
      if (refs.isEmpty) {
        return ToolResult.error(
            '生图服务未返回任何图片，请如实告知用户本次生成失败，建议换个描述重试');
      }

      final saved = await _saveImages(refs, onProgress);
      if (saved.isEmpty) {
        return ToolResult.error('图片保存失败，请如实告知用户本次生成失败');
      }

      final pathsBuffer = StringBuffer();
      for (final path in saved) {
        pathsBuffer.writeln('- $path');
      }
      onProgress?.call('图片生成完成');
      return ToolResult.success(
        '已成功生成 ${saved.length} 张图片并保存：\n$pathsBuffer\n'
        '需要放入笔记/时间线/日记时，用该路径按系统规范插图；仅在对话展示则无需写文件。',
        uiDetails: {
          'type': 'generate_image',
          'paths': saved,
          'model': config.name,
          'prompt': effectivePrompt,
        },
      );
    } on DioException catch (e) {
      return ToolResult.error(
          '${_describeDioError(e)}；请如实告知用户本次生图失败，严禁编造图片路径');
    } catch (e) {
      return ToolResult.error('生图执行失败：$e；请如实告知用户本次生图失败，严禁编造图片路径');
    }
  }

  /// 判断是否走商汤日日新 images/generations 后端（否则走网关 chat/completions）
  bool _isSenseNovaBackend(AiConfig config) => config.baseUrl.contains('sensenova');

  /// SenseNova 生图：POST /images/generations，显式 watermark:false 生成无水印图
  ///
  /// 商汤内置 Key 为 4 Key 轮询池，遇到限速/鉴权类可恢复错误时自动冷却换 Key 重试一次。
  Future<List<String>> _requestSenseNova(
    Dio dio,
    AiConfig config,
    String prompt,
    String size,
  ) async {
    var apiKey = config.apiKey;
    Object? lastError;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0) {
          await Future<void>.delayed(
              FreeModelKeyManager.instance.getBackoffDelay(attempt));
        }
        dio.options.headers['Authorization'] = 'Bearer $apiKey';
        final response = await dio.post<Map<String, dynamic>>(
          '${config.baseUrl}/images/generations',
          data: {
            'model': config.modelName,
            'prompt': prompt,
            'n': 1,
            if (size.isNotEmpty) 'size': size,
            // 公测期间无水印生成免费；显式传递避免官方默认值变化影响线上
            'watermark': false,
          },
        );
        final body = response.data;
        if (body == null) return const [];
        return parseGenerationImages(body);
      } on DioException catch (e) {
        lastError = e;
        final recoverable = FreeModelKeyManager.instance.isRecoverableError(e);
        LoggerService.instance.logAI(
          'SenseNova 生图请求失败（第 ${attempt + 1} 次）',
          details: '${e.message}, 可恢复=$recoverable',
          level: LogLevel.warning,
        );
        if (!recoverable || attempt == 1) rethrow;
        apiKey = FreeModelKeyManager.instance.rotateKeyOnFailure(apiKey);
      }
    }
    throw lastError ?? Exception('SenseNova 生图请求失败');
  }

  /// Gemini 生图：POST /chat/completions，图片以 data URI 附在 message.images 里
  ///
  /// 网关为单 Key，遇到可恢复错误（网络抖动/限速）按退避重试一次。
  Future<List<String>> _requestGemini(
    Dio dio,
    AiConfig config,
    String prompt,
  ) async {
    Object? lastError;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0) {
          await Future<void>.delayed(
              FreeModelKeyManager.instance.getBackoffDelay(attempt));
        }
        final response = await dio.post<Map<String, dynamic>>(
          '${config.baseUrl}/chat/completions',
          data: {
            'model': config.modelName,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          },
        );
        final body = response.data;
        if (body == null) return const [];
        return parseChatImages(body);
      } on DioException catch (e) {
        lastError = e;
        final recoverable = FreeModelKeyManager.instance.isRecoverableError(e);
        LoggerService.instance.logAI(
          'Gemini 生图请求失败（第 ${attempt + 1} 次）',
          details: '${e.message}, 可恢复=$recoverable',
          level: LogLevel.warning,
        );
        if (!recoverable || attempt == 1) rethrow;
      }
    }
    throw lastError ?? Exception('Gemini 生图请求失败');
  }

  /// 把图片引用（base64 或 http URL）统一保存，返回本地路径（Web 端返回 data URI）
  Future<List<String>> _saveImages(
    List<String> refs,
    void Function(String progress)? onProgress,
  ) async {
    final saved = <String>[];
    for (final ref in refs) {
      try {
        String base64Data;
        if (ref.startsWith('http')) {
          // 网络图片引用：下载字节后转 base64 再落盘
          final dio = Dio()
            ..options.connectTimeout = _connectTimeout
            ..options.receiveTimeout = _receiveTimeout;
          final resp = await dio.get<List<int>>(
            ref,
            options: Options(responseType: ResponseType.bytes),
          );
          final bytes = resp.data;
          if (bytes == null || bytes.isEmpty) continue;
          base64Data = base64Encode(bytes);
        } else {
          base64Data = ref;
        }

        // Web 端无本地文件系统，直接以 data URI 形式交付（与笔记编辑器 Web 图片方案一致）
        if (kIsWeb) {
          saved.add('data:image/png;base64,$base64Data');
          continue;
        }
        final path = await _imageRepo.saveBase64Image(base64Data, subfolder: _subfolder);
        saved.add(path);
      } catch (e) {
        LoggerService.instance.logAI(
          '生图结果保存失败，跳过该张图片',
          details: e.toString(),
          level: LogLevel.warning,
        );
      }
    }
    return saved;
  }

  /// 从 chat/completions 响应解析图片引用（data URI 或 http URL）
  ///
  /// 兼容两种结构：网关扩展的 `choices[].message.images[].image_url.url`
  /// 与 OpenAI 风格的 `data[].url` / `data[].b64_json`。
  static List<String> parseChatImages(Map<String, dynamic> responseBody) {
    final refs = <String>{};

    final choices = responseBody['choices'];
    if (choices is List) {
      for (final choice in choices) {
        if (choice is! Map<String, dynamic>) continue;
        final message = choice['message'];
        if (message is! Map<String, dynamic>) continue;
        final images = message['images'];
        if (images is! List) continue;
        for (final image in images) {
          final url = _extractImageUrl(image);
          if (url != null) refs.add(url);
        }
      }
    }

    // 部分网关按 images/generations 结构返回，兜底解析
    refs.addAll(parseGenerationImages(responseBody));
    return refs.toList();
  }

  /// 从 images/generations 响应解析图片引用（b64_json 或 url）
  static List<String> parseGenerationImages(Map<String, dynamic> responseBody) {
    final refs = <String>{};
    final data = responseBody['data'];
    if (data is! List) return refs.toList();
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      final b64 = item['b64_json']?.toString() ?? '';
      if (b64.isNotEmpty) {
        refs.add(b64);
        continue;
      }
      final url = item['url']?.toString() ?? '';
      if (url.startsWith('http')) refs.add(url);
    }
    return refs.toList();
  }

  /// 从单张图片节点提取引用（兼容 {type, image_url:{url}} 与 {url} 两种结构）
  static String? _extractImageUrl(dynamic image) {
    if (image is String) return image.startsWith('data:') ? image : null;
    if (image is! Map<String, dynamic>) return null;
    final container = image['image_url'];
    if (container is Map<String, dynamic>) {
      final url = container['url']?.toString() ?? '';
      if (url.startsWith('data:') || url.startsWith('http')) return url;
    }
    if (container is String && (container.startsWith('data:') || container.startsWith('http'))) {
      return container;
    }
    return null;
  }

  /// 把 DioException 翻译成模型可读的中文提示
  static String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return '连接生图服务超时';
      case DioExceptionType.receiveTimeout:
        return '生图响应超时（生成耗时过长）';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) return '生图服务鉴权失败（状态码 $code）';
        if (code == 429) return '生图服务限速，请稍后重试';
        return '生图服务返回异常状态码 $code';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查设备网络';
      case DioExceptionType.cancel:
        return '生图请求已取消';
      default:
        return '生图请求失败：${e.message ?? '未知错误'}';
    }
  }
}

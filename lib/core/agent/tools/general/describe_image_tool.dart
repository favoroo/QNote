import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 图片来源形态（决定走哪条取字节路径）
enum ImageSourceKind { dataUri, url, localPath }

/// 识图工具：把图片交给内置视觉链路，换回一段文字描述
///
/// 存在的原因是**对话模型不一定能看图，而网关不会报错**：实测商汤网关上的
/// `glm-5.2` 收到图片仍返回 200，只是把左红右蓝答成「左=黑色，右=白色」（编造）。
/// 因此当 `AgentLoop` 判定当前模型不支持图片输入时，会把图片从上下文里剥掉并改用
/// 本工具：图片走 [BuiltinFreeKeys.createVisionConfig] 这条视觉链路（SenseNova 6.8
/// flash-lite），只有**文字结论**回到对话模型的上下文里，模型不必也不该假装自己看见了画面。
///
/// 形态对齐桌面端的 vision 脚本：一段提问 + 一张图 → 文本回复；区别是复用 [AiService]
/// 而不是手搓 HTTP，从而带上内置 Key 池轮换、限流退避与 `ai_request_stats` 观测。
class DescribeImageTool extends AgentTool {
  /// 未传 question 时的默认提问：既要描述画面，也要把可读文字抠出来
  static const String defaultQuestion =
      '请用中文详细描述这张图片的内容；若图中含文字、数字、日期、金额、表格或清单，请逐条原样抄出。';

  /// 识图回复的 token 预算：OCR 长文本 + 场景描述够用，又不至于把上下文灌满
  static const int _maxAnswerTokens = 1200;

  /// 外链图片的下载体积上限（超过基本不是给模型看的路由页/原图）
  static const int _maxDownloadBytes = 8 * 1024 * 1024;

  final ImageRepository _imageRepo = ImageRepository();

  /// 视觉链路请求函数，签名 (提问, 图片 data URI) → 文本
  ///
  /// 刻意留成可注入：[AiService] 会真的打网关，单测里传 fake 才能覆盖
  /// 「空回复算失败」「结果如何包装」这些分支。
  final Future<String> Function(String question, String imageDataUri) _visionRequest;

  DescribeImageTool({
    Future<String> Function(String question, String imageDataUri)? visionRequester,
  }) : _visionRequest = visionRequester ?? _requestVisionModel;

  @override
  String get name => 'describe_image';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '识别图片内容并返回**文字**结果（画面描述、图中文字 OCR、颜色/物体/数字判断等）。'
      '当系统提示当前对话模型不支持图片输入时，任何「看图」需求都必须用本工具；'
      '也可用于你已经能看图、但需要精确抄录图中文字的场景。'
      'path 支持日记/笔记/时间线里真实记录的图片路径（如 "/images/xxx.jpg"）、本地绝对路径、'
      'data:image/... 开头的内联图片、以及 http(s) 图片链接；'
      'question 传你的具体问题（不传则默认全面描述）。'
      '注意：本工具返回的是另一个识图模型给出的文字，不是你亲眼看到的画面，'
      '引用时说明「识图结果」而不要假装直接看到了图片；也不要为不存在的图片虚构路径。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                '图片位置：日记/笔记/时间线中记录的图片路径、本地绝对路径、data:image/... 内联图片，或 http(s) 图片链接',
          },
          'question': {
            'type': 'string',
            'description': '要让识图模型回答的具体问题，例如「图上写了什么」「左半边是什么颜色」；不传则全面描述图片内容',
          },
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final rawPath = (arguments['path'] as String? ?? '').trim();
    if (rawPath.isEmpty) {
      return ToolResult.error(
        '图片路径为空，请传入日记/笔记/时间线中真实记录的图片路径，或 data:/http(s) 图片地址',
      );
    }
    final question = (arguments['question'] as String? ?? '').trim();
    final effectiveQuestion = question.isEmpty ? defaultQuestion : question;

    final (imageDataUri, failure) = await _resolveImageArgument(rawPath);
    if (failure != null) return failure;

    onProgress?.call('正在识别图片');

    final String answer;
    try {
      answer = await _visionRequest(effectiveQuestion, imageDataUri!);
    } on Exception catch (e) {
      return ToolResult.error('识图请求失败：$e。请如实告知用户未能识别，严禁凭想象描述图片内容');
    }

    return buildVisionResult(rawPath, effectiveQuestion, answer);
  }

  /// 把入参解析成可直接发给视觉链路的 data URI；解析失败时给出**带下一步指引**的错误
  ///
  /// 三条取字节路径的差别很大，所以分开写而不是塞进一个 if 链：
  /// - `data:` 原样透传（`AiService` 的请求组装认得 data: 前缀，重编码只会白烧 CPU）；
  /// - `http(s)` 必须先下载 —— 网关侧不认外链，且 `AiService` 会把非 data: 的入参当文件路径去读；
  /// - 本地路径统一走压缩（最长边 1080 的 JPEG），既控体积也避开 HEIC 等网关不认的编码。
  Future<(String?, ToolResult?)> _resolveImageArgument(String rawPath) async {
    switch (classifyImageSource(rawPath)) {
      case ImageSourceKind.dataUri:
        return (rawPath, null);
      case ImageSourceKind.url:
        final downloaded = await _downloadAsDataUri(rawPath);
        if (downloaded == null) {
          return (
            null,
            ToolResult.error(
              '图片下载失败或不是有效的图片：$rawPath。'
              '请如实告知用户这张图取不到，严禁凭链接文字或想象描述图片内容',
            ),
          );
        }
        return (downloaded, null);
      case ImageSourceKind.localPath:
        if (kIsWeb) {
          // Web 端没有本地文件系统，图片在「路径」列里存的本来就是 data URI
          return (
            null,
            ToolResult.error(
              '当前运行在 Web 平台，无法读取本地图片文件：$rawPath。'
              '请改用图片的内联地址（data:image/... 开头）',
            ),
          );
        }
        final base64 = await _imageRepo.getCompressedBase64Image(rawPath);
        if (base64.isEmpty) {
          return (
            null,
            ToolResult.error(
              '图片文件不存在或读取失败：$rawPath。'
              '请确认路径来自日记/笔记/时间线中真实记录的「- 图片:」字段，不要自行拼凑；'
              '确认路径无误仍读不到时，如实告知用户图片已不可用，严禁凭想象描述',
            ),
          );
        }
        return ('data:image/jpeg;base64,$base64', null);
    }
  }

  /// 把视觉链路的文本回复包装成工具结果；空回复按失败处理（否则模型会把「没有内容」当成图片是空的）
  @visibleForTesting
  ToolResult buildVisionResult(String rawPath, String question, String answer) {
    final text = answer.trim();
    if (text.isEmpty) {
      return ToolResult.error(
        '识图模型没有返回内容（图片可能过大、格式不支持或已被网关拒绝）。'
        '请如实告知用户未能识别，严禁凭想象描述图片内容',
      );
    }
    LoggerService.instance.logAI(
      'describe_image 识图完成',
      details: 'model=${BuiltinFreeKeys.visionModelName}, 输入=${_displayLabel(rawPath)}, 结果字数=${text.length}',
    );
    return ToolResult.success(
      '【识图结果 · ${BuiltinFreeKeys.visionModelName}】\n'
      '提问：$question\n'
      '图片：${_displayLabel(rawPath)}\n\n'
      '${truncateOutput(text)}\n\n'
      '以上由内置识图模型给出，当前对话模型并未直接看到画面；请基于它作答，不要补充图片里并不存在的细节。',
      uiDetails: {
        'type': 'describe_image',
        'path': _displayLabel(rawPath),
        'question': question,
        'model': BuiltinFreeKeys.visionModelName,
        'chars': text.length,
      },
    );
  }

  /// 判定图片来源形态
  ///
  /// 顺序上 data: 必须先于「本地路径」，否则 Web 端那条内联图片会被当成文件路径去读。
  @visibleForTesting
  static ImageSourceKind classifyImageSource(String path) {
    final lower = path.toLowerCase();
    if (lower.startsWith('data:')) return ImageSourceKind.dataUri;
    if (lower.startsWith('http://') || lower.startsWith('https://')) return ImageSourceKind.url;
    return ImageSourceKind.localPath;
  }

  /// 下载外链图片并转 data URI；取不到字节时返回 null
  Future<String?> _downloadAsDataUri(String url) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          followRedirects: true,
        ),
      );
      final response = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Accept': 'image/avif,image/webp,image/png,image/jpeg,*/*;q=0.8'},
          receiveDataWhenStatusError: true,
        ),
      );
      final bytes = response.data;
      // 图片体积不可控：空响应与超大原图都不值得送进识图链路（前者没内容，后者会撞请求体上限）
      if (bytes == null || bytes.isEmpty || bytes.length > _maxDownloadBytes) return null;
      final mime = _mimeFromResponse(response, bytes);
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } on Exception catch (e) {
      LoggerService.instance.logAI(
        'describe_image 下载外链图片失败: $url',
        details: e.toString(),
        level: LogLevel.warning,
      );
      return null;
    }
  }

  /// 外链图片的 MIME：优先信响应头，缺失时按文件头魔数嗅探
  ///
  /// 信 Content-Type 是因为不少 CDN 会把 webp 报成 octet-stream，此时魔数嗅探比头部靠谱。
  @visibleForTesting
  static String resolveDownloadedMime(String? contentType, List<int> bytes) {
    final header = (contentType ?? '').toLowerCase();
    for (final candidate in const ['image/png', 'image/jpeg', 'image/webp', 'image/gif']) {
      if (header.contains(candidate)) return candidate;
    }
    return detectImageMime(bytes);
  }

  /// 从文件头魔数判定图片类型（外链常常不给 Content-Type）
  @visibleForTesting
  static String detectImageMime(List<int> bytes) {
    if (bytes.length < 12) return 'image/jpeg';
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'image/jpeg';
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return 'image/gif';
    }
    final isRiff = bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46;
    final isWebp = bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50;
    if (isRiff && isWebp) return 'image/webp';
    return 'image/jpeg';
  }

  /// 给模型与 UI 看的图片标签：内联图片绝不整段回显（base64 会吃掉几千倍体积）
  static String _displayLabel(String path) {
    if (!path.startsWith('data:')) return path;
    final comma = path.indexOf(',');
    if (comma <= 0) return '内联图片';
    final mime = path.substring(5, comma).split(';').first;
    final sizeKB = ((path.length - comma - 1) * 3 / 4 / 1024).round();
    return '内联图片（$mime，约 $sizeKB KB）';
  }

  String _mimeFromResponse(Response<dynamic> response, List<int> bytes) =>
      resolveDownloadedMime(response.headers.value(Headers.contentTypeHeader), bytes);

  /// 默认的视觉链路请求：新建 [AiService] 实例，把 data URI 作为图片输入发一次非流式对话
  ///
  /// 必须新建实例而不是复用注入来的那一个 —— 主聊天、悬浮小Q、每日评分共享
  /// `aiServiceProvider` 的同一个 AiService，对它 `updateConfig` 会把用户当前对话模型改掉。
  static Future<String> _requestVisionModel(String question, String imageDataUri) async {
    final service = AiService();
    service.updateConfig(
      FreeModelService.instance.toAiConfig(BuiltinFreeKeys.createVisionConfig()),
      temperature: 0.2,
      maxTokens: _maxAnswerTokens,
    );
    return service.chat([
      ChatMessage(role: 'user', content: question, images: [imageDataUri]),
    ]);
  }
}

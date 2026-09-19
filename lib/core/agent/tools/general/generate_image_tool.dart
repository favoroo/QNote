import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

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
///
/// 稳定性约定（2026-09-19 生图静默失败复盘后加入）：
/// - 主后端失败时自动降级到另一个内置生图后端（Gemini ↔ SenseNova）重试一次；
/// - 任何「HTTP 200 但没拿到图片」的路径都必须留下 warning 日志（含脱敏响应摘要），
///   不允许静默返回空；历史故障就是网关返回零 usage 的空壳，日志里查不到任何原因；
/// - 返回给模型的文案按 [ImageFailureKind] 分级，让模型能给用户可执行建议。
class GenerateImageTool extends AgentTool {
  final ImageRepository _imageRepo = ImageRepository();

  /// AI 生成的图片统一存放到 images/ai/ 子目录
  static const String _subfolder = 'ai';

  /// 生图耗时明显高于普通请求（实测成功样本约 9~30s），接收超时保留大余量。
  ///
  /// 从 180s 收紧到 150s：网关曾出现 70s 返回空壳、96~180s 挂死后被客户端断开（499），
  /// 同时配合「接收超时不再同后端重试」，避免单次调用耗时翻倍。
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 150);

  /// 降级后端用更短超时：主路径已经不通，备用路径快进快出
  static const Duration _fallbackConnectTimeout = Duration(seconds: 10);
  static const Duration _fallbackReceiveTimeout = Duration(seconds: 90);

  /// 整体时间预算：仅当「已耗时 + 备用预算」仍在总预算内时才允许进入降级分支
  static const Duration _totalBudget = Duration(seconds: 240);

  /// 备用后端返回 http 图片链接时的下载超时（与生图请求本身的超时解耦）
  static const Duration _downloadConnectTimeout = Duration(seconds: 10);
  static const Duration _downloadReceiveTimeout = Duration(seconds: 30);

  /// 提示词长度上限，防止异常长输入拖慢生图请求
  static const int _promptMaxLength = 2000;

  /// 响应摘要最大长度，避免异常内容把日志文件写爆
  static const int _summaryMaxChars = 600;

  // 以下形态标签用于日志：指明图片究竟是从响应哪个字段取到的，便于网关改版时快速定位
  static const String shapeMessageImages = 'message.images';
  static const String shapeContentParts = 'content.parts';
  static const String shapeContentMarkdown = 'content.markdown';
  static const String shapeInlineData = 'inlineData';
  static const String shapeGenerationsData = 'generations.data';

  /// Markdown 图片语法 `![alt](url)`，url 允许被 `<>` 包裹
  ///
  /// 捕获组排除 `>`，否则 `<url>` 形态会把右尖括号一并吞进引用里。
  static final RegExp _markdownImagePattern = RegExp(r'!\[[^\]]*\]\(\s*<?([^()\s>]+)>?\s*\)');

  /// 正文中的 base64 图片载荷（仅日志摘要用，命中即替换为体积占位符）
  static final RegExp _base64PayloadPattern = RegExp(r'base64,[A-Za-z0-9+/=\s]{64,}');

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

    // 备用后端读取失败不致命：只是这一次少了降级能力
    AiConfig? fallbackConfig;
    try {
      fallbackConfig =
          await AiRoleService.instance.getImageGenerationFallbackConfig(config.modelName);
    } catch (e) {
      LoggerService.instance.logAI(
        '读取备用生图后端配置失败，本次不降级',
        details: e.toString(),
        level: LogLevel.warning,
      );
    }

    final totalSw = Stopwatch()..start();
    final attempts = <ImageAttempt>[
      await _attemptGenerate(config, effectivePrompt, size,
          isFallback: false, onProgress: onProgress),
    ];

    if (attempts.first.succeeded) {
      onProgress?.call('图片生成完成');
      return _successResult(attempts.first, effectivePrompt);
    }

    // 本地保存失败换后端也没用；剩余时间预算不足时也不能再开一次长请求
    final canFallback = shouldTryFallback(attempts.first.failureKind, totalSw.elapsed);
    if (fallbackConfig != null) {
      if (canFallback) {
        LoggerService.instance.logAI(
          '小Q生图主后端未产出图片，切换备用后端重试',
          details: '${_backendTag(config)} → ${_backendTag(fallbackConfig)}, '
              '原因=${attempts.first.failureKind.label}, 已耗时=${_fmtDuration(totalSw.elapsed)}',
          level: LogLevel.warning,
        );
        onProgress?.call('主生图后端无结果，正在切换备用后端…');
        attempts.add(await _attemptGenerate(fallbackConfig, effectivePrompt, size,
            isFallback: true, onProgress: onProgress));
        if (attempts.last.succeeded) {
          onProgress?.call('图片生成完成');
          return _successResult(attempts.last, effectivePrompt,
              switchedFrom: config.name);
        }
      } else {
        LoggerService.instance.logAI(
          '小Q生图备用后端跳过',
          details: '原因=${attempts.first.failureKind.label}, '
              '已耗时=${_fmtDuration(totalSw.elapsed)}, 总预算=${_totalBudget.inSeconds}s',
          level: LogLevel.warning,
        );
      }
    }

    return ToolResult.error(describeFailures(attempts));
  }

  /// 对单个后端跑一遍「请求 → 解析 → 落盘」，任何异常都收敛成结构化失败，不向外抛
  ///
  /// [isFallback] 决定超时档位：降级路径用更短超时，避免主备两条路都把预算耗光。
  Future<ImageAttempt> _attemptGenerate(
    AiConfig config,
    String prompt,
    String size, {
    required bool isFallback,
    void Function(String progress)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    final senseNova = _isSenseNovaBackend(config);
    final dio = Dio()
      ..options.connectTimeout = isFallback ? _fallbackConnectTimeout : _connectTimeout
      ..options.receiveTimeout = isFallback ? _fallbackReceiveTimeout : _receiveTimeout
      ..options.headers = {
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
      };

    LoggerService.instance.logAI(
      isFallback ? '小Q生图降级后端发起请求' : '小Q生图工具发起请求',
      details: 'model=${config.modelName}, backend=${senseNova ? 'sensenova' : 'gemini'}, '
          'prompt=${prompt.length}字, receive_timeout=${(isFallback ? _fallbackReceiveTimeout : _receiveTimeout).inSeconds}s',
    );
    onProgress?.call('正在调用 ${config.name} 生成图片…');

    try {
      final outcome = senseNova
          ? await _requestSenseNova(dio, config, prompt, size)
          : await _requestGemini(dio, config, prompt);

      if (!outcome.hasImages) {
        // 关键分支：HTTP 200 但没有图片。历史上这里完全静默，故障无法定位
        final kind = classifyParseResult(outcome);
        LoggerService.instance.logAI(
          '小Q生图响应中未解析到图片',
          details: 'backend=${_backendTag(config)}, 分类=${kind.label}, '
              '耗时=${_fmtDuration(sw.elapsed)}, 响应摘要=${outcome.summary}',
          level: LogLevel.warning,
        );
        return ImageAttempt.failure(
          config,
          kind,
          sw.elapsed,
          detail: outcome.sawImageLikeField
              ? '响应含疑似图片字段但格式未识别，已记录脱敏摘要'
              : '网关接受请求但未产出图片（零用量），通常为上游权限/配额或临时故障',
        );
      }

      final saved = await _saveImages(outcome.refs, onProgress);
      if (saved.isEmpty) {
        LoggerService.instance.logAI(
          '小Q生图已取回图片但保存失败',
          details: 'backend=${_backendTag(config)}, refs=${outcome.refs.length}',
          level: LogLevel.warning,
        );
        return ImageAttempt.failure(
          config,
          ImageFailureKind.saveFailed,
          sw.elapsed,
          detail: '已取回 ${outcome.refs.length} 张图片但本地保存失败',
        );
      }

      LoggerService.instance.logAI(
        '小Q生图成功',
        details: 'backend=${_backendTag(config)}, count=${saved.length}, '
            'shapes=${outcome.shapes.join('|')}, 耗时=${_fmtDuration(sw.elapsed)}',
      );
      return ImageAttempt.success(config, saved, sw.elapsed);
    } on DioException catch (e) {
      final kind =
          (e.type == DioExceptionType.receiveTimeout ||
                  e.type == DioExceptionType.connectionTimeout ||
                  e.type == DioExceptionType.sendTimeout)
              ? ImageFailureKind.timeout
              : ImageFailureKind.httpError;
      LoggerService.instance.logAI(
        '小Q生图请求失败',
        details: 'backend=${_backendTag(config)}, 分类=${kind.label}, '
            '耗时=${_fmtDuration(sw.elapsed)}, ${_describeDioError(e)}（${e.message}）',
        level: LogLevel.warning,
      );
      return ImageAttempt.failure(config, kind, sw.elapsed,
          detail: _describeDioError(e));
    } catch (e) {
      LoggerService.instance.logAI(
        '小Q生图执行异常',
        details: 'backend=${_backendTag(config)}, 耗时=${_fmtDuration(sw.elapsed)}, $e',
        level: LogLevel.warning,
      );
      return ImageAttempt.failure(config, ImageFailureKind.unknown, sw.elapsed,
          detail: e.toString());
    }
  }

  /// 组装成功结果；[switchedFrom] 非空时把降级事实如实告知模型
  ToolResult _successResult(
    ImageAttempt attempt,
    String prompt, {
    String? switchedFrom,
  }) {
    final pathsBuffer = StringBuffer();
    for (final path in attempt.saved) {
      pathsBuffer.writeln('- $path');
    }
    return ToolResult.success(
      '${switchedFrom == null ? '' : '（主后端 $switchedFrom 未产出图片，本次由备用后端完成）\n'}'
      '已成功生成 ${attempt.saved.length} 张图片并保存（生图模型：${attempt.config.name}）：\n'
      '$pathsBuffer\n'
      '图片卡片已在对话中自动展示，回复正文里不要再写 ![image](路径) 重复贴图；'
      '仅当用户要求放进笔记/时间线/日记时，才把该路径按系统规范写进对应文件。',
      uiDetails: {
        'type': 'generate_image',
        'paths': attempt.saved,
        'model': attempt.config.name,
        'prompt': prompt,
        'backend': attempt.config.modelName,
      },
    );
  }

  /// 依据解析结果判定失败分类（纯函数，供日志与文案使用）
  ///
  /// 有图片线索却取不出引用 => 格式不认识；完全没有图片线索 => 上游没真正出图。
  @visibleForTesting
  static ImageFailureKind classifyParseResult(ImageParseOutcome outcome) =>
      outcome.sawImageLikeField ? ImageFailureKind.unknownFormat : ImageFailureKind.upstreamEmpty;

  /// 主后端失败后是否还值得降级到备用后端（纯函数，承载整体时间预算规则）
  ///
  /// - [ImageFailureKind.saveFailed] 是本地落盘问题，换后端无解；
  /// - 剩余预算不足以再跑一次降级请求时也必须放弃，否则用户会等到远超预期的时间。
  @visibleForTesting
  static bool shouldTryFallback(
    ImageFailureKind kind,
    Duration elapsed, {
    Duration totalBudget = _totalBudget,
    Duration fallbackBudget = _fallbackReceiveTimeout,
  }) {
    if (kind == ImageFailureKind.saveFailed) return false;
    return totalBudget - elapsed > fallbackBudget;
  }

  /// 汇总所有后端的失败分类，翻译成模型可据此给用户建议的文案
  @visibleForTesting
  static String describeFailures(List<ImageAttempt> attempts) {
    if (attempts.isEmpty) {
      return '本次生图未能发起请求（缺少可用的生图模型配置）。请如实告知用户生图功能暂不可用，严禁编造图片路径。';
    }
    final buffer = StringBuffer('本次生图失败：');
    for (var i = 0; i < attempts.length; i++) {
      final attempt = attempts[i];
      buffer.write('${i == 0 ? '' : '；'}${attempt.config.name}=${attempt.failureKind.label}'
          '（${attempt.detail}，耗时 ${_fmtDuration(attempt.elapsed)}）');
    }
    buffer.write('。请如实向用户说明原因：');
    switch (attempts.last.failureKind) {
      case ImageFailureKind.upstreamEmpty:
        buffer.write('上游网关接受了请求但没有产出图片，多为账号权限、配额或临时故障，'
            '与用户的描述无关；建议稍后重试，或换一个更简单的画面描述再试一次。');
      case ImageFailureKind.unknownFormat:
        buffer.write('上游返回了响应但图片无法解析，App 日志已留下脱敏摘要；建议用户稍后重试或反馈日志。');
      case ImageFailureKind.timeout:
        buffer.write('生图等待已超出上限（高峰期网关排队较久），建议稍后重试。');
      case ImageFailureKind.httpError:
        buffer.write('生图服务返回错误（鉴权失效、限速或网关故障），建议稍后重试。');
      case ImageFailureKind.saveFailed:
        buffer.write('图片已生成但保存到本地失败，请检查存储空间与权限。');
      case ImageFailureKind.unknown:
        buffer.write('发生未预期错误，建议稍后重试。');
    }
    buffer.write(' 严禁编造图片路径。');
    return buffer.toString();
  }

  /// 生图后端标签（与日志字段保持一致：sensenova / gemini 两条通路）
  static String _backendTag(AiConfig config) =>
      config.baseUrl.contains('sensenova') ? 'sensenova' : 'gemini';

  /// 秒级耗时文本（保留一位小数，便于和网关日志对齐）
  static String _fmtDuration(Duration d) =>
      (d.inMilliseconds / 1000).toStringAsFixed(1);

  /// 判断是否走商汤日日新 images/generations 后端（否则走网关 chat/completions）
  bool _isSenseNovaBackend(AiConfig config) => config.baseUrl.contains('sensenova');

  /// SenseNova 生图：POST /images/generations，显式 watermark:false 生成无水印图
  ///
  /// 商汤内置 Key 为 4 Key 轮询池，遇到限速/鉴权类可恢复错误时自动冷却换 Key 重试一次；
  /// 但**接收超时不在重试范围**——换 Key 不会让慢请求变快，只会把耗时翻倍。
  Future<ImageParseOutcome> _requestSenseNova(
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
        if (body == null) {
          LoggerService.instance.logAI(
            'SenseNova 生图响应体为空',
            details: 'status=${response.statusCode}, body=null',
            level: LogLevel.warning,
          );
          return const ImageParseOutcome.empty(
              summary: 'body=null（HTTP 响应体无法解析为 JSON）');
        }
        return parseGenerationImagesDetailed(body);
      } on DioException catch (e) {
        lastError = e;
        final recoverable = _isKeyRotableError(e);
        LoggerService.instance.logAI(
          'SenseNova 生图请求失败（第 ${attempt + 1} 次）',
          details: '${e.message}, 可换Key重试=$recoverable',
          level: LogLevel.warning,
        );
        if (!recoverable || attempt == 1) rethrow;
        apiKey = FreeModelKeyManager.instance.rotateKeyOnFailure(apiKey);
      }
    }
    throw lastError ?? Exception('SenseNova 生图请求失败');
  }

  /// Gemini/网关生图：POST /chat/completions，图片以 data URI 附在 message.images 里
  ///
  /// 网关为单 Key，只对连接类错误按退避重试一次；接收超时与 HTTP 错误直接上抛，
  /// 交给上层的多后端降级处理（同后端重跑一次只会拖慢失败反馈）。
  Future<ImageParseOutcome> _requestGemini(
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
        if (body == null) {
          LoggerService.instance.logAI(
            'Gemini 生图响应体为空',
            details: 'status=${response.statusCode}, body=null',
            level: LogLevel.warning,
          );
          return const ImageParseOutcome.empty(
              summary: 'body=null（HTTP 响应体无法解析为 JSON）');
        }
        return parseChatImagesDetailed(body);
      } on DioException catch (e) {
        lastError = e;
        final retriable = _isConnectionClassError(e);
        LoggerService.instance.logAI(
          'Gemini 生图请求失败（第 ${attempt + 1} 次）',
          details: '${e.message}, 连接类可重试=$retriable',
          level: LogLevel.warning,
        );
        if (!retriable || attempt == 1) rethrow;
      }
    }
    throw lastError ?? Exception('Gemini 生图请求失败');
  }

  /// 是否值得同后端重试：只保留连接类错误（含 TLS/ socket 抖动），排除接收超时与状态码错误
  static bool _isConnectionClassError(DioException e) {
    if (e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.badResponse) {
      return false;
    }
    return FreeModelKeyManager.instance.isRecoverableError(e);
  }

  /// SenseNova 专用：换 Key 是否有意义（限速/鉴权/瞬时网络），接收超时与 4xx 业务错除外
  static bool _isKeyRotableError(DioException e) {
    if (e.type == DioExceptionType.receiveTimeout) return false;
    return FreeModelKeyManager.instance.isRecoverableError(e);
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
          // 网络图片引用：下载字节后转 base64 再落盘（下载不该占用生图级别的超时）
          final dio = Dio()
            ..options.connectTimeout = _downloadConnectTimeout
            ..options.receiveTimeout = _downloadReceiveTimeout;
          final resp = await dio.get<List<int>>(
            ref,
            options: Options(responseType: ResponseType.bytes),
          );
          final bytes = resp.data;
          if (bytes == null || bytes.isEmpty) continue;
          base64Data = base64Encode(bytes);
        } else {
          // data URI（Gemini 网关返回形态）需先剥前缀取纯 base64
          final stripped = stripDataUriPrefix(ref);
          if (stripped == null || stripped.isEmpty) {
            LoggerService.instance.logAI(
              '生图结果为无法识别的引用形态，跳过该张图片',
              details: 'ref前缀=${ref.length > 24 ? ref.substring(0, 24) : ref}',
              level: LogLevel.warning,
            );
            continue;
          }
          base64Data = stripped;
        }

        // Web 端无本地文件系统，直接以 data URI 形式交付（与笔记编辑器 Web 图片方案一致）
        if (kIsWeb) {
          // 引用本身已是 data URI 时直接复用：省掉几百 KB 字符串拷贝，且保留真实 mime
          saved.add(ref.startsWith('data:') ? ref : 'data:image/png;base64,$base64Data');
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

  /// 剥离 data URI 前缀（`data:image/xxx;base64,`），返回纯 base64
  ///
  /// 裸 base64 原样返回；`data:` 开头但未携带 `base64,` 标记（如 URL-encoded 形态）
  /// 无法解码，返回 null 由调用方跳过。
  static String? stripDataUriPrefix(String ref) {
    if (!ref.startsWith('data:')) return ref;
    const marker = 'base64,';
    final idx = ref.indexOf(marker);
    if (idx == -1) return null;
    return ref.substring(idx + marker.length);
  }

  /// 从 chat/completions 响应解析图片引用（data URI 或 http URL）
  ///
  /// 兼容结构见 [parseChatImagesDetailed]：网关扩展的 `choices[].message.images[].image_url.url`、
  /// OpenAI 多模态 `content` parts 数组、正文 Markdown 图片、Google 原生 `inlineData`，
  /// 以及 `data[].url` / `data[].b64_json` 的 images/generations 形态。
  static List<String> parseChatImages(Map<String, dynamic> responseBody) =>
      parseChatImagesDetailed(responseBody).refs;

  /// [parseChatImages] 的详细版本：额外返回命中形态、是否见过疑似图片字段、脱敏响应摘要
  ///
  /// `sawImageLikeField` 用于区分两类失败：响应里根本没有图片线索（上游未产出），
  /// 与响应里有图片字段但取不出可用引用（格式不认识）。
  static ImageParseOutcome parseChatImagesDetailed(Map<String, dynamic> responseBody) {
    final refs = <String>{};
    final shapes = <String>{};
    var sawImageLike = false;

    final choices = responseBody['choices'];
    if (choices is List) {
      for (final choice in choices) {
        if (choice is! Map) continue;
        // 非流式放在 message，流式尾包可能放在 delta，两者都扫
        for (final message in [choice['message'], choice['delta']]) {
          if (_collectFromMessage(message, refs, shapes)) sawImageLike = true;
        }
      }
    }

    // 部分网关按 images/generations 结构返回，兜底解析
    final generations = parseGenerationImagesDetailed(responseBody);
    refs.addAll(generations.refs);
    shapes.addAll(generations.shapes);
    if (generations.sawImageLikeField) sawImageLike = true;

    return ImageParseOutcome(
      refs: refs.toList(),
      shapes: shapes,
      sawImageLikeField: sawImageLike,
      summary: summarizeImageResponse(responseBody),
    );
  }

  /// 扫描单条消息节点，返回是否出现过疑似图片字段
  static bool _collectFromMessage(dynamic message, Set<String> refs, Set<String> shapes) {
    if (message is! Map) return false;
    var sawImageLike = false;

    final images = message['images'];
    if (images is List && images.isNotEmpty) {
      sawImageLike = true;
      for (final image in images) {
        final url = _extractImageUrl(image);
        if (url != null) {
          refs.add(url);
          shapes.add(shapeMessageImages);
        }
      }
    }

    if (_collectFromContentNode(message['content'], refs, shapes)) sawImageLike = true;
    return sawImageLike;
  }

  /// 扫描 content 节点：既可能是字符串（AI-studio 网关会把图片转成 Markdown 塞进正文），
  /// 也可能是 OpenAI 多模态 parts 数组（`{type:'image_url'}` / `{inlineData}`）
  static bool _collectFromContentNode(dynamic content, Set<String> refs, Set<String> shapes) {
    if (content is String) return _collectFromText(content, refs, shapes);
    if (content is! List) return false;

    var sawImageLike = false;
    for (final part in content) {
      if (part is String) {
        if (_collectFromText(part, refs, shapes)) sawImageLike = true;
        continue;
      }
      if (part is! Map) continue;

      final url = _extractImageUrl(part);
      if (url != null) {
        refs.add(url);
        shapes.add(shapeContentParts);
        sawImageLike = true;
      } else if (part['image_url'] != null ||
          part['imageUrl'] != null ||
          part['type'] == 'image_url') {
        // 图片节点存在但拿不出合法 url：属于格式不认识，不能当成上游空结果
        sawImageLike = true;
      }

      final inline = part['inlineData'] ?? part['inline_data'];
      final inlineRef = _extractInlineDataSource(inline);
      if (inlineRef != null) {
        refs.add(inlineRef);
        shapes.add(shapeInlineData);
        sawImageLike = true;
      } else if (inline != null) {
        sawImageLike = true;
      }

      final text = part['text'];
      if (text is String && _collectFromText(text, refs, shapes)) sawImageLike = true;
    }
    return sawImageLike;
  }

  /// 从文本中提取图片引用：整段就是 data URI，或正文里含 Markdown 图片语法
  static bool _collectFromText(String text, Set<String> refs, Set<String> shapes) {
    if (text.isEmpty) return false;
    var sawImageLike = false;

    final bare = _normalizeImageRef(text);
    if (bare != null && bare.startsWith('data:image')) {
      refs.add(bare);
      shapes.add(shapeContentMarkdown);
      return true;
    }

    if (text.contains('](') || text.contains('data:image')) {
      final markdown = extractMarkdownImageRefs(text);
      if (markdown.isNotEmpty) {
        refs.addAll(markdown);
        shapes.add(shapeContentMarkdown);
        sawImageLike = true;
      } else if (text.contains('base64,')) {
        sawImageLike = true; // 疑似图片但语法不认识，留给 unknownFormat 分类
      }
    }
    return sawImageLike;
  }

  /// 从 Markdown 正文提取图片引用（data URI 或 http URL）
  static List<String> extractMarkdownImageRefs(String text) {
    // 先短路，避免对几百 KB 的正文跑正则
    if (text.isEmpty || !text.contains('](')) return const [];
    final refs = <String>[];
    for (final match in _markdownImagePattern.allMatches(text)) {
      final ref = _normalizeImageRef(match.group(1) ?? '');
      if (ref != null) refs.add(ref);
    }
    return refs;
  }

  /// 规范化图片引用：去空白、剥掉 Markdown 的 `<>` 包裹，只接受 data URI 与 http(s) URL
  static String? _normalizeImageRef(String raw) {
    var value = raw.trim();
    if (value.length > 1 && value.startsWith('<') && value.endsWith('>')) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.startsWith('data:') || value.startsWith('http')) return value;
    return null;
  }

  /// Google 原生 `inlineData` 节点转 data URI（缺 mime 时按 image/png 兜底）
  static String? _extractInlineDataSource(dynamic inline) {
    if (inline is! Map) return null;
    final data = inline['data']?.toString() ?? '';
    if (data.isEmpty) return null;
    final mime = (inline['mimeType'] ?? inline['mime_type'] ?? 'image/png').toString();
    return 'data:$mime;base64,$data';
  }

  /// 从 images/generations 响应解析图片引用（b64_json 或 url）
  static List<String> parseGenerationImages(Map<String, dynamic> responseBody) =>
      parseGenerationImagesDetailed(responseBody).refs;

  /// [parseGenerationImages] 的详细版本
  static ImageParseOutcome parseGenerationImagesDetailed(Map<String, dynamic> responseBody) {
    final refs = <String>{};
    final shapes = <String>{};
    final data = responseBody['data'];
    var sawImageLike = false;
    if (data is List) {
      if (data.isNotEmpty) sawImageLike = true;
      for (final item in data) {
        if (item is! Map) continue;
        final b64 = item['b64_json']?.toString() ?? '';
        if (b64.isNotEmpty) {
          refs.add(b64);
          shapes.add(shapeGenerationsData);
          continue;
        }
        final url = item['url']?.toString() ?? '';
        if (url.startsWith('http')) {
          refs.add(url);
          shapes.add(shapeGenerationsData);
        }
      }
    }
    return ImageParseOutcome(
      refs: refs.toList(),
      shapes: shapes,
      sawImageLikeField: sawImageLike,
      summary: summarizeImageResponse(responseBody),
    );
  }

  /// 生成脱敏响应摘要，用于「HTTP 200 但没拿到图片」时留下可定位证据
  ///
  /// 只读取定位需要的字段（顶层键、choices 结构、finish_reason、usage、错误信息、正文片段），
  /// base64 载荷一律换成 `<BASE64≈N KB>` 占位，密钥打码，总长度硬截断，
  /// 既不会写爆日志，也不会把图片原文或 API Key 落进日志文件。
  static String summarizeImageResponse(
    Map<String, dynamic> body, {
    int textPreviewChars = 200,
  }) {
    final parts = <String>['keys=${body.keys.take(8).join('/')}'];

    final choices = body['choices'];
    if (choices is List) {
      parts.add('choices=${choices.length}');
      final first = choices.isNotEmpty ? choices.first : null;
      if (first is Map) {
        parts.add(
            'finish=${first['finish_reason'] ?? first['native_finish_reason'] ?? '-'}');
        final message = first['message'] ?? first['delta'];
        if (message is Map) {
          parts.add('msg_keys=${message.keys.take(8).join('/')}');
          final images = message['images'];
          parts.add(images is List ? 'images=${images.length}' : 'images=none');
          final text = _plainTextOf(message['content']);
          parts.add('text_len=${text.length}');
          if (text.isNotEmpty) parts.add('text=${_preview(text, textPreviewChars)}');
        }
      }
    } else if (body.containsKey('choices')) {
      parts.add('choices=malformed');
    }

    final data = body['data'];
    if (data is List) parts.add('data=${data.length}');

    parts.add('usage=${_usageText(body['usage'] ?? body['usageMetadata'])}');

    final error = body['error'] ?? body['message'];
    if (error != null) parts.add('error=${_preview(_maskSecret('$error'), 160)}');

    final summary = parts.join(', ');
    return summary.length <= _summaryMaxChars
        ? summary
        : '${summary.substring(0, _summaryMaxChars)}…';
  }

  /// 取节点里的纯文本（字符串直接返回，parts 数组拼接各自 text）
  static String _plainTextOf(dynamic content) {
    if (content is String) return content;
    if (content is! List) return '';
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is String) {
        buffer.write(part);
      } else if (part is Map) {
        final text = part['text'];
        if (text is String) buffer.write(text);
      }
    }
    return buffer.toString();
  }

  /// usage 三元组（输入/输出/总计）；网关返回零 usage 往往意味着上游没真正出图
  static String _usageText(dynamic usage) {
    if (usage is! Map) return 'none';
    final prompt = usage['prompt_tokens'] ?? usage['input_tokens'] ?? 0;
    final completion = usage['completion_tokens'] ?? usage['output_tokens'] ?? 0;
    final total = usage['total_tokens'] ?? 0;
    return '$prompt/$completion/$total';
  }

  /// 压缩为单行预览：base64 载荷换成占位符、空白折叠、超长截断
  static String _preview(String text, int maxChars) {
    final redacted = text.replaceAllMapped(_base64PayloadPattern, (match) {
      final payload = match.group(0)!.substring('base64,'.length);
      return '<BASE64≈${(payload.length * 3 ~/ 4 ~/ 1024)}KB>';
    });
    final flat = redacted.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= maxChars ? flat : '${flat.substring(0, maxChars)}…';
  }

  /// 日志兜底脱敏：网关错误信息里可能回显 API Key
  static String _maskSecret(String text) => text
      .replaceAll(RegExp(r'sk-[A-Za-z0-9_\-]{4,}'), 'sk-***')
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._\-]{4,}'), 'Bearer ***');

  /// 从单张图片节点提取引用（兼容 {type, image_url:{url}}、{image_url: '...'} 与裸字符串）
  static String? _extractImageUrl(dynamic image) {
    if (image is String) return image.startsWith('data:') ? image : null;
    if (image is! Map) return null;
    final container = image['image_url'] ?? image['imageUrl'];
    if (container is Map) {
      final url = _normalizeImageRef(container['url']?.toString() ?? '');
      if (url != null) return url;
    }
    if (container is String) {
      final url = _normalizeImageRef(container);
      if (url != null) return url;
    }
    // 少数网关直接把 data URI / URL 放在节点自身
    return _normalizeImageRef(image['url']?.toString() ?? '');
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

/// 生图失败分类：决定日志措辞与给模型的可执行建议
enum ImageFailureKind {
  /// 网关返回 200，但响应里既没有图片也没有用量（上游没有真正产出图片）
  upstreamEmpty,

  /// 响应里出现了疑似图片字段，但当前解析器取不出可用引用
  unknownFormat,

  /// 连接或接收超时
  timeout,

  /// HTTP 状态码错误（鉴权失效、限速、网关故障等）
  httpError,

  /// 已成功取回图片，但本地保存失败
  saveFailed,

  /// 其他未归类异常
  unknown;

  String get label => switch (this) {
        ImageFailureKind.upstreamEmpty => '上游返回空结果',
        ImageFailureKind.unknownFormat => '响应格式未识别',
        ImageFailureKind.timeout => '请求超时',
        ImageFailureKind.httpError => '服务返回错误',
        ImageFailureKind.saveFailed => '图片保存失败',
        ImageFailureKind.unknown => '未知异常',
      };
}

/// 响应图片解析结果（纯数据，便于单测直接断言形态与摘要）
class ImageParseOutcome {
  const ImageParseOutcome({
    required this.refs,
    required this.shapes,
    required this.sawImageLikeField,
    required this.summary,
  });

  /// 无图片的空结果（如响应体无法解析为 JSON）
  const ImageParseOutcome.empty({this.summary = 'body=empty'})
      : refs = const [],
        shapes = const {},
        sawImageLikeField = false;

  /// 图片引用（data URI / 裸 base64 / http URL），按出现顺序去重
  final List<String> refs;

  /// 命中的图片形态标签集合，见 GenerateImageTool 的 shape* 常量
  final Set<String> shapes;

  /// 响应中是否出现过疑似图片字段（区分「上游空结果」与「格式不认识」）
  final bool sawImageLikeField;

  /// 脱敏响应摘要（不含 base64 原文与密钥）
  final String summary;

  bool get hasImages => refs.isNotEmpty;
}

/// 单个生图后端的一次完整尝试（请求 → 解析 → 落盘）结果
class ImageAttempt {
  const ImageAttempt._(this.config, this.saved, this.kind, this.detail, this.elapsed);

  /// 成功：[saved] 为已落盘路径（Web 端为 data URI）
  factory ImageAttempt.success(
    AiConfig config,
    List<String> saved,
    Duration elapsed,
  ) =>
      ImageAttempt._(config, saved, null, '', elapsed);

  /// 失败：[kind] 为分类，[detail] 为面向模型的补充说明
  factory ImageAttempt.failure(
    AiConfig config,
    ImageFailureKind kind,
    Duration elapsed, {
    String detail = '',
  }) =>
      ImageAttempt._(config, const [], kind, detail, elapsed);

  final AiConfig config;
  final List<String> saved;
  final ImageFailureKind? kind;
  final String detail;
  final Duration elapsed;

  bool get succeeded => kind == null;

  ImageFailureKind get failureKind => kind ?? ImageFailureKind.unknown;
}


import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/daily_score.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:uuid/uuid.dart';

class NoUsefulInfoException implements Exception {
  final String? message;
  NoUsefulInfoException([this.message]);

  @override
  String toString() =>
      message != null ? 'NoUsefulInfoException: $message' : 'NoUsefulInfoException';
}

/// 带工具流式对话的单个流片段。
///
/// - [text] 非 null：模型正文增量，供打字机渲染
/// - [toolProgress] 非 null：模型正在流式生成某工具调用的参数，
///   携带工具名与已拼接的部分参数快照，供 UI 在长参数生成期间
///   （如 write_file 写大文件）展示「正在写入文件 · 路径」等进行中状态
class AiToolStreamChunk {
  final String? text;
  final ToolCallProgress? toolProgress;

  const AiToolStreamChunk.text(this.text) : toolProgress = null;

  const AiToolStreamChunk.toolProgress(this.toolProgress) : text = null;
}

/// 工具调用参数的流式生成进度快照
class ToolCallProgress {
  final String toolName;

  /// 截至当前的原始参数 JSON 片段（可能不完整，仅用于展示层提取关键信息）
  final String partialArguments;

  const ToolCallProgress({required this.toolName, required this.partialArguments});
}

class AiService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 2),
      sendTimeout: const Duration(seconds: 30),
    ),
  );
  AiConfig? _config;
  double _temperature = 0.7;
  int _maxTokens = 2048;
  String? _reasoningEffort;

  AiConfig? get config => _config;

  /// 规范化与升级模型名称（自动防御已下线废弃模型，避免网关 404 等故障）
  static String normalizeModelName(String? modelName, {String? baseUrl}) {
    if (modelName == null) return '';
    final trimmed = modelName.trim();
    // SenseNova 6.7 系列已在商汤官方网关全面下线并报错 404 (model route not found)，自动迁移至 6.8
    if (trimmed == 'sensenova-6.7-flash-lite' ||
        trimmed == 'sensenova-6.7' ||
        trimmed == 'SenseChat-6.7' ||
        trimmed.startsWith('sensenova-6.7')) {
      return 'sensenova-6.8-flash-lite';
    }
    return trimmed;
  }

  void updateConfig(AiConfig config, {double? temperature, int? maxTokens}) {
    String cleanedBaseUrl = _cleanUrl(config.baseUrl);

    // If Gemini and baseUrl is empty, default to official Gemini API endpoint
    if (config.provider == 'gemini' && cleanedBaseUrl.isEmpty) {
      cleanedBaseUrl = 'https://generativelanguage.googleapis.com';
    }

    if (config.apiKey.isEmpty || cleanedBaseUrl.isEmpty) {
      throw ArgumentError('AI配置不完整: apiKey或baseUrl为空');
    }

    if (!cleanedBaseUrl.startsWith('http://') &&
        !cleanedBaseUrl.startsWith('https://')) {
      throw ArgumentError('Base URL格式错误: 必须以http://或https://开头');
    }

    final Uri? uri = Uri.tryParse(cleanedBaseUrl);
    if (uri == null || uri.host.isEmpty) {
      throw ArgumentError('Base URL格式无效: $cleanedBaseUrl');
    }

    // 自动规范化模型名称，防御历史配置或旧缓存导致调用已下线模型
    final normalizedModel = normalizeModelName(config.modelName, baseUrl: cleanedBaseUrl);
    final effectiveConfig = normalizedModel != config.modelName
        ? config.copyWith(modelName: normalizedModel)
        : config;

    _config = effectiveConfig;
    if (temperature != null) _temperature = temperature;
    if (maxTokens != null) _maxTokens = maxTokens;
    _dio.options.baseUrl = cleanedBaseUrl.endsWith('/')
        ? cleanedBaseUrl
        : '$cleanedBaseUrl/';

    // 从提供商配置读取默认推理强度
    _reasoningEffort = _resolveReasoningEffort(effectiveConfig);

    _dio.options.headers['Content-Type'] = 'application/json';
    if (effectiveConfig.provider == 'gemini') {
      _dio.options.headers['x-goog-api-key'] = effectiveConfig.apiKey;
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer ${effectiveConfig.apiKey}';
      _dio.options.headers.remove('x-goog-api-key');
    }

    LoggerService.instance.logAI(
      '更新AI配置: 提供商=${effectiveConfig.provider}, 模型=${effectiveConfig.modelName}',
      details:
          '原始URL=${effectiveConfig.baseUrl}, 清理后URL=$cleanedBaseUrl, endpoint=$_generateContentEndpoint'
          '${normalizedModel != config.modelName ? ', 模型自动从 ${config.modelName} 迁移为 $normalizedModel' : ''}',
    );
  }

  String _cleanUrl(String url) {
    return url
        .trim()
        .replaceAll(RegExp(r'[,\s]+$'), '') // 去除末尾逗号和空格
        .replaceAll(RegExp(r'/+$'), ''); // 去除末尾多余斜杠
  }

  /// 通用重试次数上限（无 Key 池可轮换的端点）
  ///
  /// 这类端点（用户自定义模型、非 SenseNova 的免费网关）没有备用 Key 可切，
  /// 只能靠时间退避穿越瞬时故障（TLS 握手中断、连接重置、网关 5xx 等），固定 3 次。
  static const int _genericMaxRetries = 3;

  /// 单次请求的重试深度
  ///
  /// - SenseNova 免费网关：等于 Key 池容量，每个 Key 各试一次
  /// - 其它（含用户自定义模型）：[_genericMaxRetries] 次纯退避重试
  int get _maxRetries {
    final isSenseNovaPool = _config?.vendorId == 'free_model' &&
        _config?.baseUrl.contains('sensenova') == true;
    return isSenseNovaPool
        ? FreeModelKeyManager.instance.totalKeysCount
        : _genericMaxRetries;
  }

  /// 统一的重试决策：判断本次失败是否值得重试，值得则切换可用 Key（若有）并退避等待
  ///
  /// [hasYielded] 供流式场景使用 —— 首包已产出后不再重试，否则调用方会收到重复内容。
  /// 返回 `true` 时调用方应 `retryCount++` 后 `continue` 重发本轮请求。
  Future<bool> _shouldRetryAndWait(
    Object error,
    int retryCount, {
    bool hasYielded = false,
    required String scene,
  }) async {
    if (hasYielded) return false;
    if (retryCount >= _maxRetries) return false;
    if (!FreeModelKeyManager.instance.isRecoverableError(error)) return false;

    final next = retryCount + 1;
    // 仅 SenseNova Key 池会真正轮到新 Key；自定义模型 / 独立端点此处为 no-op
    final switched = switchFreeModelKey();
    final delay = FreeModelKeyManager.instance.getBackoffDelay(next);
    LoggerService.instance.logAI(
      '$scene 遭遇瞬时故障（${_briefError(error)}），'
      '${switched ? '已切换备用 API Key' : '保持当前配置'}，'
      '退避 ${delay.inMilliseconds}ms 后发起第 $next/$_maxRetries 次重试',
      level: LogLevel.warning,
    );
    await Future.delayed(delay);
    return true;
  }

  /// 把异常压成单行摘要，避免重试日志被堆栈刷屏
  String _briefError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  /// 为免费模型自动切换下一个备用 Key，并更新请求头
  bool switchFreeModelKey() {
    if (_config?.vendorId != 'free_model') return false;
    // 仅针对属于 SenseNova Key 池的模型进行 Key 轮换，避免污染其他独立网关端点
    final isSenseNova = _config?.baseUrl.contains('sensenova') == true;
    if (!isSenseNova) return false;
    final oldKey = _config!.apiKey;
    final nextKey = FreeModelKeyManager.instance.rotateKeyOnFailure(oldKey);
    if (nextKey == oldKey) {
      return false;
    }
    _config = _config!.copyWith(apiKey: nextKey);
    _dio.options.headers['Authorization'] = 'Bearer $nextKey';
    LoggerService.instance.logAI(
      '已成功自动切换 SenseNova 免费模型备用 API Key 并准备重试',
    );
    return true;
  }

  Future<String> chat(
    List<ChatMessage> messages, {
    CancelToken? cancelToken,
  }) async {
    final response = await chatResponse(messages, cancelToken: cancelToken);
    return response.content;
  }

  /// 支持 Tool Calling 的同步调用，返回完整 ChatMessage（含 content、toolCalls、thought 等）
  Future<ChatMessage> chatResponse(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始对话请求(带工具支持)',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}, 工具数=${tools?.length ?? 0}',
    );

    int retryCount = 0;

    while (true) {
      try {
        String endpoint = _chatEndpoint;
        final bodyMap = await _prepareChatRequestBody(messages, stream: false, tools: tools);
        if (_config!.provider == 'gemini') {
          endpoint = '/v1beta/models/${_config!.modelName}:generateContent';
        }
        final dynamic requestBody = bodyMap;

        final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
        LoggerService.instance.logAI(
          'AI请求 [${_config!.provider}] [${_config!.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
        );

        final response = await _dio.post(endpoint, data: requestBody, cancelToken: cancelToken);

        final duration = DateTime.now().difference(startTime).inMilliseconds;
        final data = response.data;
        LoggerService.instance.logAI('AI响应:\n${_formatJsonForLogging(data)}');

        String content = '';
        List<ToolCall>? toolCalls;

        if (_config!.provider == 'gemini') {
          content =
              data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
        } else {
          final choice = data['choices']?[0];
          final message = choice?['message'] as Map<String, dynamic>?;
          content = message?['content'] as String? ?? '';
          
          if (message?['tool_calls'] != null && message!['tool_calls'] is List) {
            toolCalls = (message['tool_calls'] as List)
                .whereType<Map<String, dynamic>>()
                .map((m) => ToolCall.fromMap(m))
                .toList();
          }
        }

        LoggerService.instance.logAI(
          '对话完成',
          details: '耗时=${duration}ms, 响应长度=${content.length}字符, 工具调用数=${toolCalls?.length ?? 0}',
        );

        return ChatMessage(
          role: 'assistant',
          content: content,
          toolCalls: toolCalls,
          timestamp: DateTime.now(),
        );
      } catch (e, stackTrace) {
        // 用户主动中止（Dio CancelToken 触发）：直接抛出，禁止进入重试退避
        if (cancelToken?.isCancelled == true) rethrow;
        if (await _shouldRetryAndWait(e, retryCount, scene: '对话请求')) {
          retryCount++;
          continue;
        }

        String details = stackTrace.toString();
        if (e is DioException) {
          final respData = e.response?.data;
          final reqData = e.requestOptions.data;
          final reqHeaders = e.requestOptions.headers;
          final sanitizedReqData = _sanitizeRequestBodyForLogging(reqData);
          debugPrint('=== AI REQUEST ERROR DIAGNOSTICS ===');
          debugPrint('URL: ${e.requestOptions.uri}');
          debugPrint('Headers: $reqHeaders');
          debugPrint('Payload: ${_formatJsonForLogging(sanitizedReqData)}');
          debugPrint('Response Status: ${e.response?.statusCode}');
          if (respData != null) {
            debugPrint('Response Data: ${_formatJsonForLogging(respData)}');
          }
          debugPrint('====================================');
          if (respData != null) {
            details = 'Response Body: $respData\n\n$details';
          }
        }
        LoggerService.instance.logAI(
          '同步对话失败: $e',
          level: LogLevel.error,
          details: details,
        );
        rethrow;
      }
    }
  }

  /// 流式支持 Tool Calling 的高级流式调用
  ///
  /// - 当模型生成文本时，yield 文本增量片段（支持即时打字机效果）
  /// - 当模型生成 tool_calls 时，在内部聚合其参数碎片并周期性 yield 参数生成进度，
  ///   避免大参数（如 write_file 写大文件）生成期间 UI 无任何状态更新而形似卡死；
  ///   聚合完成后在 onToolCallsReady 回调中一次性交付完整对象
  Stream<AiToolStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
    CancelToken? cancelToken,
  }) async* {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始带工具的流式对话请求',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}, 工具数=${tools?.length ?? 0}',
    );

    int retryCount = 0;

    while (true) {
      bool hasYielded = false;
      try {
        final dynamic bodyMap = await _prepareChatRequestBody(messages, stream: true, tools: tools);
        final dynamic requestBody = jsonEncode(bodyMap);

        final response = await _dio.post<ResponseBody>(
          _chatEndpoint,
          data: requestBody,
          options: Options(responseType: ResponseType.stream),
          cancelToken: cancelToken,
        );

        final stream = response.data?.stream;
        if (stream == null) {
          LoggerService.instance.logAI('流式响应为空', level: LogLevel.warning);
          return;
        }

        String buffer = '';
        final accumulatedResponse = StringBuffer();
        // 存储流式拼接中的 tool_calls: index -> {id, name, argumentsBuffer}
        final Map<int, Map<String, dynamic>> toolCallBuilders = {};
        // 参数生成进度上报的节流时间点（跨工具共享，首次上报不受节流限制）
        DateTime? lastProgressAt;

        await for (final chunk in stream) {
          buffer += utf8.decode(chunk, allowMalformed: true);
          final lines = buffer.split('\n');
          buffer = lines.removeLast();

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
            final data = trimmed.substring(5).trim();
            if (data == '[DONE]') {
              final duration = DateTime.now().difference(startTime).inMilliseconds;
              LoggerService.instance.logAI(
                'AI带工具流式响应完成 [耗时=${duration}ms]:\n$accumulatedResponse',
              );
              _deliverToolCalls(toolCallBuilders, onToolCallsReady);
              return;
            }

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              // 捕获商汤等服务商在流式第一包中下发的 JSON 错误对象
              if (json.containsKey('error')) {
                final errObj = json['error'];
                final errMsg = errObj is Map ? (errObj['message'] ?? errObj.toString()) : errObj.toString();
                throw Exception('AI Stream Error: $errMsg');
              }

              final choice = json['choices']?[0];
              final delta = choice?['delta'] as Map<String, dynamic>?;

              // 1. 文本内容增量
              final text = delta?['content'] as String?;
              if (text != null && text.isNotEmpty) {
                accumulatedResponse.write(text);
                hasYielded = true;
                yield AiToolStreamChunk.text(text);
              }

              // 2. 工具调用碎片聚合
              final toolCallsDelta = delta?['tool_calls'] as List?;
              if (toolCallsDelta != null) {
                for (final tc in toolCallsDelta) {
                  if (tc is! Map<String, dynamic>) continue;
                  final idx = tc['index'] as int? ?? 0;
                  final builder = toolCallBuilders.putIfAbsent(idx, () => {
                    'id': '',
                    'name': '',
                    'arguments': StringBuffer(),
                  });

                  if (tc['id'] != null) {
                    builder['id'] = (builder['id'] as String) + (tc['id'] as String);
                  }
                  final func = tc['function'] as Map<String, dynamic>?;
                  if (func != null) {
                    if (func['name'] != null) {
                      builder['name'] = (builder['name'] as String) + (func['name'] as String);
                    }
                    if (func['arguments'] != null) {
                      (builder['arguments'] as StringBuffer).write(func['arguments']);
                    }
                  }

                  // 参数生成进度上报：参数已开始流出说明工具名必已完整，
                  // 首次立即上报让 UI 尽快切到工具状态，此后 500ms 节流
                  final name = builder['name'] as String;
                  final argsBuffer = builder['arguments'] as StringBuffer;
                  if (name.isNotEmpty && argsBuffer.isNotEmpty) {
                    final now = DateTime.now();
                    final isFirstProgress = builder['progressNotified'] != true;
                    if (isFirstProgress ||
                        now.difference(lastProgressAt!).inMilliseconds >= 500) {
                      builder['progressNotified'] = true;
                      lastProgressAt = now;
                      yield AiToolStreamChunk.toolProgress(
                        ToolCallProgress(
                          toolName: name,
                          partialArguments: argsBuffer.toString(),
                        ),
                      );
                    }
                  }
                }
              }
            } catch (e) {
              // 若已进入显式错误，直接抛出交由外层重试判断
              if (e.toString().contains('AI Stream Error:')) {
                rethrow;
              }
            }
          }
        }

        _deliverToolCalls(toolCallBuilders, onToolCallsReady);
        return;
      } catch (e, stackTrace) {
        // 用户主动中止（Dio CancelToken 触发）：直接抛出，禁止进入重试退避
        if (cancelToken?.isCancelled == true) rethrow;
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          hasYielded: hasYielded,
          scene: '带工具流式对话',
        )) {
          retryCount++;
          continue;
        }
        LoggerService.instance.logAI(
          '带工具流式对话失败: $e',
          level: LogLevel.error,
          details: stackTrace.toString(),
        );
        rethrow;
      }
    }
  }

  void _deliverToolCalls(
    Map<int, Map<String, dynamic>> toolCallBuilders,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
  ) {
    if (toolCallBuilders.isEmpty || onToolCallsReady == null) return;
    final List<ToolCall> completedCalls = [];
    for (final b in toolCallBuilders.values) {
      final id = b['id'] as String? ?? 'call_${DateTime.now().millisecondsSinceEpoch}';
      final name = b['name'] as String? ?? '';
      final argsStr = (b['arguments'] as StringBuffer).toString();
      Map<String, dynamic> args = {};
      try {
        if (argsStr.trim().isNotEmpty) {
          args = jsonDecode(argsStr) as Map<String, dynamic>;
        }
      } catch (_) {}
      completedCalls.add(ToolCall(id: id, name: name, arguments: args));
    }
    if (completedCalls.isNotEmpty) {
      onToolCallsReady(completedCalls);
    }
  }

  Stream<String> chatStream(List<ChatMessage> messages) async* {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始流式对话请求',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}',
    );

    int retryCount = 0;

    while (true) {
      bool hasYielded = false;
      try {
        final dynamic bodyMap = await _prepareChatRequestBody(messages, stream: true);
        final dynamic requestBody = jsonEncode(bodyMap);

        final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
        LoggerService.instance.logAI(
          'AI流式请求 [${_config!.provider}] [${_config!.modelName}] $_chatEndpoint:\n${_formatJsonForLogging(sanitizedBody)}',
        );

        final response = await _dio.post<ResponseBody>(
          _chatEndpoint,
          data: requestBody,
          options: Options(responseType: ResponseType.stream),
        );

        final stream = response.data?.stream;
        if (stream == null) {
          LoggerService.instance.logAI('流式响应为空', level: LogLevel.warning);
          return;
        }

        String buffer = '';
        int totalChars = 0;
        final accumulatedResponse = StringBuffer();
        await for (final chunk in stream) {
          buffer += utf8.decode(chunk, allowMalformed: true);
          final lines = buffer.split('\n');
          buffer = lines.removeLast();

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
            final data = trimmed.substring(5).trim();
            if (data == '[DONE]') {
              final duration = DateTime.now()
                  .difference(startTime)
                  .inMilliseconds;
              LoggerService.instance.logAI(
                'AI流式响应完成 [总输出=$totalChars字符] [耗时=${duration}ms]:\n$accumulatedResponse',
              );
              return;
            }

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              if (json.containsKey('error')) {
                final errObj = json['error'];
                final errMsg = errObj is Map ? (errObj['message'] ?? errObj.toString()) : errObj.toString();
                throw Exception('AI Stream Error: $errMsg');
              }

              String? text;
              if (_config!.provider == 'gemini') {
                text = json['candidates']?[0]?['content']?['parts']?[0]?['text'];
              } else {
                text = json['choices']?[0]?['delta']?['content'];
              }
              if (text != null) {
                totalChars += text.length;
                accumulatedResponse.write(text);
                hasYielded = true;
                yield text;
              }
            } catch (e) {
              if (e.toString().contains('AI Stream Error:')) {
                rethrow;
              }
            }
          }
        }

        final duration = DateTime.now().difference(startTime).inMilliseconds;
        LoggerService.instance.logAI(
          'AI流式响应结束 [总输出=$totalChars字符] [耗时=${duration}ms]:\n$accumulatedResponse',
        );
        return;
      } catch (e, stackTrace) {
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          hasYielded: hasYielded,
          scene: '普通流式对话',
        )) {
          retryCount++;
          continue;
        }

        String details = stackTrace.toString();
        if (e is DioException) {
          final respData = e.response?.data;
          if (respData != null) {
            details = 'Response Body: $respData\n\n$details';
          }
        }
        LoggerService.instance.logAI(
          '流式对话失败: $e',
          level: LogLevel.error,
          details: details,
        );
        rethrow;
      }
    }
  }

  String get _chatEndpoint {
    if (_config!.provider == 'gemini') {
      return 'v1beta/models/${_config!.modelName}:streamGenerateContent?alt=sse';
    }
    final baseUrl = _config!.baseUrl;
    if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/v1/')) {
      return 'chat/completions';
    }
    return 'v1/chat/completions';
  }

  String get _generateContentEndpoint {
    if (_config!.provider == 'gemini') {
      return 'v1beta/models/${_config!.modelName}:generateContent';
    }
    final baseUrl = _config!.baseUrl;
    if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/v1/')) {
      return 'chat/completions';
    }
    return 'v1/chat/completions';
  }

  /// 统一构建普通对话与流式对话的请求体，兼容多模态图片输入与不同供应商协议
  Future<dynamic> _prepareChatRequestBody(
    List<ChatMessage> messages, {
    bool stream = false,
    List<Map<String, dynamic>>? tools,
  }) async {
    final imageRepo = ImageRepository();

    if (_config!.provider == 'gemini') {
      String? systemInstruction;
      final List<Map<String, dynamic>> contents = [];

      for (final m in messages) {
        if (m.role == 'system') {
          systemInstruction = m.content;
        } else {
          final role = m.role == 'user' ? 'user' : 'model';
          final parts = <Map<String, dynamic>>[
            {'text': m.content},
          ];

          if (m.images != null && m.images!.isNotEmpty) {
            for (final imgPath in m.images!) {
              try {
                String b64 = '';
                String mime = ImageRepository.getMimeType(imgPath);
                if (imgPath.startsWith('data:')) {
                  final commaIdx = imgPath.indexOf(',');
                  if (commaIdx != -1) {
                    b64 = imgPath.substring(commaIdx + 1);
                    final header = imgPath.substring(5, commaIdx);
                    if (header.contains(';')) {
                      mime = header.split(';').first;
                    }
                  }
                } else {
                  b64 = await imageRepo.getBase64Image(imgPath);
                }
                if (b64.isNotEmpty) {
                  parts.add({
                    'inline_data': {'mime_type': mime, 'data': b64},
                  });
                }
              } catch (e) {
                LoggerService.instance.logAI(
                  '加载Gemini多模态图片失败: $imgPath, error=$e',
                  level: LogLevel.warning,
                );
              }
            }
          }

          contents.add({
            'role': role,
            'parts': parts,
          });
        }
      }

      final bodyMap = <String, dynamic>{
        'contents': contents,
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
        },
      };
      if (systemInstruction != null) {
        bodyMap['systemInstruction'] = {
          'parts': [
            {'text': systemInstruction},
          ],
        };
      }
      return bodyMap;
    }

    final isOmni = _config!.modelName.toLowerCase().contains('omni');
    final formattedMessages = <Map<String, dynamic>>[];

    for (final m in messages) {
      if (m.role == 'tool') {
        // 工具执行结果消息 (OpenAI Tool Role)
        formattedMessages.add({
          'role': 'tool',
          'tool_call_id': m.toolCallId ?? '',
          'content': m.content,
        });
        continue;
      }

      if (m.role == 'assistant' && m.toolCalls != null && m.toolCalls!.isNotEmpty) {
        // 含有工具调用的助手消息
        formattedMessages.add({
          'role': 'assistant',
          'content': m.content.isEmpty ? null : m.content,
          'tool_calls': m.toolCalls!.map((t) => t.toMap()).toList(),
        });
        continue;
      }

      final hasImages = m.images != null && m.images!.isNotEmpty;
      if (isOmni) {
        final contentList = <Map<String, dynamic>>[
          {'type': 'text', 'text': m.content},
        ];
        if (hasImages) {
          final b64List = <String>[];
          for (final imgPath in m.images!) {
            try {
              String b64 = '';
              if (imgPath.startsWith('data:')) {
                final commaIdx = imgPath.indexOf(',');
                if (commaIdx != -1) b64 = imgPath.substring(commaIdx + 1);
              } else {
                b64 = await imageRepo.getBase64Image(imgPath);
              }
              if (b64.isNotEmpty) b64List.add(b64);
            } catch (_) {}
          }
          if (b64List.isNotEmpty) {
            contentList.add({
              'type': 'input_image',
              'input_image': {
                'type': 'base64',
                'data': b64List,
              },
            });
          }
        }
        formattedMessages.add({
          'role': m.role,
          'content': contentList,
        });
      } else if (hasImages) {
        final contentList = <Map<String, dynamic>>[
          if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
        ];
        for (final imgPath in m.images!) {
          try {
            String b64 = '';
            String mime = ImageRepository.getMimeType(imgPath);
            if (imgPath.startsWith('data:')) {
              final commaIdx = imgPath.indexOf(',');
              if (commaIdx != -1) {
                b64 = imgPath.substring(commaIdx + 1);
                final header = imgPath.substring(5, commaIdx);
                if (header.contains(';')) {
                  mime = header.split(';').first;
                }
              }
            } else {
              b64 = await imageRepo.getBase64Image(imgPath);
            }
            if (b64.isNotEmpty) {
              contentList.add({
                'type': 'image_url',
                'image_url': {'url': 'data:$mime;base64,$b64'},
              });
            }
          } catch (e) {
            LoggerService.instance.logAI(
              '加载图片失败: $imgPath, error=$e',
              level: LogLevel.warning,
            );
          }
        }
        formattedMessages.add({
          'role': m.role,
          'content': contentList,
        });
      } else {
        formattedMessages.add({'role': m.role, 'content': m.content});
      }
    }

    final bodyMap = _buildBaseBody(messages: formattedMessages, stream: stream, tools: tools);
    if (isOmni) {
      bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch.toString();
      bodyMap['output_modalities'] = ['text'];
    }
    return bodyMap;
  }

  /// 构建 OpenAI 兼容接口的基础请求体，统一注入通用参数。
  Map<String, dynamic> _buildBaseBody({
    required List<dynamic> messages,
    bool stream = false,
    Map<String, dynamic>? responseFormat,
    List<Map<String, dynamic>>? tools,
  }) {
    final body = <String, dynamic>{
      'model': _config!.modelName,
      'messages': messages,
      'temperature': _temperature,
      'max_tokens': _maxTokens,
    };
    if (stream) body['stream'] = true;
    if (responseFormat != null) body['response_format'] = responseFormat;
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }
    if (_reasoningEffort != null) {
      body['reasoning_effort'] = _reasoningEffort;
    }
    return body;
  }

  /// 根据配置推断默认推理强度。
  ///
  /// 优先级：vendorId 匹配 > baseUrl 匹配 > modelName 匹配
  String? _resolveReasoningEffort(AiConfig config) {
    // 1. 优先通过 vendorId 匹配
    if (config.vendorId != null && config.vendorId != 'free_model') {
      final providerConfig = getProviderById(config.vendorId!);
      if (providerConfig?.defaultReasoningEffort != null) {
        return providerConfig!.defaultReasoningEffort;
      }
    }

    // 2. 通过 baseUrl 匹配
    final baseUrl = config.baseUrl.toLowerCase();
    for (final provider in aiProviders) {
      if (provider.defaultReasoningEffort == null) continue;
      final providerUrl = provider.defaultBaseUrl.toLowerCase();
      if (providerUrl.isNotEmpty && baseUrl.contains(providerUrl.replaceAll('https://', '').replaceAll('http://', ''))) {
        return provider.defaultReasoningEffort;
      }
    }

    // 3. 通过 modelName 匹配
    final modelName = config.modelName.toLowerCase();
    for (final provider in aiProviders) {
      if (provider.defaultReasoningEffort == null) continue;
      for (final model in provider.models) {
        if (modelName == model.toLowerCase()) {
          return provider.defaultReasoningEffort;
        }
      }
    }

    return null;
  }

  Future<String> generateDiarySummary(String diaryContent) async {
    LoggerService.instance.logAI(
      '生成日记摘要',
      details: '输入长度=${diaryContent.length}字符',
    );

    final messages = [
      ChatMessage(
        role: 'system',
        content:
            'You are a helpful assistant that summarizes diary entries. '
            'Provide a concise and insightful summary of the diary content.',
      ),
      ChatMessage(role: 'user', content: diaryContent),
    ];
    return await chat(messages);
  }

  Future<String> analyzeMood(String diaryContent) async {
    LoggerService.instance.logAI(
      '分析心情状态',
      details: '输入长度=${diaryContent.length}字符',
    );

    final messages = [
      ChatMessage(
        role: 'system',
        content:
            'You are a mood analysis assistant. Analyze the emotional tone '
            'of the diary entry and provide a brief mood assessment.',
      ),
      ChatMessage(role: 'user', content: diaryContent),
    ];
    return await chat(messages);
  }

  Future<String> generateTodoSuggestions(String context) async {
    LoggerService.instance.logAI(
      '生成待办建议',
      details: '上下文长度=${context.length}字符',
    );

    final messages = [
      ChatMessage(
        role: 'system',
        content:
            'You are a productivity assistant. Based on the provided context, '
            'suggest actionable todo items.',
      ),
      ChatMessage(role: 'user', content: context),
    ];
    return await chat(messages);
  }

  Map<String, dynamic> _parseSimplifiedTime(String t) {
    final result = <String, dynamic>{};

    if (t.contains('~')) {
      final parts = t.split('~');
      final startPart = parts[0];
      final endPart = parts[1];

      if (startPart.isNotEmpty) {
        if (startPart.startsWith('-')) {
          result['start'] = startPart.substring(1);
          result['startOffset'] = -1;
        } else {
          result['start'] = startPart;
        }
      }

      if (endPart.isNotEmpty) {
        if (endPart.startsWith('-')) {
          result['end'] = endPart.substring(1);
          result['endOffset'] = -1;
        } else {
          result['end'] = endPart;
          result['endOffset'] = 0;
        }
      }
    } else {
      if (t.startsWith('-')) {
        result['start'] = t.substring(1);
        result['startOffset'] = -1;
      } else {
        result['start'] = t;
      }
    }

    return result;
  }

  Map<String, dynamic> _convertSimplifiedExtractResult(
    Map<String, dynamic> simplified,
  ) {
    final result = <String, dynamic>{};

    result['shortcutId'] = simplified['id'] ?? simplified['shortcutId'];

    if (simplified.containsKey('t')) {
      result['time'] = _parseSimplifiedTime(simplified['t'] as String);
    } else if (simplified.containsKey('time')) {
      final timeVal = simplified['time'];
      if (timeVal is String) {
        result['time'] = _parseSimplifiedTime(timeVal);
      } else if (timeVal is Map) {
        result['time'] = timeVal;
      } else {
        result['time'] = {};
      }
    } else {
      result['time'] = {};
    }

    result['fields'] = simplified['f'] ?? simplified['fields'] ?? {};

    result['notes'] = simplified['n'] ?? simplified['notes'] ?? '';

    if (simplified.containsKey('date')) {
      result['date'] = simplified['date'];
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> extractUnified({
    String? text,
    String? imageBase64,
    String? mimeType,
    required String schema,
    String? contextStr,
    CancelToken? cancelToken,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    final hasImage = imageBase64 != null && imageBase64.isNotEmpty;
    final hasText = text != null && text.isNotEmpty;

    String inputType;
    if (hasImage && hasText) {
      inputType = '图文';
    } else if (hasImage) {
      inputType = '图片';
    } else {
      inputType = '文本';
    }

    LoggerService.instance.logAI(
      '统一提取请求',
      details: '类型=$inputType, 有文本=$hasText, 有图片=$hasImage',
    );

    var systemPrompt = defaultSystemPrompts['unified_extraction'] ?? '';
    systemPrompt = systemPrompt
        .replaceAll('{{contextStr}}', contextStr ?? '')
        .replaceAll('{{schema}}', schema);

    dynamic requestBody;

    if (hasImage) {
      requestBody = _buildMultimodalRequestBody(
        systemPrompt: systemPrompt,
        imageBase64: imageBase64,
        mimeType: mimeType ?? 'image/jpeg',
        text: text,
        inputType: inputType,
      );
    } else {
      final userMessageText = '[用户输入] ($inputType)\n${text ?? ''}';
      if (_config!.provider == 'gemini') {
        requestBody = {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': userMessageText},
              ],
            },
          ],
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt},
            ],
          },
          'generationConfig': {
            'temperature': _temperature,
            'maxOutputTokens': _maxTokens,
            'responseMimeType': 'application/json',
          },
        };
      } else {
        final isOmni = _config!.modelName.toLowerCase().contains('omni');
        final formattedMessages = [
          if (isOmni) ...[
            {
              'role': 'system',
              'content': [
                {'type': 'text', 'text': systemPrompt},
              ],
            },
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': userMessageText},
              ],
            },
          ] else ...[
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMessageText},
          ],
        ];

        final bodyMap = _buildBaseBody(
          messages: formattedMessages,
          responseFormat: {'type': 'json_object'},
        );

        if (isOmni) {
          bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch
              .toString();
          bodyMap['output_modalities'] = ['text'];
        }

        requestBody = bodyMap;
      }
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI统一提取请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    int retryCount = 0;

    while (true) {
      try {
        final response = await _dio.post(
          _generateContentEndpoint,
          data: requestBody,
          cancelToken: cancelToken,
        );
        // 检测推理模型是否因 max_tokens 不足导致输出截断
        final finishReason = _extractFinishReason(response.data);
        if (finishReason == 'length') {
          LoggerService.instance.logAI(
            '⚠️ AI响应被截断 (finish_reason: length)，当前 max_tokens=$_maxTokens 可能不够推理模型使用',
            level: LogLevel.warning,
          );
        }

        final content = _extractTextFromResponse(response.data);
        LoggerService.instance.logAI(
          'AI统一提取响应:\n${_formatJsonForLogging(response.data)}',
        );

        final jsonResult = _parseJsonFromAiContent(content);
        LoggerService.instance.logAI(
          '统一提取完成',
          details: '结果数量=${jsonResult is List ? jsonResult.length : 1}',
        );

        List<Map<String, dynamic>> results;
        if (jsonResult is List) {
          results = jsonResult.cast<Map<String, dynamic>>();
        } else if (jsonResult is Map<String, dynamic>) {
          if (jsonResult['message'] == 'NO_USEFUL_INFO') {
            LoggerService.instance.logAI(
              '统一提取完成',
              details: 'AI返回NO_USEFUL_INFO，未提取到有用信息',
            );
            return [];
          }
          List<Map<String, dynamic>>? foundList;
          if (jsonResult['tags'] is List &&
              (jsonResult['tags'] as List).every((e) => e is Map)) {
            foundList = (jsonResult['tags'] as List).cast<Map<String, dynamic>>();
          } else if (jsonResult['results'] is List &&
              (jsonResult['results'] as List).every((e) => e is Map)) {
            foundList = (jsonResult['results'] as List)
                .cast<Map<String, dynamic>>();
          } else {
            for (final entry in jsonResult.entries) {
              final val = entry.value;
              if (val is List && val.every((e) => e is Map)) {
                foundList = val.cast<Map<String, dynamic>>();
                break;
              }
            }
          }
          if (foundList != null) {
            results = foundList;
          } else {
            results = [jsonResult];
          }
        } else {
          results = [];
        }

        if (results.isEmpty) {
          LoggerService.instance.logAI(
            '统一提取完成',
            details: '结果为空，未提取到有用信息',
          );
          return [];
        }

        return results.map(_convertSimplifiedExtractResult).toList();
      } catch (e, stackTrace) {
        if (await _shouldRetryAndWait(e, retryCount, scene: '日记统一提取')) {
          retryCount++;
          continue;
        }
        LoggerService.instance.logAI(
          '统一提取失败: $e',
          level: LogLevel.error,
          details: stackTrace.toString(),
        );
        rethrow;
      }
    }
  }

  /// 多模态对话：发送图片+文本，返回纯文本响应（不强制 JSON 格式）。
  ///
  /// 用于笔记图片内容识别等场景，与 [extractUnified] 的区别在于：
  /// - 不强制 `response_format: json_object` / `responseMimeType: application/json`
  /// - 直接返回模型的纯文本输出，由调用方自行处理
  Future<String> chatWithImage({
    required String imageBase64,
    required String mimeType,
    String? userText,
    String? systemPrompt,
    CancelToken? cancelToken,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始图片识别请求',
      details: '模型=${_config!.modelName}, 有文本=${userText != null && userText.isNotEmpty}',
    );

    final requestBody = _buildImageChatRequestBody(
      systemPrompt: systemPrompt ?? '',
      imageBase64: imageBase64,
      mimeType: mimeType,
      text: userText,
    );

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      '图片识别请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    int retryCount = 0;

    while (true) {
      try {
        final response = await _dio.post(
          _generateContentEndpoint,
          data: requestBody,
          cancelToken: cancelToken,
        );
        final result = _extractTextFromResponse(response.data);
        LoggerService.instance.logAI(
          '图片识别响应:\n${_formatJsonForLogging(response.data)}',
        );
        LoggerService.instance.logAI(
          '图片识别完成',
          details: '耗时=${DateTime.now().difference(startTime).inMilliseconds}ms, 响应长度=${result.length}字符',
        );
        return result;
      } catch (e, stackTrace) {
        if (await _shouldRetryAndWait(e, retryCount, scene: '图片识别')) {
          retryCount++;
          continue;
        }

        String details = stackTrace.toString();
        if (e is DioException) {
          final respData = e.response?.data;
          if (respData != null) {
            details = 'Response Body: $respData\n\n$details';
          }
        }
        LoggerService.instance.logAI(
          '图片识别失败: $e',
          level: LogLevel.error,
          details: details,
        );
        rethrow;
      }
    }
  }

  /// 构建多模态对话请求体（自由文本输出，不强制 JSON）。
  ///
  /// 结构与 [_buildMultimodalRequestBody] 一致，但去掉了 `response_format` /
  /// `responseMimeType` 约束，让模型自由输出文本。
  Map<String, dynamic> _buildImageChatRequestBody({
    required String systemPrompt,
    required String imageBase64,
    required String mimeType,
    String? text,
  }) {
    final userMessageText = text ?? '';
    if (_config!.provider == 'gemini') {
      final parts = <Map<String, dynamic>>[
        if (userMessageText.isNotEmpty) {'text': userMessageText},
        {
          'inline_data': {'mime_type': mimeType, 'data': imageBase64},
        },
      ];
      return {
        'contents': [
          {
            'role': 'user',
            'parts': parts,
          },
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
        },
      };
    }

    final isOmni = _config!.modelName.toLowerCase().contains('omni');
    if (isOmni) {
      return {
        'model': _config!.modelName,
        'messages': [
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              if (userMessageText.isNotEmpty)
                {'type': 'text', 'text': userMessageText},
              {
                'type': 'input_image',
                'input_image': {
                  'type': 'base64',
                  'data': [imageBase64],
                },
              },
            ],
          },
        ],
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'sessionId': DateTime.now().millisecondsSinceEpoch.toString(),
        'output_modalities': ['text'],
      };
    }

    return _buildBaseBody(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {
          'role': 'user',
          'content': [
            if (userMessageText.isNotEmpty)
              {'type': 'text', 'text': userMessageText},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mimeType;base64,$imageBase64'},
            },
          ],
        },
      ],
    );
  }

  Map<String, dynamic> _buildMultimodalRequestBody({
    required String systemPrompt,
    required String imageBase64,
    required String mimeType,
    String? text,
    required String inputType,
  }) {
    final userMessageText = '[用户输入] ($inputType)\n${text ?? ''}';
    if (_config!.provider == 'gemini') {
      return {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': userMessageText},
              {
                'inline_data': {'mime_type': mimeType, 'data': imageBase64},
              },
            ],
          },
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
          'responseMimeType': 'application/json',
        },
      };
    }

    final isOmni = _config!.modelName.toLowerCase().contains('omni');
    if (isOmni) {
      return {
        'model': _config!.modelName,
        'messages': [
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userMessageText},
              {
                'type': 'input_image',
                'input_image': {
                  'type': 'base64',
                  'data': [imageBase64],
                },
              },
            ],
          },
        ],
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'sessionId': DateTime.now().millisecondsSinceEpoch.toString(),
        'output_modalities': ['text'],
      };
    }

    return _buildBaseBody(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': userMessageText},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mimeType;base64,$imageBase64'},
            },
          ],
        },
      ],
      responseFormat: {'type': 'json_object'},
    );
  }

  String _extractTextFromResponse(dynamic data) {
    // 如果 data 本身就是字符串，直接返回（可能是未自动解析的 JSON 或纯文本响应）
    if (data is String) {
      return data;
    }
    if (data is! Map<String, dynamic>) {
      LoggerService.instance.logAI(
        'AI响应数据格式异常: ${data.runtimeType}',
        level: LogLevel.warning,
      );
      return '';
    }

    if (_config!.provider == 'gemini') {
      final candidates = data['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final content = candidates[0]?['content'];
        if (content is Map) {
          final parts = content['parts'];
          if (parts is List && parts.isNotEmpty) {
            return parts[0]?['text']?.toString() ?? '';
          }
        }
      }
      return '';
    }

    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = choices[0]?['message'];
      if (message is Map) {
        final content = message['content']?.toString();
        if (content != null && content.isNotEmpty) {
          return content;
        }
        // 推理模型（如 DeepSeek-R1、SenseNova）可能把答案放在 reasoning 中
        // 当 max_tokens 不够时 content 可能为空，回退到 reasoning
        final reasoning = message['reasoning']?.toString();
        if (reasoning != null && reasoning.isNotEmpty) {
          return reasoning;
        }
        final reasoningContent = message['reasoning_content']?.toString();
        if (reasoningContent != null && reasoningContent.isNotEmpty) {
          return reasoningContent;
        }
        return '';
      }
    }
    return '';
  }

  /// 从响应数据中提取 finish_reason，用于检测 max_tokens 截断
  String? _extractFinishReason(dynamic data) {
    if (data is! Map<String, dynamic>) return null;
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      return choices[0]?['finish_reason']?.toString();
    }
    return null;
  }

  dynamic _parseJsonFromAiContent(String content) {
    final stripped = _stripMarkdownCodeBlock(content);
    try {
      return jsonDecode(stripped);
    } catch (e) {
      // 当标准解析失败时，记录警告并尝试使用正则/括号定位提取 JSON 子字符串进行二次解析
      LoggerService.instance.logAI(
        'AI响应标准JSON解析失败，尝试提取JSON子串。原始内容:\n$content',
        level: LogLevel.warning,
      );
      try {
        final extracted = _extractJsonString(content);
        if (extracted != null) {
          return jsonDecode(extracted);
        }
      } catch (innerError) {
        LoggerService.instance.logAI(
          '提取JSON子串并解析依然失败: $innerError',
          level: LogLevel.error,
        );
      }
      rethrow;
    }
  }

  /// 从含中文推理文本中提取 JSON 子串。
  ///
  /// 推理模型（SenseNova/DeepSeek-R1）的 reasoning 字段混有中文思考文本和 JSON，
  /// 简单括号匹配会被中文文本中的 `{` `}` 干扰。本方法按优先级尝试：
  /// 1. 提取 ```json ... ``` 包裹的代码块
  /// 2. 提取普通的 ``` ... ``` 代码块
  /// 3. 按 JSON 结构标记（{"results":  / {"tags": / [{"id":）定位并做括号配对
  /// 4. 兜底：简单首 `{` 尾 `}` 匹配
  String? _extractJsonString(String text) {
    // 1. 优先尝试提取 ```json ... ``` 包裹的块
    final jsonBlockReg = RegExp(r'```json\s*([\s\S]*?)\s*```');
    var match = jsonBlockReg.firstMatch(text);
    if (match != null) {
      return match.group(1)!.trim();
    }

    // 2. 尝试提取普通的 ``` ... ``` 块
    final codeBlockReg = RegExp(r'```\s*([\s\S]*?)\s*```');
    match = codeBlockReg.firstMatch(text);
    if (match != null) {
      return match.group(1)!.trim();
    }

    // 3. 按 JSON 结构标记定位真正的 JSON 起始位置，做括号配对
    //    推理模型的 reasoning 中常有 `{"results":[{"id":...}]}` 这样的输出
    final candidate = _findJsonByStructureMarkers(text);
    if (candidate != null) return candidate;

    // 4. 兜底：简单首 { 尾 } 匹配
    final firstBrace = text.indexOf('{');
    final firstBracket = text.indexOf('[');
    final lastBrace = text.lastIndexOf('}');
    final lastBracket = text.lastIndexOf(']');

    int start = -1;
    int end = -1;

    if (firstBrace != -1 && firstBracket != -1) {
      if (firstBrace < firstBracket) {
        start = firstBrace;
        end = lastBrace;
      } else {
        start = firstBracket;
        end = lastBracket;
      }
    } else if (firstBrace != -1) {
      start = firstBrace;
      end = lastBrace;
    } else if (firstBracket != -1) {
      start = firstBracket;
      end = lastBracket;
    }

    if (start != -1 && end != -1 && end > start) {
      return text.substring(start, end + 1);
    }

    return null;
  }

  /// 通过 JSON 结构标记（如 `{"results":`、`[{"id":`）定位起始位置，
  /// 然后做括号配对提取完整 JSON 子串。
  ///
  /// 这能避免中文推理文本中 `type(select:...)` 等非 JSON 括号的干扰。
  String? _findJsonByStructureMarkers(String text) {
    // 常见的 JSON 输出开头模式
    final markerPatterns = [
      RegExp(r'\{"results"\s*:\s*\[', multiLine: true),
      RegExp(r'\{"tags"\s*:\s*\[', multiLine: true),
      RegExp(r'\{"message"\s*:', multiLine: true),
      RegExp(r'\[{"id"\s*:', multiLine: true),
    ];

    int? bestStart;
    for (final pattern in markerPatterns) {
      final m = pattern.firstMatch(text);
      if (m != null) {
        final pos = m.start;
        if (bestStart == null || pos < bestStart) {
          bestStart = pos;
        }
      }
    }

    if (bestStart == null) return null;

    // 从 bestStart 开始做括号配对
    final firstChar = text[bestStart];
    final openChar = firstChar;
    final closeChar = firstChar == '{' ? '}' : ']';

    int depth = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = bestStart; i < text.length; i++) {
      final ch = text[i];

      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;

      if (ch == openChar) {
        depth++;
      } else if (ch == closeChar) {
        depth--;
        if (depth == 0) {
          return text.substring(bestStart, i + 1);
        }
      }
    }

    // 配对失败（可能是截断的），尝试返回从头到尾的内容
    if (depth > 0 && text.length > bestStart + 1) {
      return text.substring(bestStart);
    }

    return null;
  }

  String _stripMarkdownCodeBlock(String content) {
    final trimmed = content.trim();
    final codeBlockRegex = RegExp(
      r'^```(?:json)?\s*\n?([\s\S]*?)\n?\s*```$',
      multiLine: false,
    );
    final match = codeBlockRegex.firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return trimmed;
  }

  dynamic _sanitizeRequestBodyForLogging(dynamic body) {
    // release 模式跳过深拷贝（含 base64 图片时尤其耗时），只记录占位符
    if (!kDebugMode) return '<release_mode_skipped>';
    try {
      if (body is String) {
        final decoded = jsonDecode(body);
        return _sanitizeMapOrList(decoded);
      }
      return _sanitizeMapOrList(body);
    } catch (_) {
      return body;
    }
  }

  dynamic _sanitizeMapOrList(dynamic val) {
    if (val is Map) {
      final newMap = <String, dynamic>{};
      for (final key in val.keys) {
        final kStr = key.toString();
        final value = val[key];
        if (kStr == 'data' && value is String && _isLikelyBase64Image(value)) {
          newMap[kStr] = '<IMAGE_DATA: ${_estimateImageSize(value)}>';
        } else if (kStr == 'image_url' &&
            value is Map &&
            value['url'] is String &&
            (value['url'] as String).startsWith('data:')) {
          final url = value['url'] as String;
          final mime = _extractMimeTypeFromDataUrl(url);
          newMap[kStr] = {'url': 'data:$mime;<BASE64_IMAGE_DATA>'};
        } else if (kStr == 'input_image' && value is Map) {
          newMap[kStr] = {
            'type': value['type'] ?? 'base64',
            'data': '<IMAGE_BASE64_DATA>',
          };
        } else if (kStr == 'inline_data' &&
            value is Map &&
            value['data'] is String &&
            _isLikelyBase64Image(value['data'])) {
          newMap[kStr] = {
            'mime_type': value['mime_type'] ?? 'image/...',
            'data': '<INLINE_IMAGE_DATA>',
          };
        } else {
          newMap[kStr] = _sanitizeMapOrList(value);
        }
      }
      return newMap;
    } else if (val is List) {
      return val.map((item) => _sanitizeMapOrList(item)).toList();
    } else if (val is String && _isLikelyBase64Image(val)) {
      return '<BASE64_IMAGE_STRING: ${_estimateImageSize(val)}>';
    }
    return val;
  }

  bool _isLikelyBase64Image(String str) {
    if (str.length < 500) return false;
    final trimmed = str.trim();
    if (trimmed.startsWith('data:image/')) return true;
    if (trimmed.startsWith('/') && trimmed.length > 1000) return true;
    if (trimmed.length > 2000 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed)) {
      return true;
    }
    if (trimmed.length > 5000 &&
        !trimmed.contains('\n') &&
        !trimmed.contains('\r') &&
        !trimmed.contains('\t')) {
      return true;
    }
    return false;
  }

  String _estimateImageSize(String base64) {
    try {
      final kb = (base64.length * 3 / 4 / 1024);
      if (kb >= 1024) {
        return '${(kb / 1024).toStringAsFixed(1)}MB';
      }
      return '${kb.toStringAsFixed(1)}KB';
    } catch (_) {
      return 'unknown';
    }
  }

  String _extractMimeTypeFromDataUrl(String dataUrl) {
    final match = RegExp(r'data:([^;]+)').firstMatch(dataUrl);
    return match?.group(1) ?? 'image/...';
  }

  String _formatJsonForLogging(dynamic data) {
    try {
      if (data is String) {
        final decoded = jsonDecode(data);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      }
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  Future<DailyScore> analyzeDailyScore({
    required List<DiaryRecord> records,
    required DateTime date,
    String? userInfo,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    if (records.length < 3) {
      throw ArgumentError('当日记录过少，暂无法评分');
    }

    final recordsStr = StringBuffer();
    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      recordsStr.writeln('记录 ${i + 1}:');
      recordsStr.writeln('- 时间: ${r.time.toIso8601String()}');
      if (r.displayTag.isNotEmpty) {
        recordsStr.writeln('- 分类: ${r.displayTag}');
      }
      if (r.tags.isNotEmpty) {
        recordsStr.writeln('- 标签: ${r.tags.join(', ')}');
      }
      if (r.content.isNotEmpty) {
        recordsStr.writeln('- 内容: ${r.content}');
      }
      if (r.bodyState != null && r.bodyState!.isNotEmpty) {
        recordsStr.writeln('- 身体状态: ${jsonEncode(r.bodyState)}');
      }
      recordsStr.writeln();
    }

    final systemPrompt = defaultSystemPrompts['daily_score_system'] ?? '';
    final userPrompt = '请根据上述规则和以下数据进行评分与分析。\n\n[当日记录]\n${recordsStr.toString()}\n\n[用户信息]\n${userInfo ?? "无"}';

    dynamic requestBody;
    final String endpoint = _generateContentEndpoint;

    if (_config!.provider == 'gemini') {
      requestBody = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': userPrompt},
            ],
          },
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
          'responseMimeType': 'application/json',
        },
      };
    } else {
      final isOmni = _config!.modelName.toLowerCase().contains('omni');
      final formattedMessages = [
        if (isOmni) ...[
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userPrompt},
            ],
          },
        ] else ...[
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      ];

      final bodyMap = _buildBaseBody(
        messages: formattedMessages,
        responseFormat: {'type': 'json_object'},
      );

      if (isOmni) {
        bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch.toString();
        bodyMap['output_modalities'] = ['text'];
      }

      requestBody = bodyMap;
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI评分分析请求 [${_config!.provider}] [${_config!.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    final response = await _dio.post(endpoint, data: requestBody);
    final responseContent = _extractTextFromResponse(response.data);
    LoggerService.instance.logAI(
      'AI评分分析响应:\n${_formatJsonForLogging(response.data)}',
    );

    final jsonResult = _parseJsonFromAiContent(responseContent) as Map<String, dynamic>;

    final canScore = jsonResult['canScore'] ?? true;
    if (!canScore) {
      throw Exception('AI判定当日信息过少，暂无法评分');
    }

    final totalScore = (jsonResult['totalScore'] as num?)?.toInt() ?? 60;
    final rawDimensionScores = jsonResult['dimensionScores'] as Map? ?? {};
    final dimensionScores = rawDimensionScores.map(
      (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 60),
    );

    return DailyScore(
      id: const Uuid().v4(),
      date: date,
      totalScore: totalScore,
      dimensionScores: dimensionScores,
      summary: jsonResult['summary']?.toString() ?? '',
      suggestions: jsonResult['suggestions']?.toString() ?? '',
      recordCount: records.length,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Future<bool> checkImageRecognition(AiConfig config, String imageBase64) async {
    updateConfig(config, temperature: 0.1, maxTokens: 50);

    dynamic requestBody;
    String endpoint = _generateContentEndpoint;

    if (config.provider == 'gemini') {
      requestBody = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': '请问这张图片里写了什么数字？直接回答数字即可，不要有其他解释。'},
              {
                'inline_data': {'mime_type': 'image/png', 'data': imageBase64},
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.1,
          'maxOutputTokens': 200,
        },
      };
      endpoint = 'v1beta/models/${config.modelName}:generateContent';
    } else {
      final isOmni = config.modelName.toLowerCase().contains('omni');
      List<dynamic> contentList;
      if (isOmni) {
        contentList = [
          {'type': 'text', 'text': '请问这张图片里写了数字多少？直接回答数字即可，不要有其他解释。'},
          {
            'type': 'input_image',
            'input_image': {
              'type': 'base64',
              'data': [imageBase64],
            },
          },
        ];
      } else {
        contentList = [
          {'type': 'text', 'text': '请问这张图片里写了数字多少？直接回答数字即可，不要有其他解释。'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$imageBase64'},
          },
        ];
      }

      requestBody = _buildBaseBody(
        messages: [
          {
            'role': 'user',
            'content': contentList,
          },
        ],
      );
      requestBody['temperature'] = 0.1;
      requestBody['max_tokens'] = 200;
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      '图片识别测试请求 [${config.provider}] [${config.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    final response = await _dio.post(endpoint, data: requestBody);
    final data = response.data;
    LoggerService.instance.logAI('图片识别测试响应:\n${_formatJsonForLogging(data)}');

    final String result = _extractTextFromResponse(data);
    LoggerService.instance.logAI('大模型图片识别测试结果: $result');

    final cleanResult = result.trim().replaceAll(' ', '');
    return cleanResult.contains('11') || cleanResult.contains('十一');
  }
}

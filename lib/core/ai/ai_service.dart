import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
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

  AiConfig? get config => _config;

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

    _config = config;
    if (temperature != null) _temperature = temperature;
    if (maxTokens != null) _maxTokens = maxTokens;
    _dio.options.baseUrl = cleanedBaseUrl.endsWith('/')
        ? cleanedBaseUrl
        : '$cleanedBaseUrl/';

    _dio.options.headers['Content-Type'] = 'application/json';
    if (config.provider == 'gemini') {
      _dio.options.headers['x-goog-api-key'] = config.apiKey;
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer ${config.apiKey}';
      _dio.options.headers.remove('x-goog-api-key');
    }

    LoggerService.instance.logAI(
      '更新AI配置: 提供商=${config.provider}, 模型=${config.modelName}',
      details:
          '原始URL=${config.baseUrl}, 清理后URL=$cleanedBaseUrl, endpoint=$_generateContentEndpoint',
    );
  }

  String _cleanUrl(String url) {
    return url
        .trim()
        .replaceAll(RegExp(r'[,\s]+$'), '') // 去除末尾逗号和空格
        .replaceAll(RegExp(r'/+$'), ''); // 去除末尾多余斜杠
  }

  Future<String> chat(List<ChatMessage> messages) async {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始同步对话请求',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}',
    );

    try {
      dynamic requestBody;
      String endpoint = _chatEndpoint;

      if (_config!.provider == 'gemini') {
        String? systemInstruction;
        final List<Map<String, dynamic>> contents = [];

        for (final m in messages) {
          if (m.role == 'system') {
            systemInstruction = m.content;
          } else {
            final role = m.role == 'user' ? 'user' : 'model';
            contents.add({
              'role': role,
              'parts': [
                {'text': m.content},
              ],
            });
          }
        }

        requestBody = {
          'contents': contents,
          'generationConfig': {
            'temperature': _temperature,
            'maxOutputTokens': _maxTokens,
          },
        };
        if (systemInstruction != null) {
          requestBody['systemInstruction'] = {
            'parts': [
              {'text': systemInstruction},
            ],
          };
        }
        endpoint = '/v1beta/models/${_config!.modelName}:generateContent';
      } else {
        final isOmni = _config!.modelName.toLowerCase().contains('omni');
        final formattedMessages = messages.map((m) {
          if (isOmni) {
            return {
              'role': m.role,
              'content': [
                {'type': 'text', 'text': m.content},
              ],
            };
          } else {
            return {'role': m.role, 'content': m.content};
          }
        }).toList();

        final bodyMap = <String, dynamic>{
          'model': _config!.modelName,
          'messages': formattedMessages,
          'temperature': _temperature,
          'max_tokens': _maxTokens,
        };

        if (isOmni) {
          bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch
              .toString();
          bodyMap['output_modalities'] = ['text'];
        }

        requestBody = bodyMap;
      }

      final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
      LoggerService.instance.logAI(
        'AI请求 [${_config!.provider}] [${_config!.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
      );

      final response = await _dio.post(endpoint, data: requestBody);

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      final data = response.data;
      LoggerService.instance.logAI('AI响应:\n${_formatJsonForLogging(data)}');
      String result;

      if (_config!.provider == 'gemini') {
        result =
            data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
      } else {
        result = data['choices']?[0]?['message']?['content'] ?? '';
      }

      LoggerService.instance.logAI(
        '同步对话完成',
        details: '耗时=${duration}ms, 响应长度=${result.length}字符',
      );

      return result;
    } catch (e, stackTrace) {
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

  Stream<String> chatStream(List<ChatMessage> messages) async* {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始流式对话请求',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}',
    );

    dynamic requestBody;
    if (_config!.provider == 'gemini') {
      String? systemInstruction;
      final List<Map<String, dynamic>> contents = [];

      for (final m in messages) {
        if (m.role == 'system') {
          systemInstruction = m.content;
        } else {
          final role = m.role == 'user' ? 'user' : 'model';
          contents.add({
            'role': role,
            'parts': [
              {'text': m.content},
            ],
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
      requestBody = jsonEncode(bodyMap);
    } else {
      final isOmni = _config!.modelName.toLowerCase().contains('omni');
      final formattedMessages = messages.map((m) {
        if (isOmni) {
          return {
            'role': m.role,
            'content': [
              {'type': 'text', 'text': m.content},
            ],
          };
        } else {
          return {'role': m.role, 'content': m.content};
        }
      }).toList();

      final bodyMap = <String, dynamic>{
        'model': _config!.modelName,
        'messages': formattedMessages,
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'stream': true,
      };

      if (isOmni) {
        bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch.toString();
        bodyMap['output_modalities'] = ['text'];
      }

      requestBody = jsonEncode(bodyMap);
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI流式请求 [${_config!.provider}] [${_config!.modelName}] $_chatEndpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    try {
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
              'AI流式响应完成 [总输出=$totalChars字符]:\n$accumulatedResponse',
            );
            return;
          }

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            String? text;
            if (_config!.provider == 'gemini') {
              text = json['candidates']?[0]?['content']?['parts']?[0]?['text'];
            } else {
              text = json['choices']?[0]?['delta']?['content'];
            }
            if (text != null) {
              totalChars += text.length;
              accumulatedResponse.write(text);
              yield text;
            }
          } catch (_) {}
        }
      }

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      LoggerService.instance.logAI(
        'AI流式响应结束 [总输出=$totalChars字符]:\n$accumulatedResponse',
      );
    } catch (e, stackTrace) {
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

        final bodyMap = <String, dynamic>{
          'model': _config!.modelName,
          'messages': formattedMessages,
          'temperature': _temperature,
          'max_tokens': _maxTokens,
          'response_format': {'type': 'json_object'},
        };

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

    try {
      final response = await _dio.post(
        _generateContentEndpoint,
        data: requestBody,
        cancelToken: cancelToken,
      );
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
      LoggerService.instance.logAI(
        '统一提取失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      rethrow;
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

    return {
      'model': _config!.modelName,
      'messages': [
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
      'temperature': _temperature,
      'max_tokens': _maxTokens,
    };
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

    return {
      'model': _config!.modelName,
      'messages': [
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
      'temperature': _temperature,
      'max_tokens': _maxTokens,
      'response_format': {'type': 'json_object'},
    };
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

    // 3. 通过定位最外层的 { } 或 [ ] 提取 JSON 子串
    final firstBrace = text.indexOf('{');
    final firstBracket = text.indexOf('[');
    final lastBrace = text.lastIndexOf('}');
    final lastBracket = text.lastIndexOf(']');

    int start = -1;
    int end = -1;

    if (firstBrace != -1 && firstBracket != -1) {
      // 哪个括号最先出现，就以哪个作为最外层边界
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
    if (trimmed.length > 2000 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed))
      return true;
    if (trimmed.length > 5000 &&
        !trimmed.contains('\n') &&
        !trimmed.contains('\r') &&
        !trimmed.contains('\t'))
      return true;
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
    String endpoint = _generateContentEndpoint;

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

      final bodyMap = <String, dynamic>{
        'model': _config!.modelName,
        'messages': formattedMessages,
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'response_format': {'type': 'json_object'},
      };

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

      requestBody = {
        'model': config.modelName,
        'messages': [
          {
            'role': 'user',
            'content': contentList,
          },
        ],
        'temperature': 0.1,
        'max_tokens': 200,
      };
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      '图片识别测试请求 [${config.provider}] [${config.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    final response = await _dio.post(endpoint, data: requestBody);
    final data = response.data;
    LoggerService.instance.logAI('图片识别测试响应:\n${_formatJsonForLogging(data)}');

    String result = _extractTextFromResponse(data);
    LoggerService.instance.logAI('大模型图片识别测试结果: $result');

    final cleanResult = result.trim().replaceAll(' ', '');
    return cleanResult.contains('11') || cleanResult.contains('十一');
  }
}

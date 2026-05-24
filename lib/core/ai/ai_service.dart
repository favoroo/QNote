import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';

class NoUsefulInfoException implements Exception {}

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
        .replaceAll('{{inputType}}', inputType)
        .replaceAll('{{contextStr}}', contextStr ?? '')
        .replaceAll('{{schema}}', schema)
        .replaceAll('{{text}}', text ?? '');

    dynamic requestBody;

    if (hasImage) {
      requestBody = _buildMultimodalRequestBody(
        systemPrompt: systemPrompt,
        imageBase64: imageBase64,
        mimeType: mimeType ?? 'image/jpeg',
      );
    } else {
      if (_config!.provider == 'gemini') {
        requestBody = {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': text ?? ''},
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
                {'type': 'text', 'text': text ?? ''},
              ],
            },
          ] else ...[
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': text ?? ''},
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
          throw NoUsefulInfoException();
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

  Map<String, dynamic> _buildMultimodalRequestBody({
    required String systemPrompt,
    required String imageBase64,
    required String mimeType,
  }) {
    if (_config!.provider == 'gemini') {
      return {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': systemPrompt},
              {
                'inline_data': {'mime_type': mimeType, 'data': imageBase64},
              },
            ],
          },
        ],
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
    if (_config!.provider == 'gemini') {
      return data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
    }
    return data['choices']?[0]?['message']?['content'] ?? '';
  }

  dynamic _parseJsonFromAiContent(String content) {
    final stripped = _stripMarkdownCodeBlock(content);
    return jsonDecode(stripped);
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
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';

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
    _dio.options.baseUrl = cleanedBaseUrl;
    
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
                {'text': m.content}
              ]
            });
          }
        }

        requestBody = {
          'contents': contents,
          'generationConfig': {
            'temperature': _temperature,
            'maxOutputTokens': _maxTokens,
          }
        };
        if (systemInstruction != null) {
          requestBody['systemInstruction'] = {
            'parts': [
              {'text': systemInstruction}
            ]
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
                {'type': 'text', 'text': m.content}
              ],
            };
          } else {
            return {
              'role': m.role,
              'content': m.content,
            };
          }
        }).toList();

        final bodyMap = <String, dynamic>{
          'model': _config!.modelName,
          'messages': formattedMessages,
          'temperature': _temperature,
          'max_tokens': _maxTokens,
        };

        if (isOmni) {
          bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch.toString();
          bodyMap['output_modalities'] = ['text'];
        }

        requestBody = bodyMap;
      }

      final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
      LoggerService.instance.logAI(
        'AI请求 [${_config!.provider}] [${_config!.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}'
      );

      final response = await _dio.post(
        endpoint,
        data: requestBody,
      );

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      final data = response.data;
      LoggerService.instance.logAI(
        'AI响应:\n${_formatJsonForLogging(data)}'
      );
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
        debugPrint('=== AI REQUEST ERROR DIAGNOSTICS ===');
        debugPrint('URL: ${e.requestOptions.uri}');
        debugPrint('Headers: $reqHeaders');
        debugPrint('Payload: $reqData');
        debugPrint('Response Status: ${e.response?.statusCode}');
        debugPrint('Response Data: $respData');
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
              {'text': m.content}
            ]
          });
        }
      }

      final bodyMap = <String, dynamic>{
        'contents': contents,
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
        }
      };
      if (systemInstruction != null) {
        bodyMap['systemInstruction'] = {
          'parts': [
            {'text': systemInstruction}
          ]
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
              {'type': 'text', 'text': m.content}
            ],
          };
        } else {
          return {
            'role': m.role,
            'content': m.content,
          };
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
      'AI流式请求 [${_config!.provider}] [${_config!.modelName}] $_chatEndpoint:\n${_formatJsonForLogging(sanitizedBody)}'
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
              'AI流式响应完成 [总输出=$totalChars字符]:\n$accumulatedResponse'
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
        'AI流式响应结束 [总输出=$totalChars字符]:\n$accumulatedResponse'
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
      return '/v1beta/models/${_config!.modelName}:streamGenerateContent?alt=sse';
    }
    final baseUrl = _config!.baseUrl;
    if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/v1/')) {
      return '/chat/completions';
    }
    return '/v1/chat/completions';
  }

  String get _generateContentEndpoint {
    if (_config!.provider == 'gemini') {
      return '/v1beta/models/${_config!.modelName}:generateContent';
    }
    final baseUrl = _config!.baseUrl;
    if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/v1/')) {
      return '/chat/completions';
    }
    return '/v1/chat/completions';
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

  Future<List<Map<String, dynamic>>> extractDiaryStructure({
    required String text,
    required String schemaContext,
    String? contextStr,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    LoggerService.instance.logAI('提取日记结构化数据', details: '文本长度=${text.length}字符');

    var systemPrompt = defaultSystemPrompts['diary_extraction'] ?? '';
    systemPrompt = systemPrompt
        .replaceAll('{{text}}', text)
        .replaceAll('{{schemaContext}}', schemaContext)
        .replaceAll('{{contextStr}}', contextStr ?? '');

    dynamic requestBody;
    if (_config!.provider == 'gemini') {
      requestBody = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ]
          }
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
          'responseMimeType': 'application/json',
        }
      };
    } else {
      final isOmni = _config!.modelName.toLowerCase().contains('omni');
      final formattedMessages = [
        if (isOmni) ...[
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt}
            ]
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': text}
            ]
          }
        ] else ...[
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': text},
        ]
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
      'AI提取日记结构请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}'
    );

    try {
      final response = await _dio.post(
        _generateContentEndpoint,
        data: requestBody,
      );
      final content = _extractTextFromResponse(response.data);
      LoggerService.instance.logAI(
        'AI提取日记结构响应:\n${_formatJsonForLogging(response.data)}'
      );

      final jsonResult = jsonDecode(content);
      LoggerService.instance.logAI(
        '日记结构提取完成',
        details: '结果类型=${jsonResult is List ? "数组" : "对象"}',
      );

      if (jsonResult is List) {
        return jsonResult.cast<Map<String, dynamic>>();
      }
      return [jsonResult as Map<String, dynamic>];
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        '日记结构提取失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>> extractImageInfo({
    required String imageBase64,
    required String mimeType,
    required String prompt,
    required String schema,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    LoggerService.instance.logAI(
      '提取单张图片信息',
      details:
          '图片类型=$mimeType, 大小≈${(imageBase64.length * 3 / 4 / 1024).toStringAsFixed(1)}KB',
    );

    var systemPrompt = defaultSystemPrompts['image_extraction_base'] ?? '';
    systemPrompt = systemPrompt
        .replaceAll('{{prompt}}', prompt)
        .replaceAll('{{schema}}', schema);

    final requestBody = _buildMultimodalRequestBody(
      systemPrompt: systemPrompt,
      imageBase64: imageBase64,
      mimeType: mimeType,
    );

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI提取图片请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}'
    );

    try {
      final response = await _dio.post(
        _generateContentEndpoint,
        data: requestBody,
      );
      final content = _extractTextFromResponse(response.data);
      LoggerService.instance.logAI(
        'AI提取图片响应:\n${_formatJsonForLogging(response.data)}'
      );

      final result = jsonDecode(content) as Map<String, dynamic>;
      LoggerService.instance.logAI('单张图片信息提取完成');
      return result;
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        '单张图片信息提取失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> extractGlobalImageInfo({
    required String imageBase64,
    required String mimeType,
    required String prompt,
    required String schema,
    String? contextStr,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    LoggerService.instance.logAI(
      '提取全局图片信息',
      details: '图片类型=$mimeType, 有上下文=${contextStr != null}',
    );

    var systemPrompt = defaultSystemPrompts['global_image_extraction'] ?? '';
    systemPrompt = systemPrompt
        .replaceAll('{{prompt}}', prompt)
        .replaceAll('{{schema}}', schema)
        .replaceAll('{{contextStr}}', contextStr ?? '');

    final requestBody = _buildMultimodalRequestBody(
      systemPrompt: systemPrompt,
      imageBase64: imageBase64,
      mimeType: mimeType,
    );

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI提取全局图片请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}'
    );

    try {
      final response = await _dio.post(
        _generateContentEndpoint,
        data: requestBody,
      );
      final content = _extractTextFromResponse(response.data);
      LoggerService.instance.logAI(
        'AI提取全局图片响应:\n${_formatJsonForLogging(response.data)}'
      );

      final jsonResult = jsonDecode(content);
      LoggerService.instance.logAI(
        '全局图片信息提取完成',
        details: '结果数量=${jsonResult is List ? jsonResult.length : 1}',
      );

      if (jsonResult is List) {
        return jsonResult.cast<Map<String, dynamic>>();
      }
      return [jsonResult as Map<String, dynamic>];
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        '全局图片信息提取失败: $e',
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
              {'type': 'text', 'text': systemPrompt}
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'input_image',
                'input_image': {
                  'type': 'base64',
                  'data': [imageBase64]
                }
              }
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
        if (kStr == 'data' && value is String && value.length > 200) {
          newMap[kStr] = '<IMAGE_BASE64_DATA_OMITTED>';
        } else if (kStr == 'image_url' && value is Map && value['url'] is String && (value['url'] as String).startsWith('data:')) {
          newMap[kStr] = {'url': 'data:image/...;<BASE64_OMITTED>'};
        } else if (kStr == 'input_image' && value is Map && value['input_image'] is Map && value['input_image']['data'] is List) {
          newMap[kStr] = {
            'type': 'base64',
            'data': ['<IMAGE_BASE64_DATA_OMITTED>']
          };
        } else {
          newMap[kStr] = _sanitizeMapOrList(value);
        }
      }
      return newMap;
    } else if (val is List) {
      return val.map((item) => _sanitizeMapOrList(item)).toList();
    }
    return val;
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

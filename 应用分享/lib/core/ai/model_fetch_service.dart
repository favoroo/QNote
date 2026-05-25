import 'package:dio/dio.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';

class ModelFetchService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  /// 获取指定厂商的模型列表
  Future<List<String>> fetchModels({
    required String vendorId,
    required String baseUrl,
    required String? apiKey,
    required String authType,
    required String modelsEndpoint,
  }) async {
    // 1. 检查 API Key 鉴权要求
    if (authType != 'none' && (apiKey == null || apiKey.trim().isEmpty)) {
      throw ArgumentError('请先填写 API Key');
    }

    // 2. 规范化 baseUrl 和 endpoint 路径
    String cleanedBaseUrl = baseUrl.trim().replaceAll(RegExp(r'[,\s]+$'), '').replaceAll(RegExp(r'/+$'), '');
    
    // 如果是 Gemini 并且 baseUrl 为空，使用官方 API 端点
    if (vendorId == 'gemini' && cleanedBaseUrl.isEmpty) {
      cleanedBaseUrl = 'https://generativelanguage.googleapis.com';
    }

    String path = modelsEndpoint.trim();
    if (path.isNotEmpty && !path.startsWith('/')) {
      path = '/$path';
    }

    // 3. 构建 URL、Headers 和 Query parameters
    String requestUrl = '$cleanedBaseUrl$path';
    final Map<String, dynamic> headers = {
      'Accept': 'application/json',
    };
    final Map<String, dynamic> queryParameters = {};

    // OpenRouter 免费模型获取的特殊接口处理
    if (vendorId == 'openrouter') {
      requestUrl = 'https://openrouter.ai/api/frontend/models/find?active=true&fmt=cards&q=free';
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      headers['Referer'] = 'https://openrouter.ai/';
    } else {
      if (authType == 'bearer' && apiKey != null) {
        headers['Authorization'] = 'Bearer ${apiKey.trim()}';
      } else if (authType == 'query' && apiKey != null) {
        queryParameters['key'] = apiKey.trim();
      }
    }

    LoggerService.instance.logAI(
      '开始获取厂商模型列表: vendorId=$vendorId',
      details: 'URL=$requestUrl, authType=$authType',
    );

    try {
      // 4. 执行 HTTP GET 请求
      final response = await _dio.get(
        requestUrl,
        options: Options(headers: headers),
        queryParameters: queryParameters,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        List<String> fetchedModels;
        if (vendorId == 'openrouter') {
          fetchedModels = _parseOpenRouterFreeModels(data);
        } else if (vendorId == 'gemini') {
          fetchedModels = _parseGeminiFormat(data);
        } else if (vendorId == 'zhipu') {
          fetchedModels = _parseGlmFormat(data);
        } else {
          fetchedModels = _parseOpenAiFormat(data);
        }

        LoggerService.instance.logAI(
          '获取厂商模型列表成功: vendorId=$vendorId',
          details: '获取到 ${fetchedModels.length} 个模型: $fetchedModels',
        );

        return fetchedModels;
      } else {
        throw Exception('HTTP 错误: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      String details = stackTrace.toString();
      if (e is DioException) {
        final respData = e.response?.data;
        if (respData != null) {
          details = 'Response Body: $respData\n\n$details';
        }
      }
      LoggerService.instance.logAI(
        '获取厂商模型列表失败: vendorId=$vendorId, 错误=$e',
        level: LogLevel.error,
        details: details,
      );
      rethrow;
    }
  }

  /// 解析 OpenRouter 免费格式的响应 (保留原有逻辑)
  List<String> _parseOpenRouterFreeModels(dynamic data) {
    if (data is Map && data['data'] != null) {
      final nestedData = data['data'];
      final modelsList = nestedData['models'];
      final Map<String, dynamic> analytics = nestedData['analytics'] is Map ? nestedData['analytics'] : {};

      if (modelsList is List) {
        final List<Map<String, dynamic>> parsedModels = [];
        for (final item in modelsList) {
          if (item is Map) {
            final endpoint = item['endpoint'];
            if (endpoint is Map && endpoint['is_free'] == true) {
              final slug = endpoint['model_variant_slug'];
              final permaslug = endpoint['model_variant_permaslug'];
              if (slug is String && slug.isNotEmpty) {
                int usage = 0;
                
                int getUsage(String key) {
                  final cleanKey = key.replaceAll(':free', '');
                  if (analytics[cleanKey] != null) {
                    final a = analytics[cleanKey];
                    if (a is Map) {
                      return ((a['total_prompt_tokens'] ?? 0) as num).toInt() + ((a['total_completion_tokens'] ?? 0) as num).toInt();
                    }
                  }
                  if (analytics[key] != null) {
                    final a = analytics[key];
                    if (a is Map) {
                      return ((a['total_prompt_tokens'] ?? 0) as num).toInt() + ((a['total_completion_tokens'] ?? 0) as num).toInt();
                    }
                  }
                  return 0;
                }

                usage = getUsage(permaslug ?? slug);
                if (usage == 0) usage = getUsage(slug);

                parsedModels.add({
                  'slug': slug,
                  'usage': usage,
                });
              }
            }
          }
        }

        parsedModels.sort((a, b) => (b['usage'] as int).compareTo(a['usage'] as int));
        return parsedModels.map((m) => m['slug'] as String).toList();
      }
    }
    throw Exception('OpenRouter 响应数据结构无效');
  }

  /// 解析 OpenAI 兼容格式的响应
  List<String> _parseOpenAiFormat(dynamic data) {
    if (data is Map && data['data'] is List) {
      final List<String> fetchedModels = [];
      for (final item in data['data']) {
        if (item is Map && item['id'] is String) {
          fetchedModels.add(item['id'] as String);
        }
      }
      fetchedModels.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return fetchedModels;
    }
    throw Exception('返回数据格式无效 (非 OpenAI 兼容格式)');
  }

  /// 解析 Gemini 格式的响应
  List<String> _parseGeminiFormat(dynamic data) {
    if (data is Map && data['models'] is List) {
      final List<String> fetchedModels = [];
      for (final item in data['models']) {
        if (item is Map && item['name'] is String) {
          String name = item['name'] as String;
          if (name.startsWith('models/')) {
            name = name.substring('models/'.length);
          }
          fetchedModels.add(name);
        }
      }
      fetchedModels.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return fetchedModels;
    }
    throw Exception('返回数据格式无效 (非 Gemini 格式)');
  }

  /// 解析 GLM (智谱) 格式的响应
  List<String> _parseGlmFormat(dynamic data) {
    // 智谱 v4 models 也是类似 OpenAI 的 data 数组结构
    return _parseOpenAiFormat(data);
  }
}

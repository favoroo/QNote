import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';

/// 网页搜索工具：让小Q 能通过 Bing 检索公开网页，返回标题、链接与摘要列表
///
/// 与 fetch_url 组成"搜索 → 深读"链路：本工具负责发现链接与摘要，
/// 读取具体正文交给 fetch_url。v1 采用 Bing 结果页免费抓取（无需 API Key），
/// 解析逻辑收敛在 [parseBingResults] / [detectEmptyState] 静态纯函数中，
/// 便于单测；后续接入 Tavily / 博查等 Key 版 API 时只需在 execute 中增加引擎分支。
class WebSearchTool extends AgentTool {
  /// 单次请求默认返回条数
  static const int _defaultMaxResults = 5;

  /// 单次请求允许的最大条数（防止模型刷屏与结果页超长）
  static const int _maxResultsLimit = 10;

  /// 单条摘要的最大字符数，控制回传给模型的体积
  static const int _snippetMaxLength = 200;

  /// 伪装桌面 Chrome，降低被搜索引擎反爬拦截的概率
  static const String _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 15);

  /// Web 端公共 CORS 只读代理（与 fetch_url 同款方案），绕过浏览器同源限制
  static const String _webProxyPrefix = 'https://api.allorigins.win/raw?url=';

  @override
  String get name => 'web_search';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '通过 Bing 搜索引擎联网检索公开网页，返回标题、链接与摘要列表（不含正文）。'
      '适用于时效性问题（新闻、天气、价格、版本、赛事等）或需要核实可能过时的事实；'
      '用户已给出具体网址时应改用 fetch_url 直接读取；'
      '需要深入了解某条结果的完整正文时，再对相应链接调用 fetch_url。'
      '本工具不搜索用户的笔记与待办（请用 grep / read_file），也不支持站内关键词全文检索。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '搜索关键词。建议包含时间限定词（如"2026"）或具体实体名，'
                '过长的问题应提炼为关键词组合，而非整句照搬。',
          },
          'max_results': {
            'type': 'integer',
            'description': '期望返回的结果条数，默认 5，最大 10。',
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    // 参数解析与校验：query 必填非空；max_results 兼容 int/num/string 并收敛到合法区间
    final query = (arguments['query']?.toString() ?? '').trim();
    if (query.isEmpty) {
      return ToolResult.error('query 不能为空，请提供要搜索的关键词');
    }
    final maxResults = _parseMaxResults(arguments['max_results']);

    onProgress?.call('正在联网搜索：$query');

    final bingUrl = 'https://www.bing.com/search'
        '?q=${Uri.encodeQueryComponent(query)}'
        '&count=$maxResults&mkt=zh-CN&setlang=zh-CN';
    // Web 端浏览器存在同源限制，必须经公共代理转发；原生端直连（国内会自动重定向到 cn.bing.com）
    final requestUrl = kIsWeb ? '$_webProxyPrefix${Uri.encodeComponent(bingUrl)}' : bingUrl;

    try {
      final dio = Dio()
        ..options.connectTimeout = _connectTimeout
        ..options.receiveTimeout = _receiveTimeout
        ..options.headers = {
          'User-Agent': _userAgent,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        };
      final response = await dio.get<List<int>>(
        requestUrl,
        options: Options(responseType: ResponseType.bytes, followRedirects: true),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        return ToolResult.error('搜索服务返回了空响应，请如实告知用户本轮无法联网搜索');
      }

      final document =
          html_parser.parse(_decodeBytes(bytes, response.headers.value('content-type')));
      final results = parseBingResults(document, limit: maxResults);
      if (results.isEmpty) {
        // 区分"真的没有结果"与"页面被拦截/结构变化"，给模型不同的应对提示
        switch (detectEmptyState(document)) {
          case _emptyNoResults:
            return ToolResult.success(
              '未通过 Bing 搜索到与「$query」相关的结果。'
              '建议更换或精简关键词、补充时间限定词后重试；'
              '若无进展请如实告知用户，不要编造搜索结果。',
              uiDetails: {'type': 'web_search', 'query': query, 'engine': 'bing', 'results': []},
            );
          case _emptyBlocked:
            return ToolResult.error('搜索请求被 Bing 反爬拦截，本轮无法联网搜索，'
                '请如实告知用户暂时搜不到，严禁编造结果');
          default:
            return ToolResult.error('Bing 结果页解析失败（页面结构可能已变化），'
                '本轮无法联网搜索，请如实告知用户，严禁编造结果');
        }
      }

      onProgress?.call('搜索完成，共 ${results.length} 条结果');
      return ToolResult.success(
        formatResults(query, results),
        uiDetails: {
          'type': 'web_search',
          'query': query,
          'engine': 'bing',
          'results': results,
        },
      );
    } on DioException catch (e) {
      return ToolResult.error(
          '${_describeDioError(e)}；请如实告知用户本轮无法联网搜索，严禁编造结果');
    } catch (e) {
      return ToolResult.error('搜索执行失败：$e；请如实告知用户本轮无法联网搜索，严禁编造结果');
    }
  }

  /// 解析 max_results 参数：兼容 int / num / string，缺省 5，收敛到 [1, 10]
  int _parseMaxResults(dynamic raw) {
    int? value;
    if (raw is int) {
      value = raw;
    } else if (raw is num) {
      value = raw.round();
    } else if (raw is String) {
      value = int.tryParse(raw);
    }
    if (value == null) return _defaultMaxResults;
    if (value < 1) return 1;
    if (value > _maxResultsLimit) return _maxResultsLimit;
    return value;
  }

  /// 解析 Bing 搜索结果页，提取 [limit] 条 {title, url, snippet}
  ///
  /// 纯静态函数便于单测。结果节点为 `li.b_algo`，标题取 `h2 > a`，
  /// 摘要优先 `b_caption p`、兜底首个 `p`；Bing 跳转链接（/ck/a）会被还原为真实地址。
  static List<Map<String, String>> parseBingResults(Document document, {int limit = 10}) {
    final items = document.querySelectorAll('li.b_algo');
    final results = <Map<String, String>>[];
    final seenUrls = <String>{};
    for (final item in items) {
      if (results.length >= limit) break;
      final anchor = item.querySelector('h2 a');
      final title = anchor?.text.trim();
      final rawHref = anchor?.attributes['href'];
      if (title == null || title.isEmpty || rawHref == null || rawHref.isEmpty) continue;

      final url = _unwrapBingRedirect(rawHref);
      if (!url.startsWith('http') || !seenUrls.add(url)) continue;

      var snippet = item.querySelector('.b_caption p')?.text ?? item.querySelector('p')?.text ?? '';
      snippet = snippet.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (snippet.length > _snippetMaxLength) {
        snippet = '${snippet.substring(0, _snippetMaxLength)}…';
      }

      results.add({'title': title, 'url': url, 'snippet': snippet});
    }
    return results;
  }

  /// 判断结果页为空的原因，用于给模型不同的应对提示
  ///
  /// 返回 `_emptyNoResults`（真的无结果）、`_emptyBlocked`（触发反爬验证）或
  /// `_emptyUnknown`（页面结构变化等未知情况，解析失效）。
  static const String _emptyNoResults = 'no_results';
  static const String _emptyBlocked = 'blocked';
  static const String _emptyUnknown = 'unknown';

  static String detectEmptyState(Document document) {
    final bodyText = document.body?.text.replaceAll(RegExp(r'\s+'), ' ') ?? '';
    // Bing 无结果页会带 b_no 提示节点或"没有找到"文案
    if (document.querySelector('li.b_no') != null ||
        bodyText.contains('没有找到') ||
        bodyText.toLowerCase().contains('no results')) {
      return _emptyNoResults;
    }
    // 人机验证 / 异常流量提示
    final lowerText = bodyText.toLowerCase();
    if (bodyText.contains('确认您是真人') ||
        bodyText.contains('异常流量') ||
        lowerText.contains('captcha') ||
        lowerText.contains('unusual traffic')) {
      return _emptyBlocked;
    }
    return _emptyUnknown;
  }

  /// 还原 Bing 跳转链接：`bing.com/ck/a?...&u=a1<base64url>` 中藏着真实地址
  static String _unwrapBingRedirect(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null) return href;
    final host = uri.host.toLowerCase();
    final isBingInternal = host.isEmpty || host.endsWith('bing.com');
    if (!isBingInternal) return href;
    final encoded = uri.queryParameters['u'];
    if (encoded == null || encoded.length <= 2) return href;
    try {
      // u 参数以 a1 前缀 + base64url 编码真实 URL，需还原 padding 后解码
      final normalized = encoded.substring(2).replaceAll('-', '+').replaceAll('_', '/');
      final decoded = utf8.decode(base64.decode(base64.normalize(normalized)), allowMalformed: true);
      if (decoded.startsWith('http')) return decoded;
    } catch (_) {
      // 解码失败则保留原跳转链接（浏览器与 fetch_url 仍可跟随跳转）
    }
    return href;
  }

  /// 把结果列表格式化为模型可读的 Markdown 编号列表（公开便于单测）
  static String formatResults(String query, List<Map<String, String>> results) {
    final buffer = StringBuffer('已通过 Bing 搜索「$query」，共 ${results.length} 条结果：\n');
    for (var i = 0; i < results.length; i++) {
      final item = results[i];
      buffer
        ..writeln()
        ..writeln('${i + 1}. [${item['title']}](${item['url']})');
      final snippet = item['snippet'];
      if (snippet != null && snippet.isNotEmpty) {
        buffer.writeln('   $snippet');
      }
    }
    buffer
      ..writeln()
      ..writeln('如需深入了解某条结果的完整正文，可调用 fetch_url 读取对应链接；引用搜索结果时请注明来源。');
    return buffer.toString();
  }

  /// 按响应头 charset 解码字节，异常时统一回退 UTF-8 宽容解码（Bing 中文页为 UTF-8）
  static String _decodeBytes(List<int> bytes, String? contentType) {
    final charset =
        RegExp(r'charset=([\w-]+)', caseSensitive: false).firstMatch(contentType ?? '')?.group(1);
    final name = charset?.toLowerCase() ?? '';
    try {
      if (name.contains('8859') || name.contains('latin')) return latin1.decode(bytes);
    } catch (_) {
      // 编码失败时回退 UTF-8
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 把 DioException 翻译成模型可读的中文提示
  static String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return '连接搜索服务超时';
      case DioExceptionType.receiveTimeout:
        return '搜索响应超时';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return code == null ? '搜索服务返回异常响应' : '搜索服务返回异常状态码 $code';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查设备网络';
      case DioExceptionType.cancel:
        return '搜索请求已取消';
      default:
        return '搜索请求失败：${e.message ?? '未知错误'}';
    }
  }
}

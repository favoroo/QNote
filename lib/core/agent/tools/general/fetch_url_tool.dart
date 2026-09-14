import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';

/// 网页正文提取结果
class FetchedPage {
  final String title;
  final String? description;

  /// 提炼后的 Markdown 正文
  final String markdown;

  const FetchedPage({
    required this.title,
    this.description,
    required this.markdown,
  });
}

/// 小Q 的网页阅读工具：抓取 URL 并把 HTML 正文提炼为 Markdown 供模型阅读
///
/// 对齐桌面端编码智能体的 WebFetch 模式：抓取 → 清洗正文 → 喂给模型。
/// - Web 平台受浏览器 CORS 限制，走公共只读代理（同 [LinkPreviewHelper] 的既有方案）；
/// - 移动端直连目标站点，无跨域问题。
class FetchUrlTool extends AgentTool {
  /// 单次返回给模型的最大正文字符数（长文用 offset 分段续读，防止冲爆上下文）
  static const int _maxChunkChars = 6000;

  /// 伪装成桌面 Chrome，减少被目标站反爬拦截的概率（同 ModelFetchService 的既有做法）
  static const String _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 与正文无关的噪音标签，提取前整体剔除
  static const List<String> _noiseTags = [
    'script', 'style', 'noscript', 'template', 'svg', 'iframe', 'canvas',
    'nav', 'aside', 'form', 'button', 'select', 'input', 'dialog', 'video', 'audio',
  ];

  @override
  String get name => 'fetch_url';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '读取一个网页（URL）的真实内容并转为 Markdown 正文，用于总结、摘录或引用。'
      '当用户发送了网址、或笔记/待办/对话中包含需要了解内容的链接时调用；'
      '长文章会分段返回，按结果末尾提示传入 offset 可继续读取。'
      '仅支持 http/https 完整链接，不支持网页搜索，无法读取需要登录的页面。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': '要读取的网页地址（完整的 http/https URL）',
          },
          'offset': {
            'type': 'integer',
            'description': '从正文的第几个字符开始读取，默认 0；上次结果提示可继续读取时传入其给出的 offset',
          },
        },
        'required': ['url'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final rawUrl = (arguments['url'] as String? ?? '').trim();
    final offsetArg = arguments['offset'] is int
        ? arguments['offset'] as int
        : int.tryParse('${arguments['offset']}') ?? 0;

    final uri = Uri.tryParse(rawUrl);
    if (rawUrl.isEmpty ||
        uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return ToolResult.error('URL 格式无效，请提供完整的 http/https 链接：$rawUrl');
    }

    onProgress?.call('正在读取网页：$rawUrl');

    final String bodyText;
    final String contentType;
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          followRedirects: true,
          headers: {
            'User-Agent': _browserUserAgent,
            'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        ),
      );
      // Web 平台受浏览器同源策略限制，走公共只读代理；其他平台直连
      final targetUrl =
          kIsWeb ? 'https://api.allorigins.win/raw?url=${Uri.encodeComponent(rawUrl)}' : rawUrl;
      final response = await dio.get<List<int>>(
        targetUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        return ToolResult.error('网页返回了空内容，可能链接失效：$rawUrl');
      }
      contentType = (response.headers.value(Headers.contentTypeHeader) ?? '').toLowerCase();
      bodyText = _decodeBytes(bytes, contentType);
    } on DioException catch (e) {
      return ToolResult.error(_describeDioError(e, rawUrl));
    } catch (e) {
      return ToolResult.error('网页读取失败：$e（$rawUrl）');
    }

    FetchedPage page;
    if (_looksLikeHtml(contentType, bodyText)) {
      page = extractReadableContent(bodyText, uri);
    } else {
      // 纯文本 / JSON 等非 HTML 响应直接返回原文
      page = FetchedPage(title: uri.host, markdown: bodyText.trim());
    }

    final total = page.markdown.length;
    final details = <String, dynamic>{
      'type': 'fetch_url',
      'url': rawUrl,
      'title': page.title,
      'total': total,
    };

    final header = StringBuffer()
      ..writeln('网页读取成功。')
      ..writeln('标题：${page.title.isEmpty ? uri.host : page.title}')
      ..writeln('来源：$rawUrl');
    if (page.description != null && page.description!.isNotEmpty) {
      header.writeln('摘要：${page.description}');
    }

    if (total == 0) {
      // 静态 HTML 提取为空，大概率是 JS 渲染的 SPA 页面，走服务端无头渲染兜底
      final rendered = await _fetchRenderedPage(rawUrl);
      if (rendered == null || rendered.isEmpty) {
        return ToolResult.success(
          '$header\n正文为空（页面由 JavaScript 动态渲染，且渲染兜底服务不可用，无法提取内容）。',
          uiDetails: details,
        );
      }
      page = FetchedPage(
        title: page.title,
        description: page.description,
        markdown: rendered,
      );
    }

    final totalLength = page.markdown.length;
    details['total'] = totalLength;
    if (totalLength == 0) {
      return ToolResult.success(
        '$header\n正文为空（页面可能完全由 JavaScript 动态渲染，无法静态提取内容）。',
        uiDetails: details,
      );
    }

    header
      ..writeln('正文（Markdown）：')
      ..writeln();

    final start = offsetArg.clamp(0, totalLength);
    final end = (start + _maxChunkChars).clamp(start, totalLength);
    final chunk = page.markdown.substring(start, end);
    details['chars'] = end - start;

    String footer = '';
    if (end < totalLength) {
      footer =
          '\n\n[正文仅展示第 $start~$end 字符，全文共 $totalLength 字符。如需继续阅读，请再次调用本工具并传 offset: $end]';
    } else if (start > 0) {
      footer = '\n\n[已读到正文末尾，全文共 $totalLength 字符]';
    }

    return ToolResult.success(
      '$header$chunk$footer',
      uiDetails: details,
    );
  }

  /// 把 HTML 解析为「标题 + meta 摘要 + Markdown 正文」，纯静态函数便于单测
  static FetchedPage extractReadableContent(String html, Uri baseUri) {
    final document = parse(html);
    for (final tag in _noiseTags) {
      document.querySelectorAll(tag).forEach((element) => element.remove());
    }

    final title = (document.querySelector('title')?.text ?? '').trim();
    final description = (document.querySelector('meta[name="description"]')?.attributes['content'] ??
                document.querySelector('meta[property="og:description"]')?.attributes['content'])
            ?.trim() ??
        '';

    // 正文容器选择：article 语义最优，其次 main，兜底 body
    final root = document.querySelector('article') ??
        document.querySelector('[role="main"]') ??
        document.querySelector('main') ??
        document.body ??
        document.documentElement;

    var markdown = root == null ? '' : _renderBlocks(root, baseUri);
    markdown = markdown.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

    return FetchedPage(
      title: title,
      description: description.isEmpty ? null : description,
      markdown: markdown,
    );
  }

  /// 块级元素递归渲染为 Markdown
  static String _renderBlocks(Element element, Uri baseUri) {
    final buf = StringBuffer();
    for (final child in element.children) {
      switch (child.localName) {
        case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
          final level = int.parse(child.localName!.substring(1));
          final text = _inlineText(child, baseUri);
          if (text.isNotEmpty) buf.writeln('\n${'#' * level} $text\n');
        case 'p' || 'dd' || 'figcaption' || 'caption' || 'legend' || 'label' || 'summary':
          final text = _inlineText(child, baseUri);
          if (text.isNotEmpty) buf.writeln('\n$text\n');
        case 'pre':
          final code = child.text.replaceFirst(RegExp(r'^\n'), '').replaceFirst(RegExp(r'\s+$'), '');
          if (code.isNotEmpty) buf.writeln('\n```\n$code\n```\n');
        case 'blockquote':
          final inner = _renderBlocks(child, baseUri).trim();
          // 纯文本引用没有块级子节点，回退到行内文本提取
          final text = inner.isEmpty ? _inlineText(child, baseUri) : inner;
          if (text.isNotEmpty) {
            buf.writeln('\n${text.split('\n').map((line) => '> $line').join('\n')}\n');
          }
        case 'ul' || 'ol':
          final list = StringBuffer();
          _renderList(child, 0, baseUri, list);
          if (list.isNotEmpty) buf.writeln('\n$list');
        case 'table':
          final rows = child.querySelectorAll('tr');
          if (rows.isNotEmpty) {
            buf.writeln();
            for (final tr in rows) {
              final cells = tr.children
                  .where((c) => c.localName == 'td' || c.localName == 'th')
                  .map((c) => c.text.trim().replaceAll(RegExp(r'\s+'), ' '))
                  .where((c) => c.isNotEmpty)
                  .toList();
              if (cells.isNotEmpty) buf.writeln('| ${cells.join(' | ')} |');
            }
            buf.writeln();
          }
        case 'hr':
          buf.writeln('\n---\n');
        case 'article' || 'section' || 'main' || 'div' || 'span' || 'body' || 'html' || 'figure':
          buf.write(_renderBlocks(child, baseUri));
        default:
          // 其余未知标签：有子元素继续递归，否则按 inline 文本输出
          if (child.children.isEmpty) {
            final text = _inlineText(child, baseUri);
            if (text.isNotEmpty) buf.writeln('\n$text\n');
          } else {
            buf.write(_renderBlocks(child, baseUri));
          }
      }
    }
    return buf.toString();
  }

  /// 列表渲染，支持有序/无序与嵌套缩进
  static void _renderList(Element list, int indent, Uri baseUri, StringBuffer buf) {
    final ordered = list.localName == 'ol';
    var index = 1;
    for (final li in list.children.where((c) => c.localName == 'li')) {
      final prefix = ordered ? '${index++}. ' : '- ';
      buf.writeln('${'  ' * indent}$prefix${_liText(li, baseUri)}');
      for (final sub in li.children) {
        if (sub.localName == 'ul' || sub.localName == 'ol') {
          _renderList(sub, indent + 1, baseUri, buf);
        }
      }
    }
  }

  /// 单个 li 的行内内容（跳过嵌套列表，嵌套由 _renderList 递归处理）
  static String _liText(Element li, Uri baseUri) {
    final buf = StringBuffer();
    for (final node in li.nodes) {
      if (node is Element && (node.localName == 'ul' || node.localName == 'ol')) continue;
      if (node is Text) {
        buf.write(node.text);
      } else if (node is Element) {
        _renderInline(node, baseUri, buf);
      }
    }
    return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 行内内容拍平为文本，保留链接/加粗/斜体/行内代码语义
  static String _inlineText(Element element, Uri baseUri) {
    final buf = StringBuffer();
    for (final node in element.nodes) {
      if (node is Text) {
        buf.write(node.text);
      } else if (node is Element) {
        _renderInline(node, baseUri, buf);
      }
    }
    return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static void _renderInline(Element element, Uri baseUri, StringBuffer buf) {
    switch (element.localName) {
      case 'br':
        buf.write('\n');
      case 'a':
        final text = element.text.trim();
        final href = element.attributes['href'];
        if (text.isEmpty) return;
        if (href == null ||
            href.isEmpty ||
            href.startsWith('#') ||
            href.startsWith('javascript:') ||
            href.startsWith('mailto:')) {
          buf.write(text);
          return;
        }
        // 相对地址基于当前页面解析为绝对地址，便于模型引用
        final resolved = baseUri.resolve(href).toString();
        buf.write('[$text]($resolved)');
      case 'strong' || 'b':
        final text = element.text.trim();
        if (text.isNotEmpty) buf.write('**$text**');
      case 'em' || 'i':
        final text = element.text.trim();
        if (text.isNotEmpty) buf.write('*$text*');
      case 'code' || 'kbd' || 'samp':
        final text = element.text.trim();
        if (text.isNotEmpty) buf.write('`$text`');
      case 'img' || 'picture' || 'source':
        // 图片对总结无贡献，忽略以节省 token
        return;
      default:
        for (final node in element.nodes) {
          if (node is Text) {
            buf.write(node.text);
          } else if (node is Element) {
            _renderInline(node, baseUri, buf);
          }
        }
    }
  }

  /// 按响应头 charset 解码字节，中文页面常见 utf-8/gbk；失败依次 utf8 → latin1 兜底
  static String _decodeBytes(List<int> bytes, String contentType) {
    final charsetMatch = RegExp(r'charset=([\w-]+)').firstMatch(contentType);
    if (charsetMatch != null) {
      final encoding = Encoding.getByName(charsetMatch.group(1)!.toLowerCase());
      if (encoding != null) {
        try {
          return encoding.decode(bytes);
        } catch (_) {
          // 声明的 charset 与实际不符，落入下方通用解码
        }
      }
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  /// 判断响应是否为 HTML：优先信任 Content-Type，缺失时嗅探正文头部
  static bool _looksLikeHtml(String contentType, String body) {
    if (contentType.contains('text/html') || contentType.contains('xhtml')) return true;
    if (contentType.contains('json') ||
        contentType.contains('text/plain') ||
        contentType.contains('text/css') ||
        contentType.contains('javascript')) {
      return false;
    }
    final head = body.length > 2000 ? body.substring(0, 2000) : body;
    return RegExp(r'<\s*(!doctype|html|head|body|div|p)\b', caseSensitive: false).hasMatch(head);
  }

  /// 服务端无头渲染兜底：静态抓取拿不到正文（JS 渲染的 SPA）时，
  /// 借助 r.jina.ai 在服务端执行页面脚本并返回 Markdown（免费只读，有速率限制）。
  /// 失败返回 null，由调用方回退为"无法提取"提示。
  static Future<String?> _fetchRenderedPage(String url) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          // 服务端渲染比静态抓取慢，给足超时
          receiveTimeout: const Duration(seconds: 30),
          // 注意：jina 前面的 Cloudflare 会放行 Dart 默认 UA、却拦截伪装的 Chrome UA（403 挑战页），此处保持默认
        ),
      );
      const readerPrefix = 'https://r.jina.ai/';
      // Web 平台仍套公共 CORS 代理，与主链路保持同一模式
      final targetUrl = kIsWeb
          ? 'https://api.allorigins.win/raw?url=${Uri.encodeComponent('$readerPrefix$url')}'
          : '$readerPrefix$url';
      final response = await dio.get<String>(
        targetUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final text = response.data;
      if (text == null || text.trim().isEmpty) return null;
      return _stripJinaHeader(text);
    } catch (_) {
      return null;
    }
  }

  /// 剥离 jina reader 返回文本的元信息头（Title/URL Source/Markdown Content:）
  static String _stripJinaHeader(String text) {
    const marker = 'Markdown Content:';
    final markerIndex = text.indexOf(marker);
    if (markerIndex >= 0) return text.substring(markerIndex + marker.length).trim();
    return text.trim();
  }

  /// 把 Dio 异常翻译成模型可读的中文提示
  static String _describeDioError(DioException e, String url) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '读取网页超时，站点可能响应缓慢或不可达：$url';
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode;
        return '网页返回异常状态码 ${status ?? "未知"}，链接可能已失效或拒绝访问：$url';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络或该链接是否可达：$url';
      case DioExceptionType.cancel:
        return '本次网页读取已被用户停止';
      default:
        return '网页读取失败：${e.message ?? e.type.name}（$url）';
    }
  }
}

import 'dart:convert';

import 'package:qnote_flutter/core/agent/services/q_text_quote.dart';

/// 网页预览选择探针回传的原始 payload。
///
/// 由注入到 HTML 预览里的脚本采集：文字选区或长按选中的元素，
/// 以及它的 CSS 选择器、outerHTML、渲染文本与视口位置。
class HtmlSelectionPayload {
  /// 是否为「长按选中的元素」（false 表示文字选区）
  final bool isElement;

  /// 渲染后 DOM 的 CSS 路径
  final String selector;

  /// 标签名（小写）
  final String tagName;

  /// 元素 id
  final String? elementId;

  /// class 列表
  final List<String> classNames;

  /// 选中文字 / 元素文本摘录
  final String? text;

  /// 渲染后 DOM 序列化的 outerHTML
  final String? outerHtml;

  /// 父级路径
  final String? ancestors;

  /// 视口坐标与尺寸
  final QWebRect? rect;

  /// 采集时视口尺寸（x/y 恒为 0）
  final QWebRect? viewport;

  /// 页面地址
  final String? url;

  /// 页面标题
  final String? pageTitle;

  /// 探针注入时生成的随机会话 token（Web 端用于过滤其他 iframe 的消息）
  final String token;

  const HtmlSelectionPayload({
    required this.isElement,
    required this.selector,
    required this.tagName,
    this.elementId,
    this.classNames = const [],
    this.text,
    this.outerHtml,
    this.ancestors,
    this.rect,
    this.viewport,
    this.url,
    this.pageTitle,
    this.token = '',
  });

  /// 简短的元素标识（如 `section#today.card`），用于引用卡片与提示
  String get shortLabel {
    final buffer = StringBuffer(tagName.isEmpty ? '元素' : tagName);
    final id = elementId;
    if (id != null && id.isNotEmpty) {
      buffer.write('#$id');
    }
    for (final name in classNames.take(2)) {
      if (name.isNotEmpty) {
        buffer.write('.$name');
      }
    }
    return buffer.toString();
  }

  /// 解析探针回传的 JSON 字符串；格式不合法或信息过少时返回 null。
  ///
  /// 容错策略：脚本/页面异常可能缺字段，只要还能拿到标签、选择器或文本
  /// 之一就保留引用，避免一次脏数据让整个「给小Q」入口失效。
  static HtmlSelectionPayload? tryParse(String raw) {
    if (raw.trim().isEmpty) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final tagName = (decoded['tag'] ?? '').toString().toLowerCase();
    final selector = (decoded['selector'] ?? '').toString();
    final text = _nonEmpty(decoded['text']);
    final outerHtml = _nonEmpty(decoded['html']);
    if (tagName.isEmpty && selector.isEmpty && text == null && outerHtml == null) {
      return null;
    }

    final classes = <String>[];
    final rawClasses = decoded['classes'];
    if (rawClasses is List) {
      for (final item in rawClasses) {
        final name = item?.toString().trim();
        if (name != null && name.isNotEmpty) {
          classes.add(name);
        }
      }
    }

    return HtmlSelectionPayload(
      isElement: (decoded['kind'] ?? '').toString() == 'element',
      selector: selector,
      tagName: tagName,
      elementId: _nonEmpty(decoded['id']),
      classNames: classes,
      text: text,
      outerHtml: outerHtml,
      ancestors: _nonEmpty(decoded['ancestors']),
      rect: _parseRect(decoded['rect'], widthKey: 'w', heightKey: 'h'),
      viewport: _parseViewport(decoded['viewport']),
      url: _nonEmpty(decoded['url']),
      pageTitle: _nonEmpty(decoded['pageTitle']),
      token: (decoded['token'] ?? '').toString(),
    );
  }
}

/// 源码中的一个候选位置
class HtmlSourceMatch {
  /// 1 基行号
  final int line;

  /// 匹配到的开标签摘录（压缩空白、限长）
  final String snippet;

  const HtmlSourceMatch({required this.line, required this.snippet});
}

/// 元素在 HTML 源码中的候选位置集合
class HtmlSourceHints {
  /// 按标签/id/class 匹配到的开标签候选（优先 id，其次 class，最后退回标签）
  final List<HtmlSourceMatch> openTags;

  /// 选中文字在源码中出现的候选行号
  final List<int> textLines;

  const HtmlSourceHints({this.openTags = const [], this.textLines = const []});
}

/// 在 HTML 源码中查找元素的开标签候选行与选中文字的候选行。
///
/// 只做启发式匹配（不解析完整 DOM，也不处理脚本动态生成的节点），
/// 目的只是给小Q一个「先看哪几行」的线索；最终的定位与替换必须以
/// `read_file` 的实际内容为准。
HtmlSourceHints locateHtmlElementInSource(
  String source, {
  required String tagName,
  String? elementId,
  List<String> classNames = const [],
  String? text,
}) {
  final masked = _maskNonMarkup(source);
  final openTags = <HtmlSourceMatch>[];

  final tag = tagName.trim().toLowerCase();
  if (tag.isNotEmpty && RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(tag)) {
    final matches = _matchOpenTags(masked, tag, elementId: elementId, classNames: classNames);
    for (final match in matches.take(5)) {
      openTags.add(HtmlSourceMatch(line: _lineNumberAt(masked, match.start), snippet: match.snippet));
    }
  }

  return HtmlSourceHints(openTags: openTags, textLines: _locateTextLines(masked, text));
}

/// 把网页预览选择结果组装成「给小Q」引用。
///
/// [sourceHtml] 是当前笔记的 HTML 源码，用于补充源码行号候选；
/// 渲染后的 DOM 与源码可能存在格式差异，因此这些行号只作为定位线索。
QTextQuote buildHtmlSelectionQuote({
  required HtmlSelectionPayload payload,
  required String noteId,
  required String noteTitle,
  required String sourceHtml,
}) {
  final hints = locateHtmlElementInSource(
    sourceHtml,
    tagName: payload.tagName,
    elementId: payload.elementId,
    classNames: payload.classNames,
    text: payload.text,
  );

  final renderedText = payload.text?.trim();
  final outerHtml = payload.outerHtml?.trim();
  final quotedText = (renderedText != null && renderedText.isNotEmpty)
      ? _clip(renderedText, 2000)
      : (outerHtml != null && outerHtml.isNotEmpty)
      ? _clip(outerHtml, 2000)
      : payload.shortLabel;

  return QTextQuote(
    source: QQuoteSource.note,
    sourceId: noteId,
    sourceTitle: noteTitle,
    quotedText: quotedText,
    locationDesc: _buildLocationDesc(payload, hints),
    webElement: QWebElementRef(
      selector: payload.selector.isEmpty ? payload.tagName : payload.selector,
      tagName: payload.tagName,
      elementId: payload.elementId,
      classNames: payload.classNames,
      outerHtml: outerHtml == null || outerHtml.isEmpty ? null : _clip(outerHtml, 6000),
      renderedText: renderedText == null || renderedText.isEmpty ? null : _clip(renderedText, 3000),
      ancestors: payload.ancestors,
      rect: payload.rect,
      viewport: payload.viewport,
      url: payload.url,
      sourceLines: hints.openTags.map((m) => m.line).toList(),
      textLines: hints.textLines,
    ),
  );
}

String _buildLocationDesc(HtmlSelectionPayload payload, HtmlSourceHints hints) {
  // 行号放在前面：引用卡片标题只有一行，行号比元素描述更容易被优先看到
  final target = payload.isElement ? payload.shortLabel : '选中文字（${payload.shortLabel}）';
  final lines = hints.openTags.map((m) => m.line).toList();
  final lineDesc = switch (lines) {
    [] when hints.textLines.isEmpty => null,
    [] => '第 ${hints.textLines.first} 行（按文本匹配）',
    [final single] => '第 $single 行',
    _ => '第 ${lines.take(3).join('/')} 行候选',
  };
  return ['网页预览', ?lineDesc, target].join(' · ');
}

/// 匹配开标签：优先 id 精确匹配，其次要求全部 class 命中，再退回首个 class，
/// 最后才按标签名兜底；一旦某一级有结果就停止，避免把整页同名标签都列出来。
List<_OpenTagMatch> _matchOpenTags(String masked, String tag, {String? elementId, required List<String> classNames}) {
  final pattern = RegExp('<$tag\\b[^>]*>', caseSensitive: false, multiLine: true);
  final all = <_OpenTagMatch>[];
  for (final match in pattern.allMatches(masked)) {
    final raw = match.group(0) ?? '';
    all.add(
      _OpenTagMatch(
        start: match.start,
        id: _attribute(raw, 'id'),
        classes: _classesOf(raw),
        snippet: _clip(raw.replaceAll(RegExp(r'\s+'), ' ').trim(), 180),
      ),
    );
  }
  if (all.isEmpty) {
    return const [];
  }

  final id = elementId?.trim();
  if (id != null && id.isNotEmpty) {
    final exact = all.where((m) => m.id == id).toList();
    if (exact.isNotEmpty) {
      return exact;
    }
  }

  final wanted = classNames.where((name) => name.trim().isNotEmpty).toList();
  if (wanted.isNotEmpty) {
    final allMatched = all.where((m) => wanted.every(m.classes.contains)).toList();
    if (allMatched.isNotEmpty) {
      return allMatched;
    }
    for (final name in wanted) {
      final matched = all.where((m) => m.classes.contains(name)).toList();
      if (matched.isNotEmpty) {
        return matched;
      }
    }
  }

  return all;
}

/// 查找选中文字在源码中的候选行（只取前 40 个字符作为锚点，压缩空白）。
List<int> _locateTextLines(String masked, String? text) {
  final normalized = text?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized == null || normalized.length < 2) {
    return const [];
  }
  final anchor = normalized.length > 40 ? normalized.substring(0, 40) : normalized;
  final pattern = RegExp(RegExp.escape(anchor), caseSensitive: false);
  final lines = <int>[];
  for (final match in pattern.allMatches(masked)) {
    final line = _lineNumberAt(masked, match.start);
    if (!lines.contains(line)) {
      lines.add(line);
    }
    if (lines.length >= 3) {
      break;
    }
  }
  return lines;
}

/// 把 script/style 内容与 HTML 注释替换为等长空白（保留换行），
/// 避免脚本字符串里的 `<div>` 被当成真实标签，同时不改变行号。
String _maskNonMarkup(String source) {
  var masked = source;
  masked = _maskRegion(masked, RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false));
  masked = _maskRegion(masked, RegExp(r'<style\b[^>]*>[\s\S]*?</style\s*>', caseSensitive: false));
  masked = _maskRegion(masked, RegExp(r'<!--[\s\S]*?-->'));
  return masked;
}

String _maskRegion(String input, RegExp pattern) {
  return input.replaceAllMapped(pattern, (match) {
    final raw = match.group(0) ?? '';
    return raw.replaceAll(RegExp(r'[^\n]'), ' ');
  });
}

int _lineNumberAt(String source, int offset) {
  var count = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A) {
      count++;
    }
  }
  return count;
}

String? _attribute(String tagText, String name) {
  final pattern = RegExp('\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', caseSensitive: false);
  final match = pattern.firstMatch(tagText);
  if (match == null) {
    return null;
  }
  return match.group(1) ?? match.group(2) ?? match.group(3);
}

Set<String> _classesOf(String tagText) {
  final raw = _attribute(tagText, 'class');
  if (raw == null || raw.trim().isEmpty) {
    return const {};
  }
  return raw.split(RegExp(r'\s+')).where((name) => name.isNotEmpty).toSet();
}

QWebRect? _parseRect(Object? raw, {required String widthKey, required String heightKey}) {
  if (raw is! Map) {
    return null;
  }
  final x = (raw['x'] as num?)?.toDouble() ?? 0;
  final y = (raw['y'] as num?)?.toDouble() ?? 0;
  final width = (raw[widthKey] as num?)?.toDouble();
  final height = (raw[heightKey] as num?)?.toDouble();
  if (width == null || height == null) {
    return null;
  }
  return QWebRect(x: x, y: y, width: width, height: height);
}

QWebRect? _parseViewport(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final width = (raw['w'] as num?)?.toDouble();
  final height = (raw['h'] as num?)?.toDouble();
  if (width == null || height == null) {
    return null;
  }
  return QWebRect(x: 0, y: 0, width: width, height: height);
}

String? _nonEmpty(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String _clip(String text, int maxLength) {
  if (text.length <= maxLength) {
    return text;
  }
  return '${text.substring(0, maxLength)}…（已截断）';
}

class _OpenTagMatch {
  final int start;
  final String? id;
  final Set<String> classes;
  final String snippet;

  const _OpenTagMatch({required this.start, required this.id, required this.classes, required this.snippet});
}

import 'package:html/dom.dart';
import 'package:html/parser.dart' show parseFragment;

/// HTML → Markdown 通用渲染器
///
/// 供 `fetch_url` 的网页正文提炼与技能市场安装（skills.sh 详情页正文）共用，
/// 避免两处各维护一套容易漂移的标签处理逻辑。
/// 只保留对模型阅读有价值的块级结构（标题 / 段落 / 列表 / 引用 / 代码 / 表格），
/// 图片与脚本等噪音直接丢弃。
abstract final class HtmlMarkdown {
  /// 与正文无关的噪音标签，渲染前整体剔除
  static const List<String> noiseTags = [
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'iframe',
    'canvas',
    'nav',
    'aside',
    'form',
    'button',
    'select',
    'input',
    'dialog',
    'video',
    'audio',
  ];

  /// 渲染一个 HTML 片段（可含多个顶层节点），返回规整后的 Markdown
  static String fromHtmlFragment(String html) {
    final fragment = parseFragment(html);
    final container = Element.tag('div');
    // 移到临时容器后再统一剔除噪音标签，保证与整页提取走同一套过滤规则
    for (final node in fragment.nodes.toList()) {
      container.append(node);
    }
    for (final tag in noiseTags) {
      container.querySelectorAll(tag).forEach((element) => element.remove());
    }
    final markdown = _renderBlocks(container, null);
    return markdown.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 渲染一个已有元素的子节点，[baseUri] 用于把相对链接解析成绝对地址
  ///
  /// 返回值不做空白规整，调用方按自己的需要处理（fetch_url 会在整页提取后统一收尾）。
  static String renderElement(Element element, Uri? baseUri) => _renderBlocks(element, baseUri);

  /// 块级元素递归渲染为 Markdown
  static String _renderBlocks(Element element, Uri? baseUri) {
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
  static void _renderList(Element list, int indent, Uri? baseUri, StringBuffer buf) {
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

  /// 单个 li 的行内内容（跳过嵌套列表，嵌套由 [_renderList] 递归处理）
  static String _liText(Element li, Uri? baseUri) {
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
  static String _inlineText(Element element, Uri? baseUri) {
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

  static void _renderInline(Element element, Uri? baseUri, StringBuffer buf) {
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
        final resolved = baseUri == null ? href : baseUri.resolve(href).toString();
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
}

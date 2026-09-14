import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/web_search_tool.dart';

void main() {
  /// 构造标准 Bing 结果节点：标题链接 + 可选摘要 + 可选跳转链接
  String bingItemHtml({
    required String title,
    required String href,
    String? caption,
    bool useRedirectHref = false,
  }) {
    final realHref = useRedirectHref
        // 模拟 Bing /ck/a 跳转：u 参数 = 'a1' + base64url(真实地址)
        ? 'https://www.bing.com/ck/a?!&p=1&u=a1${base64UrlEncode(href.codeUnits)}&ntb=1'
        : href;
    final captionHtml =
        caption == null ? '' : '<div class="b_caption"><p>$caption</p></div>';
    return '<li class="b_algo"><h2><a href="$realHref">$title</a></h2>'
        '$captionHtml<p>兜底摘要段落</p></li>';
  }

  group('WebSearchTool.parseBingResults', () {
    test('解析标准结果页：标题、链接、摘要齐全', () {
      final html = '<html><body><ol id="b_results">'
          '${bingItemHtml(title: 'Flutter 官网', href: 'https://flutter.dev', caption: 'Flutter 是 UI 框架')}'
          '${bingItemHtml(title: 'Dart 语言', href: 'https://dart.dev')}'
          '</ol></body></html>';
      final results = WebSearchTool.parseBingResults(html_parser.parse(html));

      expect(results.length, 2);
      expect(results[0]['title'], 'Flutter 官网');
      expect(results[0]['url'], 'https://flutter.dev');
      expect(results[0]['snippet'], 'Flutter 是 UI 框架');
      // 无 b_caption 时回退取首个 p
      expect(results[1]['snippet'], '兜底摘要段落');
    });

    test('Bing 跳转链接被还原为真实地址', () {
      final html = '<html><body><ol id="b_results">'
          '${bingItemHtml(title: '真实地址', href: 'https://example.com/article', useRedirectHref: true)}'
          '</ol></body></html>';
      final results = WebSearchTool.parseBingResults(html_parser.parse(html));

      expect(results.single['url'], 'https://example.com/article');
    });

    test('默认条数内重复链接被去重，limit 限制返回条数', () {
      final html = '<html><body><ol id="b_results">'
          '${List.generate(5, (i) => bingItemHtml(title: '结果$i', href: 'https://example.com/$i')).join()}'
          // 与第 0 条重复的链接应被过滤
          '${bingItemHtml(title: '重复链接', href: 'https://example.com/0')}'
          '</ol></body></html>';
      final all = WebSearchTool.parseBingResults(html_parser.parse(html));
      expect(all.length, 5);
      expect(all.where((r) => r['url'] == 'https://example.com/0').length, 1);

      final limited =
          WebSearchTool.parseBingResults(html_parser.parse(html), limit: 3);
      expect(limited.length, 3);
    });
  });

  group('WebSearchTool.detectEmptyState', () {
    test('无结果页（b_no 节点）返回 no_results', () {
      const html = '<html><body><ol id="b_results">'
          '<li class="b_no">没有找到与 xxx 相关的结果</li></ol></body></html>';
      expect(WebSearchTool.detectEmptyState(html_parser.parse(html)), 'no_results');
    });

    test('反爬验证页返回 blocked', () {
      const html = '<html><body>请确认您是真人 to continue</body></html>';
      expect(WebSearchTool.detectEmptyState(html_parser.parse(html)), 'blocked');
    });

    test('既无结果节点也无提示文案时返回 unknown（结构变化）', () {
      const html = '<html><body><div>完全陌生的页面结构</div></body></html>';
      expect(WebSearchTool.detectEmptyState(html_parser.parse(html)), 'unknown');
    });
  });

  group('WebSearchTool.formatResults', () {
    test('输出编号 Markdown 列表并提示可用 fetch_url 深读', () {
      final output = WebSearchTool.formatResults('测试词', [
        {'title': '第一条', 'url': 'https://example.com/1', 'snippet': '摘要一'},
        {'title': '第二条', 'url': 'https://example.com/2', 'snippet': ''},
      ]);

      expect(output, contains('「测试词」'));
      expect(output, contains('1. [第一条](https://example.com/1)'));
      expect(output, contains('摘要一'));
      expect(output, contains('2. [第二条](https://example.com/2)'));
      expect(output, contains('fetch_url'));
    });
  });

  group('WebSearchTool 参数校验', () {
    test('缺少 query 时返回错误且不发起网络请求', () async {
      final result = await WebSearchTool().execute({});

      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('query 不能为空'));
    });

    test('工具声明为并行只读模式，schema 包含必填 query', () {
      final tool = WebSearchTool();

      expect(tool.name, 'web_search');
      expect(tool.executionMode, ToolExecutionMode.parallel);
      expect(tool.parametersSchema['required'], ['query']);
      expect(tool.parametersSchema['properties'], contains('max_results'));
    });
  });
}

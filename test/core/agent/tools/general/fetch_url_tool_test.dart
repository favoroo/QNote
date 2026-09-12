import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/fetch_url_tool.dart';

void main() {
  Uri baseUri(String url) => Uri.parse(url);

  group('FetchUrlTool.extractReadableContent HTML 提取', () {
    test('提取标题、meta 摘要与正文段落', () {
      const html = '''
<!DOCTYPE html>
<html>
<head>
  <title>小Q 使用指南</title>
  <meta name="description" content="这是一份测试页面摘要">
</head>
<body>
  <article>
    <h1>快速上手</h1>
    <p>这是第一段内容。</p>
    <p>这是第二段内容。</p>
  </article>
</body>
</html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com/guide'));

      expect(page.title, '小Q 使用指南');
      expect(page.description, '这是一份测试页面摘要');
      expect(page.markdown, contains('# 快速上手'));
      expect(page.markdown, contains('这是第一段内容。'));
      expect(page.markdown, contains('这是第二段内容。'));
    });

    test('剔除 script/style 与导航噪音，仅保留正文', () {
      const html = '''
<html>
<head>
  <title>干净正文</title>
  <style>body { color: red; }</style>
  <script>console.log('should be removed');</script>
</head>
<body>
  <nav><a href="/home">首页导航</a></nav>
  <main><p>真正需要保留的正文段落。</p></main>
  <footer>版权信息页脚</footer>
</body>
</html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com'));
      expect(page.markdown, contains('真正需要保留的正文段落。'));
      expect(page.markdown, isNot(contains('should be removed')));
      expect(page.markdown, isNot(contains('color: red')));
      expect(page.markdown, isNot(contains('首页导航')));
      expect(page.markdown, isNot(contains('版权信息页脚')));
    });

    test('标题层级、列表与引用转 Markdown 结构', () {
      const html = '''
<html><body><article>
  <h1>主标题</h1>
  <h2>二级标题</h2>
  <ul>
    <li>无序项一</li>
    <li>无序项二
      <ul><li>嵌套子项</li></ul>
    </li>
  </ul>
  <ol><li>有序项一</li><li>有序项二</li></ol>
  <blockquote>引用的一句话</blockquote>
</article></body></html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com/list'));
      expect(page.markdown, contains('# 主标题'));
      expect(page.markdown, contains('## 二级标题'));
      expect(page.markdown, contains('- 无序项一'));
      expect(page.markdown, contains('- 无序项二'));
      expect(page.markdown, contains('嵌套子项'));
      expect(page.markdown, contains('1. 有序项一'));
      expect(page.markdown, contains('2. 有序项二'));
      expect(page.markdown, contains('> 引用的一句话'));
    });

    test('链接转为 Markdown 并把相对地址解析为绝对地址', () {
      const html = '''
<html><body><article>
  <p>参考 <a href="/docs/api">接口文档</a> 与 <a href="https://other.com/page">外部页面</a>。</p>
  <p>锚点 <a href="#section">跳转标题</a> 保留纯文本。</p>
</article></body></html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com/posts/1'));
      expect(page.markdown, contains('[接口文档](https://example.com/docs/api)'));
      expect(page.markdown, contains('[外部页面](https://other.com/page)'));
      expect(page.markdown, isNot(contains('[跳转标题](#section)')));
      expect(page.markdown, contains('跳转标题'));
    });

    test('中文内容与 HTML 实体正常解码', () {
      const html = '''
<html><head><title>中文 &amp; 测试</title></head>
<body><article><p>中文内容，含 &quot;引号&quot; 与 &lt;标签&gt; 字符。&nbsp;空格保留。</p></article></body></html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com/cn'));
      expect(page.title, '中文 & 测试');
      expect(page.markdown, contains('"引号" 与 <标签> 字符'));
    });

    test('加粗、斜体与行内代码保留 Markdown 语义', () {
      const html = '''
<html><body><article>
  <p><strong>重点</strong>与<em>强调</em>以及<code>code_snippet</code>混排。</p>
</article></body></html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com/style'));
      expect(page.markdown, contains('**重点**'));
      expect(page.markdown, contains('*强调*'));
      expect(page.markdown, contains('`code_snippet`'));
    });

    test('pre 代码块保留换行', () {
      const html = '''
<html><body><article>
<pre>line one
line two</pre>
</article></body></html>
''';
      final page = FetchUrlTool.extractReadableContent(html, baseUri('https://example.com/code'));
      expect(page.markdown, contains('```\nline one\nline two\n```'));
    });
  });

  group('FetchUrlTool 参数校验', () {
    final tool = FetchUrlTool();

    test('工具元信息符合预期', () {
      expect(tool.name, 'fetch_url');
      expect(tool.executionMode, ToolExecutionMode.parallel);
      expect(tool.parametersSchema['required'], contains('url'));
    });

    test('空 URL 返回错误且不发起网络请求', () async {
      final result = await tool.execute({'url': ''});
      expect(result.isError, true);
      expect(result.modelOutput, contains('URL 格式无效'));
    });

    test('非 http/https 协议返回错误', () async {
      final result = await tool.execute({'url': 'ftp://example.com/file'});
      expect(result.isError, true);
      expect(result.modelOutput, contains('URL 格式无效'));
    });

    test('纯文本域名缺少协议返回错误', () async {
      final result = await tool.execute({'url': 'example.com/page'});
      expect(result.isError, true);
    });
  });
}

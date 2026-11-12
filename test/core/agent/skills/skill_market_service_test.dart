import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/skills/skill_market_service.dart';
import 'package:qnote_flutter/core/utils/html_markdown.dart';

void main() {
  group('SkillMarketService.parseSearchResponse', () {
    test('解析正常搜索结果并保留安装量', () {
      const json = '''
{"query":"pdf","count":2,"skills":[
  {"id":"anthropics/skills/pdf","source":"anthropics/skills","skillId":"pdf","name":"pdf","installs":227573},
  {"id":"openai/skills/pdf","source":"openai/skills","skillId":"pdf","name":"pdf","installs":13778}
]}
''';
      final items = SkillMarketService.parseSearchResponse(json);
      expect(items.length, 2);
      expect(items.first.id, 'anthropics/skills/pdf');
      expect(items.first.source, 'anthropics/skills');
      expect(items.first.skillId, 'pdf');
      expect(items.first.installs, 227573);
    });

    test('缺字段或结构异常时安全降级', () {
      final items = SkillMarketService.parseSearchResponse('{"skills":[{"source":"a/b","skillId":"c"}]}');
      expect(items.length, 1);
      expect(items.single.id, 'a/b/c');
      expect(items.single.name, 'c');

      expect(SkillMarketService.parseSearchResponse('{"skills":null}'), isEmpty);
      expect(() => SkillMarketService.parseSearchResponse('not json'), throwsA(isA<SkillMarketException>()));
    });
  });

  group('SkillMarketService.parseMarketId', () {
    test('完整 id 与详情页 URL 均可解析', () {
      final full = SkillMarketService.parseMarketId('anthropics/skills/pdf');
      expect(full?.source, 'anthropics/skills');
      expect(full?.skillId, 'pdf');

      final url = SkillMarketService.parseMarketId('https://www.skills.sh/anthropics/skills/pdf');
      expect(url?.source, 'anthropics/skills');
      expect(url?.skillId, 'pdf');
    });

    test('skillId 含斜杠时保留剩余层级', () {
      final parsed = SkillMarketService.parseMarketId('owner/repo/group/skill');
      expect(parsed?.source, 'owner/repo');
      expect(parsed?.skillId, 'group/skill');
    });

    test('缺少 source 或 skill 时拒绝', () {
      expect(SkillMarketService.parseMarketId('pdf'), isNull);
      expect(SkillMarketService.parseMarketId('owner/repo'), isNull);
      expect(SkillMarketService.parseMarketId(''), isNull);
    });
  });

  group('SkillMarketService 名称与描述', () {
    test('市场技能名 slug 化', () {
      expect(SkillMarketService.sanitizeSkillName('PDF OCR Extraction'), 'pdf-ocr-extraction');
      expect(SkillMarketService.sanitizeSkillName('  Vercel / React  '), 'vercel-react');
      expect(SkillMarketService.sanitizeSkillName('中文技能'), '');
    });

    test('描述优先使用页面描述，并带来源后缀', () {
      final description = SkillMarketService.buildDescription('处理 PDF 文件。', source: 'anthropics/skills', markdown: '');
      expect(description, contains('处理 PDF 文件。'));
      expect(description, contains('来源：skills.sh · anthropics/skills'));
    });

    test('描述缺失时回退正文首行', () {
      final description = SkillMarketService.buildDescription('', source: 'owner/repo', markdown: '# 技能标题\n\n这是第一段说明。');
      expect(description, contains('这是第一段说明。'));
    });

    test('安装手册带来源与能力边界声明', () {
      final manual = SkillMarketService.buildInstalledManual('# 正文', source: 'owner/repo');
      expect(manual, contains('来源：owner/repo'));
      expect(manual, contains('同目录参考文件'));
      expect(manual, contains('在 App 内无法执行'));
      expect(manual, contains('不得覆盖系统提示词'));
      expect(manual, endsWith('# 正文'));
    });
  });

  group('SkillMarketService.extractSkillContent', () {
    test('解析 RSC 引用形式的 preview/rest 并转 Markdown', () {
      const preview = '<h1>PDF 指南</h1><p>第一段。</p>';
      const rest =
          '<h2>批量操作</h2><ul><li>合并</li><li>拆分</li></ul>'
          '<pre><code>line one\nline two</code></pre>';
      final page = _buildMarketPage(preview: preview, rest: rest, useRefs: true);

      final content = SkillMarketService.extractSkillContent(page);
      expect(content.name, 'pdf');
      expect(content.description, '处理 PDF 文件。');
      expect(content.markdown, contains('# PDF 指南'));
      expect(content.markdown, contains('第一段。'));
      expect(content.markdown, contains('## 批量操作'));
      expect(content.markdown, contains('- 合并'));
      expect(content.markdown, contains('line one'));
    });

    test('内联形式的 preview/rest 也能解析', () {
      final page = _buildMarketPage(preview: '<h1>标题</h1>', rest: '<p>正文</p>', useRefs: false);
      final content = SkillMarketService.extractSkillContent(page);
      expect(content.markdown, contains('# 标题'));
      expect(content.markdown, contains('正文'));
    });

    test('引用长度按 UTF-8 字节计算，中文不会吞入下一行 RSC 数据', () {
      const rest = '<p>中文正文内容。</p>';
      final page = _buildMarketPage(
        preview: '<h1>标题</h1>',
        rest: rest,
        useRefs: true,
        trailingRsc: '39:["\$","div",null,{"children":"下一段 RSC"}]',
      );
      final content = SkillMarketService.extractSkillContent(page);
      expect(content.markdown, contains('中文正文内容。'));
      expect(content.markdown, isNot(contains('下一段 RSC')));
      expect(content.markdown, isNot(contains('39:')));
    });

    test('页面无 RSC 内容时抛出可读异常', () {
      expect(
        () => SkillMarketService.extractSkillContent('<html><body>空页面</body></html>'),
        throwsA(isA<SkillMarketException>()),
      );
    });
  });

  group('HtmlMarkdown.fromHtmlFragment', () {
    test('标题、列表、代码与表格转 Markdown', () {
      const html = '''
<h1>主标题</h1>
<p>段落 <strong>加粗</strong> 与 <code>code</code>。</p>
<ul><li>条目一</li><li>条目二</li></ul>
<pre><code>line one
line two</code></pre>
<table><tr><th>列一</th><th>列二</th></tr><tr><td>a</td><td>b</td></tr></table>
''';
      final markdown = HtmlMarkdown.fromHtmlFragment(html);
      expect(markdown, contains('# 主标题'));
      expect(markdown, contains('**加粗**'));
      expect(markdown, contains('`code`'));
      expect(markdown, contains('- 条目一'));
      expect(markdown, contains('line one\nline two'));
      expect(markdown, contains('| 列一 | 列二 |'));
    });

    test('剔除脚本与样式噪音', () {
      const html = '<p>保留</p><script>alert(1)</script><style>.x{}</style>';
      final markdown = HtmlMarkdown.fromHtmlFragment(html);
      expect(markdown, contains('保留'));
      expect(markdown, isNot(contains('alert(1)')));
      expect(markdown, isNot(contains('.x{}')));
    });
  });
}

/// 构造一个接近 skills.sh 真实结构的详情页
///
/// RSC 正文可能以 `$3d` 引用两种形式出现：直接内联字符串，或后文 `3d:T<十六进制字节数>,<内容>`。
String _buildMarketPage({
  required String preview,
  required String rest,
  required bool useRefs,
  String trailingRsc = '',
}) {
  final restBytes = utf8.encode(rest).length.toRadixString(16);
  final previewBytes = utf8.encode(preview).length.toRadixString(16);
  final rsc = useRefs
      ? '1:{"previewHtml":"\$3d","restHtml":"\$3e"}\n'
            '3d:T$previewBytes,$preview\n'
            '3e:T$restBytes,$rest$trailingRsc'
      : '1:{"previewHtml":${jsonEncode(preview)},"restHtml":${jsonEncode(rest)}}';

  final meta = jsonEncode({
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    'name': 'pdf',
    'description': '处理 PDF 文件。',
  });

  return '''
<!DOCTYPE html>
<html>
<head>
<script type="application/ld+json">$meta</script>
</head>
<body>
<script>self.__next_f.push([1,${jsonEncode(rsc)}])</script>
</body>
</html>
''';
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_path_utils.dart';

void main() {
  group('normalizeWorkspacePath', () {
    test('根路径与空串统一为 /', () {
      expect(normalizeWorkspacePath(''), '/');
      expect(normalizeWorkspacePath('   '), '/');
      expect(normalizeWorkspacePath('/'), '/');
      expect(normalizeWorkspacePath('///'), '/');
    });

    test('相对路径补前导斜杠', () {
      expect(normalizeWorkspacePath('todos'), '/todos');
      expect(normalizeWorkspacePath('notes/我的笔记.md'), '/notes/我的笔记.md');
    });

    test('合并重复斜杠', () {
      expect(normalizeWorkspacePath('//todos///今日//清单.md'), '/todos/今日/清单.md');
    });

    test('保留结尾斜杠（目录语义不被吞掉）', () {
      expect(normalizeWorkspacePath('/todos/'), '/todos/');
      expect(normalizeWorkspacePath('todos//'), '/todos/');
    });

    test('反斜杠转正斜杠', () {
      expect(normalizeWorkspacePath(r'\todos\今日\清单.md'), '/todos/今日/清单.md');
    });

    test('中文与空格：仅去首尾空白，保留路径内空格', () {
      expect(normalizeWorkspacePath('  /笔记/我的 日记.md  '), '/笔记/我的 日记.md');
    });

    test('.. 不做解析，原样保留（与历史行为一致）', () {
      expect(normalizeWorkspacePath('/todos/../notes'), '/todos/../notes');
      expect(normalizeWorkspacePath('../etc/passwd'), '/../etc/passwd');
      expect(normalizeWorkspacePath('/..'), '/..');
    });
  });

  group('日期与路径拼接', () {
    test('formatWorkspaceDate 补零到 YYYY-MM-DD', () {
      expect(formatWorkspaceDate(DateTime(2026, 9, 11)), '2026-09-11');
      expect(formatWorkspaceDate(DateTime(2026, 12, 31)), '2026-12-31');
      expect(formatWorkspaceDate(DateTime(999, 1, 2)), '0999-01-02');
    });

    test('workspaceStatsDateKey 只取日期部分', () {
      expect(workspaceStatsDateKey(DateTime(2026, 9, 11)), '2026-09-11');
      expect(workspaceStatsDateKey(DateTime(2026, 9, 11, 23, 59, 59)), '2026-09-11');
    });

    test('journalWorkspacePath 生成固定日记路径（月份日期补零）', () {
      expect(journalWorkspacePath(DateTime(2026, 9, 1)), '/journal/2026-09-01.md');
      expect(journalWorkspacePath(DateTime(999, 1, 2)), '/journal/999-01-02.md');
    });
  });

  group('parseWorkspaceStatsDate', () {
    test('解析合法日期并丢弃时间部分', () {
      expect(parseWorkspaceStatsDate('2026-09-11T10:20:30', '开始日期'), DateTime(2026, 9, 11));
      expect(parseWorkspaceStatsDate('2026-09-11', '结束日期'), DateTime(2026, 9, 11));
    });

    test('缺失与非法日期抛出带字段名的异常', () {
      expect(() => parseWorkspaceStatsDate('', '开始日期'), throwsA(predicate((e) => e.toString().contains('缺少 开始日期'))));
      expect(
        () => parseWorkspaceStatsDate('not-a-date', '结束日期'),
        throwsA(predicate((e) => e.toString().contains('结束日期 日期格式无效') && e.toString().contains('not-a-date'))),
      );
    });
  });

  group('日期序列目录展开', () {
    test('isWorkspaceDateSeriesRoot 识别四类目录并兼容结尾斜杠', () {
      expect(isWorkspaceDateSeriesRoot('/timeline'), isTrue);
      expect(isWorkspaceDateSeriesRoot('/timeline/'), isTrue);
      expect(isWorkspaceDateSeriesRoot('/journal/'), isTrue);
      expect(isWorkspaceDateSeriesRoot('/health'), isTrue);
      expect(isWorkspaceDateSeriesRoot('/stats/scores'), isTrue);
      expect(isWorkspaceDateSeriesRoot('/todos'), isFalse);
      expect(isWorkspaceDateSeriesRoot('/stats/scores/2026-09-01.json'), isFalse);
    });

    test('expandWorkspaceDateSeriesPaths 按目录生成正确后缀且含首尾', () {
      expect(expandWorkspaceDateSeriesPaths('/timeline', DateTime(2026, 9, 7), DateTime(2026, 9, 9)), [
        '/timeline/2026-09-07.md',
        '/timeline/2026-09-08.md',
        '/timeline/2026-09-09.md',
      ]);
      expect(expandWorkspaceDateSeriesPaths('/journal/', DateTime(2026, 9, 7), DateTime(2026, 9, 7)), [
        '/journal/2026-09-07.md',
      ]);
      expect(expandWorkspaceDateSeriesPaths('/health', DateTime(2026, 9, 7), DateTime(2026, 9, 8)), [
        '/health/2026-09-07.json',
        '/health/2026-09-08.json',
      ]);
      expect(expandWorkspaceDateSeriesPaths('/stats/scores', DateTime(2026, 9, 7), DateTime(2026, 9, 8)), [
        '/stats/scores/2026-09-07.json',
        '/stats/scores/2026-09-08.json',
      ]);
    });

    test('跨月展开与非法区间', () {
      final paths = expandWorkspaceDateSeriesPaths('/timeline', DateTime(2026, 1, 30), DateTime(2026, 2, 2));
      expect(paths, [
        '/timeline/2026-01-30.md',
        '/timeline/2026-01-31.md',
        '/timeline/2026-02-01.md',
        '/timeline/2026-02-02.md',
      ]);
      expect(expandWorkspaceDateSeriesPaths('/timeline', DateTime(2026, 2, 2), DateTime(2026, 1, 30)), isEmpty);
      expect(expandWorkspaceDateSeriesPaths('/todos', DateTime(2026, 1, 1), DateTime(2026, 1, 2)), isEmpty);
    });

    test('tryParseWorkspaceDate 严格校验格式与真实日历日', () {
      expect(tryParseWorkspaceDate('2026-09-11'), DateTime(2026, 9, 11));
      expect(tryParseWorkspaceDate(' 2026-09-11 '), DateTime(2026, 9, 11));
      expect(tryParseWorkspaceDate('2026-2-3'), isNull);
      expect(tryParseWorkspaceDate('2026-09-11T10:00:00'), isNull);
      // DateTime 会把 2 月 30 日顺延到 3 月，必须拦截
      expect(tryParseWorkspaceDate('2026-02-30'), isNull);
      expect(tryParseWorkspaceDate('not-a-date'), isNull);
    });
  });

  group('stripWorkspaceLineNumbers', () {
    test('剥离行首数字加制表符', () {
      expect(stripWorkspaceLineNumbers('1\t第一行\n2\t第二行'), '第一行\n第二行');
      expect(stripWorkspaceLineNumbers('12\t'), '');
    });

    test('正文自带的制表符与行内数字不误伤', () {
      const content = '正文\t带制表符\n缩进\t仍保留\n第1行\t内容';
      expect(stripWorkspaceLineNumbers(content), content);
    });

    test('只锚定行首，行中出现数字加制表符保持不变', () {
      expect(stripWorkspaceLineNumbers('前缀1\t后缀'), '前缀1\t后缀');
      expect(stripWorkspaceLineNumbers('1\tA\n\tB'), 'A\n\tB');
    });

    test('空串与纯换行保持原样', () {
      expect(stripWorkspaceLineNumbers(''), '');
      expect(stripWorkspaceLineNumbers('\n\n'), '\n\n');
    });
  });

  group('占位文案判定', () {
    test('五类空态占位文案均命中', () {
      for (final marker in kWorkspacePlaceholderMarkers) {
        expect(isWorkspacePlaceholderText('> $marker。'), isTrue, reason: marker);
      }
    });

    test('真实内容与空串不判定为占位', () {
      expect(isWorkspacePlaceholderText('- 用户喜欢深色模式'), isFalse);
      expect(isWorkspacePlaceholderText(''), isFalse);
      expect(isWorkspacePlaceholderText('暂无'), isFalse);
    });
  });

  group('路径解析', () {
    test('todoTitleFromPath 解析分类后的标题', () {
      expect(todoTitleFromPath('/todos/工作/写报告.md'), '写报告');
      expect(todoTitleFromPath('/todos/单段.md'), '单段');
      expect(todoTitleFromPath('/todos/今日/子目录/标题.md'), '子目录/标题');
      expect(todoTitleFromPath('/todos/工作/标题.markdown'), '标题.markdown');
    });

    test('todoTitleFromPath 去掉待办勾选前缀', () {
      expect(todoTitleFromPath('/todos/[ ] 待办.md'), '待办');
      expect(todoTitleFromPath('/todos/[x] 已完成.md'), '已完成');
      // 仅识别小写 x（与读取端正则一致）
      expect(todoTitleFromPath('/todos/[X] 大写.md'), '[X] 大写');
    });

    test('noteTitleFromPath 只取末段标题', () {
      expect(noteTitleFromPath('/notes/笔记本/标题.md'), '标题');
      expect(noteTitleFromPath('/notes/标题.md'), '标题');
      expect(noteTitleFromPath('/notes/带 空格.md'), '带 空格');
    });

    test('workspaceFolderNameFromPath 去掉全部斜杠', () {
      expect(workspaceFolderNameFromPath('/todos/工作/', '/todos/'), '工作');
      expect(workspaceFolderNameFromPath('/notes/技术/架构/', '/notes/'), '技术架构');
    });

    test('workspaceEntityKeyFromPath 取末段实体标识', () {
      const uuid = '123e4567-e89b-12d3-a456-426614174000';
      expect(workspaceEntityKeyFromPath('/todos/工作/$uuid.md', '/todos/'), uuid);
      expect(workspaceEntityKeyFromPath('/todos/工作/[x] 写报告.md', '/todos/'), '写报告');
      expect(workspaceEntityKeyFromPath('/notes/笔记本/标题.md', '/notes/'), '标题');
    });
  });

  group('isUuidPathSegment', () {
    test('合法 UUID（大小写均支持）', () {
      expect(isUuidPathSegment('123e4567-e89b-12d3-a456-426614174000'), isTrue);
      expect(isUuidPathSegment('123E4567-E89B-12D3-A456-426614174000'), isTrue);
    });

    test('非法形态与带后缀片段不判定为 id', () {
      expect(isUuidPathSegment('123e4567e89b12d3a456426614174000'), isFalse);
      expect(isUuidPathSegment('123e4567-e89b-12d3-a456-426614174000.md'), isFalse);
      expect(isUuidPathSegment('not-a-uuid'), isFalse);
      expect(isUuidPathSegment('未命名笔记'), isFalse);
      expect(isUuidPathSegment(''), isFalse);
    });
  });

  group('workspaceFieldValue', () {
    test('取第一个冒号之后的全部内容', () {
      expect(workspaceFieldValue('title: 带: 冒号'), '带: 冒号');
      expect(workspaceFieldValue('time: 09:30'), '09:30');
      expect(workspaceFieldValue(': 值'), '值');
    });

    test('无冒号或冒号结尾返回空串', () {
      expect(workspaceFieldValue('noColon'), '');
      expect(workspaceFieldValue('title:'), '');
    });
  });

  group('extractWorkspaceMarkdownImages', () {
    test('按出现顺序提取独立成行的图片并去重', () {
      const content = '开头\n![图1](a.png)\n中间\n![图2](b.png)\n![重复](a.png)';
      expect(extractWorkspaceMarkdownImages(content), ['a.png', 'b.png']);
    });

    test('跳过 data URI 与空路径', () {
      const content = '![内嵌](data:image/png;base64,AAAA)\n![空]()\n![正常](c.png)';
      expect(extractWorkspaceMarkdownImages(content), ['c.png']);
    });

    test('非独立成行的图片语法不匹配', () {
      expect(extractWorkspaceMarkdownImages('文字![图](a.png)文字'), isEmpty);
    });
  });

  group('formatWorkspaceDueTime', () {
    test('null 返回 null，其余补零到分钟', () {
      expect(formatWorkspaceDueTime(null), isNull);
      expect(formatWorkspaceDueTime(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
    });
  });

  group('颜色与主题转换', () {
    test('workspaceColorToHex 输出 #RRGGBB 并丢弃透明度', () {
      expect(workspaceColorToHex(const Color(0xFF005BCB)), '#005BCB');
      expect(workspaceColorToHex(const Color(0x80FF0000)), '#FF0000');
      expect(workspaceColorToHex(const Color(0xFF0000FF)), '#0000FF');
    });

    test('parseWorkspaceColor 支持 hex、别名与 int', () {
      expect(parseWorkspaceColor('#FF0000'), const Color(0xFFFF0000));
      expect(parseWorkspaceColor('0x00FF00'), const Color(0xFF00FF00));
      expect(parseWorkspaceColor('red'), const Color(0xFFF80004));
      expect(parseWorkspaceColor('经典蓝'), const Color(0xFF005BCB));
      expect(parseWorkspaceColor(0xFF00FF00), const Color(0xFF00FF00));
    });

    test('parseWorkspaceColor 无法识别时返回 null', () {
      expect(parseWorkspaceColor(null), isNull);
      expect(parseWorkspaceColor('not-a-color'), isNull);
      expect(parseWorkspaceColor(12.5), isNull);
    });

    test('parseWorkspaceThemeMode 支持中英文别名并回退 system', () {
      expect(parseWorkspaceThemeMode('dark'), ThemeMode.dark);
      expect(parseWorkspaceThemeMode('深色'), ThemeMode.dark);
      expect(parseWorkspaceThemeMode('light'), ThemeMode.light);
      expect(parseWorkspaceThemeMode('浅色'), ThemeMode.light);
      expect(parseWorkspaceThemeMode('system'), ThemeMode.system);
      expect(parseWorkspaceThemeMode('unknown'), ThemeMode.system);
      expect(parseWorkspaceThemeMode(null), ThemeMode.system);
    });

    test('workspaceThemeModeToString 三态映射', () {
      expect(workspaceThemeModeToString(ThemeMode.dark), 'dark');
      expect(workspaceThemeModeToString(ThemeMode.light), 'light');
      expect(workspaceThemeModeToString(ThemeMode.system), 'system');
    });
  });

  group('grep 辅助', () {
    test('buildWorkspaceGrepRegExp 大小写不敏感', () {
      expect(buildWorkspaceGrepRegExp('foo').hasMatch('FOO'), isTrue);
    });

    test('buildWorkspaceGrepRegExp 非法正则降级为字面量', () {
      final reg = buildWorkspaceGrepRegExp('[');
      expect(reg.hasMatch('数组 [1, 2]'), isTrue);
    });

    test('buildWorkspaceGrepSnippet 空内容返回空串', () {
      expect(buildWorkspaceGrepSnippet('   ', RegExp('x')), '');
    });

    test('buildWorkspaceGrepSnippet 无命中时原样返回（超长截断）', () {
      expect(buildWorkspaceGrepSnippet('短文本', RegExp('x')), '短文本');
      final long = 'a' * 260;
      final snippet = buildWorkspaceGrepSnippet(long, RegExp('x'));
      expect(snippet.length, kWorkspaceGrepMatchMaxLength + 1);
      expect(snippet.endsWith('…'), isTrue);
    });

    test('buildWorkspaceGrepSnippet 命中点前后截取并替换换行', () {
      final content = '${'前' * 60}\n命中\n${'后' * 80}';
      final snippet = buildWorkspaceGrepSnippet(content, RegExp('命中'));
      expect(snippet.contains('命中'), isTrue);
      expect(snippet.contains('\n'), isFalse);
      expect(snippet.startsWith('…'), isTrue);
      expect(snippet.endsWith('…'), isTrue);
    });
  });

  group('parseWorkspaceFrontmatter', () {
    test('无 frontmatter 时正文原样返回', () {
      final parsed = parseWorkspaceFrontmatter('普通正文\n第二行');
      expect(parsed.meta, isEmpty);
      expect(parsed.body, '普通正文\n第二行');
    });

    test('解析键值、引号与布尔值', () {
      const content = '---\nid: "abc-123"\ntitle: 标题\nstatus: true\npinned: false\n---\n正文内容';
      final parsed = parseWorkspaceFrontmatter(content);
      expect(parsed.meta['id'], 'abc-123');
      expect(parsed.meta['title'], '标题');
      expect(parsed.meta['status'], isTrue);
      expect(parsed.meta['pinned'], isFalse);
      expect(parsed.body, '正文内容');
    });

    test('未闭合的 frontmatter 不解析', () {
      const content = '---\nid: "abc"\n正文';
      final parsed = parseWorkspaceFrontmatter(content);
      expect(parsed.meta, isEmpty);
      expect(parsed.body, content);
    });
  });
}

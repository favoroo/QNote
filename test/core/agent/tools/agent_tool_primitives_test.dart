import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/edit_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/skill_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/write_files_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 工具层纯逻辑测试：不依赖数据库，覆盖参数校验与文本处理契约
void main() {
  group('VFS 文本原语', () {
    test('stripLineNumbers 还原读取回显里的真实文本', () {
      const echoed = '1\t---\n2\tstatus: pending\n\n4\t正文';
      expect(
        VirtualWorkspaceService.stripLineNumbers(echoed),
        '---\nstatus: pending\n\n正文',
      );
      // 不带行号的文本原样返回
      expect(VirtualWorkspaceService.stripLineNumbers('普通文本'), '普通文本');
    });

    test('isPlaceholderText 识别各类空态占位文案', () {
      expect(VirtualWorkspaceService.isPlaceholderText('> 暂无流水事件打卡。可以通过 write_file 追加事件。'), isTrue);
      expect(VirtualWorkspaceService.isPlaceholderText('> 尚未开始编写这天的深度反思日记。'), isTrue);
      expect(VirtualWorkspaceService.isPlaceholderText('> 暂无记忆条目。'), isTrue);
      expect(VirtualWorkspaceService.isPlaceholderText('- 用户喜欢深色模式'), isFalse);
    });

    test('grepScopes 覆盖全部检索分区', () {
      expect(
        VirtualWorkspaceService.grepScopes,
        containsAll(['all', 'notes', 'todos', 'timeline', 'journal', 'memory', 'settings', 'chats']),
      );
    });
  });

  group('SkillTool 按章加载', () {
    test('extractSection 支持序号、完整标题与标题关键词', () {
      final doc = SkillRegistry.instance.getSkillContent('todo-manager')!;

      final byNumber = SkillTool.extractSection(doc, '4');
      expect(byNumber, isNotNull);
      expect(byNumber, contains('四象限'));

      final byTitle = SkillTool.extractSection(doc, '5. 批量操作');
      expect(byTitle, isNotNull);
      expect(byTitle, contains('write_files'));

      final byKeyword = SkillTool.extractSection(doc, '批量');
      expect(byKeyword, isNotNull);
      expect(byKeyword, contains('批量删除'));

      // 只取到本章，不应把后续章节一并带回
      expect(byTitle, isNot(contains('四象限')));
    });

    test('章节未命中返回 null，并可用 listSectionTitles 给出菜单', () {
      final doc = SkillRegistry.instance.getSkillContent('todo-manager')!;
      expect(SkillTool.extractSection(doc, '不存在的章节'), isNull);

      final titles = SkillTool.listSectionTitles(doc);
      expect(titles.length, greaterThanOrEqualTo(3));
      expect(titles.any((t) => t.contains('批量操作')), isTrue);
    });

    test('传入 section 时只回传该章内容', () async {
      final result = await SkillTool().execute({'name': 'todo-manager', 'section': '5'});
      expect(result.modelOutput, contains('write_files'));
      expect(result.modelOutput.length, lessThan(1500), reason: '应明显小于整篇手册');
    });

    test('章节未命中时回传章节菜单而非整篇手册', () async {
      final result = await SkillTool().execute({'name': 'todo-manager', 'section': '99'});
      expect(result.modelOutput, contains('可用章节'));
      expect(
        result.modelOutput.length,
        lessThan(1000),
        reason: '只回章节菜单，不整篇回灌（整篇手册 2000 字以上）',
      );
    });
  });

  group('WriteFilesTool 参数校验', () {
    test('files 为空报错', () async {
      final result = await WriteFilesTool().execute({'files': const []});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('不能为空'));
    });

    test('超过批量上限报错', () async {
      final files = List.generate(
        WriteFilesTool.maxBatchSize + 1,
        (i) => {'path': '/todos/今日/批量$i.md', 'content': '内容'},
      );
      final result = await WriteFilesTool().execute({'files': files});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('最多'));
    });

    test('空路径条目计入失败且不中断', () async {
      final result = await WriteFilesTool().execute({
        'files': [
          {'path': '', 'content': '内容'},
        ],
      });
      expect(result.isError, isTrue, reason: '全部失败应按错误上报');
      expect(result.modelOutput, contains('✗'));
      expect(result.uiDetails?['failed'], 1);
    });
  });

  group('EditFileTool 参数校验', () {
    test('old_text 与 new_text 相同直接报错，不发起写入', () async {
      final result = await EditFileTool().execute({
        'path': '/todos/今日/某待办.md',
        'old_text': 'status: pending',
        'new_text': 'status: pending',
      });
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('完全相同'));
    });

    test('路径或原文本为空时报错', () async {
      final result = await EditFileTool().execute({
        'path': '/todos/今日/某待办.md',
        'old_text': '',
        'new_text': 'x',
      });
      expect(result.isError, isTrue);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('VirtualWorkspace (VFS) 虚拟工作区与 Skill 机制测试', () {
    final vfs = VirtualWorkspaceService.instance;
    final dispatcher = AgentToolRegistry.createDefaultDispatcher();
    final todoRepo = TodoRepository();

    test('1. AGENTS.md 与 Skill 手册加载', () async {
      final agentsContent = await vfs.readFile('/AGENTS.md');
      expect(agentsContent, contains('QNote Agent Operating System'));
      expect(agentsContent, contains('/todos/'));

      final skills = SkillRegistry.instance.listSkills();
      expect(skills.length, greaterThanOrEqualTo(5));

      final todoSkill = SkillRegistry.instance.getSkillContent('todo-manager');
      expect(todoSkill, isNotNull);
      expect(todoSkill, contains('待办事项管理技能'));

      final skillFileRead = await vfs.readFile('/skills/todo-manager.md');
      expect(skillFileRead, contains('todo-manager'));
    });

    test('2. 目录遍历 list_dir', () async {
      final rootItems = await vfs.listDir('/');
      expect(rootItems, contains('todos/'));
      expect(rootItems, contains('skills/'));
      expect(rootItems, contains('AGENTS.md'));

      final todoFolders = await vfs.listDir('/todos');
      expect(todoFolders, contains('今日/'));
    });

    test('3. write_file: 写入待办并自动创建分类', () async {
      // 写入到自定义分类 "工作项目"
      final res = await vfs.writeFile(
        '/todos/工作项目/准备周报.md',
        '---\npriority: important\ndue_date: "2026-09-15 18:00"\n---\n本周工作总结与下周计划',
      );
      expect(res['status'], anyOf('created', 'updated'));
      expect(res['folder'], '工作项目');

      // 验证在 SQLite 中能查到
      final all = await todoRepo.getAll();
      final created = all.where((t) => t.title == '准备周报').firstOrNull;
      expect(created, isNotNull);
      expect(created!.priority, 'important');
      expect(created.folderId, isNotNull);
      expect(created.folderId, isNotEmpty);
    });

    test('4. read_file: 读取待办 Frontmatter 与内容', () async {
      final content = await vfs.readFile('/todos/工作项目/准备周报.md');
      expect(content, contains('title: "准备周报"'));
      expect(content, contains('priority: important'));
      expect(content, contains('本周工作总结与下周计划'));
    });

    test('5. edit_file: 精准文本替换（标记完成）', () async {
      final editRes = await vfs.editFile(
        '/todos/工作项目/准备周报.md',
        'status: pending',
        'status: completed',
      );
      expect(editRes['status'], 'updated');

      final all = await todoRepo.getAll();
      final updated = all.where((t) => t.title == '准备周报').firstOrNull;
      expect(updated, isNotNull);
      expect(updated!.isCompleted, isTrue);
    });

    test('6. WorkspaceEventBus 变更监听', () async {
      bool eventReceived = false;
      void listener(WorkspaceChangeEvent e) {
        if (e.path.contains('测试待办')) {
          eventReceived = true;
        }
      }

      WorkspaceEventBus.instance.addListener(listener);
      await vfs.writeFile('/todos/今日/测试待办.md', '这是测试待办内容');
      WorkspaceEventBus.instance.removeListener(listener);

      expect(eventReceived, isTrue);
    });

    test('7. 通过 Agent Dispatcher 执行新工具', () async {
      // 验证 skill 工具调用
      final skillCall = await dispatcher.dispatch(
        const ToolCall(id: 'call_skill', name: 'skill', arguments: {'name': 'note-manager'}),
      );
      expect(skillCall.isError, isFalse);
      expect(skillCall.content, contains('笔记与知识库管理技能'));

      // 验证 list_dir 工具调用
      final listCall = await dispatcher.dispatch(
        const ToolCall(id: 'call_list', name: 'list_dir', arguments: {'path': '/todos'}),
      );
      expect(listCall.isError, isFalse);
      expect(listCall.content, contains('今日/'));
    });
  });
}

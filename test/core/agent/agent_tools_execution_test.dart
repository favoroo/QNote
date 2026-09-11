import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('小Q Agent 端到端工具执行真实测试（VFS 工具集）', () {
    final dispatcher = AgentToolRegistry.createDefaultDispatcher();
    final noteRepo = NoteRepository();
    final todoRepo = TodoRepository();
    final configRepo = ConfigRepository.instance;

    // ffi 数据库为持久文件，历史运行的残留数据会按标题匹配命中，
    // 因此所有测试数据带时间戳后缀保证唯一
    final ts = DateTime.now().millisecondsSinceEpoch;

    test('1. write_file: 创建笔记并在库中验证', () async {
      final call = ToolCall(
        id: 'call_note_create',
        name: 'write_file',
        arguments: {
          'path': '/notes/测试笔记本-$ts/小Q笔记测试-$ts.md',
          'content': '---\ntags: ["小Q", "AI"]\n---\n这是小Q的初始内容：Flutter 是一个跨平台框架。',
        },
      );

      final result = await dispatcher.dispatch(call);
      expect(result.isError, false);

      final noteId = result.uiDetails?['id'] as String;
      expect(noteId.isNotEmpty, true);

      final saved = await noteRepo.getById(noteId);
      expect(saved != null, true);
      expect(saved!.title, '小Q笔记测试-$ts');
      expect(saved.content.contains('跨平台框架'), true);
      expect(saved.tags.contains('小Q'), true);
    });

    test('2. edit_file: 对笔记进行精准文本替换，验证未破坏整体结构', () async {
      // 先建一篇根目录笔记
      final createCall = ToolCall(
        id: 'call_create_for_edit',
        name: 'write_file',
        arguments: {
          'path': '/notes/待编辑笔记-$ts.md',
          'content': '第一行内容\n待替换关键词：苹果$ts\n第三行内容',
        },
      );
      final createRes = await dispatcher.dispatch(createCall);
      expect(createRes.isError, false);
      final noteId = createRes.uiDetails!['id'] as String;

      // 使用 edit_file 工具替换 "苹果" -> "橙子"
      final editCall = ToolCall(
        id: 'call_edit_text',
        name: 'edit_file',
        arguments: {
          'path': '/notes/待编辑笔记-$ts.md',
          'old_text': '苹果$ts',
          'new_text': '橙子$ts',
        },
      );

      final editRes = await dispatcher.dispatch(editCall);
      expect(editRes.isError, false);
      expect(editRes.content.contains('已成功编辑文件'), true);

      // 验证数据库真实落库结果
      final updated = await noteRepo.getById(noteId);
      expect(updated!.content, '第一行内容\n待替换关键词：橙子$ts\n第三行内容');
    });

    test('3. grep: 跨模块正则与关键词搜索', () async {
      final grepCall = ToolCall(
        id: 'call_grep',
        name: 'grep',
        arguments: {
          'query': '橙子$ts',
          'scope': 'notes',
        },
      );

      final grepRes = await dispatcher.dispatch(grepCall);
      expect(grepRes.isError, false);
      expect(grepRes.content.contains('待编辑笔记-$ts'), true);
      expect(grepRes.content.contains('橙子$ts'), true);
    });

    test('4. write_file + read_file + delete_file: 日记全生命周期', () async {
      const todayStr = '2026-09-11';
      final writeRes = await dispatcher.dispatch(ToolCall(
        id: 'call_write_journal',
        name: 'write_file',
        arguments: {
          'path': '/journal/$todayStr.md',
          'content': '# 2026-09-11 日记\n今天天气晴朗，完成了 agent 框架优化（批次 $ts）。',
        },
      ));
      expect(writeRes.isError, false);

      // 读取验证
      final readRes = await dispatcher.dispatch(ToolCall(
        id: 'call_read_journal',
        name: 'read_file',
        arguments: {'path': '/journal/$todayStr.md'},
      ));
      expect(readRes.content.contains('今天天气晴朗'), true);

      // 删除
      final deleteRes = await dispatcher.dispatch(ToolCall(
        id: 'call_delete_journal',
        name: 'delete_file',
        arguments: {'path': '/journal/$todayStr.md'},
      ));
      expect(deleteRes.isError, false);
      expect(deleteRes.content.contains('已成功删除'), true);

      // 再次读取验证已被清空
      final readAfterDelete = await dispatcher.dispatch(ToolCall(
        id: 'call_read_journal_after',
        name: 'read_file',
        arguments: {'path': '/journal/$todayStr.md'},
      ));
      expect(readAfterDelete.content.contains('尚未开始编写'), true);
    });

    test('5. write_file + edit_file: 待办创建与状态切换', () async {
      final createRes = await dispatcher.dispatch(ToolCall(
        id: 'call_create_todo',
        name: 'write_file',
        arguments: {
          'path': '/todos/今日/明天下午开会-$ts.md',
          'content': '---\nstatus: pending\npriority: important\ndue_date: "2026-09-12 15:00"\n---\n准备会议材料',
        },
      ));
      expect(createRes.isError, false);
      final todoId = createRes.uiDetails!['id'] as String;

      // 通过 edit_file 将 status: pending 替换为 completed（标记完成）
      final editRes = await dispatcher.dispatch(ToolCall(
        id: 'call_toggle_todo',
        name: 'edit_file',
        arguments: {
          'path': '/todos/今日/明天下午开会-$ts.md',
          'old_text': 'status: pending',
          'new_text': 'status: completed',
        },
      ));
      expect(editRes.isError, false);

      final savedTodo = await todoRepo.getById(todoId);
      expect(savedTodo!.isCompleted, true);
      expect(savedTodo.priority, 'important');
    });

    test('6. read_file + write_file: 修改个人信息配置', () async {
      // 先读取当前 profile.json（read_file 输出带行号前缀，需剥离后再解析）
      final readRes = await dispatcher.dispatch(ToolCall(
        id: 'call_read_profile',
        name: 'read_file',
        arguments: {'path': '/settings/profile.json'},
      ));
      expect(readRes.isError, false);
      final cleanJson = readRes.content
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^\d+\t'), ''))
          .join('\n');
      final profileMap = jsonDecode(cleanJson) as Map<String, dynamic>;

      // 修改昵称与身高后写回（保留 id/created_at 等必填字段）
      profileMap['nickname'] = '小Q的主人-$ts';
      profileMap['height'] = 185;
      final writeRes = await dispatcher.dispatch(ToolCall(
        id: 'call_update_profile',
        name: 'write_file',
        arguments: {
          'path': '/settings/profile.json',
          'content': jsonEncode(profileMap),
        },
      ));
      expect(writeRes.isError, false);

      final profile = await configRepo.getUserProfile();
      expect(profile!.nickname, '小Q的主人-$ts');
      expect(profile.height, 185.0);
    });
  });
}

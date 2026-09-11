import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
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

  group('小Q Agent 端到端工具执行真实测试', () {
    final dispatcher = AgentToolRegistry.createDefaultDispatcher();
    final noteRepo = NoteRepository();
    final todoRepo = TodoRepository();
    final configRepo = ConfigRepository.instance;

    test('1. manage_note: 创建笔记并在库中验证', () async {
      final call = ToolCall(
        id: 'call_note_create',
        name: 'manage_note',
        arguments: {
          'action': 'create_note',
          'title': '测试小Q笔记',
          'content': '这是小Q的初始内容：Flutter 是一个跨平台框架。',
          'tags': '小Q,AI',
        },
      );

      final result = await dispatcher.dispatch(call);
      expect(result.isError, false);
      expect(result.content.contains('已成功创建笔记'), true);

      final noteId = result.uiDetails?['note']?['id'] as String;
      expect(noteId.isNotEmpty, true);

      final saved = await noteRepo.getById(noteId);
      expect(saved != null, true);
      expect(saved!.title, '测试小Q笔记');
      expect(saved.content.contains('跨平台框架'), true);
    });

    test('2. edit: 对笔记进行精准文本替换，验证未破坏整体结构', () async {
      // 先建一篇
      final createCall = ToolCall(
        id: 'call_create_for_edit',
        name: 'manage_note',
        arguments: {
          'action': 'create_note',
          'title': '待编辑笔记',
          'content': '第一行内容\n待替换关键词：苹果\n第三行内容',
        },
      );
      final createRes = await dispatcher.dispatch(createCall);
      final noteId = createRes.uiDetails!['note']['id'] as String;

      // 使用 edit 工具替换 "苹果" -> "橙子"
      final editCall = ToolCall(
        id: 'call_edit_text',
        name: 'edit',
        arguments: {
          'target_type': 'note',
          'id': noteId,
          'old_text': '苹果',
          'new_text': '橙子',
        },
      );

      final editRes = await dispatcher.dispatch(editCall);
      expect(editRes.isError, false);
      expect(editRes.content.contains('已成功更新目标'), true);

      // 验证数据库真实落库结果
      final updated = await noteRepo.getById(noteId);
      expect(updated!.content, '第一行内容\n待替换关键词：橙子\n第三行内容');
    });

    test('3. grep: 跨模块正则与关键词搜索', () async {
      final grepCall = ToolCall(
        id: 'call_grep',
        name: 'grep',
        arguments: {
          'query': '橙子',
          'scope': 'notes',
        },
      );

      final grepRes = await dispatcher.dispatch(grepCall);
      expect(grepRes.isError, false);
      expect(grepRes.content.contains('待编辑笔记'), true);
      expect(grepRes.content.contains('橙子'), true);
    });

    test('4. manage_journal: 编写和追加长篇日记', () async {
      final todayStr = '2026-09-11';
      final writeCall = ToolCall(
        id: 'call_write_journal',
        name: 'manage_journal',
        arguments: {
          'action': 'write',
          'date': todayStr,
          'content': '# 2026-09-11 日记\n今天天气晴朗。',
        },
      );
      final writeRes = await dispatcher.dispatch(writeCall);
      expect(writeRes.isError, false);

      // 追加一段
      final appendCall = ToolCall(
        id: 'call_append_journal',
        name: 'manage_journal',
        arguments: {
          'action': 'append',
          'date': todayStr,
          'content': '晚上完成了小Q的开发！',
        },
      );
      final appendRes = await dispatcher.dispatch(appendCall);
      expect(appendRes.isError, false);

      // 读取验证
      final getCall = ToolCall(
        id: 'call_get_journal',
        name: 'manage_journal',
        arguments: {
          'action': 'get',
          'date': todayStr,
        },
      );
      final getRes = await dispatcher.dispatch(getCall);
      expect(getRes.content.contains('今天天气晴朗'), true);
      expect(getRes.content.contains('晚上完成了小Q的开发'), true);
    });

    test('5. manage_todo: 增、改、切换完成状态', () async {
      final createTodoCall = ToolCall(
        id: 'call_create_todo',
        name: 'manage_todo',
        arguments: {
          'action': 'create',
          'title': '明天下午开会',
          'priority': 'high',
          'due_date': '2026-09-12 15:00:00',
        },
      );
      final createTodoRes = await dispatcher.dispatch(createTodoCall);
      expect(createTodoRes.isError, false);
      final todoId = createTodoRes.uiDetails!['todo']['id'] as String;

      // 切换为已完成
      final toggleCall = ToolCall(
        id: 'call_toggle_todo',
        name: 'manage_todo',
        arguments: {
          'action': 'toggle_complete',
          'id': todoId,
          'is_completed': true,
        },
      );
      final toggleRes = await dispatcher.dispatch(toggleCall);
      expect(toggleRes.isError, false);

      final savedTodo = await todoRepo.getById(todoId);
      expect(savedTodo!.isCompleted, true);
    });

    test('6. manage_settings: 修改个人信息', () async {
      final updateProfileCall = ToolCall(
        id: 'call_update_profile',
        name: 'manage_settings',
        arguments: {
          'target': 'profile',
          'action': 'update',
          'nickname': '小Q的主人',
          'height': 185,
        },
      );
      final updateProfileRes = await dispatcher.dispatch(updateProfileCall);
      expect(updateProfileRes.isError, false);

      final profile = await configRepo.getUserProfile();
      expect(profile!.nickname, '小Q的主人');
      expect(profile.height, 185.0);
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/chat_session.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('内置 glm-5.2 模型真实端到端测试：创建笔记、创建待办、编辑文件', () async {
    // 1. 初始化 GLM-5.2 模型配置
    final glmModel = BuiltinFreeKeys.createGlmConfig();
    final aiConfig = FreeModelService.instance.toAiConfig(glmModel);

    // ignore: avoid_print
    print('========================================');
    // ignore: avoid_print
    print('使用模型: ${aiConfig.modelName} (${aiConfig.baseUrl})');
    // ignore: avoid_print
    print('========================================');

    final aiService = AiService();
    aiService.updateConfig(aiConfig);
    final dispatcher = AgentToolRegistry.createDefaultDispatcher();
    final agentLoop = AgentLoop(
      aiService: aiService,
      dispatcher: dispatcher,
      maxTurns: 6,
    );

    final history = <ChatMessage>[];

    // ----------------------------------------------------
    // 测试 1：通过小Q创建笔记（标题：小Q测试笔记，内容：笔记文本测试）
    // ----------------------------------------------------
    // ignore: avoid_print
    print('\n>>> [测试 1] 发送指令：帮我创建一个笔记，标题为“小Q测试笔记”，内容写上“笔记文本测试”');
    history.add(ChatMessage(
      role: 'user',
      content: '帮我创建一个笔记，标题为“小Q测试笔记”，内容写上“笔记文本测试”',
    ));

    final stream1 = agentLoop.run(
      conversationHistory: history,
      systemPrompt: QSystemPrompt.prompt,
    );

    ChatMessage? reply1;
    await for (final event in stream1) {
      if (event.type == AgentEventType.toolExecuting) {
        // ignore: avoid_print
        print('⚡ 工具调用: ${event.toolCall?.name} -> 参数: ${event.toolCall?.arguments}');
      } else if (event.type == AgentEventType.toolCompleted) {
        // ignore: avoid_print
        print('✅ 工具执行结果: ${event.message?.content}');
      } else if (event.type == AgentEventType.contentDelta) {
        // ignore: avoid_print
        // stdout.write(event.text ?? '');
      } else if (event.type == AgentEventType.finished) {
        reply1 = event.message;
      } else if (event.type == AgentEventType.error) {
        // ignore: avoid_print
        print('❌ 错误事件: ${event.error}');
      }
    }

    // ignore: avoid_print
    print('\n🤖 小Q回复 1:\n${reply1?.content}');
    expect(reply1, isNotNull);
    if (reply1 != null) history.add(reply1);

    // 验证底层笔记是否真正写入数据库和 VFS
    final allNotes = await NoteRepository().getAll();
    final createdNote = allNotes.where((n) => n.title.contains('小Q测试笔记')).firstOrNull;
    // ignore: avoid_print
    print('【数据库核验 - 笔记】 ID=${createdNote?.id}, 标题=${createdNote?.title}, 内容=${createdNote?.content}');
    expect(createdNote, isNotNull);
    expect(createdNote!.content, contains('笔记文本测试'));

    // ----------------------------------------------------
    // 测试 2：通过小Q创建待办（写上中午取快递）
    // ----------------------------------------------------
    // ignore: avoid_print
    print('\n>>> [测试 2] 发送指令：再帮我创建一个待办，写上中午取快递');
    history.add(ChatMessage(
      role: 'user',
      content: '再帮我创建一个待办，写上中午取快递',
    ));

    final stream2 = agentLoop.run(
      conversationHistory: history,
      systemPrompt: QSystemPrompt.prompt,
    );

    ChatMessage? reply2;
    await for (final event in stream2) {
      if (event.type == AgentEventType.toolExecuting) {
        // ignore: avoid_print
        print('⚡ 工具调用: ${event.toolCall?.name} -> 参数: ${event.toolCall?.arguments}');
      } else if (event.type == AgentEventType.toolCompleted) {
        // ignore: avoid_print
        print('✅ 工具执行结果: ${event.message?.content}');
      } else if (event.type == AgentEventType.finished) {
        reply2 = event.message;
      }
    }

    // ignore: avoid_print
    print('\n🤖 小Q回复 2:\n${reply2?.content}');
    expect(reply2, isNotNull);
    if (reply2 != null) history.add(reply2);

    // 验证底层待办是否真正写入数据库和 VFS
    final allTodos = await TodoRepository().getAll();
    final createdTodo = allTodos.where((t) => t.title.contains('取快递') || t.title.contains('快递')).firstOrNull;
    // ignore: avoid_print
    print('【数据库核验 - 待办】 ID=${createdTodo?.id}, 标题=${createdTodo?.title}, 分类ID=${createdTodo?.folderId}');
    expect(createdTodo, isNotNull);
    expect(createdTodo!.folderId, isNotNull);
    expect(createdTodo.folderId, isNotEmpty);

    // ----------------------------------------------------
    // 测试 3：测试文件编辑功能（修改或追加刚才的笔记内容）
    // ----------------------------------------------------
    // ignore: avoid_print
    print('\n>>> [测试 3] 发送指令：把刚才的笔记“小Q测试笔记”编辑一下，在内容后面加上“（编辑功能已验证通过）”');
    history.add(ChatMessage(
      role: 'user',
      content: '把刚才的笔记“小Q测试笔记”编辑一下，在内容后面加上“（编辑功能已验证通过）”',
    ));

    final stream3 = agentLoop.run(
      conversationHistory: history,
      systemPrompt: QSystemPrompt.prompt,
    );

    ChatMessage? reply3;
    await for (final event in stream3) {
      if (event.type == AgentEventType.toolExecuting) {
        // ignore: avoid_print
        print('⚡ 工具调用: ${event.toolCall?.name} -> 参数: ${event.toolCall?.arguments}');
      } else if (event.type == AgentEventType.toolCompleted) {
        // ignore: avoid_print
        print('✅ 工具执行结果: ${event.message?.content}');
      } else if (event.type == AgentEventType.finished) {
        reply3 = event.message;
      }
    }

    // ignore: avoid_print
    print('\n🤖 小Q回复 3:\n${reply3?.content}');
    expect(reply3, isNotNull);

    // 验证底层笔记内容是否更新成功
    final updatedNote = await NoteRepository().getById(createdNote.id);
    // ignore: avoid_print
    print('【数据库核验 - 笔记编辑后】 ID=${updatedNote?.id}, 内容=${updatedNote?.content}');
    expect(updatedNote, isNotNull);
    expect(updatedNote!.content, contains('验证通过'));
    // ignore: avoid_print
    print('\n🎉🎉🎉 GLM-5.2 模型全流程真实调用与文件创建/编辑核验 100% 通过！');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

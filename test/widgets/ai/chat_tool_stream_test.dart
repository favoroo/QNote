import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/pages/ai_page.dart';

void main() {
  group('小Q对话流工具卡片紧凑与折叠测试', () {
    testWidgets('skill 工具：仅显示单行技能胶囊，不展开大段手册，点击「查看」弹出手册弹窗',
        (tester) async {
      final skillMessage = ChatMessage(
        role: 'tool',
        toolName: 'skill',
        content: '# 技能手册《frontend-design》\n\n这里是非常长的大段技能手册内容，不应直接在气泡内平铺渲染。',
        uiDetails: {'name': 'frontend-design', 'loaded': true},
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ChatBubble.buildToolFeedback(
                context,
                skillMessage,
                Theme.of(context),
              ),
            ),
          ),
        ),
      );

      // 验证单行胶囊展示了技能名
      expect(find.text('已调用技能手册 · frontend-design'), findsOneWidget);
      // 验证气泡本身没有直接以文本方式铺开手册正文
      expect(find.textContaining('这里是非常长的大段技能手册内容'), findsNothing);
      // 验证存在「查看」按钮
      final viewButton = find.text('查看');
      expect(viewButton, findsOneWidget);

      // 点击「查看」，应弹出弹窗展示完整手册
      await tester.tap(viewButton);
      await tester.pumpAndSettle();

      expect(find.text('技能手册 · frontend-design'), findsOneWidget);
      expect(find.textContaining('这里是非常长的大段技能手册内容'), findsOneWidget);
    });

    testWidgets('list_dir 工具：折叠展示目录及条目总数，点击可展开查看条目列表',
        (tester) async {
      final listDirMessage = ChatMessage(
        role: 'tool',
        toolName: 'list_dir',
        content: 'notes/a.md\nnotes/b.md\nnotes/c.md',
        uiDetails: {
          'path': '/notes',
          'items': ['notes/a.md', 'notes/b.md', 'notes/c.md'],
        },
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ChatBubble.buildToolFeedback(
                context,
                listDirMessage,
                Theme.of(context),
              ),
            ),
          ),
        ),
      );

      // 折叠态：显示总数
      expect(find.text('已查看目录 /notes (共 3 项)'), findsOneWidget);
      // 此时列表项未展开
      expect(find.text('notes/a.md'), findsNothing);

      // 点击折叠条展开
      await tester.tap(find.text('已查看目录 /notes (共 3 项)'));
      await tester.pumpAndSettle();

      // 展开态：显示各项文件
      expect(find.text('notes/a.md'), findsOneWidget);
      expect(find.text('notes/b.md'), findsOneWidget);
      expect(find.text('notes/c.md'), findsOneWidget);
    });

    testWidgets('read_file 工具：成功时展示路径与「预览」按钮，失败时展示错误提示',
        (tester) async {
      final readSuccessMsg = ChatMessage(
        role: 'tool',
        toolName: 'read_file',
        content: '这是文件的详细内容片段...',
        uiDetails: {'path': '/notes/todo.md'},
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ChatBubble.buildToolFeedback(
                context,
                readSuccessMsg,
                Theme.of(context),
              ),
            ),
          ),
        ),
      );

      expect(find.text('已读取文件 /notes/todo.md'), findsOneWidget);
      expect(find.text('预览'), findsOneWidget);
      expect(find.textContaining('这是文件的详细内容片段...'), findsNothing);

      // 点击「预览」弹出文件详情
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.text('文件预览 · /notes/todo.md'), findsOneWidget);
      expect(find.textContaining('这是文件的详细内容片段...'), findsOneWidget);

      // 关闭弹窗
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // 错误测试
      final readErrorMsg = ChatMessage(
        role: 'tool',
        toolName: 'read_file',
        content: '文件不存在: /notes/not_found.md',
        isError: true,
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ChatBubble.buildToolFeedback(
                context,
                readErrorMsg,
                Theme.of(context),
              ),
            ),
          ),
        ),
      );

      expect(find.text('文件不存在: /notes/not_found.md'), findsOneWidget);
    });

    testWidgets('_ToolChainGroupWidget 多步连续工具调用折叠组件：汇总步骤数与分布，展开显示各步细节',
        (tester) async {
      final tool1 = ChatMessage(
        role: 'tool',
        toolName: 'list_dir',
        content: '1.md\n2.md',
        uiDetails: {'path': '/notes', 'items': ['1.md', '2.md']},
        timestamp: DateTime.now(),
      );
      final tool2 = ChatMessage(
        role: 'tool',
        toolName: 'read_file',
        content: '内容1',
        uiDetails: {'path': '/notes/1.md'},
        timestamp: DateTime.now(),
      );
      final tool3 = ChatMessage(
        role: 'tool',
        toolName: 'read_file',
        content: '内容2',
        uiDetails: {'path': '/notes/2.md'},
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ToolChainGroupWidget(
                toolMessages: [tool1, tool2, tool3],
                theme: Theme.of(context),
              ),
            ),
          ),
        ),
      );

      // 折叠总览：连续完成 3 步操作
      expect(find.textContaining('已连续完成 3 步操作'), findsOneWidget);
      expect(find.textContaining('读取文件 2 项'), findsOneWidget);
      expect(find.textContaining('查看目录 1 项'), findsOneWidget);

      // 展开前子项未挂载
      expect(find.text('已读取文件 /notes/1.md'), findsNothing);

      // 点击展开
      await tester.tap(find.textContaining('已连续完成 3 步操作'));
      await tester.pumpAndSettle();

      // 展开后所有步骤均可见
      expect(find.text('已查看目录 /notes (共 2 项)'), findsOneWidget);
      expect(find.text('已读取文件 /notes/1.md'), findsOneWidget);
      expect(find.text('已读取文件 /notes/2.md'), findsOneWidget);
    });
  });
}

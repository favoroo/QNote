import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/widgets/ai/bubble_action_bar.dart';
import 'package:qnote_flutter/widgets/ai/workflow_process_view.dart';
import 'package:qnote_flutter/widgets/common/thinking_process_view.dart';

/// ZCode 风格单行折叠工作流的渲染与交互回归测试
void main() {
  Widget wrap(Widget child, {bool disableAnimations = false}) {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
  }

  WorkflowData sampleWorkflow({bool isLive = false, List<WorkflowStep>? steps}) {
    final list =
        steps ??
        [
          WorkflowStep(
            kind: WorkflowStepKind.thought,
            message: ChatMessage(role: 'thought', content: '先看看有哪些日记', thoughtSeconds: 3),
          ),
          WorkflowStep(
            kind: WorkflowStepKind.tool,
            message: ChatMessage(
              role: 'tool',
              toolName: 'read_file',
              content: '日记正文内容',
              uiDetails: {'path': '/diary/2026-11-14.md'},
            ),
          ),
          WorkflowStep(
            kind: WorkflowStepKind.prose,
            message: ChatMessage(role: 'assistant', content: '我先翻阅一下最近的记录'),
          ),
          WorkflowStep(
            kind: WorkflowStepKind.thought,
            message: ChatMessage(role: 'thought', content: '已经拿到全部数据', thoughtSeconds: 2),
          ),
        ];
    return WorkflowData(turnKey: 'turn_0_0', steps: list, summary: WorkflowSummary.fromSteps(list), isLive: isLive);
  }

  Widget toolBuilder(BuildContext context, ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text('工具结果: ${msg.toolName} ${msg.uiDetails?['path'] ?? ''}'),
    );
  }

  testWidgets('已完成工作流默认折叠成一行汇总，点击后平滑展开全部步骤', (tester) async {
    await tester.pumpWidget(wrap(WorkflowProcessView(workflow: sampleWorkflow(), toolBuilder: toolBuilder)));
    await tester.pumpAndSettle();

    expect(find.text('思考 5 秒 · 查阅 1 项'), findsOneWidget);
    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsNothing);
    expect(find.text('我先翻阅一下最近的记录'), findsNothing);

    await tester.tap(find.text('思考 5 秒 · 查阅 1 项'));
    await tester.pumpAndSettle();

    expect(find.byType(ThinkingProcessView), findsNWidgets(2));
    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsOneWidget);
    expect(find.text('我先翻阅一下最近的记录'), findsOneWidget);

    await tester.tap(find.text('思考 5 秒 · 查阅 1 项'));
    await tester.pumpAndSettle();

    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsNothing);
  });

  testWidgets('运行中折叠态单行流水按阶段切换：思考 → 工具执行 → 刚完成步骤 → 开始输出正文', (tester) async {
    final steps = [
      WorkflowStep(
        kind: WorkflowStepKind.tool,
        message: ChatMessage(role: 'tool', toolName: 'read_file', content: '内容', uiDetails: {'path': '/notes/a.md'}),
      ),
    ];
    final liveWorkflow = sampleWorkflow(isLive: true, steps: steps);
    final startedAt = DateTime.now().subtract(const Duration(seconds: 6));

    // 1. 正在思考
    await tester.pumpWidget(
      wrap(
        WorkflowProcessView(
          workflow: liveWorkflow,
          toolBuilder: toolBuilder,
          liveThought: '第一行\n正在分析笔记结构',
          liveTurnStartedAt: startedAt,
          liveStartedAt: startedAt,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('思考'), findsOneWidget);
    expect(find.text('正在分析笔记结构'), findsOneWidget);
    expect(find.text('工作中'), findsOneWidget);

    // 2. 正在调用工具（应优先展示工具进度而非残留思考）
    await tester.pumpWidget(
      wrap(
        WorkflowProcessView(
          workflow: liveWorkflow,
          toolBuilder: toolBuilder,
          liveThought: '第一行\n正在分析笔记结构',
          liveStatusText: '⚡ 正在读取文件 · /notes/b.md',
          liveTurnStartedAt: startedAt,
          liveStartedAt: startedAt,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('正在读取文件 · /notes/b.md'), findsOneWidget);
    expect(find.text('工作中'), findsOneWidget);

    // 3. 轮次间隙（工具刚完成、下一轮思考未到达）：展示刚完成的步骤
    await tester.pumpWidget(
      wrap(
        WorkflowProcessView(
          workflow: liveWorkflow,
          toolBuilder: toolBuilder,
          liveStatusText: '小Q思考中 · 第 2 步',
          liveStartedAt: startedAt,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('已读取 · /notes/a.md'), findsOneWidget);
    expect(find.text('工作中'), findsOneWidget);

    // 4. 最终正文开始输出：隐藏「工作中」副行，收拢为摘要
    await tester.pumpWidget(
      wrap(
        WorkflowProcessView(
          workflow: liveWorkflow,
          toolBuilder: toolBuilder,
          liveStartedAt: startedAt,
          hasStreamingOutput: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('工作中'), findsNothing);
    expect(find.text('查阅 1 项'), findsOneWidget);
  });

  testWidgets('流式期间手动展开后，完成落库仍保持展开状态（受控模式）', (tester) async {
    var expanded = false;
    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            return WorkflowProcessView(
              workflow: sampleWorkflow(isLive: true),
              toolBuilder: toolBuilder,
              expanded: expanded,
              onExpandedChanged: (v) => setState(() => expanded = v),
              liveStartedAt: DateTime.now(),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(InkWell).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(expanded, isTrue);
    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsOneWidget);

    // 切换为已完成工作流（模拟落库）
    await tester.pumpWidget(
      wrap(
        WorkflowProcessView(
          workflow: sampleWorkflow(isLive: false),
          toolBuilder: toolBuilder,
          expanded: expanded,
          onExpandedChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsOneWidget);
  });

  testWidgets('减弱动态效果模式下可正常切换展开与收起', (tester) async {
    await tester.pumpWidget(
      wrap(WorkflowProcessView(workflow: sampleWorkflow(), toolBuilder: toolBuilder), disableAnimations: true),
    );
    await tester.pump();

    await tester.tap(find.text('思考 5 秒 · 查阅 1 项'));
    await tester.pump();
    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsOneWidget);
  });

  testWidgets('ChatBubble 渲染 role=workflow 行时不套气泡且不展示操作条', (tester) async {
    final workflow = sampleWorkflow();
    await tester.pumpWidget(
      wrap(
        ChatBubble(
          message: ChatMessage(role: 'workflow', content: '', uiDetails: {'workflow': workflow}),
          isFirstInGroup: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('小Q'), findsOneWidget);
    expect(find.text('思考 5 秒 · 查阅 1 项'), findsOneWidget);
    expect(find.byType(BubbleActionBar), findsNothing);
  });
}

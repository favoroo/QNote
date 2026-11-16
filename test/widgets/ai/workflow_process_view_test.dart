import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/agent_working_badge.dart';
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
    // 「工作中 · N s」已上移到小Q名字右侧徽章（AgentWorkingBadge），折叠行不再渲染副行
    expect(find.text('工作中'), findsNothing);

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
    expect(find.text('工作中'), findsNothing);

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
    expect(find.text('工作中'), findsNothing);

    // 4. 最终正文开始输出：折叠行收拢为摘要（徽章同样由正文流式接管隐藏）
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

  testWidgets('AgentWorkingBadge：任务开始即时显示计时，限流替换文案，空闲与正文流式隐藏', (tester) async {
    // 1. 任务刚开始（startedAt 就绪）：零缓冲立即显示「工作中」+ 秒数
    await tester.pumpWidget(wrap(AgentWorkingBadge(startedAt: DateTime.now())));
    await tester.pump();
    expect(find.text('工作中'), findsOneWidget);
    expect(find.text('· 0 s'), findsOneWidget);

    // 2. 限流：文案替换为限流倒计时
    await tester.pumpWidget(wrap(AgentWorkingBadge(startedAt: DateTime.now(), statusText: '服务商限流 · 5s 后重试')));
    await tester.pump();
    expect(find.text('服务商限流 · 5s 后重试'), findsOneWidget);
    expect(find.text('工作中'), findsNothing);

    // 3. 无进行中任务（startedAt 为 null）：不渲染
    await tester.pumpWidget(wrap(const AgentWorkingBadge(startedAt: null)));
    await tester.pump();
    expect(find.text('工作中'), findsNothing);
    expect(find.text('服务商限流 · 5s 后重试'), findsNothing);

    // 4. 正文开始流式（active=false）：隐藏
    await tester.pumpWidget(wrap(AgentWorkingBadge(startedAt: DateTime.now(), active: false)));
    await tester.pump();
    expect(find.text('工作中'), findsNothing);
  });

  testWidgets('活跃工作流消息的组抬头挂「工作中」徽章，完成后抬头回归纯静态', (tester) async {
    Widget badgeWrap(Widget child) {
      return ProviderScope(
        overrides: [aiStreamingStartedAtProvider.overrideWith((ref) => DateTime.now())],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );
    }

    // 活跃工作流：小Q 名字右侧出现徽章
    await tester.pumpWidget(
      badgeWrap(
        ChatBubble(
          message: ChatMessage(role: 'workflow', content: '', uiDetails: {'workflow': sampleWorkflow(isLive: true)}),
          isFirstInGroup: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('小Q'), findsOneWidget);
    expect(find.text('工作中'), findsOneWidget);

    // 同一条消息落库完成（isLive=false）：徽章消失
    await tester.pumpWidget(
      badgeWrap(
        ChatBubble(
          message: ChatMessage(role: 'workflow', content: '', uiDetails: {'workflow': sampleWorkflow()}),
          isFirstInGroup: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作中'), findsNothing);
  });

  testWidgets('完成后折叠行只显示「已工作 X 分 Y 秒」总耗时（对齐 ZCode）', (tester) async {
    final base = DateTime(2026, 11, 15, 9, 0, 0);
    final steps = sampleWorkflow().steps;
    final workflow = WorkflowData(
      turnKey: 'turn_0_0',
      steps: steps,
      summary: WorkflowSummary.fromSteps(steps),
      startedAt: base,
      endedAt: base.add(const Duration(minutes: 9, seconds: 10)),
    );

    await tester.pumpWidget(wrap(WorkflowProcessView(workflow: workflow, toolBuilder: toolBuilder)));
    await tester.pumpAndSettle();

    expect(find.text('已工作 9 分 10 秒'), findsOneWidget);
    // 动作计数不再占用折叠行，收进展开区
    expect(find.text('思考 5 秒 · 查阅 1 项'), findsNothing);
    expect(find.text('查阅 1 项'), findsNothing);
  });

  testWidgets('完成工作流含异常步骤时，总耗时行保留异常计数', (tester) async {
    final base = DateTime(2026, 11, 15, 9, 0, 0);
    final steps = [
      WorkflowStep(
        kind: WorkflowStepKind.tool,
        message: ChatMessage(role: 'tool', toolName: 'edit_file', content: '失败', isError: true),
      ),
    ];
    final workflow = WorkflowData(
      turnKey: 'turn_0_0',
      steps: steps,
      summary: WorkflowSummary.fromSteps(steps),
      startedAt: base,
      endedAt: base.add(const Duration(seconds: 50)),
    );

    await tester.pumpWidget(wrap(WorkflowProcessView(workflow: workflow, toolBuilder: toolBuilder)));
    await tester.pumpAndSettle();

    expect(find.text('已工作 50 秒 · 1 项异常'), findsOneWidget);
  });

  testWidgets('失败工作流折叠为一行错误标题，展开后可见完整错误、此前步骤与重试入口', (tester) async {
    final steps = [
      WorkflowStep(
        kind: WorkflowStepKind.thought,
        message: ChatMessage(role: 'thought', content: '先查一下最近的记录', thoughtSeconds: 3),
      ),
      WorkflowStep(
        kind: WorkflowStepKind.tool,
        message: ChatMessage(role: 'tool', toolName: 'read_file', content: '日记正文内容'),
      ),
      WorkflowStep(
        kind: WorkflowStepKind.error,
        message: ChatMessage(role: 'assistant', content: '本轮对话请求失败\n\n问题：连接服务器超时', isError: true),
        stateIndex: 5,
      ),
    ];
    final workflow = WorkflowData(turnKey: 'turn_0_1', steps: steps, summary: WorkflowSummary.fromSteps(steps));
    var retried = 0;

    await tester.pumpWidget(
      wrap(WorkflowProcessView(workflow: workflow, toolBuilder: toolBuilder, onRetry: () => retried++)),
    );
    await tester.pumpAndSettle();

    // 折叠态只保留一行错误标题：完整错误详情与已完成步骤都不外露
    expect(find.text('本轮对话请求失败'), findsOneWidget);
    expect(find.textContaining('连接服务器超时'), findsNothing);
    expect(find.textContaining('工具结果: read_file'), findsNothing);

    await tester.tap(find.text('本轮对话请求失败'));
    await tester.pumpAndSettle();

    // 展开后能回看工作到哪一步，并读到完整错误详情
    expect(find.textContaining('问题：连接服务器超时'), findsOneWidget);
    expect(find.textContaining('工具结果: read_file'), findsOneWidget);
    expect(find.byType(ThinkingProcessView), findsOneWidget);

    await tester.tap(find.text('重试本轮'));
    expect(retried, 1);
  });

  testWidgets('失败工作流支持长按折叠行弹错误操作菜单', (tester) async {
    final steps = [
      WorkflowStep(
        kind: WorkflowStepKind.error,
        message: ChatMessage(role: 'assistant', content: '执行失败\n\n详情', isError: true),
        stateIndex: 1,
      ),
    ];
    final workflow = WorkflowData(turnKey: 'turn_0_0', steps: steps, summary: WorkflowSummary.fromSteps(steps));
    var longPressed = 0;

    await tester.pumpWidget(
      wrap(WorkflowProcessView(workflow: workflow, toolBuilder: toolBuilder, onErrorLongPress: () => longPressed++)),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('执行失败'));
    expect(longPressed, 1);
  });

  testWidgets('完成态展开工作过程：内容已在视野内时不滚动，不会滚到回复底部', (tester) async {
    final controller = ScrollController();
    final view = WorkflowProcessView(workflow: sampleWorkflow(), toolBuilder: toolBuilder);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 100),
              view,
              // 后面跟着很长的最终正文：展开工作流不该把视图一路带到这里
              const SizedBox(height: 1600),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('思考 5 秒 · 查阅 1 项'));
    await tester.pumpAndSettle();

    // 展开区就在点击行下方且完整可见，保持原位
    expect(controller.offset, 0);
    expect(find.text('工具结果: read_file /diary/2026-11-14.md'), findsOneWidget);
  });

  testWidgets('展开行贴着视口下沿时，只下滑到内容完整露出', (tester) async {
    final controller = ScrollController();
    final view = WorkflowProcessView(workflow: sampleWorkflow(), toolBuilder: toolBuilder);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [const SizedBox(height: 540), view, const SizedBox(height: 1600)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('思考 5 秒 · 查阅 1 项'));
    await tester.pumpAndSettle();

    // 下滑了，但停在展开区刚好完整露出的位置，而不是列表底部
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(controller.position.maxScrollExtent));
    // 展开区底边留在视口内（600 高的测试视口，留 12 的下边距）
    expect(tester.getBottomLeft(find.byType(WorkflowProcessView)).dy, lessThanOrEqualTo(600));
  });
}

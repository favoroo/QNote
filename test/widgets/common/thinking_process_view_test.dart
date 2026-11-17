import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/common/thinking_process_view.dart';
import 'package:qnote_flutter/widgets/common/thought_tail_scroll_view.dart';

/// 思考过程展示的交互回归：默认单行，点击展开全文，流式结束后按用户选择收放
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );
  }

  group('thoughtPreviewText', () {
    test('折叠换行后保留整段摘要', () {
      expect(thoughtPreviewText('第一行\n第二行'), '第一行 第二行');
    });

    test('结尾空行不会让预览变成空串', () {
      expect(thoughtPreviewText('思考\n\n'), '思考');
    });

    test('连续空白折叠为一个空格', () {
      expect(thoughtPreviewText('第一段\n\n  第二段'), '第一段 第二段');
    });

    test('超长文本截取末尾并前置省略号', () {
      final text = thoughtPreviewText('${'前' * 200}结尾');
      expect(text.startsWith('…'), isTrue);
      expect(text.characters.length, 121);
      expect(text.endsWith('结尾'), isTrue);
    });

    test('空白文本返回空串', () {
      expect(thoughtPreviewText('   \n \n'), '');
    });
  });

  group('thinkingDurationLabel', () {
    test('无有效秒数不展示', () {
      expect(thinkingDurationLabel(null), '');
      expect(thinkingDurationLabel(0), '');
    });

    test('一分钟内按秒展示', () {
      expect(thinkingDurationLabel(3), '3 秒');
      expect(thinkingDurationLabel(59), '59 秒');
    });

    test('超过一分钟按分秒展示', () {
      expect(thinkingDurationLabel(60), '1 分');
      expect(thinkingDurationLabel(83), '1 分 23 秒');
    });
  });

  testWidgets('折叠态展示末尾摘要，点击后展开全文', (tester) async {
    await tester.pumpWidget(wrap(const ThinkingProcessView(thought: '先想第一步\n再想第二步')));

    expect(find.text('思考'), findsOneWidget);
    expect(find.text('先想第一步 再想第二步'), findsOneWidget);
    expect(find.byType(ThoughtTailScrollView), findsNothing);

    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsOneWidget);
    expect(find.text('先想第一步\n再想第二步'), findsOneWidget);
    expect(find.text('先想第一步 再想第二步'), findsNothing, reason: '标题行不再重复摘要');

    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsNothing);
  });

  testWidgets('折叠态短预览紧贴标题左侧，不被居中', (tester) async {
    await tester.pumpWidget(
      wrap(
        const Center(
          child: SizedBox(width: 600, child: ThinkingProcessView(thought: '简短回答。', durationSeconds: 2)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final durationRect = tester.getRect(find.text(' · 2 秒'));
    final previewRect = tester.getRect(find.text('简短回答。'));
    expect(previewRect.left - durationRect.right, closeTo(8, 1.5), reason: '预览应从耗时文案右侧 8px 开始；居中会把短预览推到行中间，看起来像一大段空白');
  });

  testWidgets('已结束的思考段展示耗时', (tester) async {
    await tester.pumpWidget(wrap(const ThinkingProcessView(thought: '思考完成', durationSeconds: 7)));

    expect(find.text(' · 7 秒'), findsOneWidget);
  });

  testWidgets('流式期间展示递增计时', (tester) async {
    await tester.pumpWidget(
      wrap(
        ThinkingProcessView(
          thought: '正在思考',
          isStreaming: true,
          startedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
      ),
    );
    // 呼吸动画持续运行，不能用 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining(' · 5 秒'), findsOneWidget);
  });

  testWidgets('流式结束后自动收起（未手动展开过）', (tester) async {
    await tester.pumpWidget(wrap(ThinkingProcessView(thought: '思考', isStreaming: true, startedAt: DateTime.now())));
    expect(find.byType(ThoughtTailScrollView), findsNothing);

    await tester.pumpWidget(wrap(const ThinkingProcessView(thought: '思考', durationSeconds: 3)));
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsNothing);
  });

  testWidgets('用户手动展开后，流式结束保持展开', (tester) async {
    await tester.pumpWidget(wrap(ThinkingProcessView(thought: '思考', isStreaming: true, startedAt: DateTime.now())));

    await tester.tap(find.byType(InkWell));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ThoughtTailScrollView), findsOneWidget);

    await tester.pumpWidget(wrap(const ThinkingProcessView(thought: '思考完成', durationSeconds: 5)));
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsOneWidget, reason: '手动展开过就不应被自动收起，否则会打断阅读');
  });
}

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

  group('latestThoughtLine', () {
    test('取最后一个非空行', () {
      expect(latestThoughtLine('第一行\n第二行'), '第二行');
    });

    test('结尾空行不会让最新一行变成空串', () {
      expect(latestThoughtLine('思考\n\n'), '思考');
    });

    test('整段不换行时返回整段', () {
      expect(latestThoughtLine('连续输出的一整段思考'), '连续输出的一整段思考');
    });

    test('空白文本返回空串', () {
      expect(latestThoughtLine('   \n \n'), '');
    });
  });

  testWidgets('折叠态只展示最新一行，点击后展开全文', (tester) async {
    await tester.pumpWidget(
      wrap(const ThinkingProcessView(thought: '先想第一步\n再想第二步')),
    );

    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('再想第二步'), findsOneWidget);
    expect(find.byType(ThoughtTailScrollView), findsNothing);

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsOneWidget);
    expect(find.text('先想第一步\n再想第二步'), findsOneWidget);
    expect(find.text('再想第二步'), findsNothing, reason: '标题行不再重复最新一行');

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsNothing);
  });

  testWidgets('流式期间文案为「思考中」', (tester) async {
    await tester.pumpWidget(
      wrap(const ThinkingProcessView(thought: '正在思考', isStreaming: true)),
    );

    expect(find.text('思考中'), findsOneWidget);
    expect(find.text('思考过程'), findsNothing);
  });

  testWidgets('未手动展开时，流式结束自动收起', (tester) async {
    await tester.pumpWidget(
      wrap(const ThinkingProcessView(thought: '思考', isStreaming: true)),
    );
    expect(find.byType(ThoughtTailScrollView), findsNothing);

    await tester.pumpWidget(
      wrap(const ThinkingProcessView(thought: '思考', isStreaming: false)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ThoughtTailScrollView), findsNothing);
  });

  testWidgets('用户手动展开后，流式结束保持展开', (tester) async {
    await tester.pumpWidget(
      wrap(const ThinkingProcessView(thought: '思考', isStreaming: true)),
    );

    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    expect(find.byType(ThoughtTailScrollView), findsOneWidget);

    await tester.pumpWidget(
      wrap(const ThinkingProcessView(thought: '思考完成', isStreaming: false)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(ThoughtTailScrollView),
      findsOneWidget,
      reason: '手动展开过就不应被自动收起，否则会打断阅读',
    );
  });
}

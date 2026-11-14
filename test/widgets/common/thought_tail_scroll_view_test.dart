import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/common/thought_tail_scroll_view.dart';

/// 思考过程滚动区的跟随行为回归：
/// 流式贴底不能和用户拖动抢滚动位置（此前会表现为「思考区滑不动」）。
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 320, height: 120, child: child)),
      ),
    );
  }

  String longThought({int lines = 80}) => List.generate(lines, (i) => '第 $i 行思考内容').join('\n');

  ScrollPosition positionOf(WidgetTester tester) {
    final scrollable = find.descendant(of: find.byType(ThoughtTailScrollView), matching: find.byType(Scrollable));
    return tester.state<ScrollableState>(scrollable).position;
  }

  testWidgets('默认贴底，新内容到达后继续跟随', (tester) async {
    await tester.pumpWidget(wrap(ThoughtTailScrollView(text: longThought())));
    await tester.pumpAndSettle();

    final position = positionOf(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, position.maxScrollExtent, reason: '打开时应直接看到最新一行');

    await tester.pumpWidget(wrap(ThoughtTailScrollView(text: '${longThought()}\n第 81 行')));
    await tester.pumpAndSettle();

    expect(position.pixels, position.maxScrollExtent, reason: '用户没离开底部时应持续跟随新内容');
  });

  testWidgets('用户向上阅读时，连续拖动不会被自动贴底拽回', (tester) async {
    await tester.pumpWidget(wrap(ThoughtTailScrollView(text: longThought())));
    await tester.pumpAndSettle();

    final position = positionOf(tester);
    final startOffset = position.pixels;

    // 小步拖动：旧实现会在每次滚动更新后把 _follow 重置为 true，
    // 并在下一帧贴底，手指每移动一点都被拽回 maxScrollExtent。
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ThoughtTailScrollView)));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(position.pixels, lessThan(startOffset - 40), reason: '拖动应真正改变阅读位置');
  });
}

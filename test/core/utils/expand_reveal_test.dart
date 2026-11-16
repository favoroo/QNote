import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/expand_reveal.dart';

/// 展开折叠区「最小露出」滚动规则的回归测试
void main() {
  /// 列表视口高 600：目标块从 300 开始，尾部留足可滚动空间
  Future<(GlobalKey, ScrollController)> pumpList(
    WidgetTester tester, {
    required double blockHeight,
    double initialOffset = 0,
  }) async {
    final key = GlobalKey();
    final controller = ScrollController(initialScrollOffset: initialOffset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: ListView(
              controller: controller,
              children: [
                const SizedBox(height: 300),
                SizedBox(
                  key: key,
                  height: blockHeight,
                  child: const ColoredBox(color: Colors.red),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (key, controller);
  }

  double? offsetFor(GlobalKey key, ScrollController controller) {
    final target = key.currentContext!.findRenderObject()!;
    return expandedRevealOffset(target, controller.position);
  }

  testWidgets('内容超出视口下沿时，只下滑到刚好看全', (tester) async {
    final (key, controller) = await pumpList(tester, blockHeight: 500);
    // 块 [300, 800] 只露出一半，下滑到 800 - 600 + 12 = 212
    expect(offsetFor(key, controller), moreOrLessEquals(212, epsilon: 0.01));
  });

  testWidgets('内容已完整可见时不滚动', (tester) async {
    final (key, controller) = await pumpList(tester, blockHeight: 500, initialOffset: 300);
    expect(offsetFor(key, controller), isNull);
  });

  testWidgets('仅部分露出时按最小距离下滑', (tester) async {
    final (key, controller) = await pumpList(tester, blockHeight: 500, initialOffset: 100);
    expect(offsetFor(key, controller), moreOrLessEquals(212, epsilon: 0.01));
  });

  testWidgets('内容比视口还高时，顶部对齐视口顶部', (tester) async {
    final (key, controller) = await pumpList(tester, blockHeight: 700);
    expect(offsetFor(key, controller), moreOrLessEquals(300, epsilon: 0.01));
  });

  testWidgets('内容整体在视口上方时不往回滚', (tester) async {
    final (key, controller) = await pumpList(tester, blockHeight: 500, initialOffset: 1000);
    expect(offsetFor(key, controller), isNull);
  });
}

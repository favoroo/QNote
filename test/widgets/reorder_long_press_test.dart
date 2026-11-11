import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定「整行长按拾起」的手势契约。
///
/// 待办页依赖 [ReorderableDelayedDragStartListener]（500ms 延迟拖拽）来接管整行，
/// 再用原始指针轨迹区分「长按后拖拽排序」与「长按后原地松手弹菜单」。
/// 这里把两个前提钉住：
/// 1. 按住 500ms 不动会真正进入拖拽态（onReorderStart 触发）；
/// 2. 原地松手不会产生排序（onReorderItem 不触发，落点仍是原下标）。
/// 3. 长按后向下拖动会真的改写顺序。
void main() {
  Widget buildList({
    required VoidCallback onStart,
    required void Function(int oldIndex, int newIndex) onReorder,
    required void Function(int index) onEnd,
  }) {
    const items = ['A', 'B', 'C'];
    return MaterialApp(
      home: Scaffold(
        body: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: items.length,
          onReorderStart: (_) => onStart(),
          onReorderEnd: onEnd,
          onReorderItem: onReorder,
          itemBuilder: (context, index) {
            return ReorderableDelayedDragStartListener(
              key: ValueKey(items[index]),
              index: index,
              child: SizedBox(height: 60, child: Center(child: Text(items[index]))),
            );
          },
        ),
      ),
    );
  }

  testWidgets('长按拾起后原地松手：进入拖拽态但不改变顺序', (tester) async {
    var started = 0;
    int? reorderedFrom;
    int? endIndex;

    await tester.pumpWidget(
      buildList(
        onStart: () => started++,
        onReorder: (oldIndex, newIndex) {
          reorderedFrom = oldIndex;
        },
        onEnd: (index) => endIndex = index,
      ),
    );

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 600));

    // 500ms 延迟已过：拖拽态成立，可据此弹「拾起」反馈
    expect(started, 1);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(endIndex, 0, reason: '原地松手的落点应仍是原下标');
    expect(reorderedFrom, isNull, reason: '没有移动就不该发生排序');
  });

  testWidgets('长按拾起后向下拖动：改写顺序', (tester) async {
    var started = 0;
    int? reorderedFrom;
    int? reorderedTo;

    await tester.pumpWidget(
      buildList(
        onStart: () => started++,
        onReorder: (oldIndex, newIndex) {
          reorderedFrom = oldIndex;
          reorderedTo = newIndex;
        },
        onEnd: (_) {},
      ),
    );

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(started, 1);

    // 越过一行的高度（60px）即可让落点跨过下一个条目
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorderedFrom, 0);
    expect(reorderedTo, isNotNull, reason: '向下拖动应触发排序');
    expect(reorderedTo! > 0, isTrue, reason: '条目应被移到更靠后的位置');
  });
}

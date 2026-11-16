import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';

DiaryRecord _record() {
  return DiaryRecord(
    id: 'r1',
    title: '早餐',
    time: DateTime(2026, 11, 11, 9),
    content: '250ml牛奶，加一点点咖啡',
    createdAt: DateTime(2026, 11, 11, 9),
    updatedAt: DateTime(2026, 11, 11, 9),
  );
}

/// 读取带 [key] 的切换子项当前的不透明度；子项已被移出树时视为 0。
///
/// 图标切换由 AnimatedSwitcher 的 FadeTransition 驱动，这里沿祖先链找回它，
/// 用来判断某一帧里是否同时存在「旧图标 + 新图标」（重影）。
double _opacityOf(WidgetTester tester, Key key) {
  final elements = find.byKey(key).evaluate();
  if (elements.isEmpty) return 0;
  var value = 1.0;
  elements.first.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is FadeTransition) {
      value = widget.opacity.value;
      return false;
    }
    return true;
  });
  return value;
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with SingleTickerProviderStateMixin {
  // 倒计时控制器由页面持有；这里固定到终态，只验证「切回待提取态」这一步的过渡。
  late final AnimationController controller = AnimationController(vsync: this, duration: const Duration(seconds: 15))
    ..value = 1;

  bool undoable = true;

  void finishCountdown() {
    setState(() => undoable = false);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            DiaryItem(
              record: _record(),
              onAiExtract: () {},
              onUndo: () {},
              isUndoable: undoable,
              // 与真实页面一致：倒计时结束后把动画置空，但控制器本身要等退场动画
              // 播完才释放。退场旧子树会捕获控制器，不能在这里重新读 null。
              undoAnimation: undoable ? controller : null,
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('撤回倒计时结束回到待提取态时，新旧图标不重叠成重影', (tester) async {
    final harnessKey = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: harnessKey));
    await tester.pump();

    // 起始处于可撤回态：显示倒计时圆环 + 撤回图标。
    expect(find.byKey(const ValueKey('undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('idle')), findsNothing);
    expect(tester.takeException(), isNull);

    harnessKey.currentState!.finishCountdown();
    await tester.pump();

    // 逐帧检查整个切换过程：
    // 1. 任一帧都不允许新旧图标同时可辨（旧代码的等时交叉淡入会重影）；
    // 2. 置空 undoAnimation 后，退场旧子树不能解引用 null 抛异常
    //    （release 下会被替换成 32×32 的灰色 ErrorWidget，正是按钮位置闪过的方块）。
    for (var i = 0; i < 12; i++) {
      expect(tester.takeException(), isNull, reason: '第 $i 帧撤回退场子树抛异常，会闪出灰色方块');
      final undoOpacity = _opacityOf(tester, const ValueKey('undo'));
      final idleOpacity = _opacityOf(tester, const ValueKey('idle'));
      expect(
        undoOpacity > 0.15 && idleOpacity > 0.15,
        isFalse,
        reason: '第 $i 帧新旧图标同时可见（undo=$undoOpacity idle=$idleOpacity），会出现闪动重影',
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);

    // 切换完成后只剩待提取图标。
    expect(find.byKey(const ValueKey('undo')), findsNothing);
    expect(find.byKey(const ValueKey('idle')), findsOneWidget);
  });
}

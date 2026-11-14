import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/action_menu.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );
  }

  testWidgets('ActionMenu.showAt 根据锚点象限动态决定缩放原点并支持收起关闭', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late BuildContext capturedCtx;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) {
            capturedCtx = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );

    // 左上锚点：菜单位于下方且锚点偏左，缩放原点应朝左上方（x <= 0, y == -1）
    ActionMenu.showAt(
      context: capturedCtx,
      position: const Offset(24, 40),
      items: [ActionMenuItem(icon: Icons.edit, label: '编辑', onTap: () {})],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 外层菜单本身有一层 ScaleTransition（菜单行内的 PressableScale 也会生成内层 ScaleTransition，因此取最外层祖先）。
    final topLeftScale = tester.widget<ScaleTransition>(
      find.ancestor(of: find.text('编辑'), matching: find.byType(ScaleTransition)).last,
    );
    final topLeftAlignment = topLeftScale.alignment;
    expect(topLeftAlignment.y, -1.0);
    expect(topLeftAlignment.x, lessThanOrEqualTo(0.0));

    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);

    // 点击菜单项会触发 dismiss，等待退出动画完成
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsNothing);

    // 右下锚点：菜单需要向上弹出，缩放原点应朝右下方（x >= 0, y == 1）
    ActionMenu.showAt(
      context: capturedCtx,
      position: const Offset(760, 560),
      items: [ActionMenuItem(icon: Icons.delete, label: '删除', onTap: () {}, isDestructive: true)],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final bottomRightScale = tester.widget<ScaleTransition>(
      find.ancestor(of: find.text('删除'), matching: find.byType(ScaleTransition)).last,
    );
    final bottomRightAlignment = bottomRightScale.alignment;
    expect(bottomRightAlignment.y, 1.0);
    expect(bottomRightAlignment.x, greaterThanOrEqualTo(0.0));

    ActionMenu.dismiss(immediate: true);
    await tester.pump();
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('ActionMenu.showForContext 按锚点 Context 位置弹出并支持未挂载兜底', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late BuildContext pageCtx;
    late BuildContext anchorCtx;

    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) {
            pageCtx = context;
            return Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 40, right: 24),
                child: Builder(
                  builder: (ctx) {
                    anchorCtx = ctx;
                    return const SizedBox(width: 80, height: 32, child: Text('日期'));
                  },
                ),
              ),
            );
          },
        ),
      ),
    );

    ActionMenu.showForContext(
      context: pageCtx,
      anchorContext: anchorCtx,
      items: [ActionMenuItem(icon: Icons.palette_outlined, label: '标色', onTap: () {})],
    );
    await tester.pumpAndSettle();

    expect(find.text('标色'), findsOneWidget);
    final anchorBox = anchorCtx.findRenderObject()! as RenderBox;
    final anchorRect = anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
    final menuTop = tester.getTopLeft(find.text('标色')).dy;
    // 锚点位于顶部时菜单应展开在锚点底部附近
    expect(menuTop, greaterThanOrEqualTo(anchorRect.bottom));

    ActionMenu.dismiss(immediate: true);
    await tester.pump();
    expect(find.text('标色'), findsNothing);
  });
}

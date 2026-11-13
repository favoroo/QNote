import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/common/app_collapsible.dart';

void main() {
  Widget wrap(Widget child, {bool disableAnimations = false}) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  group('AppCollapsible', () {
    testWidgets('初始折叠时不构建子组件，初始展开时稳态直出子组件且无多余过渡层', (tester) async {
      await tester.pumpWidget(wrap(const AppCollapsible(expanded: false, child: Text('hidden_body'))));
      expect(find.text('hidden_body'), findsNothing);

      await tester.pumpWidget(wrap(const AppCollapsible(expanded: true, child: Text('visible_body'))));
      // 从 false 切到 true 会先播放展开动画
      expect(find.text('visible_body'), findsOneWidget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(SizeTransition)), findsOneWidget);

      await tester.pumpAndSettle();
      // 展开动画结束后应卸载 ClipRect/SizeTransition/FadeTransition 包装层
      expect(find.text('visible_body'), findsOneWidget);
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(SizeTransition)), findsNothing);
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(FadeTransition)), findsNothing);
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(ClipRect)), findsNothing);
    });

    testWidgets('以 expanded=true 挂载时直接进入稳态，不携带多余过渡层', (tester) async {
      await tester.pumpWidget(wrap(const AppCollapsible(expanded: true, child: Text('initial_visible'))));
      expect(find.text('initial_visible'), findsOneWidget);
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(SizeTransition)), findsNothing);
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(ClipRect)), findsNothing);
    });

    testWidgets('收起动画完成后移除子组件', (tester) async {
      await tester.pumpWidget(wrap(const AppCollapsible(expanded: true, child: Text('collapsible_item'))));
      expect(find.text('collapsible_item'), findsOneWidget);

      await tester.pumpWidget(wrap(const AppCollapsible(expanded: false, child: Text('collapsible_item'))));
      await tester.pumpAndSettle();
      expect(find.text('collapsible_item'), findsNothing);
    });

    testWidgets('减弱动态效果开启时一帧完成展开与收起且无过渡包装层', (tester) async {
      await tester.pumpWidget(
        wrap(const AppCollapsible(expanded: false, child: Text('reduced_item')), disableAnimations: true),
      );
      expect(find.text('reduced_item'), findsNothing);

      await tester.pumpWidget(
        wrap(const AppCollapsible(expanded: true, child: Text('reduced_item')), disableAnimations: true),
      );
      await tester.pump();
      expect(find.text('reduced_item'), findsOneWidget);
      expect(find.descendant(of: find.byType(AppCollapsible), matching: find.byType(SizeTransition)), findsNothing);

      await tester.pumpWidget(
        wrap(const AppCollapsible(expanded: false, child: Text('reduced_item')), disableAnimations: true),
      );
      await tester.pump();
      expect(find.text('reduced_item'), findsNothing);
    });
  });
}

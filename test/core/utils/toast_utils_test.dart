import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

void main() {
  // 显式给 1 秒停留：既长于入场动画的推进量（可稳定断言在屏），
  // 又能在收尾的等待窗口内到期，避免用例结束残留挂起 Timer
  const hold = Duration(seconds: 1);

  /// Toast 入场动画 250ms：先 pump 一帧让 entry 完成 initState，再推进动画时长
  Future<void> settleToast(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 排干自动消失 Timer 与滑出动画
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  group('Toast', () {
    testWidgets('show(context) 仍正常挂载（委托给 showIn 之后的回归保障）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      final context = tester.element(find.byType(Scaffold));

      Toast.show(context, '已保存', type: ToastType.success, duration: hold);
      await settleToast(tester);

      expect(find.text('已保存'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await drainToast(tester);
    });

    testWidgets('showIn 与 show 共用同一单槽，后来者顶掉前一条', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      final context = tester.element(find.byType(Scaffold));
      final overlay = Overlay.of(context);

      Toast.show(context, '第一条', duration: hold);
      await settleToast(tester);
      expect(find.text('第一条'), findsOneWidget);

      Toast.showIn(overlay, '第二条', duration: hold);
      await settleToast(tester);

      expect(find.text('第一条'), findsNothing);
      expect(find.text('第二条'), findsOneWidget);

      await drainToast(tester);
    });
  });
}

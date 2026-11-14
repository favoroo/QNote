import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/common/pressable_scale.dart';

void main() {
  testWidgets('仅有 onTap 时不注册长按识别器，祖先长按仍可触发', (tester) async {
    var outerLongPressStarted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) => outerLongPressStarted = true,
            child: const PressableScale(
              // 只给 onTap：按压缩放反馈不该因此引入长按识别器
              onTap: _noop,
              child: SizedBox(width: 200, height: 80),
            ),
          ),
        ),
      ),
    );

    // 按住不放超过长按判定时长：胜利者应是祖先，而不是 PressableScale
    final gesture = await tester.startGesture(tester.getCenter(find.byType(PressableScale)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(outerLongPressStarted, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('提供 onLongPress 时自身长按正常触发', (tester) async {
    var innerLongPress = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PressableScale(
              onTap: _noop,
              onLongPress: () => innerLongPress = true,
              child: const SizedBox(width: 200, height: 80),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(PressableScale));
    await tester.pumpAndSettle();
    expect(innerLongPress, isTrue);
  });
}

void _noop() {}

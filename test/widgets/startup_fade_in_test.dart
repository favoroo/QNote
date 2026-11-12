import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/startup_fade_in.dart';

/// 只找 [StartupFadeIn] 自己那一层，避开 MaterialApp 路由转场自带的 FadeTransition。
final Finder _ownFade = find.descendant(of: find.byType(StartupFadeIn), matching: find.byType(FadeTransition));

void main() {
  testWidgets('首帧从非零透明度起步，动画结束后移除透明度图层', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StartupFadeIn(child: Scaffold(body: Text('内容'))),
      ),
    );

    // 起步就不能是全透明：否则首帧会先露出一段空屏，观感比闪变更差
    expect(_ownFade, findsOneWidget);
    final start = tester.widget<FadeTransition>(_ownFade).opacity.value;
    expect(start, greaterThan(0.9));
    expect(start, lessThan(1.0));

    await tester.pumpAndSettle();

    // 动画跑完必须把这层摘掉，后续滚动/切页不再多一层合成
    expect(_ownFade, findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('系统开启减弱动效时直接呈现终态', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: StartupFadeIn(child: Scaffold(body: Text('内容'))),
        ),
      ),
    );
    await tester.pump();

    expect(_ownFade, findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });
}

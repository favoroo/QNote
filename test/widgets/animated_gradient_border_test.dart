import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';

/// 只找流光描边自己的 CustomPaint，避免把 Material 内部绘制的 CustomPaint 算进来。
Finder _shimmerPainter() {
  return find.byWidgetPredicate((widget) => widget is CustomPaint && widget.foregroundPainter is GradientBorderPainter);
}

Widget _card({required bool extracting}) {
  return AnimatedGradientBorder(
    isAnimating: extracting,
    child: const SizedBox(width: 200, height: 80, child: ColoredBox(color: Color(0xFF111318))),
  );
}

Widget _app({required bool extracting, bool reduceMotion = false}) {
  return MaterialApp(
    theme: AppTheme.darkTheme(const Color(0xFF00E5FF)),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        body: Center(child: _card(extracting: extracting)),
      ),
    ),
  );
}

void main() {
  testWidgets('提取开始后出现流光，结束后先淡出再移除描边', (tester) async {
    var extracting = false;
    late StateSetter rebuild;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _app(extracting: extracting);
        },
      ),
    );

    expect(_shimmerPainter(), findsNothing, reason: '未提取时不应有常驻流光');

    rebuild(() => extracting = true);
    // forward() 要等 ticker 落下第一帧才会离开 0，淡入本来就从透明开始。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_shimmerPainter(), findsOneWidget);

    rebuild(() => extracting = false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_shimmerPainter(), findsOneWidget, reason: '结束瞬间应保留描边，让淡出看得见');

    await tester.pump(const Duration(milliseconds: 200));
    expect(_shimmerPainter(), findsNothing);
  });

  testWidgets('减弱动效下保留静态柔光，且不会留下永不停歇的动画', (tester) async {
    await tester.pumpWidget(_app(extracting: true, reduceMotion: true));

    expect(_shimmerPainter(), findsOneWidget);
    // 静态模式没有 ticker 在跑，pumpAndSettle 不应超时。
    await tester.pumpAndSettle();
    expect(_shimmerPainter(), findsOneWidget);
  });
}

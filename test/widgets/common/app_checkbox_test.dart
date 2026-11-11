import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/common/app_checkbox.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('勾选框始终是圆角矩形，选中时显示对勾', (tester) async {
    await tester.pumpWidget(wrap(const AppCheckbox(value: true)));

    final container = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(6));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('提供 onTap 时点击可切换', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(AppCheckbox(value: false, onTap: () => taps++)));

    await tester.tap(find.byType(AppCheckbox));
    expect(taps, 1);
  });

  testWidgets('未提供 onTap 时仅作视觉指示器，不拦截父级点击', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(GestureDetector(onTap: () => taps++, child: const AppCheckbox(value: false))));

    await tester.tap(find.byType(AppCheckbox));
    expect(taps, 1);
  });
}

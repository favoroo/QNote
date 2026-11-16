import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/widgets/ai/chat_empty_state.dart';

/// 新建对话空态：居中的 Hi 与主题色圆点
void main() {
  testWidgets('居中展示 Hi，并在其后带一枚主题色圆点', (tester) async {
    final theme = AppTheme.lightTheme(const Color(0xFFE53935));

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: ChatEmptyState()),
      ),
    );
    await tester.pump();

    expect(find.text('Hi'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat_empty_dot')), findsOneWidget);
    // 已移除呼吸光标
    expect(find.byKey(const ValueKey('chat_empty_caret')), findsNothing);

    final dot = tester.widget<Container>(find.byKey(const ValueKey('chat_empty_dot')));
    final decoration = dot.decoration! as BoxDecoration;
    expect(decoration.color, theme.colorScheme.primary);
    expect(decoration.shape, BoxShape.circle);

    final textRect = tester.getRect(find.text('Hi'));
    final dotRect = tester.getRect(find.byKey(const ValueKey('chat_empty_dot')));
    // 圆点在 Hi 右侧，并下沉到接近基线的位置
    expect(dotRect.left, greaterThan(textRect.right));
    expect(dotRect.center.dy, greaterThan(textRect.center.dy));

    // 空态整体位于聊天区正中间（文字中心会因右侧圆点略微偏左）
    final screen = tester.getSize(find.byType(Scaffold));
    expect(textRect.center.dx, closeTo(screen.width / 2 - 10, 12));
    expect(textRect.center.dy, closeTo(screen.height / 2, 8));
  });
}

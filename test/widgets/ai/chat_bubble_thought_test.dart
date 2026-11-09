import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/widgets/ai/bubble_action_bar.dart';
import 'package:qnote_flutter/widgets/common/thinking_process_view.dart';

/// 思考步骤行的渲染回归：角色为 thought 的消息独立成行，不套气泡、不给操作条
void main() {
  Widget harness(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  testWidgets('thought 步骤行展示「思考」与最新一行，可展开全文', (tester) async {
    await tester.pumpWidget(
      harness(
        ChatBubble(
          message: ChatMessage(
            role: 'thought',
            content: '第一步\n第二步',
            thoughtSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ThinkingProcessView), findsOneWidget);
    expect(find.text('思考'), findsOneWidget);
    expect(find.text(' · 4 秒'), findsOneWidget);
    expect(find.text('第二步'), findsOneWidget);

    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();

    expect(find.text('第一步\n第二步'), findsOneWidget);
  });

  testWidgets('thought 步骤行不给操作条', (tester) async {
    await tester.pumpWidget(
      harness(
        ChatBubble(message: ChatMessage(role: 'thought', content: '想一下')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BubbleActionBar), findsNothing);
  });
}

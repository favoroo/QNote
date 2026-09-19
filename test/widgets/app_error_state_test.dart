import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';

/// 把组件放进限定尺寸的内容区，贴近各页面 `AsyncValue.when(error:)` 的真实用法
Future<void> _pumpIn(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  double height = 600,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: width, height: height, child: child),
      ),
    ),
  );
}

void main() {
  group('AppErrorState', () {
    testWidgets('默认态展示失败动作、异常线索与重试入口', (tester) async {
      var retryCount = 0;
      await _pumpIn(
        tester,
        AppErrorState(
          error: Exception('database is locked'),
          action: '加载笔记失败',
          onRetry: () => retryCount++,
        ),
      );

      expect(find.text('加载笔记失败'), findsOneWidget);
      expect(find.textContaining('database is locked'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pump();
      expect(retryCount, 1);
    });

    testWidgets('未传 action 时使用默认文案，避免出现空白标题', (tester) async {
      await _pumpIn(
        tester,
        AppErrorState(error: StateError('boom'), onRetry: () {}),
      );

      expect(find.text('加载失败'), findsOneWidget);
    });

    testWidgets('compact 态用轻量按钮，适配抽屉与 Stack 局部区域', (tester) async {
      await _pumpIn(
        tester,
        AppErrorState(
          error: Exception('network unreachable'),
          action: '加载历史对话失败',
          compact: true,
          onRetry: () {},
        ),
      );

      expect(find.textContaining('network unreachable'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
      // 紧凑态不应带出整屏卡片式的重图标底衬
      expect(find.widgetWithText(FilledButton, '重试'), findsNothing);
    });

    testWidgets('长异常串在 320 窄屏下不溢出不抛渲染异常', (tester) async {
      final longError = Exception('${'连接超时 ' * 40}details: tunnel unreachable');

      for (final compact in [false, true]) {
        await _pumpIn(
          tester,
          AppErrorState(
            error: longError,
            action: '加载记录失败',
            compact: compact,
            onRetry: () {},
          ),
          width: 320,
        );

        expect(find.textContaining('tunnel unreachable'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('深色主题下同样可渲染（错误色走 scheme，不硬编码）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AppErrorState(error: Exception('denied'), onRetry: () {}),
          ),
        ),
      );

      expect(find.text('加载失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

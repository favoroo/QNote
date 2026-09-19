import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/unsaved_changes_dialog.dart';

void main() {
  /// 宿主页面：点「离开」触发确认框，把返回值记到 resultLabel 上供断言
  Future<void> pumpHost(
    WidgetTester tester, {
    Future<void> Function()? onSave,
    String content = '有未保存的更改，离开后将丢失。',
    required void Function(bool canLeave) onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onResult(
                  await promptUnsavedChanges(
                    context,
                    content: content,
                    onSave: onSave,
                  ),
                );
              },
              child: const Text('leave'),
            ),
          ),
        ),
      ),
    );
  }

  group('promptUnsavedChanges', () {
    testWidgets('保存成功后才允许离开', (tester) async {
      var saved = false;
      bool? result;
      await pumpHost(
        tester,
        onSave: () async => saved = true,
        onResult: (canLeave) => result = canLeave,
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      expect(find.text('未保存的更改'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(saved, isTrue);
      expect(result, isTrue);
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('保存抛错时留在原页并提示，绝不放行离开', (tester) async {
      bool? result;
      await pumpHost(
        tester,
        onSave: () async => throw Exception('database is locked'),
        onResult: (canLeave) => result = canLeave,
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.textContaining('database is locked'), findsOneWidget);

      // 排干 Toast 的 3 秒自动消失定时器，否则用例结束时报「Timer 仍在挂起」
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('选「放弃更改」直接放行且不再写库', (tester) async {
      var saved = false;
      bool? result;
      await pumpHost(
        tester,
        onSave: () async => saved = true,
        onResult: (canLeave) => result = canLeave,
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(saved, isFalse);
    });

    testWidgets('选「取消」不放行', (tester) async {
      bool? result;
      await pumpHost(tester, onResult: (canLeave) => result = canLeave);

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('无保存能力时不出现「保存」按钮', (tester) async {
      await pumpHost(tester, onResult: (_) {});

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();

      expect(find.text('保存'), findsNothing);
      expect(find.text('放弃更改'), findsOneWidget);
    });

    testWidgets('自定义文案生效，供不同页面复用同一对话框', (tester) async {
      await pumpHost(
        tester,
        content: '这条记录有未保存的修改，离开将丢失。',
        onResult: (_) {},
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();

      expect(find.text('这条记录有未保存的修改，离开将丢失。'), findsOneWidget);
    });
  });
}

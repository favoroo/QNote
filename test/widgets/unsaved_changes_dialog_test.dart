import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/unsaved_changes_dialog.dart';

void main() {
  /// 排干 Toast 的自动消失定时器，避免用例结束时报「Timer 仍在挂起」
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
  }

  /// 宿主页面：点「离开」触发确认框，把返回值回传给断言
  Future<void> pumpHost(
    WidgetTester tester, {
    Future<bool> Function()? onSave,
    String content = '有未保存的更改，离开后将丢失。',
    String? failureMessage,
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
                    failureMessage: failureMessage ?? '未能保存，仍停在当前页',
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
        onSave: () async {
          saved = true;
          return true;
        },
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

    testWidgets('onSave 返回 false 时留在原页并提示，绝不放行离开', (tester) async {
      bool? result;
      await pumpHost(
        tester,
        onSave: () async => false,
        onResult: (canLeave) => result = canLeave,
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(find.text('未能保存，仍停在当前页'), findsOneWidget);
      // 提示的是通用文案，不把异常对象拼进用户可见文本
      expect(find.textContaining('Exception'), findsNothing);

      await drainToast(tester);
    });

    testWidgets('onSave 抛异常同样按失败处理，不让异常逃到调用方', (tester) async {
      bool? result;
      await pumpHost(
        tester,
        onSave: () async => throw StateError('boom'),
        failureMessage: '写库失败，请重试',
        onResult: (canLeave) => result = canLeave,
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(find.text('写库失败，请重试'), findsOneWidget);

      await drainToast(tester);
    });

    testWidgets('选「放弃更改」直接放行且不再写库', (tester) async {
      var saveCalled = false;
      bool? result;
      await pumpHost(
        tester,
        onSave: () async {
          saveCalled = true;
          return true;
        },
        onResult: (canLeave) => result = canLeave,
      );

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(saveCalled, isFalse);
    });

    testWidgets('选「取消」不放行', (tester) async {
      bool? result;
      await pumpHost(
        tester,
        onSave: () async => true,
        onResult: (canLeave) => result = canLeave,
      );

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

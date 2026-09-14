import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';

/// 包装观察者：转发 didPush/didRemove/didReplace 但吞掉 didPop，
/// 模拟"弹层关闭事件丢失"，验证动画 dismissed 自愈剔除逻辑
class _SkipDidPopObserver extends NavigatorObserver {
  _SkipDidPopObserver(this._inner);
  final FloatingQModalRouteObserver _inner;

  @override
  void didPush(Route route, Route? previousRoute) =>
      _inner.didPush(route, previousRoute);

  @override
  void didRemove(Route route, Route? previousRoute) =>
      _inner.didRemove(route, previousRoute);

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) =>
      _inner.didReplace(newRoute: newRoute, oldRoute: oldRoute);

  // didPop 故意不转发
}

Widget _host(List<NavigatorObserver> observers) => MaterialApp(
      navigatorObservers: observers,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AlertDialog(title: Text('dialog')),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    // 全局计数器在测试间复位
    floatingQModalCount.value = 0;
  });

  testWidgets('对话框打开/关闭正常计数', (tester) async {
    final observer = FloatingQModalRouteObserver();
    await tester.pumpWidget(_host([observer]));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(floatingQModalCount.value, 1);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(floatingQModalCount.value, 0);
  });

  testWidgets('多层弹窗叠加计数，全部关闭后归零', (tester) async {
    final observer = FloatingQModalRouteObserver();
    late final BuildContext hostContext;
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [observer],
      home: Builder(
        builder: (context) {
          hostContext = context;
          return const Scaffold(body: SizedBox());
        },
      ),
    ));

    showDialog<void>(
      context: hostContext,
      builder: (_) => const AlertDialog(title: Text('dialog-1')),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: hostContext,
      builder: (_) => const AlertDialog(title: Text('dialog-2')),
    );
    await tester.pumpAndSettle();
    expect(floatingQModalCount.value, 2);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator
      ..pop()
      ..pop();
    await tester.pumpAndSettle();
    expect(floatingQModalCount.value, 0);
  });

  testWidgets('didPop 事件丢失时动画 dismissed 触发自愈剔除', (tester) async {
    // 正常路径会转发的观察者被 _SkipDidPopObserver 包裹，didPop 被吞掉
    final inner = FloatingQModalRouteObserver();
    await tester.pumpWidget(_host([_SkipDidPopObserver(inner)]));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(floatingQModalCount.value, 1);

    // pop 后 didPop 未转发（计数本应卡在 1），但弹层动画回到 dismissed
    // 应触发自愈剔除，计数归零——防止悬浮球被永久隐藏
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(floatingQModalCount.value, 0);
  });
}

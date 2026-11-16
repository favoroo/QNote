import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/agent_exit_guard.dart';

/// 验证守卫对系统返回的处置。
///
/// 核心断言是 `PopScope.canPop`：它决定框架是否把返回交回 Dart。根路由若没有
/// `PopScope`（或恒为 true），`targetSdk=35` 下 Android 预测性返回会由系统直接
/// 结束 Activity，任务当场断掉——这正是本次要守住的行为。
void main() {
  Widget host({
    required bool panelRunning,
    required bool panelOpen,
    required bool fullPageRunning,
    _FakeFloatingQNotifier? notifier,
  }) {
    final fake = notifier ?? _FakeFloatingQNotifier(panelRunning: panelRunning, panelOpen: panelOpen);
    return ProviderScope(
      overrides: [
        floatingQProvider.overrideWith(() => fake),
        agentRunningSessionsProvider.overrideWith((ref) => fullPageRunning ? {'session-1'} : <String>{}),
      ],
      child: const MaterialApp(
        home: AgentExitGuard(child: Scaffold(body: Text('root'))),
      ),
    );
  }

  /// PopScope 是泛型类，`find.byType(PopScope)` 匹配不到 `PopScope<Object?>`。
  PopScope<Object?> guardScope(WidgetTester tester) {
    return tester.widget<PopScope<Object?>>(find.byWidgetPredicate((w) => w is PopScope).first);
  }

  testWidgets('无任务、面板收起：不拦截（canPop 为 true）', (tester) async {
    await tester.pumpWidget(host(panelRunning: false, panelOpen: false, fullPageRunning: false));
    expect(guardScope(tester).canPop, isTrue);
  });

  testWidgets('悬浮面板展开：拦截返回', (tester) async {
    await tester.pumpWidget(host(panelRunning: false, panelOpen: true, fullPageRunning: false));
    expect(guardScope(tester).canPop, isFalse);
  });

  testWidgets('悬浮面板任务进行中：拦截返回', (tester) async {
    await tester.pumpWidget(host(panelRunning: true, panelOpen: false, fullPageRunning: false));
    expect(guardScope(tester).canPop, isFalse);
  });

  testWidgets('/ai 全页面任务进行中：拦截返回', (tester) async {
    await tester.pumpWidget(host(panelRunning: false, panelOpen: false, fullPageRunning: true));
    expect(guardScope(tester).canPop, isFalse);
  });

  testWidgets('面板展开且任务进行中：返回只收面板，不弹退出确认', (tester) async {
    final fake = _FakeFloatingQNotifier(panelRunning: true, panelOpen: true);
    await tester.pumpWidget(host(panelRunning: true, panelOpen: true, fullPageRunning: false, notifier: fake));

    // 模拟系统返回被 PopScope 拦下（didPop=false）
    guardScope(tester).onPopInvokedWithResult?.call(false, null);
    await tester.pump();

    expect(fake.minimized, isTrue, reason: '面板展开时返回应先最小化成气泡');
    expect(find.text('小Q 正在工作中'), findsNothing, reason: '收面板的同一帧不应再弹退出确认');
  });

  testWidgets('任务进行中且面板收起：返回弹出退出确认', (tester) async {
    await tester.pumpWidget(host(panelRunning: true, panelOpen: false, fullPageRunning: false));

    guardScope(tester).onPopInvokedWithResult?.call(false, null);
    await tester.pumpAndSettle();

    expect(find.text('小Q 正在工作中'), findsOneWidget);
    expect(find.text('继续等待'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
  });
}

/// 只覆写守卫关心的两个字段（runActive / panelMode）。
///
/// 真实 notifier 的 `build` 会读路由上下文并挂一堆联动，widget 测试里没必要拉起。
class _FakeFloatingQNotifier extends FloatingQNotifier {
  _FakeFloatingQNotifier({required this.panelRunning, required this.panelOpen});

  final bool panelRunning;
  final bool panelOpen;

  bool minimized = false;

  @override
  FloatingQState build() => FloatingQState(
    runActive: panelRunning,
    panelMode: panelOpen ? FloatingQPanelMode.panel : FloatingQPanelMode.hidden,
  );

  @override
  void minimizePanel() {
    minimized = true;
  }
}

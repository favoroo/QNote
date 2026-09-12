import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/floating_q/floating_q_overlay.dart';
/// 测试宿主：与真实挂载方式一致（MaterialApp.builder 内用局部 Overlay 叠
/// FloatingQOverlay，面板内 Tooltip 依赖该 Overlay），仅用极简 GoRouter 覆盖
/// routerProvider（FloatingQOverlay initState 会读取），面板开合只依赖
/// floatingQProvider 的状态翻转，无需真实页面路由
Widget _host() {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
    ],
  );
  return ProviderScope(
    overrides: [routerProvider.overrideWithValue(router)],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => Stack(
        children: [
          child!,
          Overlay(
            initialEntries: [
              OverlayEntry(builder: (_) => const FloatingQOverlay()),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 通过 provider 直接驱动面板开合（悬浮球用原始 Listener 处理指针，
/// 状态驱动比手势模拟更稳，转场动画由 overlay 的 widget 层负责）
void _setPanelOpen(WidgetTester tester, bool open) {
  final context = tester.element(find.byType(FloatingQOverlay));
  final container = ProviderScope.containerOf(context, listen: false);
  open
      ? container.read(floatingQProvider.notifier).openPanel()
      : container.read(floatingQProvider.notifier).closePanel();
}

/// 取悬浮层最外层的 IgnorePointer（控制整层禁点）：
/// 外层距根最近，取全部 IgnorePointer 中深度最小者即可精确定位
IgnorePointer _outerIgnorePointer(WidgetTester tester) {
  final outer = find
      .byType(IgnorePointer)
      .evaluate()
      .reduce((a, b) => a.depth < b.depth ? a : b);
  return outer.widget as IgnorePointer;
}

void main() {
  setUp(() {
    // 全局模态计数器在测试间复位
    floatingQModalCount.value = 0;
  });

  testWidgets('初始只渲染悬浮球，面板不挂载', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ball')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel')), findsNothing);
  });

  testWidgets('打开面板：转场中球与面板共存，结束后球移除面板驻留', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    _setPanelOpen(tester, true);
    // 转场进行中：出场的球与入场的面板同时存在（交叉过渡）
    await tester.pump();
    expect(find.byKey(const ValueKey('ball')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ball')), findsNothing);
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
  });

  testWidgets('关闭面板：转场中面板与球共存，结束后面板移除球弹回', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    _setPanelOpen(tester, true);
    await tester.pumpAndSettle();

    _setPanelOpen(tester, false);
    await tester.pump();
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('ball')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel')), findsNothing);
    expect(find.byKey(const ValueKey('ball')), findsOneWidget);
  });

  testWidgets('模态打开时悬浮层淡出禁点但保持挂载，关闭后输入框文本保留', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    _setPanelOpen(tester, true);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '草稿内容');

    floatingQModalCount.value = 1;
    await tester.pumpAndSettle();
    // 整层未卸载（面板仍在树中，仅淡出并禁点）
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
    expect(_outerIgnorePointer(tester).ignoring, isTrue);

    floatingQModalCount.value = 0;
    await tester.pumpAndSettle();
    expect(_outerIgnorePointer(tester).ignoring, isFalse);
    // 面板全程未重挂载，输入框草稿不丢失
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '草稿内容',
    );
  });

  group('「给小Q」引用卡片', () {
    /// 通过 provider 挂起一条笔记引用（悬浮层经 openWithQuote 打开面板）
    void _openWithQuote(WidgetTester tester) {
      final context = tester.element(find.byType(FloatingQOverlay));
      final container = ProviderScope.containerOf(context, listen: false);
      container.read(floatingQProvider.notifier).openWithQuote(
            const QTextQuote(
              source: QQuoteSource.note,
              sourceId: 'n1',
              sourceTitle: '小Q的自我介绍',
              quotedText: '我是 QNote 内置的全能终端管家与专属助理。',
              locationDesc: '第 3 行附近',
            ),
          );
    }

    testWidgets('挂起引用后面板展开并渲染引用卡片（来源+位置+摘录）', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quote-card')), findsNothing);

      _openWithQuote(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('quote-card')), findsOneWidget);
      expect(find.text('笔记《小Q的自我介绍》 · 第 3 行附近'), findsOneWidget);
      expect(find.text('我是 QNote 内置的全能终端管家与专属助理。'), findsOneWidget);
    });

    testWidgets('点击 × 移除引用，卡片消失且面板保持打开', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      _openWithQuote(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('移除引用'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('quote-card')), findsNothing);
      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
    });

    testWidgets('会话签名切换清空挂起引用，卡片不再渲染', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      // 模拟笔记编辑页打开：先压栈上下文再挂起引用
      const noteContext = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        signature: 'note:n1',
        displayLabel: '笔记《小Q的自我介绍》',
      );
      final context = tester.element(find.byType(FloatingQOverlay));
      final container = ProviderScope.containerOf(context, listen: false);
      container.read(floatingQProvider.notifier).pushOverlayContext(noteContext);
      _openWithQuote(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quote-card')), findsOneWidget);

      // 模拟离开笔记编辑页：签名变化使挂起引用作废
      container
          .read(floatingQProvider.notifier)
          .popOverlayContext(noteContext);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('quote-card')), findsNothing);
    });
  });
}

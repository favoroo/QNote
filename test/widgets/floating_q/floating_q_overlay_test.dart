import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/floating_q/floating_q_overlay.dart';

/// 测试宿主：与真实挂载方式一致（MaterialApp.builder 内用局部 Overlay 叠
/// FloatingQOverlay，面板内 Tooltip 依赖该 Overlay），仅用极简 GoRouter 覆盖
/// routerProvider（FloatingQOverlay initState 会读取）。
Widget _host() {
  final router = GoRouter(
    initialLocation: '/',
    routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink())],
  );
  return ProviderScope(
    overrides: [routerProvider.overrideWithValue(router)],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => Stack(
        children: [
          child!,
          Overlay(initialEntries: [OverlayEntry(builder: (_) => const FloatingQOverlay())]),
        ],
      ),
    ),
  );
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(FloatingQOverlay)), listen: false);

FloatingQNotifier _notifier(WidgetTester tester) => _container(tester).read(floatingQProvider.notifier);

Future<void> _openPanel(WidgetTester tester) async {
  _notifier(tester).openPanel();
  await tester.pumpAndSettle();
}

/// 取悬浮层最外层的 IgnorePointer（控制整层禁点）：
/// 外层距根最近，取全部 IgnorePointer 中深度最小者即可精确定位
IgnorePointer _outerIgnorePointer(WidgetTester tester) {
  final outer = find.byType(IgnorePointer).evaluate().reduce((a, b) => a.depth < b.depth ? a : b);
  return outer.widget as IgnorePointer;
}

const _quote = QTextQuote(
  source: QQuoteSource.note,
  sourceId: 'n1',
  sourceTitle: '小Q的自我介绍',
  quotedText: '我是 QNote 内置的全能终端管家与专属助理。',
  locationDesc: '第 3 行附近',
);

void main() {
  setUp(() {
    // 全局模态计数器在测试间复位
    floatingQModalCount.value = 0;
  });

  testWidgets('初始不渲染弹窗和气泡', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('panel')), findsNothing);
    expect(find.byKey(const ValueKey('floating-q-bubble')), findsNothing);
  });

  testWidgets('打开后是居中弹窗，尺寸比旧底部面板更大', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await _openPanel(tester);

    final panel = tester.getRect(find.byKey(const ValueKey('panel')));
    final screen = tester.getSize(find.byType(MaterialApp));
    // 居中而不是贴底；宽度受 560 上限约束，高度明显高于旧版 380
    expect(panel.center.dx, closeTo(screen.width / 2, 1));
    expect(panel.center.dy, closeTo(screen.height / 2, 1));
    expect(panel.width, closeTo(560, 1));
    expect(panel.height, greaterThan(380));
    expect(find.byKey(const ValueKey('floating-q-bubble')), findsNothing);
  });

  testWidgets('打开时从最近点按位置容器变形展开', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    _notifier(tester)
      ..recordPointerDown(const Offset(100, 500))
      ..openPanel();
    await tester.pump();

    final morph = find.byKey(const ValueKey('floating-q-morph'));
    expect(morph, findsOneWidget);
    final first = tester.getRect(morph);
    expect(first.center.dx, closeTo(100, 2));
    expect(first.center.dy, closeTo(500, 2));

    await tester.pump(const Duration(milliseconds: 220));
    final mid = tester.getRect(morph);
    expect(mid.width, greaterThan(first.width + 40));

    await tester.pumpAndSettle();
    // 入场结束容器撤掉，改由未裁切的内容窗口直接画卡片
    expect(find.byKey(const ValueKey('floating-q-morph')), findsNothing);
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
  });

  testWidgets('减号最小化成气泡，点击气泡恢复同一段对话和草稿', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await _openPanel(tester);

    await tester.enterText(find.byType(TextField), '继续改这一段');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('floating-q-minimize')));
    await tester.pump();
    // 收回途中：变形容器还在，内容窗口正在缩向气泡
    expect(find.byKey(const ValueKey('floating-q-morph')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel')), findsNothing);
    expect(find.byKey(const ValueKey('floating-q-bubble')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('floating-q-bubble')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
    // 草稿由 provider 留存，面板重挂载后回填
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '继续改这一段');
  });

  testWidgets('点遮罩最小化成气泡而不是彻底关闭', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await _openPanel(tester);
    await tester.enterText(find.byType(TextField), '先放一放');
    await tester.pump();

    // 面板居中，左上角一定在遮罩上
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('panel')), findsNothing);
    expect(find.byKey(const ValueKey('floating-q-bubble')), findsOneWidget);
  });

  testWidgets('× 彻底关闭：面板和气泡都消失', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await _openPanel(tester);
    await tester.enterText(find.byType(TextField), '不聊了');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('floating-q-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('panel')), findsNothing);
    expect(find.byKey(const ValueKey('floating-q-bubble')), findsNothing);
    expect(_container(tester).read(floatingQProvider).messages, isEmpty);
    expect(_container(tester).read(floatingQProvider).draftText, isEmpty);
  });

  testWidgets('气泡存在时再次触发给小Q，继续同一段对话并保留草稿', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await _openPanel(tester);
    await tester.enterText(find.byType(TextField), '草稿内容');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('floating-q-minimize')));
    await tester.pumpAndSettle();

    _notifier(tester).openWithQuote(_quote);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('quote-card')), findsOneWidget);
    expect(find.text('笔记《小Q的自我介绍》 · 第 3 行附近'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '草稿内容');
  });

  testWidgets('长按拖动气泡，松手磁吸到最近边缘', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await _openPanel(tester);
    await tester.enterText(find.byType(TextField), '拖一下');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('floating-q-minimize')));
    await tester.pumpAndSettle();

    final bubble = find.byKey(const ValueKey('floating-q-bubble'));
    final start = tester.getCenter(bubble);
    final gesture = await tester.startGesture(start);
    // 超过长按阈值后才进入拖动
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(Offset(80, start.dy));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(bubble).dx, closeTo(8, 1));
  });

  testWidgets('模态打开时悬浮层淡出禁点但保持挂载，关闭后输入框文本保留', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await _openPanel(tester);
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
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '草稿内容');
  });

  group('「给小Q」引用卡片', () {
    testWidgets('挂起引用后面板展开并渲染引用卡片（来源+位置+摘录）', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quote-card')), findsNothing);

      _notifier(tester).openWithQuote(_quote);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('quote-card')), findsOneWidget);
      expect(find.text('笔记《小Q的自我介绍》 · 第 3 行附近'), findsOneWidget);
      expect(find.text('我是 QNote 内置的全能终端管家与专属助理。'), findsOneWidget);
    });

    testWidgets('点击 × 移除引用，卡片消失且面板保持打开', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      _notifier(tester).openWithQuote(_quote);
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
      final container = _container(tester);
      container.read(floatingQProvider.notifier).pushOverlayContext(noteContext);
      _notifier(tester).openWithQuote(_quote);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quote-card')), findsOneWidget);

      // 模拟离开笔记编辑页：签名变化使挂起引用随旧会话暂存，新页面不再渲染
      container.read(floatingQProvider.notifier).popOverlayContext(noteContext);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('quote-card')), findsNothing);
    });

    testWidgets('框选状态下打开面板：捕获引用打开面板并渲染引用卡片', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      // 模拟笔记编辑页打开且正文有框选（桥钩子返回捕获结果）
      const noteContext = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        signature: 'note:sel',
        displayLabel: '笔记《小Q的自我介绍》',
      );
      final container = _container(tester);
      container.read(floatingQProvider.notifier).pushOverlayContext(noteContext);
      QTargetBridge.instance.register(
        'note:sel',
        QTargetHooks(
          quoteSelection: () => const QTextQuote(
            source: QQuoteSource.note,
            sourceId: 'n1',
            sourceTitle: '小Q的自我介绍',
            quotedText: '悬浮球框选引用的文本',
            locationDesc: '第 5 行附近',
          ),
        ),
      );
      addTearDown(() => QTargetBridge.instance.unregister('note:sel'));

      // 真实场景由底部导航栏中央按钮长按触发：先捕获选区引用，有引用则 openWithQuote
      final fqState = container.read(floatingQProvider);
      final sig = fqState.effectiveContext?.signature;
      final quote = QTargetBridge.instance.captureQuote(sig);
      expect(quote, isNotNull);
      container.read(floatingQProvider.notifier).openWithQuote(quote!);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('quote-card')), findsOneWidget);
      expect(find.text('笔记《小Q的自我介绍》 · 第 5 行附近'), findsOneWidget);
    });

    testWidgets('无框选时打开面板仅渲染面板（不渲染引用卡片）', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      await _openPanel(tester);

      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('quote-card')), findsNothing);
    });
  });

  group('展开全页面', () {
    testWidgets('浮层在路由之外时仍能跳转到 /ai（不再抛 No GoRouter）', (tester) async {
      // 回归：曾用 context.push，而本浮层挂在 MaterialApp.builder 的 Stack 上、
      // 位于路由 Navigator 之外，context 里没有 GoRouter 的 InheritedWidget，
      // 点击「展开」必然失败并弹「展开失败：No GoRouter found in context」。
      //
      // 刻意留空草稿与消息：promoteActiveSession 会在空会话时提前返回，
      // 从而完全不碰 sqflite，测试只验证导航本身。
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(
            path: '/ai',
            builder: (_, _) => const Scaffold(body: Text('AI 会话页')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [routerProvider.overrideWithValue(router)],
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => Stack(
              children: [
                child!,
                Overlay(initialEntries: [OverlayEntry(builder: (_) => const FloatingQOverlay())]),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openPanel(tester);

      expect(find.byKey(const ValueKey('floating-q-expand')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('floating-q-expand')), warnIfMissed: true);
      await tester.pumpAndSettle();

      // 断言页面真的渲染出来（GoRouter 的 currentConfiguration 在 push 后
      // 仍可能报基础位置，用它判断会误判）
      expect(find.textContaining('展开失败'), findsNothing);
      expect(find.text('AI 会话页'), findsOneWidget);
    });
  });
}

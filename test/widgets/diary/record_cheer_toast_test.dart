import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/cheer_burst.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';
import 'package:qnote_flutter/widgets/diary/record_cheer_toast.dart';

/// 流光描边开没开，直接问 `AnimatedGradientBorder.isAnimating`。
///
/// 别用「子树里有没有 CustomPaint」来判：Material/Scaffold 树里本来就挂着
/// painter 为 null 的 CustomPaint，计数会被无关节点污染成 1~2 个。
bool _flowAnimating(WidgetTester tester) =>
    tester
        .widget<AnimatedGradientBorder>(
          find.descendant(
            of: find.byType(RecordCheerToast),
            matching: find.byType(AnimatedGradientBorder),
          ),
        )
        .isAnimating;

double _opacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(of: find.byType(RecordCheerToast), matching: find.byType(Opacity)),
    )
    .opacity;

class _ToastHost extends StatefulWidget {
  const _ToastHost({required this.event, this.onAction, this.onDismissed});

  final CheerEvent event;
  final VoidCallback? onAction;
  final VoidCallback? onDismissed;

  @override
  State<_ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<_ToastHost> {
  late CheerEvent _event = widget.event;
  bool _leaving = false;

  void replace(CheerEvent event) => setState(() {
    _event = event;
    _leaving = false;
  });

  void leave() => setState(() => _leaving = true);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: RecordCheerToast(
            event: _event,
            leaving: _leaving,
            onAction: widget.onAction,
            onDismissed: widget.onDismissed,
          ),
        ),
      ),
    );
  }
}

CheerEvent _event({
  CheerLevel level = CheerLevel.full,
  int id = 1,
  String? sub = '共3条，太棒了',
  String? actionLabel = '看看统计',
}) {
  return CheerEvent(
    id: id,
    title: level == CheerLevel.full ? '今日完整！连续4天' : '今日第$id条',
    sub: sub,
    level: level,
    actionLabel: actionLabel,
  );
}

Future<_ToastHostState> _pump(
  WidgetTester tester,
  _ToastHost host, {
  Size screen = const Size(600, 900),
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(host);
  await tester.pump(const Duration(milliseconds: 300));
  return tester.state<_ToastHostState>(find.byType(_ToastHost));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecordCheerToast 分级样式', () {
    testWidgets('满档带流光描边与副标题', (tester) async {
      await _pump(tester, _ToastHost(event: _event(level: CheerLevel.full)));

      expect(find.text('今日完整！连续4天'), findsOneWidget);
      expect(find.text('共3条，太棒了'), findsOneWidget);
      expect(_flowAnimating(tester), isTrue);
    });

    testWidgets('破纪录同样走重头样式', (tester) async {
      await _pump(tester, _ToastHost(event: _event(level: CheerLevel.record)));

      expect(_flowAnimating(tester), isTrue);
    });

    testWidgets('普通记录不放流光也不给跳转入口，保持极轻', (tester) async {
      await _pump(
        tester,
        _ToastHost(
          event: _event(level: CheerLevel.plain, sub: null, actionLabel: null),
        ),
      );

      expect(_flowAnimating(tester), isFalse);
      expect(find.text('看看统计'), findsNothing);
    });
  });

  group('RecordCheerToast 退场', () {
    testWidgets('leaving 置真后播完退场并回调一次', (tester) async {
      var dismissed = 0;
      final host = await _pump(
        tester,
        _ToastHost(event: _event(), onDismissed: () => dismissed++),
      );

      host.leave();
      // 换方向后的第一帧只重新计时、不推进进度，所以要两帧以后才看得出动。
      // 这条也在锁「退场有过程」：停留到点不能把胶囊硬切成没了。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(_opacity(tester), inInclusiveRange(0.01, 0.99));

      await tester.pump(const Duration(milliseconds: 250));
      expect(_opacity(tester), 0);
      expect(dismissed, 1);

      // 已 dismissed 后不该再重复回调，否则父级会被连环移除一次事件。
      await tester.pump(const Duration(milliseconds: 400));
      expect(dismissed, 1);
    });

    testWidgets('挂载时已是 leaving 也能直接退场，不会卡在屏幕上', (tester) async {
      var dismissed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RecordCheerToast(
                event: _event(),
                leaving: true,
                onDismissed: () => dismissed++,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(dismissed, 1);
    });

    testWidgets('连记多条换事件重播入场，不误触发退场', (tester) async {
      var dismissed = 0;
      final host = await _pump(
        tester,
        _ToastHost(event: _event(id: 1), onDismissed: () => dismissed++),
      );

      host.replace(_event(id: 2));
      await tester.pump(const Duration(milliseconds: 60));

      expect(dismissed, 0);
      // 重播意味着回到了入场中段，而不是停在 1.0 的死图上。
      expect(_opacity(tester), lessThan(1));
      expect(_flowAnimating(tester), isTrue);

      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacity(tester), 1);
    });
  });

  group('RecordCheerToast 交互与布局', () {
    testWidgets('「看看统计」回调送达调用方', (tester) async {
      var tapped = 0;
      await _pump(tester, _ToastHost(event: _event(), onAction: () => tapped++));

      await tester.tap(find.text('看看统计'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tapped, 1);
    });

    testWidgets('超长文案单行省略，不撑破胶囊', (tester) async {
      await _pump(
        tester,
        _ToastHost(
          event: _event(sub: '已连续记录 1234567890 天，这段文案故意拉得很长'),
        ),
        screen: const Size(320, 640),
      );

      expect(tester.getSize(find.byType(RecordCheerToast)).width, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });

    testWidgets('320pt 窄屏不溢出', (tester) async {
      await _pump(
        tester,
        _ToastHost(event: _event()),
        screen: const Size(320, 640),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('深浅色都照常出图', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness, useMaterial3: true),
            home: Scaffold(
              body: Center(child: RecordCheerToast(event: _event())),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull, reason: '$brightness 下渲染异常');
      }
    });
  });
}

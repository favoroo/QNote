import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/ai/user_bubble_reedit_tap.dart';

const Key _bubbleKey = Key('bubble');

/// 新组件不 watch 任何 provider，因此宿主只需最小 MaterialApp + Scaffold
Widget _harness(UserBubbleReeditTap tap) => MaterialApp(
  home: Scaffold(
    body: ListView(
      children: [
        tap,
        const SizedBox(height: 1200), // 撑出可滚动范围，供「拖拽不该算点击」用例使用
      ],
    ),
  ),
);

UserBubbleReeditTap _tapWidget({
  bool enabled = true,
  bool active = false,
  required VoidCallback onTap,
}) => UserBubbleReeditTap(
  enabled: enabled,
  active: active,
  onTap: onTap,
  // 气泡定宽右对齐，复刻真实行布局：用户气泡 maxWidth 恒小于屏宽，行左必留空档，
  // 「点空档算不算命中」这条用例才有地方下指
  child: const Align(
    alignment: Alignment.centerRight,
    child: SizedBox(
      key: _bubbleKey,
      width: 160,
      height: 40,
      child: ColoredBox(
        color: Color(0xFF0000AA),
        child: Center(child: Text('帮我记一条待办')),
      ),
    ),
  ),
);

/// 取承载层自己的背景（未按下时 color 为 null）
Color? _highlightColor(WidgetTester tester) =>
    (tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).decoration
            as BoxDecoration?)
        ?.color;

void main() {
  var hapticCount = 0;

  setUp(() {
    hapticCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCount++;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('不再挂编辑图标：点击已不具破坏性，常驻图标会误导成撤回按钮', (tester) async {
    await tester.pumpWidget(_harness(_tapWidget(onTap: () {})));

    expect(find.byIcon(Icons.edit_note_rounded), findsNothing);
    expect(
      find.descendant(
        of: find.byType(UserBubbleReeditTap),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
    );
  });

  testWidgets('编辑态常驻淡底色，非编辑态未按下无背景', (tester) async {
    await tester.pumpWidget(_harness(_tapWidget(active: true, onTap: () {})));
    expect(_highlightColor(tester), isNotNull);

    await tester.pumpWidget(_harness(_tapWidget(active: false, onTap: () {})));
    await tester.pumpAndSettle();
    expect(_highlightColor(tester), isNull);
  });

  testWidgets('点击气泡上抛回调并轻震动一次', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_harness(_tapWidget(onTap: () => taps++)));

    await tester.tap(find.byKey(_bubbleKey));
    await tester.pumpAndSettle();

    expect(taps, 1);
    // 震动放在抬手确认，不在按下：翻聊天记录经过这条气泡时不该震
    expect(hapticCount, 1);
  });

  testWidgets('禁用态仍上抛（由页面 Toast 说明原因）但不震动', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(_tapWidget(enabled: false, onTap: () => taps++)),
    );

    await tester.tap(find.byKey(_bubbleKey));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(hapticCount, 0);
  });

  testWidgets('按下出现高亮，抬手回到无背景', (tester) async {
    await tester.pumpWidget(_harness(_tapWidget(onTap: () {})));
    expect(_highlightColor(tester), isNull);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_bubbleKey)),
    );
    // 列表里有拖拽识别器竞争，onTapDown 要等 kPressTimeout 才落定（与 InkWell 一致）
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    final pressed = _highlightColor(tester);
    expect(pressed, isNotNull);
    expect(pressed!.a, greaterThan(0));

    await gesture.up();
    await tester.pump();
    expect(_highlightColor(tester), isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('禁用态按下不给高亮反馈', (tester) async {
    await tester.pumpWidget(_harness(_tapWidget(enabled: false, onTap: () {})));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_bubbleKey)),
    );
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    expect(_highlightColor(tester), isNull);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('在气泡上起手滚动列表不算点击、不震动', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_harness(_tapWidget(onTap: () => taps++)));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_bubbleKey)),
    );
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    expect(_highlightColor(tester), isNotNull); // 起手时先给了高亮

    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // 拖拽抢走手势后 onTapCancel 生效：既不回退也不震，高亮同时收回
    expect(taps, 0);
    expect(hapticCount, 0);
    expect(_highlightColor(tester), isNull);
  });

  testWidgets('删掉图标没有缩小命中面：原图标所在的行左留白依旧可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_harness(_tapWidget(onTap: () => taps++)));

    final bubbleLeft = tester.getTopLeft(find.byKey(_bubbleKey)).dx;
    final bubbleCenter = tester.getCenter(find.byKey(_bubbleKey));
    // 行背景是矩形 BoxDecoration，hitTest 对整个行无条件为 true（并非 deferToChild
    // 只管气泡本体）。点击已不具破坏性，宽命中面换来好点中，这里锁住别被改窄
    await tester.tapAt(Offset(bubbleLeft - 40, bubbleCenter.dy));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(hapticCount, 1);
  });
}

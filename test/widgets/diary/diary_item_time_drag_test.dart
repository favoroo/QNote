import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';

DiaryRecord _record() {
  return DiaryRecord(
    id: 'r1',
    title: '早餐',
    time: DateTime(2026, 11, 11, 9),
    content: '250ml牛奶，加一点点咖啡',
    createdAt: DateTime(2026, 11, 11, 9),
    updatedAt: DateTime(2026, 11, 11, 9),
  );
}

Widget _buildHarness({required GlobalKey handleKey, required ValueChanged<Offset> onTimelineLongPress}) {
  return MaterialApp(
    home: Scaffold(
      body: GestureDetector(
        // 模拟日记页包住 ListView 的时间线长按手势
        onLongPressStart: (details) => onTimelineLongPress(details.globalPosition),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [DiaryItem(record: _record(), timeDragHandleKey: handleKey)],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('长按左侧节点把手由时间线外层手势接管', (tester) async {
    final handleKey = GlobalKey();
    Offset? longPressPosition;

    await tester.pumpWidget(
      _buildHarness(handleKey: handleKey, onTimelineLongPress: (position) => longPressPosition = position),
    );

    final handleRect = tester.getRect(find.byKey(handleKey));
    final gesture = await tester.startGesture(handleRect.center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

    expect(longPressPosition, isNotNull);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('长按卡片本体不触发时间线拖拽，仍由卡片弹出操作菜单', (tester) async {
    final handleKey = GlobalKey();
    Offset? longPressPosition;

    await tester.pumpWidget(
      _buildHarness(handleKey: handleKey, onTimelineLongPress: (position) => longPressPosition = position),
    );

    final cardRect = tester.getRect(find.byType(AnimatedGradientBorder));
    final gesture = await tester.startGesture(cardRect.center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

    expect(longPressPosition, isNull);

    await gesture.up();
    await tester.pumpAndSettle();
    // 关闭长按弹出的操作菜单，避免残留 Overlay 影响后续用例
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
  });

  testWidgets('长按卡片菜单展示批量管理入口并可回调', (tester) async {
    var batchTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [DiaryItem(record: _record(), onBatchManage: () => batchTapped = true)],
          ),
        ),
      ),
    );

    final cardRect = tester.getRect(find.byType(AnimatedGradientBorder));
    final gesture = await tester.startGesture(cardRect.center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('批量管理'), findsOneWidget);
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    expect(batchTapped, isTrue);
  });
}

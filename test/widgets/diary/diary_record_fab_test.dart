import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/widgets/diary/diary_record_fab.dart';

/// 单测里把「今天」定死，否则跨零点跑测试会得到不同角标。
DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

ProviderContainer _container({
  TimelineTimeSelectEvent? selection,
  DiaryComposeDraft? draft,
}) {
  return ProviderContainer(
    overrides: [
      if (selection != null)
        diaryInputTimeProvider.overrideWith((ref) => selection),
      if (draft != null)
        diaryComposeDraftProvider.overrideWith(() => _SeedDraftNotifier(draft)),
    ],
  );
}

class _SeedDraftNotifier extends DiaryComposeDraftNotifier {
  _SeedDraftNotifier(this._seed);

  final DiaryComposeDraft _seed;

  @override
  DiaryComposeDraft build() => _seed;
}

Future<void> _pumpFab(
  WidgetTester tester,
  ProviderContainer container, {
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: DiaryRecordFab(onTap: onTap ?? () {})),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未选时间时是纯圆钮，只有加号', (tester) async {
    final container = _container();
    addTearDown(container.dispose);

    await _pumpFab(tester, container);

    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.text('14:30'), findsNothing);
  });

  testWidgets('选中时间后加号仍在左侧，时间与 × 长在它右边', (tester) async {
    final container = _container(
      selection: TimelineTimeSelectEvent(
        const TimeOfDay(hour: 14, minute: 30),
        date: _today(),
      ),
    );
    addTearDown(container.dispose);

    await _pumpFab(tester, container);

    expect(find.text('14:30'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    // 加号是胶囊的固定锚点，展开后依然在，不换成别的图标
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);

    // 顺序：加号 → 时间 → ×（从左往右）
    final addX = tester.getCenter(find.byIcon(Icons.add_rounded)).dx;
    final timeX = tester.getCenter(find.text('14:30')).dx;
    final closeX = tester.getCenter(find.byIcon(Icons.close_rounded)).dx;
    expect(addX, lessThan(timeX));
    expect(timeX, lessThan(closeX));
  });

  testWidgets('区间选择显示起止时间', (tester) async {
    final container = _container(
      selection: TimelineTimeSelectEvent(
        const TimeOfDay(hour: 14, minute: 30),
        endTime: const TimeOfDay(hour: 16, minute: 0),
        date: _today(),
      ),
    );
    addTearDown(container.dispose);

    await _pumpFab(tester, container);

    expect(find.text('14:30–16:00'), findsOneWidget);
  });

  testWidgets('非今天的选中日带日期角标', (tester) async {
    final container = _container(
      selection: TimelineTimeSelectEvent(
        const TimeOfDay(hour: 9, minute: 0),
        date: _today().subtract(const Duration(days: 1)),
      ),
    );
    addTearDown(container.dispose);

    await _pumpFab(tester, container);

    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
  });

  testWidgets('点主体触发记录面板，点 × 只清除时间选择', (tester) async {
    var tapped = false;
    final container = _container(
      selection: TimelineTimeSelectEvent(
        const TimeOfDay(hour: 14, minute: 30),
        date: _today(),
      ),
    );
    addTearDown(container.dispose);

    await _pumpFab(tester, container, onTap: () => tapped = true);

    await tester.tap(find.text('14:30'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
    expect(container.read(diaryInputTimeProvider), isNotNull);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(container.read(diaryInputTimeProvider), isNull);
    expect(tapped, isTrue, reason: '清除不应顺手打开面板');
  });

  testWidgets('有未保存草稿时右上角出现圆点', (tester) async {
    final container = _container(
      draft: DiaryComposeDraft(id: 'd1', inputText: '写了一半'),
    );
    addTearDown(container.dispose);

    await _pumpFab(tester, container);

    expect(find.byKey(const ValueKey('fab-draft-dot')), findsOneWidget);
  });

  testWidgets('空草稿不亮圆点', (tester) async {
    final container = _container(draft: DiaryComposeDraft(id: 'd1'));
    addTearDown(container.dispose);

    await _pumpFab(tester, container);

    expect(find.byKey(const ValueKey('fab-draft-dot')), findsNothing);
  });
}

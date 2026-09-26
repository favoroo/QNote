import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/widgets/diary/today_progress_ring.dart';

/// 只喂记录列表，让 diaryProgressProvider 走真实计算链路。
class _FakeDiaryListNotifier extends DiaryListNotifier {
  _FakeDiaryListNotifier(this._records);

  final List<DiaryRecord> _records;

  @override
  Future<List<DiaryRecord>> build() async => _records;
}

/// 相对「今天」造记录：diaryProgressProvider 内部用的是真实 DateTime.now()。
DiaryRecord _recordAt(int daysAgo, int minute) {
  final now = DateTime.now();
  final time = DateTime(now.year, now.month, now.day - daysAgo, 9, minute);
  return DiaryRecord(
    id: '$daysAgo-$minute',
    title: '记录',
    time: time,
    createdAt: time,
    updatedAt: time,
  );
}

List<DiaryRecord> _records(Map<int, int> perDay) {
  return [
    for (final entry in perDay.entries)
      for (var i = 0; i < entry.value; i++) _recordAt(entry.key, i),
  ];
}

Future<void> _pumpRing(WidgetTester tester, List<DiaryRecord> records) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        diaryListProvider.overrideWith(() => _FakeDiaryListNotifier(records)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [TodayProgressRing(), SizedBox(width: 8)],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 圆环所在的 44×44 命中盒。
Finder get _ringBox => find.byType(TodayProgressRing);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TodayProgressRing', () {
    testWidgets('今日2条、连续3天：环内 2/3，徽标显示连续天数', (tester) async {
      await _pumpRing(tester, _records({0: 2, 1: 1, 2: 1}));

      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('达到目标：环内 3/3 且满环', (tester) async {
      await _pumpRing(tester, _records({0: 3}));

      expect(find.text('3/3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('超过目标不封顶显示，仍如实反映条数', (tester) async {
      await _pumpRing(tester, _records({0: 5}));

      expect(find.text('5/3'), findsOneWidget);
    });

    testWidgets('今天没记但连续未断：徽标显示从昨天起算的天数', (tester) async {
      await _pumpRing(tester, _records({1: 1, 2: 1}));

      expect(find.text('0/3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('无任何记录：0/3 与连续 0', (tester) async {
      await _pumpRing(tester, const []);

      expect(find.text('0/3'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('整句提示降级进 Tooltip 与 Semantics，信息不丢', (tester) async {
      await _pumpRing(tester, _records({0: 1, 1: 1}));

      final tooltip = tester.widget<Tooltip>(
        find.descendant(of: _ringBox, matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, contains('今日 1/3'));
      expect(tooltip.message, contains('连续2天'));
    });

    testWidgets('今日未记时提示会断连', (tester) async {
      await _pumpRing(tester, _records({1: 1}));

      final tooltip = tester.widget<Tooltip>(
        find.descendant(of: _ringBox, matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, contains('今天还没记'));
    });

    testWidgets('固定 44×44 命中区，与发送按钮同尺寸不挤压输入框', (tester) async {
      await _pumpRing(tester, _records({0: 1}));

      final size = tester.getSize(_ringBox);
      expect(size, const Size(44, 44));
    });

    testWidgets('320pt 窄屏按真实输入行排布（圆环+输入框+两枚按钮）不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            diaryListProvider.overrideWith(() => _FakeDiaryListNotifier(_records({0: 2}))),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const TodayProgressRing(),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 44,
                        alignment: Alignment.centerLeft,
                        child: const TextField(decoration: InputDecoration(hintText: '记录当前...')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const SizedBox(width: 44, height: 44),
                    const SizedBox(width: 12),
                    const SizedBox(width: 44, height: 44),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 圆环仍占满 44，输入框被挤到剩余宽度但未被压没
      expect(tester.getSize(_ringBox), const Size(44, 44));
      expect(find.text('2/3'), findsOneWidget);
    });
  });
}

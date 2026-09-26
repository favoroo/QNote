import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/widgets/statistics/streak_summary_strip.dart';

/// 只喂记录列表，让 streakSummaryProvider 走真实计算链路。
class _FakeDiaryListNotifier extends DiaryListNotifier {
  _FakeDiaryListNotifier(this._records);

  final List<DiaryRecord> _records;

  @override
  Future<List<DiaryRecord>> build() async => _records;
}

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

Future<void> _pumpStrip(WidgetTester tester, List<DiaryRecord> records) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        diaryListProvider.overrideWith(() => _FakeDiaryListNotifier(records)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: StreakSummaryStrip(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StreakSummaryStrip', () {
    testWidgets('四个口径一次摊开：当前/最长/达标/近30天', (tester) async {
      // 今天起连续 5 天各 1 条；更早有一段 6 天每天 3 条
      await _pumpStrip(tester, _records({
        0: 1,
        1: 1,
        2: 1,
        3: 1,
        4: 1,
        7: 3,
        8: 3,
        9: 3,
        10: 3,
        11: 3,
        12: 3,
      }));

      expect(find.text('5'), findsOneWidget); // 当前连续记录
      expect(find.text('6'), findsOneWidget); // 最长连续记录（更早那段 6 天）
      expect(find.text('0'), findsOneWidget); // 当前连续达标：今天只有 1 条
      expect(find.text('11'), findsOneWidget); // 近30天有记录天数
      expect(find.text('当前连续'), findsOneWidget);
      expect(find.text('最长连续'), findsOneWidget);
      expect(find.text('连续达标'), findsOneWidget);
      expect(find.text('近30天'), findsOneWidget);
    });

    testWidgets('说明行带上每日目标与达标天数', (tester) async {
      await _pumpStrip(tester, _records({0: 3, 1: 3}));

      expect(find.textContaining('目标 3 条/天'), findsOneWidget);
      expect(find.textContaining('近30天达标 2 天'), findsOneWidget);
    });

    testWidgets('今天还没记时补一句续上提示', (tester) async {
      await _pumpStrip(tester, _records({1: 1, 2: 1}));

      expect(find.textContaining('今天还没记，记一条就续上'), findsOneWidget);
    });

    testWidgets('空数据不崩，全为0', (tester) async {
      await _pumpStrip(tester, const []);

      expect(find.text('当前连续'), findsOneWidget);
      expect(find.text('0'), findsWidgets);
    });

    testWidgets('320pt 窄屏不溢出', (tester) async {
      await _pumpStrip(tester, _records({0: 1, 1: 9, 2: 12}));

      expect(tester.takeException(), isNull);
    });
  });
}

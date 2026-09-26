import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_progress_provider.dart';
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

  group('庆祝爆点上报', () {
    testWidgets('圆环把自己的圆心写进 cheerAnchorProvider', (tester) async {
      ValueNotifier<Offset?>? anchor;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            diaryListProvider.overrideWith(() => _FakeDiaryListNotifier(_records({0: 1}))),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  const TodayProgressRing(),
                  Consumer(
                    builder: (context, ref, _) {
                      anchor = ref.read(cheerAnchorProvider);
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Row 首位、44×44，body 无安全区 → 圆心就在 (22, 22)。
      expect(anchor, isNotNull);
      expect(anchor!.value, tester.getCenter(_ringBox));
    });

    testWidgets('收起/展开两份同时挂在 AnimatedCrossFade 上也不炸', (tester) async {
      // 输入条的 AnimatedCrossFade 会同时挂载两份 child（淡出的那份只是关了
      // ticker），所以爆点用的 GlobalKey 必须每个实例各持一把。谁哪天图省事把它
      // 换成共享 key，这条会立刻红。
      Future<void> pumpCrossFade(bool expanded) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              diaryListProvider.overrideWith(() => _FakeDiaryListNotifier(_records({0: 2}))),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: AnimatedCrossFade(
                  firstChild: const Row(
                    children: [TodayProgressRing(), SizedBox(width: 8)],
                  ),
                  secondChild: const SizedBox(
                    width: 200,
                    height: 120,
                    child: TodayProgressRing(),
                  ),
                  crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 300),
                ),
              ),
            ),
          ),
        );
      }

      await pumpCrossFade(false);
      await tester.pumpAndSettle();
      expect(find.byType(TodayProgressRing), findsNWidgets(2));

      await pumpCrossFade(true);
      // 过渡中途两份的 TickerMode 都为 true，正是会抢写同一个 key 的时刻。
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('爆点按圆环实际布局算，不是写死的左上角', (tester) async {
      ValueNotifier<Offset?>? anchor;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            diaryListProvider.overrideWith(() => _FakeDiaryListNotifier(_records({0: 2}))),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const SizedBox(
                    height: 120,
                    child: Center(child: TodayProgressRing()),
                  ),
                  Consumer(
                    builder: (context, ref, _) {
                      // 只取 notifier 本身：watch notifier.value 会自下而上重建，
                      // 值留到断言时再读，避免抓到上报前的一次性 null。
                      anchor = ref.read(cheerAnchorProvider);
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(anchor, isNotNull);
      expect(anchor!.value, tester.getCenter(find.byType(TodayProgressRing)));
    });
  });
}

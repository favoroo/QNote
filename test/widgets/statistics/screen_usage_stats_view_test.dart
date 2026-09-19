import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/health/screen_usage_snapshot_service.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';
import 'package:qnote_flutter/providers/screen_usage_provider.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';
import 'package:qnote_flutter/widgets/statistics/screen_usage_stats_view.dart';

/// 1x1 透明 PNG，用于走通 Image.memory 的真实渲染分支
final Uint8List _kIconPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
);

/// 伪造用量服务：绕开平台判断与 MethodChannel，只保留视图需要的数据形状
class _FakeUsageService extends ScreenUsageService {
  @override
  bool get isSupported => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Map<String, Uint8List>> getIcons(List<String> packageNames) async {
    return {for (final pkg in packageNames) pkg: _kIconPng};
  }
}

/// 快照采集在测试里会真去读数据库，直接短路成「本轮没写新数据」
class _FakeSnapshotService extends ScreenUsageSnapshotService {
  _FakeSnapshotService(super.ref);

  @override
  Future<bool> ensureSnapshot({bool force = false}) async => false;
}

List<AppUsageInfo> _dayApps(int count) => [
  for (int i = 0; i < count; i++)
    AppUsageInfo(
      packageName: 'com.demo.app$i',
      appName: '应用$i',
      totalTimeInForegroundMs: 6600000 - i * 300000,
      lastTimeUsedMs: 0,
      iconBytes: i == 0 ? _kIconPng : null,
    ),
];

List<ScreenAppUsage> _rankApps(int count) => [
  for (int i = 0; i < count; i++)
    ScreenAppUsage(
      packageName: 'com.demo.app$i',
      appName: '应用$i',
      timeMs: 6600000 - i * 300000,
    ),
];

/// 在 360×780 的小屏上渲染整页，返回内容总高度（逻辑像素）
Future<double> pumpView(WidgetTester tester, {DateTime? anchor}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final selected = anchor ?? today;
  final weekStart = selected.subtract(Duration(days: selected.weekday - 1));
  final weekEnd = weekStart.add(const Duration(days: 6));
  final dataEnd = weekEnd.isAfter(today) ? today : weekEnd;
  final elapsedDays = dataEnd.difference(weekStart).inDays + 1;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedDateProvider.overrideWith((ref) => selected),
        screenUsageServiceProvider.overrideWithValue(_FakeUsageService()),
        screenUsageSnapshotServiceProvider.overrideWith(
          (ref) => _FakeSnapshotService(ref),
        ),
        screenUsageEarliestDateProvider.overrideWith((ref) async => weekStart),
        screenUsageDayProvider.overrideWith((ref, date) async {
          return ScreenUsageDayView(
            date: date,
            totalTimeMs: 27720000, // 7小时42分
            previousTotalMs: 47520000,
            apps: _dayApps(6),
            collected: true,
            isToday: date == today,
          );
        }),
        screenUsageRangeProvider.overrideWith((ref, arg) async {
          return ScreenUsageAggregate(
            bounds: ScreenRangeBounds(
              start: weekStart,
              end: weekEnd,
              dataEnd: dataEnd,
              prevStart: weekStart.subtract(const Duration(days: 7)),
              prevEnd: dataEnd.subtract(const Duration(days: 7)),
            ),
            totalMs: 211920000, // 58小时52分
            recordedDays: elapsedDays,
            spanDays: elapsedDays,
            avgMs: 27720000,
            previousTotalMs: 200000000,
            topApps: _rankApps(12),
            previousLabel: '上周',
          );
        }),
        screenUsageTrendProvider.overrideWith((ref, arg) async {
          return ScreenUsageTrend(
            points: [
              for (int i = 0; i < elapsedDays; i++)
                ScreenUsageTrendPoint(
                  date: weekStart.add(Duration(days: i)),
                  totalTimeMs: 3600000 * (i + 1),
                  collected: i != 0,
                ),
            ],
          );
        }),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ScreenUsageStatsView()),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
  return scrollable.position.maxScrollExtent + scrollable.position.viewportDimension;
}

void main() {
  testWidgets('小屏手机上整页渲染无溢出异常', (tester) async {
    await pumpView(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('本周屏幕时长'), findsOneWidget);
    expect(find.text('今日屏幕时长'), findsOneWidget);
  });

  testWidgets('周/月/年切换条已移除，只保留周口径', (tester) async {
    await pumpView(tester);

    expect(find.text('周'), findsNothing);
    expect(find.text('月'), findsNothing);
    expect(find.text('年'), findsNothing);
    expect(find.textContaining('屏幕时长'), findsNWidgets(2));
  });

  testWidgets('应用榜只渲染前 8 名，当日明细只渲染前 5 名', (tester) async {
    await pumpView(tester);

    // 应用0~4 同时出现在「今日明细」与「本周榜」，应用5~7 只在榜单，应用8+ 不出现
    expect(find.text('应用0'), findsNWidgets(2));
    expect(find.text('应用4'), findsNWidgets(2));
    expect(find.text('应用5'), findsOneWidget);
    expect(find.text('应用7'), findsOneWidget);
    expect(find.text('应用8'), findsNothing);
    expect(find.text('应用11'), findsNothing);
  });

  testWidgets('整页高度收敛在 1300 逻辑像素内（360 宽小屏）', (tester) async {
    final contentHeight = await pumpView(tester);

    // 旧版是「今日 + 区间 + 趋势」三张卡加最多 30 条两列格子，光应用榜就要十几行格子
    expect(contentHeight, lessThan(1300));
  });

  testWidgets('回看历史周时标题切到「所选周」', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await pumpView(tester, anchor: today.subtract(const Duration(days: 7)));

    expect(find.text('本周屏幕时长'), findsNothing);
    expect(find.text('所选周屏幕时长'), findsOneWidget);
  });
}

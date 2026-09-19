import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/screen_usage_daily_repository.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';

/// 每日屏幕时长快照仓储测试。
///
/// 重点锁的是 MAX 合并语义：系统 UsageStats 的每日 bucket 会滚动淘汰，
/// 同一天越晚读到的值可能越小。若这里退化成覆盖，用户会看到上周的柱子
/// 莫名其妙变矮，比数值偏小更不可信。
void main() {
  late Database db;
  late ScreenUsageDailyRepository repo;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
    final container = ProviderContainer();
    repo = container.read(screenUsageDailyRepositoryProvider);
    addTearDown(container.dispose);
  });

  setUp(() async {
    await db.delete('screen_usage_daily');
  });

  ScreenUsageDaily snapshot(
    DateTime date,
    int totalMs, {
    List<ScreenAppUsage> apps = const [],
    bool isComplete = true,
  }) {
    final now = DateTime(2026, 9, 19);
    return ScreenUsageDaily(
      date: ScreenUsageDaily.dateKey(date),
      totalTimeMs: totalMs,
      topApps: apps,
      isComplete: isComplete,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('首次写入按原样落库', () async {
    final day = DateTime(2026, 9, 18);
    final wrote = await repo.upsertSnapshot(snapshot(day, 3 * 3600 * 1000));

    expect(wrote, isTrue);
    final read = await repo.getByDate(ScreenUsageDaily.dateKey(day));
    expect(read, isNotNull);
    expect(read!.totalTimeMs, 3 * 3600 * 1000);
    expect(read.isComplete, isTrue);
  });

  test('更小的新值不会让历史时长倒退', () async {
    final day = DateTime(2026, 9, 17);
    await repo.upsertSnapshot(snapshot(day, 5 * 3600 * 1000));

    // 模拟系统窗口淘汰后重新读到的小值
    final advanced = await repo.upsertSnapshot(
      snapshot(day, 2 * 3600 * 1000, apps: [
        const ScreenAppUsage(packageName: 'com.demo', appName: '演示', timeMs: 2 * 3600 * 1000),
      ]),
    );

    expect(advanced, isFalse);
    final read = await repo.getByDate(ScreenUsageDaily.dateKey(day));
    expect(read!.totalTimeMs, 5 * 3600 * 1000, reason: '总时长必须停留在见过的最大值');
  });

  test('更大的新值覆盖并刷新明细', () async {
    final day = DateTime(2026, 9, 16);
    await repo.upsertSnapshot(snapshot(day, 1 * 3600 * 1000, apps: [
      const ScreenAppUsage(packageName: 'com.a', appName: 'A', timeMs: 1 * 3600 * 1000),
    ]));

    final advanced = await repo.upsertSnapshot(snapshot(day, 4 * 3600 * 1000, apps: [
      const ScreenAppUsage(packageName: 'com.b', appName: 'B', timeMs: 4 * 3600 * 1000),
    ]));

    expect(advanced, isTrue);
    final read = await repo.getByDate(ScreenUsageDaily.dateKey(day));
    expect(read!.totalTimeMs, 4 * 3600 * 1000);
    expect(read.topApps.single.packageName, 'com.b');
  });

  test('总时长未前进时仍可补齐缺失的明细', () async {
    final day = DateTime(2026, 9, 15);
    await repo.upsertSnapshot(snapshot(day, 2 * 3600 * 1000));

    await repo.upsertSnapshot(
      snapshot(day, 2 * 3600 * 1000, apps: [
        const ScreenAppUsage(packageName: 'com.c', appName: 'C', timeMs: 2 * 3600 * 1000),
      ]),
    );

    final read = await repo.getByDate(ScreenUsageDaily.dateKey(day));
    expect(read!.topApps.single.appName, 'C');
  });

  test('完成标记只进不退', () async {
    final day = DateTime(2026, 9, 14);
    await repo.upsertSnapshot(snapshot(day, 3600 * 1000, isComplete: true));

    // 迟到的「进行中」快照不应把整天打回未完成
    await repo.upsertSnapshot(snapshot(day, 3600 * 1000, isComplete: false));

    final read = await repo.getByDate(ScreenUsageDaily.dateKey(day));
    expect(read!.isComplete, isTrue);
  });

  test('区间查询含端点且按日期升序', () async {
    await repo.upsertSnapshots([
      snapshot(DateTime(2026, 9, 3), 1000),
      snapshot(DateTime(2026, 9, 4), 2000),
      snapshot(DateTime(2026, 9, 5), 3000),
      snapshot(DateTime(2026, 9, 6), 4000),
    ]);

    final rows = await repo.getRange('2026-09-04', '2026-09-05');

    expect(rows.length, 2);
    expect(rows.first.date, '2026-09-04');
    expect(rows.last.date, '2026-09-05');
  });

  test('earliestDate 反映最早已采集日，空表返回 null', () async {
    expect(await repo.earliestDate(), isNull);

    await repo.upsertSnapshots([
      snapshot(DateTime(2026, 9, 8), 1000),
      snapshot(DateTime(2026, 9, 2), 1000),
    ]);

    final earliest = await repo.earliestDate();
    expect(earliest, DateTime(2026, 9, 2));
  });

  test('损坏的 top_apps_json 降级为空明细而不影响总时长', () async {
    final day = DateTime(2026, 9, 10);
    await repo.upsertSnapshot(snapshot(day, 5000));
    await db.update(
      'screen_usage_daily',
      {'top_apps_json': '{not json'},
      where: 'date = ?',
      whereArgs: [ScreenUsageDaily.dateKey(day)],
    );

    final read = await repo.getByDate(ScreenUsageDaily.dateKey(day));
    expect(read!.totalTimeMs, 5000);
    expect(read.topApps, isEmpty);
  });
}

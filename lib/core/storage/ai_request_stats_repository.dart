import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_request_stat.dart';

final aiRequestStatsRepositoryProvider = Provider<AiRequestStatsRepository>(
  (ref) => AiRequestStatsRepository(),
);

/// 免费网关逐请求事实仓储
///
/// **有意不写 sync_log**：这是纯观测数据，只描述「这台设备这次发信发生了什么」，
/// 换设备读到它没有任何意义（Key 掩码、耗时、限流形态都是本机视角），
/// 混进 WebDAV 增量包只会膨胀流量。口径与 `widget_snapshot`、`screen_usage_daily`
/// 一致（见 `widget_snapshot_repository` 的类注释）。
///
/// **写入点必须能容忍失败**：调用方是 AiService 的热路径，观测数据不能把对话拖下水，
/// 所以 [record] 吞掉一切异常且从不抛出，调用侧用 `unawaited` 即可。
class AiRequestStatsRepository {
  static const String table = 'ai_request_stats';

  static final AiRequestStatsRepository _instance =
      AiRequestStatsRepository._internal();
  factory AiRequestStatsRepository() => _instance;
  AiRequestStatsRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<Database> get _db async => await _dbHelper.database;

  /// 自上次裁剪以来的写入条数：观测表是只增的，靠低频顺手裁剪控制体积，
  /// 不引入定时任务（App 大部分时间在后台，定时器只会白烧电）。
  int _writesSincePrune = 0;

  /// 每写入多少行触发一次裁剪
  static const int _pruneEveryWrites = 100;

  /// 保留天数
  static const int keepDays = 7;

  /// 保留行数上限（约等于「7 天内每次发信都留着」，量级按日活用户够用）
  static const int maxRows = 5000;

  /// 追加一行发信事实；任何异常都吞掉（观测失败不该影响对话）
  Future<void> record(AiRequestStat stat) async {
    try {
      final db = await _db;
      await db.insert(table, stat.toMap());
      if (++_writesSincePrune >= _pruneEveryWrites) {
        _writesSincePrune = 0;
        await prune();
      }
    } catch (_) {
      // 表还没建好（首次升级）、写锁、磁盘满：静默放弃这一行
    }
  }

  /// 读取最近 [hours] 小时的事实行，按时间倒序（UI 只取聚合，倒序便于截断）
  ///
  /// 用 [AiRequestStat.hourBucket] 等值下界而不是 `created_at` 区间：分桶列有索引，
  /// 且定宽 `YYYYMMDDHH` 的字典序与时间序一致，代价是窗口按小时对齐（诊断够用）。
  Future<List<AiRequestStat>> recent({int hours = 24, int limit = 3000}) async {
    try {
      final db = await _db;
      final cutoff = AiRequestStat.hourBucketOf(
        DateTime.now().subtract(Duration(hours: hours - 1)),
      );
      final rows = await db.query(
        table,
        where: 'hour_bucket >= ?',
        whereArgs: [cutoff],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map(AiRequestStat.fromMap).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 不受时间窗口约束地读取全部事实行（诊断卡选「全部」档时用），按时间倒序
  Future<List<AiRequestStat>> all({int limit = 5000}) async {
    try {
      final db = await _db;
      final rows = await db.query(
        table,
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map(AiRequestStat.fromMap).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<int> count() async {
    try {
      final db = await _db;
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      return (rows.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 裁剪到「最近 [keepDays] 天且不超过 [maxRows] 行」
  ///
  /// 两条判据都要：只按天数则重度用户一天就能写下几万行，只按行数则长期不用的
  /// 设备会留着半年前的旧数据。删除走 id 下界，一条 SQL 搞定，不逐行比对时间。
  Future<int> prune() async {
    try {
      final db = await _db;
      final cutoffTime = DateTime.now()
          .subtract(const Duration(days: keepDays))
          .toIso8601String();
      var deleted = await db.delete(
        table,
        where: 'created_at < ?',
        whereArgs: [cutoffTime],
      );

      final total = await count();
      if (total > maxRows) {
        // 取「倒数第 maxRows 行的 id」作为保留下界：比 OFFSET 分页写法更省事，
        // 且 created_at 有索引时顺序稳定
        final rows = await db.query(
          table,
          columns: ['id'],
          orderBy: 'created_at DESC, id DESC',
          offset: maxRows,
          limit: 1,
        );
        final boundaryId = rows.isEmpty ? null : rows.first['id'] as int?;
        if (boundaryId != null) {
          deleted += await db.delete(table, where: 'id <= ?', whereArgs: [boundaryId]);
        }
      }
      return deleted;
    } catch (_) {
      return 0;
    }
  }

  /// 清空观测数据（设置页「清空诊断数据」用，属破坏性操作，调用方需二次确认）
  Future<int> clear() async {
    try {
      final db = await _db;
      return await db.delete(table);
    } catch (_) {
      return 0;
    }
  }
}

import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_token_usage.dart';

/// Token 用量按日聚合仓储（表 `ai_token_usage_daily`）
///
/// 用户要看的是「累计消耗」而不是逐请求明细，因此按
/// `(date, provider_id, model_name)` 聚合：一个模型一天最多一行，长期使用也不会
/// 像逐请求事实表那样膨胀。
///
/// **有意不写 sync_log、不参与备份导出**：用量是本机视角的观测数据，换设备后
/// 累计没有意义，多端合并还会把计数写冲突。口径与 `screen_usage_daily`、
/// `widget_snapshot` 一致。
///
/// **写入点必须能容忍失败**：调用方是 AiService 的响应热路径，统计失败绝不能
/// 把对话拖下水，因此 [record] 吞掉一切异常且从不抛出，调用侧 `unawaited` 即可。
class AiTokenUsageRepository {
  static const String table = 'ai_token_usage_daily';

  static final AiTokenUsageRepository instance = AiTokenUsageRepository._internal();

  AiTokenUsageRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<Database> get _db async => await _dbHelper.database;

  /// 本地自然日键：`YYYY-MM-DD`，定宽后字典序与时间序一致
  static String dateKeyOf(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  /// 累加一次成功请求的 token 消耗
  ///
  /// 同一天同一厂商同一模型的多次请求在事务里读改写，避免并发发信（AgentLoop
  /// 的多个工具轮次、日记提取与主对话并行）互相覆盖计数。
  Future<void> record({
    required String providerId,
    required String modelName,
    required AiTokenUsage usage,
  }) async {
    if (usage.isEmpty) return;
    try {
      final db = await _db;
      final date = dateKeyOf(DateTime.now());
      final now = DateTime.now().toIso8601String();
      await db.transaction((txn) async {
        final rows = await txn.query(
          table,
          columns: [
            'prompt_tokens',
            'completion_tokens',
            'total_tokens',
            'request_count',
          ],
          where: 'date = ? AND provider_id = ? AND model_name = ?',
          whereArgs: [date, providerId, modelName],
          limit: 1,
        );
        if (rows.isEmpty) {
          await txn.insert(table, {
            'date': date,
            'provider_id': providerId,
            'model_name': modelName,
            'prompt_tokens': usage.promptTokens,
            'completion_tokens': usage.completionTokens,
            'total_tokens': usage.totalTokens,
            'request_count': 1,
            'updated_at': now,
          });
          return;
        }

        int read(String key) => (rows.first[key] as num?)?.toInt() ?? 0;
        await txn.update(
          table,
          {
            'prompt_tokens': read('prompt_tokens') + usage.promptTokens,
            'completion_tokens':
                read('completion_tokens') + usage.completionTokens,
            'total_tokens': read('total_tokens') + usage.totalTokens,
            'request_count': read('request_count') + 1,
            'updated_at': now,
          },
          where: 'date = ? AND provider_id = ? AND model_name = ?',
          whereArgs: [date, providerId, modelName],
        );
      });
    } catch (_) {
      // 表未建好（首次升级）、写锁、磁盘满：静默放弃这次统计
    }
  }

  /// 读取累计 / 今日 / 近 7 天三个口径（单条 SQL 聚合，避免多次扫表）
  Future<AiTokenUsageSummary> getSummary() async {
    try {
      final db = await _db;
      final today = dateKeyOf(DateTime.now());
      final weekStart = dateKeyOf(
        DateTime.now().subtract(const Duration(days: 6)),
      );
      final rows = await db.rawQuery('''
        SELECT
          COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
          COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
          COALESCE(SUM(total_tokens), 0) AS total_tokens,
          COALESCE(SUM(request_count), 0) AS request_count,
          COALESCE(SUM(CASE WHEN date = ? THEN total_tokens ELSE 0 END), 0)
            AS today_tokens,
          COALESCE(SUM(CASE WHEN date >= ? THEN total_tokens ELSE 0 END), 0)
            AS week_tokens
        FROM $table
      ''', [today, weekStart]);

      if (rows.isEmpty) return AiTokenUsageSummary.empty;
      int read(String key) => (rows.first[key] as num?)?.toInt() ?? 0;
      return AiTokenUsageSummary(
        promptTokens: read('prompt_tokens'),
        completionTokens: read('completion_tokens'),
        totalTokens: read('total_tokens'),
        requestCount: read('request_count'),
        todayTokens: read('today_tokens'),
        weekTokens: read('week_tokens'),
      );
    } catch (_) {
      return AiTokenUsageSummary.empty;
    }
  }

  /// 清空本机统计（测试与将来的设置项使用）
  Future<void> clear() async {
    try {
      final db = await _db;
      await db.delete(table);
    } catch (_) {
      // 清空失败不影响主流程
    }
  }
}

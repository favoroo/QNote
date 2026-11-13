import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/read_files_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';

/// read_files 批量读取工具测试：参数校验不触库，读取用例使用 sqflite ffi 真实落库
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final vfs = VirtualWorkspaceService.instance;

  group('ReadFilesTool 参数校验', () {
    test('默认分发器已注册 read_files', () {
      final dispatcher = AgentToolRegistry.createDefaultDispatcher();
      expect(dispatcher.hasTool('read_files'), isTrue);
      expect(dispatcher.toFunctionDefinitions().any((f) => (f['function'] as Map)['name'] == 'read_files'), isTrue);
    });

    test('paths 为空报错', () async {
      final result = await ReadFilesTool().execute({'paths': const []});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('不能为空'));
    });

    test('超过显式路径上限报错', () async {
      final paths = List.generate(ReadFilesTool.maxBatchSize + 1, (i) => '/notes/批量校验/$i.md');
      final result = await ReadFilesTool().execute({'paths': paths});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('最多'));
    });

    test('目录根不能直接读取，且兼容单字符串 paths', () async {
      final result = await ReadFilesTool().execute({'paths': '/notes'});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('是目录'));
    });

    test('日期序列目录缺少区间报错', () async {
      final result = await ReadFilesTool().execute({
        'paths': ['/timeline'],
      });
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('start_date'));
    });

    test('非法日期与结束早于开始均报错', () async {
      final invalid = await ReadFilesTool().execute({
        'paths': ['/timeline'],
        'start_date': '2026-2-3',
      });
      expect(invalid.isError, isTrue);
      expect(invalid.modelOutput, contains('日期格式无效'));

      final reversed = await ReadFilesTool().execute({
        'paths': ['/timeline'],
        'start_date': '2026-09-13',
        'end_date': '2026-09-07',
      });
      expect(reversed.isError, isTrue);
      expect(reversed.modelOutput, contains('不能早于'));
    });

    test('日期区间超过上限报错', () async {
      final result = await ReadFilesTool().execute({
        'paths': ['/timeline'],
        'start_date': '2026-01-01',
        'end_date': '2026-02-01',
      });
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('最长'));
    });
  });

  group('ReadFilesTool 批量读取', () {
    test('按日期区间读取时间线并跳过无数据日期', () async {
      await vfs.writeFile('/timeline/2025-03-01.md', '## [08:00] 早餐\n- 分类: 饮食');
      await vfs.writeFile('/timeline/2025-03-03.md', '## [09:00] 徒步\n- 分类: 活动');

      final result = await ReadFilesTool().execute({
        'paths': ['/timeline'],
        'start_date': '2025-03-01',
        'end_date': '2025-03-03',
      });

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('早餐'));
      expect(result.modelOutput, contains('徒步'));
      expect(result.modelOutput, contains('跳过 1 个无数据日期'));
      expect(result.uiDetails?['read'], 2);
      expect(result.uiDetails?['skipped'], 1);
      expect(result.uiDetails?['dateRange'], '2025-03-01~2025-03-03');
    });

    test('显式多路径去重读取', () async {
      await vfs.writeFile('/notes/批量读取测试/甲.md', '甲的内容');
      await vfs.writeFile('/notes/批量读取测试/乙.md', '乙的内容');

      final result = await ReadFilesTool().execute({
        'paths': ['/notes/批量读取测试/甲.md', '/notes/批量读取测试/乙.md', '/notes/批量读取测试/甲.md'],
      });

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('甲的内容'));
      expect(result.modelOutput, contains('乙的内容'));
      expect(result.uiDetails?['total'], 2);
    });

    test('健康数据无数据日期自动跳过', () async {
      final healthRepo = HealthMetricRepository(DatabaseHelper.instance);
      await healthRepo.upsertDailyMetrics(
        HealthDailyMetrics(date: '2025-04-01', steps: 4321, updatedAt: DateTime.now()),
      );

      final result = await ReadFilesTool().execute({
        'paths': ['/health'],
        'start_date': '2025-04-01',
        'end_date': '2025-04-02',
      });

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('4321'));
      expect(result.uiDetails?['read'], 1);
      expect(result.uiDetails?['skipped'], 1);
    });

    test('总预算不足时停止读取并列出未读文件', () async {
      await vfs.writeFile('/notes/批量读取测试/长文1.md', 'A' * 4000);
      await vfs.writeFile('/notes/批量读取测试/长文2.md', 'B' * 4000);

      final result = await ReadFilesTool().execute({
        'paths': ['/notes/批量读取测试/长文1.md', '/notes/批量读取测试/长文2.md'],
        'max_chars': 2000,
      });

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('未读'));
      expect(result.uiDetails?['unread'], 1);
    });

    test('单文件超预算时按行截断并提示续读', () async {
      final longContent = List.generate(300, (i) => '第 $i 行内容').join('\n');
      await vfs.writeFile('/notes/批量读取测试/超长.md', longContent);

      final result = await ReadFilesTool().execute({
        'paths': ['/notes/批量读取测试/超长.md'],
        'max_chars_per_file': 1000,
      });

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('可用 read_file 的 offset 续读'));
      final files = result.uiDetails?['files'] as List;
      expect(files.first['truncated'], isTrue);
    });
  });
}

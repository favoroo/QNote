import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/refresh/refresh_failure_notice.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // 刷新失败会先写日志，日志持久化依赖 SharedPreferences
    SharedPreferences.setMockInitialValues({});
    RefreshFailureNotice.resetForTest();
  });

  /// 复刻真实 app 结构：rootNavigatorKey 挂在 MaterialApp 的 Navigator 上
  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();
  }

  /// Toast 入场动画 250ms：先 pump 一帧让 entry 完成 initState，再推进动画时长
  Future<void> settleToast(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 排干 LoggerService 的 5 秒落盘防抖 Timer，否则用例结束时报「Timer 仍在挂起」
  Future<void> flushLogger(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
  }

  group('RefreshFailureNotice', () {
    testWidgets('经 rootNavigatorKey 的 Overlay 挂出提示并提供重试', (tester) async {
      await pumpHost(tester);
      var retryCount = 0;

      RefreshFailureNotice.report(
        source: '日记',
        error: Exception('database is locked'),
        retry: () => retryCount++,
      );
      await settleToast(tester);

      expect(find.text('日记列表刷新失败，显示的是上次数据'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retryCount, 1);

      await flushLogger(tester);
    });

    testWidgets('不传 retry 时只显示提示，不出现重试入口', (tester) async {
      await pumpHost(tester);

      RefreshFailureNotice.report(source: '笔记', error: Exception('no such table'));
      await settleToast(tester);

      expect(find.text('笔记列表刷新失败，显示的是上次数据'), findsOneWidget);
      expect(find.text('重试'), findsNothing);

      await flushLogger(tester);
    });

    testWidgets('合并窗口内的并发失败只提示一条，避免 Toast 互相顶掉', (tester) async {
      await pumpHost(tester);

      // 一次工作区事件会并发刷新多个列表 provider，全部落在同一个合并窗口内
      RefreshFailureNotice.report(source: '日记', error: Exception('e1'), retry: () {});
      RefreshFailureNotice.report(source: '笔记', error: Exception('e2'), retry: () {});
      RefreshFailureNotice.report(source: '待办', error: Exception('e3'), retry: () {});
      await settleToast(tester);

      expect(find.text('日记列表刷新失败，显示的是上次数据'), findsOneWidget);
      expect(find.text('笔记列表刷新失败，显示的是上次数据'), findsNothing);
      expect(find.text('待办列表刷新失败，显示的是上次数据'), findsNothing);

      await flushLogger(tester);
    });

    testWidgets('提示被合并吞掉时仍必须留下日志痕迹', (tester) async {
      await pumpHost(tester);

      RefreshFailureNotice.report(source: '日记', error: Exception('e1'), retry: () {});
      await settleToast(tester);

      // LoggerService 是跨用例累积的单例，只看本次新增的部分
      final entriesBefore = LoggerService.instance.entries.length;
      // 第二条落在合并窗口内：不再弹提示，但日志仍要记录
      RefreshFailureNotice.report(source: '笔记', error: Exception('e2'), retry: () {});
      await tester.pump();

      final added = LoggerService.instance.entries
          .skip(entriesBefore)
          .map((e) => e.message)
          .toList();
      expect(added.where((m) => m.contains('笔记列表刷新失败')), hasLength(1));
      expect(find.text('笔记列表刷新失败，显示的是上次数据'), findsNothing);

      await flushLogger(tester);
    });
  });
}

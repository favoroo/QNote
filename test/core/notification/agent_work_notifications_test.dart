import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/notification/agent_work_notifications.dart';

/// 记录调用序列的假 sink：方法体内无 await，调用即同步落记录。
class _FakeSink implements AgentNotificationSink {
  _FakeSink({required this.keepsAliveInBackground});

  @override
  final bool keepsAliveInBackground;

  final List<String> calls = [];
  String? lastTitle;
  String? lastBody;
  bool? lastNotify;

  @override
  Future<void> showWorking({required String title, required String body}) async {
    calls.add('show');
    lastTitle = title;
    lastBody = body;
  }

  @override
  Future<void> updateWorking({required String title, required String body}) async {
    calls.add('update');
    lastTitle = title;
    lastBody = body;
  }

  @override
  Future<void> finishWorking({required String title, required String body, required bool notify}) async {
    calls.add('finish:$notify');
    lastTitle = title;
    lastBody = body;
    lastNotify = notify;
  }

  @override
  Future<void> dismissWorking() async {
    calls.add('dismiss');
  }

  @override
  Future<void> resetOnLaunch() async {
    calls.add('reset');
  }
}

void main() {
  late _FakeSink android;
  late _FakeSink ios;

  setUp(() {
    android = _FakeSink(keepsAliveInBackground: true);
    ios = _FakeSink(keepsAliveInBackground: false);
  });

  group('Android（有前台服务）', () {
    test('任务一开始就挂常驻通知，正文含指令摘要', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: '整理今天的日记和待办', statusText: '小Q准备中');
      expect(android.calls, ['show']);
      expect(android.lastTitle, '小Q 正在工作');
      expect(android.lastBody, contains('整理今天的日记和待办'));
      expect(n.isRunning, isTrue);
    });

    test('并发任务引用计数：全部结束才收尾', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: '任务A');
      n.onRunStarted(summary: '任务B');
      expect(android.calls, ['show']); // 第二个任务不重复挂通知
      n.onRunFinished(outcome: AgentRunOutcome.completed);
      expect(android.calls, ['show']); // 仍有一个在跑，不收尾
      n.onRunFinished(outcome: AgentRunOutcome.completed);
      expect(android.calls, ['show', 'finish:false']);
      expect(n.isRunning, isFalse);
    });

    test('在后台完成才响铃提醒，前台完成只撤通知', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: '写周报');
      n.setAppForeground(false);
      n.onRunFinished(outcome: AgentRunOutcome.completed, resultSummary: '周报已生成');
      expect(android.lastNotify, isTrue);
      expect(android.lastTitle, '小Q 已完成');
      expect(android.lastBody, contains('周报已生成'));
    });

    test('结局映射标题：中止/失败', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: 'x');
      n.onRunFinished(outcome: AgentRunOutcome.aborted);
      expect(android.lastTitle, '小Q 已中止');

      n.onRunStarted(summary: 'y');
      n.onRunFinished(outcome: AgentRunOutcome.failed);
      expect(android.lastTitle, '小Q 执行失败');
    });

    test('前台时的状态变化不打扰通知栏', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: 'x');
      android.calls.clear();
      n.onRunStatus('小Q思考中 · 第 3 步');
      expect(android.calls, isEmpty);
    });

    test('退到后台会立即刷新一次最新状态', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: 'x');
      n.onRunStatus('小Q思考中 · 第 3 步'); // 前台：不推
      android.calls.clear();
      n.setAppForeground(false);
      expect(android.calls, ['update']);
      expect(android.lastBody, contains('小Q思考中 · 第 3 步'));
    });

    test('回到前台不会撤下常驻通知（保活需要）', () {
      final n = AgentWorkNotifications(sink: android);
      n.onRunStarted(summary: 'x');
      n.setAppForeground(false);
      n.setAppForeground(true);
      expect(android.calls.contains('dismiss'), isFalse);
    });
  });

  group('iOS（无前台服务）', () {
    test('前台开始不通知，退到后台才挂工作通知', () {
      final n = AgentWorkNotifications(sink: ios);
      n.onRunStarted(summary: '整理笔记');
      expect(ios.calls, isEmpty);
      n.setAppForeground(false);
      expect(ios.calls, ['show']);
      expect(ios.lastBody, contains('整理笔记'));
    });

    test('回到前台撤下工作通知', () {
      final n = AgentWorkNotifications(sink: ios);
      n.onRunStarted(summary: '整理笔记');
      n.setAppForeground(false);
      ios.calls.clear();
      n.setAppForeground(true);
      expect(ios.calls, ['dismiss']);
    });

    test('后台完成时用完成通知替换工作通知并响铃', () {
      final n = AgentWorkNotifications(sink: ios);
      n.onRunStarted(summary: '整理笔记');
      n.setAppForeground(false);
      n.onRunFinished(outcome: AgentRunOutcome.completed, resultSummary: '搞定');
      expect(ios.lastNotify, isTrue);
    });
  });

  test('resetOnLaunch 清空计数并清理残留', () {
    final n = AgentWorkNotifications(sink: android);
    n.onRunStarted(summary: 'x');
    android.calls.clear();
    n.resetOnLaunch();
    expect(android.calls, ['reset']);
    expect(n.isRunning, isFalse);
    // 清理后游离的完成回调不应误触发通知
    n.onRunFinished(outcome: AgentRunOutcome.completed);
    expect(android.calls, ['reset']);
  });

  test('未注入 sink 时安全空转', () {
    final n = AgentWorkNotifications();
    expect(() => n.onRunStarted(summary: 'x'), returnsNormally);
    expect(n.isRunning, isTrue);
    expect(() => n.onRunFinished(outcome: AgentRunOutcome.completed), returnsNormally);
    expect(n.isRunning, isFalse);
  });
}

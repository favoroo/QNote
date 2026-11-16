import 'dart:async';

import 'package:qnote_flutter/core/utils/agent_notification_text.dart';

/// 一次小Q 任务的最终结局（决定完成通知的标题）。
enum AgentRunOutcome {
  /// 正常跑完
  completed,

  /// 用户主动中止
  aborted,

  /// 执行报错
  failed,
}

/// 完成/工作中通知的落地接口。
///
/// 抽出接口是为了让 [AgentWorkNotifications] 的聚合逻辑可单测：
/// 生产实现是 [NotificationService]（内部走 flutter_local_notifications），
/// 测试里注入假实现验证调用序列即可，无需触碰平台通道。
abstract interface class AgentNotificationSink {
  /// 该平台是否有前台服务能力（Android 为 true）。
  ///
  /// true：任务一开始就挂常驻通知并保活；
  /// false（iOS）：只在退到后台后才发工作通知，回到前台即撤下。
  bool get keepsAliveInBackground;

  /// 显示「小Q 正在工作」常驻通知。
  Future<void> showWorking({required String title, required String body});

  /// 原地更新常驻通知的标题/正文。
  Future<void> updateWorking({required String title, required String body});

  /// 收尾：结束常驻通知；[notify] 为真时再补一条带声音的完成提醒。
  Future<void> finishWorking({required String title, required String body, required bool notify});

  /// 撤回常驻通知但不发完成提醒（平台不支持常驻、回到前台时用）。
  Future<void> dismissWorking();

  /// 启动时清理上一次运行可能残留的通知/前台服务。
  Future<void> resetOnLaunch();
}

/// 小Q 任务运行期的通知调度（全局单例）。
///
/// 悬浮面板与全页面两条 Agent 管线都会调用它，因此内部按引用计数聚合：
/// 只有「第一个任务开始」「最后一个任务结束」才真正动通知，任务并存时
/// 不会因为其中一个结束就撤掉通知或误报完成。
class AgentWorkNotifications {
  AgentWorkNotifications({AgentNotificationSink? sink}) : _sink = sink;

  /// 全局单例；sink 在 [NotificationService.init] 时通过 [attachSink] 注入。
  static final AgentWorkNotifications instance = AgentWorkNotifications();

  /// 状态行刷新到通知正文的最小间隔：太频繁会闪动，太慢又显不出进度。
  static const Duration _kStatusThrottle = Duration(seconds: 3);

  static const String _workingTitle = '小Q 正在工作';
  static const String _completedTitle = '小Q 已完成';
  static const String _abortedTitle = '小Q 已中止';
  static const String _failedTitle = '小Q 执行失败';

  AgentNotificationSink? _sink;

  int _activeRuns = 0;
  String _summary = '';
  String _latestStatus = '';
  DateTime? _lastStatusPushAt;
  bool _foreground = true;

  /// 当前是否已挂出常驻工作通知（避免重复 show / 误 dismiss）
  bool _showingWorking = false;

  /// 是否有任务正在执行（供返回键拦截等外部判断）。
  bool get isRunning => _activeRuns > 0;

  /// 注入平台实现（Web/未初始化时为 null，所有调用安全空转）。
  void attachSink(AgentNotificationSink sink) => _sink = sink;

  /// 首个任务开始。
  void onRunStarted({required String summary, String? statusText}) {
    _activeRuns += 1;
    if (_activeRuns == 1) {
      _summary = agentNotificationSummary(summary, fallback: '小Q 正在处理你的请求');
      _latestStatus = statusText?.trim() ?? '';
      _lastStatusPushAt = null;
    }
    _syncWorkingVisibility();
  }

  /// 状态行文案变化（思考中/第 N 步/执行某工具…）。
  void onRunStatus(String statusText) {
    final text = statusText.trim();
    if (text.isEmpty) return;
    _latestStatus = text;
    final sink = _sink;
    // 前台时不打扰通知栏；后台时限流刷新，避免状态跳动太频繁
    if (sink == null || _activeRuns == 0 || _foreground || !_showingWorking) return;
    final now = DateTime.now();
    if (_lastStatusPushAt != null && now.difference(_lastStatusPushAt!) < _kStatusThrottle) return;
    _lastStatusPushAt = now;
    unawaited(sink.updateWorking(title: _workingTitle, body: _workingBody));
  }

  /// 最后一个任务结束。
  void onRunFinished({required AgentRunOutcome outcome, String? resultSummary}) {
    if (_activeRuns == 0) return;
    _activeRuns -= 1;
    if (_activeRuns > 0) return;

    final sink = _sink;
    _latestStatus = '';
    _lastStatusPushAt = null;
    final title = switch (outcome) {
      AgentRunOutcome.completed => _completedTitle,
      AgentRunOutcome.aborted => _abortedTitle,
      AgentRunOutcome.failed => _failedTitle,
    };
    final fallbackBody = switch (outcome) {
      AgentRunOutcome.completed => '任务已完成，点此查看结果',
      AgentRunOutcome.aborted => '任务已中止，点此查看',
      AgentRunOutcome.failed => '任务执行失败，点此查看',
    };
    // 只有用户已经离开 App 才需要"提醒"；留在前台时正文已经直接可见
    final notify = !_foreground;
    if (sink != null) {
      unawaited(
        sink.finishWorking(
          title: title,
          body: agentNotificationSummary(resultSummary, fallback: fallbackBody),
          notify: notify,
        ),
      );
    }
    _showingWorking = false;
  }

  /// App 前后台切换（由全局生命周期监听驱动）。
  void setAppForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (_activeRuns == 0) return;
    if (!foreground) {
      // 刚离开前台：立即同步一次最新状态，让用户一进通知栏就看到真进度
      _lastStatusPushAt = null;
    }
    _syncWorkingVisibility(forceStatusPush: !foreground);
  }

  /// 启动时清理残留（进程被杀后可能留下"工作中"通知或前台服务）。
  void resetOnLaunch() {
    _activeRuns = 0;
    _summary = '';
    _latestStatus = '';
    _lastStatusPushAt = null;
    _showingWorking = false;
    unawaited(_sink?.resetOnLaunch());
  }

  /// 根据「有无任务 + 平台能力 + 前后台」决定常驻通知的显示/更新/撤下。
  void _syncWorkingVisibility({bool forceStatusPush = false}) {
    final sink = _sink;
    if (sink == null) return;
    // Android（有前台服务）恒定显示；iOS 等只在后台时显示
    final shouldShow = _activeRuns > 0 && (sink.keepsAliveInBackground || !_foreground);
    if (shouldShow) {
      final body = _workingBody;
      if (_showingWorking) {
        if (forceStatusPush) {
          _lastStatusPushAt = DateTime.now();
          unawaited(sink.updateWorking(title: _workingTitle, body: body));
        }
      } else {
        _showingWorking = true;
        unawaited(sink.showWorking(title: _workingTitle, body: body));
      }
    } else if (_showingWorking) {
      _showingWorking = false;
      unawaited(sink.dismissWorking());
    }
  }

  /// 工作通知正文：状态行在前（更实时），任务摘要随其后（可能被截断）。
  String get _workingBody =>
      agentNotificationSummary(_latestStatus.isEmpty ? _summary : '$_latestStatus｜$_summary', fallback: '小Q 正在处理你的请求');
}

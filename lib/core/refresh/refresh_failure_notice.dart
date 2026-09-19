import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 列表后台刷新失败的统一轻提示。
///
/// 刷新失败时列表状态**保留上一次数据**（不整屏转错误态，避免首屏能看、后台一刷新
/// 就整屏报错的观感倒退），但失败本身必须留下痕迹：写日志 + 一条带重试的轻提示。
class RefreshFailureNotice {
  RefreshFailureNotice._();

  /// 一次工作区事件会并发触发多个列表 provider 刷新，而 Toast 是 Overlay 单槽无队列
  /// （后一条顶掉前一条），故用窗口期合并成一条，避免连环覆盖导致只看到最后一个数据源。
  static const Duration _coalesceWindow = Duration(seconds: 5);

  /// 带重试按钮的提示需要留出点击时间
  static const Duration _toastDuration = Duration(seconds: 5);

  static DateTime? _lastShownAt;

  /// [source] 数据源中文名（如「日记」「笔记」），[retry] 为空时只显示提示不提供重试。
  static void report({
    required String source,
    required Object error,
    StackTrace? stackTrace,
    VoidCallback? retry,
  }) {
    LoggerService.instance.error(
      '$source列表刷新失败',
      category: LogCategory.database,
      details: error.toString(),
      stackTrace: stackTrace,
    );

    final now = DateTime.now();
    final lastShownAt = _lastShownAt;
    if (lastShownAt != null && now.difference(lastShownAt) < _coalesceWindow) {
      return;
    }
    _lastShownAt = now;

    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) {
      return;
    }
    Toast.showIn(
      overlay,
      '$source列表刷新失败，显示的是上次数据',
      type: ToastType.error,
      duration: retry == null ? null : _toastDuration,
      actionLabel: retry == null ? null : '重试',
      onAction: retry,
    );
  }

  /// 重置合并窗口。
  ///
  /// 窗口基于 `DateTime.now()` 判断，而 widget test 的 `pump(Duration)` 只推进
  /// 假定时器、不推进墙上时钟，用例之间无法靠等待越过窗口，故显式暴露重置口。
  @visibleForTesting
  static void resetForTest() => _lastShownAt = null;
}

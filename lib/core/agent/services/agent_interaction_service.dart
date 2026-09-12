import 'dart:async';

import 'package:flutter/material.dart'
    show BuildContext, Navigator;
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/widgets/ai/ask_user_dialog.dart';

/// Agent 人机交互调度服务
///
/// 负责在 Agent 执行 `ask_user` 等需要用户确认的工具时挂起异步执行，
/// 唤起全局交互弹窗让用户选择或输入，并将用户的决策结果返回给工具恢复执行。
class AgentInteractionService {
  AgentInteractionService._();
  static final AgentInteractionService instance = AgentInteractionService._();

  Completer<String?>? _pendingCompleter;
  Timer? _timeoutTimer;

  /// 当前打开中的 ask_user 对话框 context，用于取消/超时时主动关闭残留弹窗
  BuildContext? _dialogContext;

  /// 向用户提出确认或选择请求并等待结果
  ///
  /// 返回用户选取的选项文本或自定义输入的文字。
  /// 若用户取消、关闭弹窗或操作超时，返回 null。
  Future<String?> askUser({
    required String question,
    List<String>? options,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    // 若有上一个未决的提问，先予以取消
    cancelPending('新的提问请求已覆盖');

    final completer = Completer<String?>();
    _pendingCompleter = completer;

    // 设置安全超时，防止未操作导致 Agent 永远挂起
    _timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        LoggerService.instance.logAI('用户交互确认超时未响应，已自动取消');
        completer.complete(null);
        _closeDialog();
      }
    });

    // 调度 UI 弹窗
    Future.microtask(() async {
      final context = rootNavigatorKey.currentContext;
      if (context == null || !context.mounted) {
        LoggerService.instance.logAI(
          '无法获取有效的全局 NavigatorContext 弹出确认对话框',
          level: LogLevel.warning,
        );
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        return;
      }

      try {
        final result = await showAskUserDialog(
          context: context,
          question: question,
          options: options,
          onDialogBuilt: (dialogContext) => _dialogContext = dialogContext,
        );
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (e, stack) {
        LoggerService.instance.logAI(
          '弹出用户交互对话框失败: $e',
          level: LogLevel.error,
          details: stack.toString(),
        );
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }
    });

    try {
      final answer = await completer.future;
      return answer;
    } finally {
      _cleanup();
    }
  }

  /// 取消当前挂起的用户提问
  void cancelPending([String reason = '已取消']) {
    if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
      _pendingCompleter!.complete(null);
    }
    _closeDialog();
    _cleanup();
  }

  /// 主动关闭仍在打开中的 ask_user 对话框。
  ///
  /// 只完成 Completer 的话对话框会残留在导航栈上（Agent 已结束但确认弹窗
  /// 挡住整个界面），因此取消/超时时需要把它一并 pop 掉
  void _closeDialog() {
    final dialogContext = _dialogContext;
    _dialogContext = null;
    if (dialogContext == null || !dialogContext.mounted) return;
    try {
      Navigator.of(dialogContext).pop();
    } catch (e) {
      LoggerService.instance.logAI(
        '关闭 ask_user 残留对话框失败: $e',
        level: LogLevel.warning,
      );
    }
  }

  void _cleanup() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _pendingCompleter = null;
    _dialogContext = null;
  }
}

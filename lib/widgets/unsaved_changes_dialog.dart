import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 存在未保存改动时的统一离开确认；返回 true 表示可以继续离开。
///
/// 命名刻意区别于调用方常见的 `confirmUnsavedChanges` 实例方法，避免同类内
/// 方法名遮蔽顶层函数。
///
/// 三种落点：选「保存」且保存成功、选「放弃更改」、或直接关闭对话框外的其它
/// 显式选择。**关闭（点遮罩/返回键）视为留在当前页**，与「取消」同义。
///
/// [onSave] 约定：返回 true 表示已保存成功、可以离开；返回 false 或抛异常都算失败，
/// 此时留在当前页并提示 [failureMessage]。**具体错误细节请调用方自己写日志**，
/// 这里只给一句通用文案，避免把异常对象直接拼进用户可见的提示里。
Future<bool> promptUnsavedChanges(
  BuildContext context, {
  String title = '未保存的更改',
  String content = '有未保存的更改，离开后将丢失。',
  String failureMessage = '未能保存，仍停在当前页',
  Future<bool> Function()? onSave,
}) async {
  final colorScheme = Theme.of(context).colorScheme;

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('discard'),
          child: Text(
            '放弃更改',
            style: TextStyle(color: colorScheme.error),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('cancel'),
          child: const Text('取消'),
        ),
        if (onSave != null)
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
      ],
    ),
  );

  switch (result) {
    case 'discard':
      return true;
    case 'save':
      bool saved = false;
      try {
        saved = await onSave!();
      } catch (_) {
        // 抛异常与返回 false 同义：没存上就不许离开
      }
      if (!saved && context.mounted) {
        // 保存没成功就离开等于丢内容，停在原页等用户处理
        Toast.error(context, failureMessage);
      }
      return saved;
    default:
      // 含 'cancel' 与对话框被遮罩/返回键关闭
      return false;
  }
}

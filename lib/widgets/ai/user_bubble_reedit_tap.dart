import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_durations.dart';

/// 最后一条用户提问的「点一下再次编辑」承载层：整行可点 + 按下高亮 + 轻震动。
///
/// 做成气泡外层装饰而不是给 `ChatBubble` 加回调：`ChatBubble` 是无状态组件，按下态
/// 需要局部状态；且用户气泡本体是不透明的 `colorScheme.primary` 底色，`InkWell` 的水波纹
/// 画在祖先 Material 上会被整个遮掉，只能自绘一层行背景。
///
/// 不再挂编辑图标：点击本身已不具破坏性（只把提问回填进输入框，撤回推迟到点发送），
/// 常驻图标反而让人误以为那是一条独立的「撤回」按钮。
class UserBubbleReeditTap extends StatefulWidget {
  const UserBubbleReeditTap({
    super.key,
    required this.enabled,
    this.active = false,
    required this.onTap,
    required this.child,
  });

  /// 生成中为 false：不给按下反馈，但点击仍上抛，由页面 Toast 说明原因
  final bool enabled;

  /// 这条提问是否已在编辑态：常驻一层淡底色，让「输入框里那份就是这条提问」可见
  final bool active;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<UserBubbleReeditTap> createState() => _UserBubbleReeditTapState();
}

class _UserBubbleReeditTapState extends State<UserBubbleReeditTap> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return GestureDetector(
      // 命中面是整行，不是只有气泡本体：`BoxDecoration.hitTest` 对矩形无条件返回 true，
      // 背景盒把行左留白一起算作可点区域。点击已不具破坏性，宽命中面换来的是好点中；
      // 想滚动仍会被拖拽手势抢走（见 onTapCancel）
      onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      // 震动放在抬手确认的 onTap 而非 onTapDown：列表里按下常常只是想滚动，
      // 放在 tapDown 会让用户翻聊天记录经过这条气泡时莫名震一下
      onTap: () {
        // 成功点按不会走 onTapCancel，高亮必须在这里自己收，否则抬手后一直亮着
        setState(() => _pressed = false);
        if (widget.enabled) HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: AnimatedContainer(
        duration: AppDurations.fast,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          // 三态底色：按下最重、编辑态常驻一档、其余不画。常驻色替代已移除的编辑图标，
          // 表示「输入框里那份就是这条提问」
          color: _pressed && widget.enabled
              ? primary.withValues(alpha: isDark ? 0.14 : 0.08)
              : widget.active
              ? primary.withValues(alpha: isDark ? 0.10 : 0.06)
              : null,
          borderRadius: BorderRadius.circular(16),
        ),
        child: widget.child,
      ),
    );
  }
}

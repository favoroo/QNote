import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_durations.dart';

/// 最后一条用户提问的「点一下重新编辑」承载层：气泡左侧常驻编辑图标 + 按下高亮 + 轻震动。
///
/// 做成气泡外层装饰而不是给 `ChatBubble` 加回调：`ChatBubble` 是无状态组件，按下态
/// 需要局部状态；且用户气泡本体是不透明的 `colorScheme.primary` 底色，`InkWell` 的水波纹
/// 画在祖先 Material 上会被整个遮掉，只能自绘一层行背景。
class UserBubbleReeditTap extends StatefulWidget {
  const UserBubbleReeditTap({
    super.key,
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  /// 生成中为 false：图标转禁用色、不给按下反馈，但点击仍上抛，由页面 Toast 说明原因
  final bool enabled;
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
      // 命中判定用默认的 deferToChild：只有气泡本体与图标算命中，整行左侧留白不算，
      // 免得在滚动区随手一点就触发回退
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
          // 未按下时 color 传 null 而非 transparent：ColoredBox 会吞掉命中测试，
          // 那样整行留白都变成可点区域，deferToChild 就白设了
          color: _pressed && widget.enabled
              ? primary.withValues(alpha: isDark ? 0.14 : 0.08)
              : null,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            // 用户气泡 maxWidth 恒为屏宽的 82%，行左恒留有余 ≥18% 的空档，
            // 图标挂在空档里既不挤压气泡排版，也不会与正文重叠
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: Tooltip(
                  message: '点击重新编辑这条提问',
                  child: Icon(
                    Icons.edit_note_rounded,
                    size: 18,
                    // 弱化色点缀：M3 次级文本色在深浅 surface 上都清晰，又不抢正文注意力
                    color: widget.enabled
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.38,
                          ),
                  ),
                ),
              ),
            ),
            widget.child,
          ],
        ),
      ),
    );
  }
}

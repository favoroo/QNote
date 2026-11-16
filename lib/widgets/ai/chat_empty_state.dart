import 'package:flutter/material.dart';

/// 新建对话的空态。
///
/// 旧版本会把欢迎语作为一条 assistant 消息塞进会话流，新会话看起来像小Q
/// 已经说了一句，而且每个新会话都重复。现在会话保持真正的空白，只在中间
/// 留一个「Hi」和一枚主题色圆点，安静地提示可以开始输入。
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Hi',
            style: theme.textTheme.displayLarge?.copyWith(
              fontSize: 72,
              fontWeight: FontWeight.w700,
              height: 1,
              letterSpacing: -2.5,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          // 圆点压到接近基线的位置，读起来像句号，但保留主题色作为视觉落点
          Transform.translate(
            offset: const Offset(0, 16),
            child: Container(
              key: const ValueKey('chat_empty_dot'),
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            ),
          ),
        ],
      ),
    );
  }
}

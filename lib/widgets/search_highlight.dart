import 'package:flutter/material.dart';

/// 把 [text] 中首个 [query] 命中处加粗着色；未命中或关键词为空时退化为普通 [Text]。
///
/// 全局搜索页（`widgets/search_view.dart`）与小Q历史对话抽屉共用这一份实现，
/// 避免同一个关键词在两个地方高亮得不一样。
///
/// [baseStyle] 为整行基础样式：不传时沿用主题 `bodyLarge`（全局搜索的用法），
/// 抽屉里则传入会话标题自己的字色，让「选中态着 primary」与高亮不互相打架。
Widget highlightSearchMatch(
  String text,
  String query,
  ThemeData theme, {
  bool isSubtitle = false,
  TextStyle? baseStyle,
}) {
  final lineStyle = isSubtitle
      ? theme.textTheme.bodySmall
      : (baseStyle ?? theme.textTheme.bodyLarge);
  // 未命中分支保持「不传 style」以继承宿主（ListTile）默认样式，与原实现一致：
  // 只有高亮分支需要自己拿一套样式来铺 RichText。
  final plain = Text(
    text,
    maxLines: isSubtitle ? 2 : 1,
    overflow: TextOverflow.ellipsis,
    style: isSubtitle ? theme.textTheme.bodySmall : baseStyle,
  );

  if (query.isEmpty) {
    return plain;
  }

  final index = text.toLowerCase().indexOf(query.toLowerCase());
  if (index == -1) {
    return plain;
  }

  final before = text.substring(0, index);
  final match = text.substring(index, index + query.length);
  final after = text.substring(index + query.length);

  return RichText(
    maxLines: isSubtitle ? 2 : 1,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: lineStyle,
      children: [
        TextSpan(text: before),
        TextSpan(
          text: match,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.primaryContainer.withValues(
              alpha: 0.3,
            ),
          ),
        ),
        TextSpan(text: after),
      ],
    ),
  );
}

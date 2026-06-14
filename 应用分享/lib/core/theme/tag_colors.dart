import 'package:flutter/material.dart';

abstract class TagColors {
  static const Color sleep = Color(0xFF6366F1);
  static const Color diet = Color(0xFFF59E0B);
  static const Color activity = Color(0xFF10B981);
  static const Color finance = Color(0xFFEF4444);
  static const Color defaultTag = Color(0xFF6B7280);

  static const Map<String, Color> map = {
    '睡眠': sleep,
    '饮食': diet,
    '活动': activity,
    '记账': finance,
  };

  static Color of(String displayTag) => map[displayTag] ?? defaultTag;
}

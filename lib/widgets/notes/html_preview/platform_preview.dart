import 'package:flutter/material.dart';

/// 非 io/web 平台的兜底实现（当前目标平台 Web/iOS/Android 均会命中前两者）
class PlatformPreview extends StatelessWidget {
  final String htmlContent;
  final String? noteId;

  const PlatformPreview({
    super.key,
    required this.htmlContent,
    this.noteId,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '当前平台不支持网页预览',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

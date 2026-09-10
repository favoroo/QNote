import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:qnote_flutter/core/network/update_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 弹出应用更新提示框。
///
/// 返回 true 表示用户选择更新（此时已尝试拉起下载），false 表示取消或关闭。
Future<bool> showUpdateDialog({
  required BuildContext context,
  required UpdateInfo updateInfo,
  required String currentVersion,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => _UpdateDialog(
      updateInfo: updateInfo,
      currentVersion: currentVersion,
    ),
  ).then((value) => value ?? false);
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({
    required this.updateInfo,
    required this.currentVersion,
  });

  final UpdateInfo updateInfo;
  final String currentVersion;

  /// 关闭弹窗后统一用根节点 context 提示，避免弹窗已销毁导致 Toast 丢失。
  void _notifyError(String message) {
    final rootContext = rootNavigatorKey.currentContext;
    if (rootContext == null) return;
    Toast.error(rootContext, message);
  }

  /// 先关闭弹窗再拉起下载，避免 Toast 与弹窗叠加。
  Future<void> _handleUpdate(BuildContext context) async {
    Navigator.of(context).pop(true);

    final uri = Uri.tryParse(updateInfo.downloadUrl);
    if (uri == null) {
      _notifyError('下载链接无效');
      return;
    }

    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        _notifyError('无法打开下载链接');
      }
    } catch (_) {
      _notifyError('打开下载链接失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sizeText = updateInfo.fileSizeText;
    final notes = updateInfo.releaseNotes.trim();

    return AlertDialog(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      icon: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.system_update_rounded,
          color: colorScheme.onPrimaryContainer,
          size: 26,
        ),
      ),
      title: Text(
        '发现新版本',
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: colorScheme.onSurface,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 版本对比：当前版本 → 最新版本
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _VersionBadge(
                    label: currentVersion,
                    highlighted: false,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  _VersionBadge(
                    label: updateInfo.version,
                    highlighted: true,
                  ),
                ],
              ),
            ),
            if (sizeText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Center(
                child: Text(
                  '安装包 $sizeText',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                '更新内容',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: notes,
                    shrinkWrap: true,
                    onTapLink: (text, href, title) {
                      final link = href == null ? null : Uri.tryParse(href);
                      if (link != null) {
                        launchUrl(link, mode: LaunchMode.externalApplication);
                      }
                    },
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.6,
                      ),
                      pPadding: const EdgeInsets.symmetric(vertical: 2),
                      h1: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      h2: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      h3: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      listBullet: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.6,
                      ),
                      strong: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      a: TextStyle(
                        color: colorScheme.primary,
                        fontSize: 13,
                        decoration: TextDecoration.underline,
                      ),
                      code: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        fontSize: 12,
                      ),
                      tableBody: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                      tableHead: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      actions: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => _handleUpdate(context),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('更新'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 版本号徽标，最新一版用主色高亮。
class _VersionBadge extends StatelessWidget {
  const _VersionBadge({
    required this.label,
    required this.highlighted,
  });

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: highlighted ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: highlighted ? FontWeight.bold : FontWeight.w500,
        ),
      ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:qnote_flutter/core/network/update_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/utils/app_installer.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 弹出应用更新提示框。
///
/// 返回 true 表示更新操作已触发，false 表示取消或关闭。
Future<bool> showUpdateDialog({
  required BuildContext context,
  required UpdateInfo updateInfo,
  required String currentVersion,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _UpdateDialog(
      updateInfo: updateInfo,
      currentVersion: currentVersion,
    ),
  ).then((value) => value ?? false);
}

enum _DownloadState {
  idle,
  downloading,
  completed,
  failed,
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.updateInfo,
    required this.currentVersion,
  });

  final UpdateInfo updateInfo;
  final String currentVersion;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _DownloadState _state = _DownloadState.idle;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _errorMessage;
  String? _apkFilePath;
  CancelToken? _cancelToken;

  @override
  void dispose() {
    _cancelToken?.cancel('对话框已销毁');
    super.dispose();
  }

  void _notifyError(String message) {
    final rootContext = rootNavigatorKey.currentContext;
    if (rootContext == null) return;
    Toast.error(rootContext, message);
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 使用系统浏览器直接下载或打开链接
  Future<void> _handleBrowserDownload() async {
    Navigator.of(context).pop(true);
    final launched = await AppInstaller.openInBrowser(widget.updateInfo.downloadUrl);
    if (!launched) {
      _notifyError('无法打开下载链接');
    }
  }

  /// 点击更新：Android 平台且包含 APK 时进入应用内下载，其余平台降级为浏览器打开。
  Future<void> _handleStartUpdate() async {
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (!isAndroid || !widget.updateInfo.hasApk) {
      await _handleBrowserDownload();
      return;
    }

    await _startDownload();
  }

  /// 开始应用内下载
  Future<void> _startDownload() async {
    _cancelToken?.cancel();
    _cancelToken = CancelToken();

    setState(() {
      _state = _DownloadState.downloading;
      _progress = 0.0;
      _receivedBytes = 0;
      _totalBytes = widget.updateInfo.fileSize ?? 0;
      _errorMessage = null;
    });

    try {
      final filePath = await UpdateService.instance.downloadApk(
        candidateUrls: widget.updateInfo.candidateDownloadUrls,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            if (total > 0) {
              _totalBytes = total;
              _progress = received / total;
            }
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _state = _DownloadState.completed;
        _apkFilePath = filePath;
        _progress = 1.0;
      });

      // 下载成功后，自动尝试拉起安装程序
      await _installApk();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        if (!mounted) return;
        setState(() {
          _state = _DownloadState.idle;
          _progress = 0.0;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _state = _DownloadState.failed;
        _errorMessage = e.message ?? '下载连接异常';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _DownloadState.failed;
        _errorMessage = e.toString();
      });
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('用户取消下载');
    setState(() {
      _state = _DownloadState.idle;
      _progress = 0.0;
    });
  }

  Future<void> _installApk() async {
    final path = _apkFilePath;
    if (path == null) return;

    final success = await AppInstaller.installApk(path);
    if (!success) {
      _notifyError('调起安装程序失败，请检查安装未知应用权限');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sizeText = widget.updateInfo.fileSizeText;
    final notes = widget.updateInfo.releaseNotes.trim();

    return PopScope(
      canPop: _state != _DownloadState.downloading,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _state == _DownloadState.downloading) {
          _cancelDownload();
        }
      },
      child: AlertDialog(
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
            _state == _DownloadState.completed
                ? Icons.check_circle_outline_rounded
                : (_state == _DownloadState.failed
                    ? Icons.error_outline_rounded
                    : Icons.system_update_rounded),
            color: colorScheme.onPrimaryContainer,
            size: 26,
          ),
        ),
        title: Text(
          _state == _DownloadState.downloading
              ? '正在下载更新'
              : (_state == _DownloadState.completed
                  ? '下载完成'
                  : (_state == _DownloadState.failed ? '下载失败' : '发现新版本')),
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
              // 版本对比
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _VersionBadge(
                      label: widget.currentVersion,
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
                      label: widget.updateInfo.version,
                      highlighted: true,
                    ),
                  ],
                ),
              ),
              if (sizeText.isNotEmpty && _state == _DownloadState.idle) ...[
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

              // 下载中进度展示
              if (_state == _DownloadState.downloading) ...[
                const SizedBox(height: 24),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _totalBytes > 0 ? _progress.clamp(0.0, 1.0) : null,
                    minHeight: 8,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _totalBytes > 0
                          ? '${(_progress * 100).toStringAsFixed(1)}%'
                          : '下载中...',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _totalBytes > 0
                          ? '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}'
                          : _formatBytes(_receivedBytes),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],

              // 下载完成提示
              if (_state == _DownloadState.completed) ...[
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    '安装包已下载完成，若未自动弹出安装器可点击下方按钮重新安装。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],

              // 下载失败提示
              if (_state == _DownloadState.failed) ...[
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _errorMessage ?? '下载失败，请稍后重试',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                ),
              ],

              // 更新日志说明（下载中折叠/精简显示）
              if (notes.isNotEmpty && _state == _DownloadState.idle) ...[
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
          _buildActionButtons(context, colorScheme),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, ColorScheme colorScheme) {
    switch (_state) {
      case _DownloadState.idle:
        final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
        final canInAppDownload = isAndroid && widget.updateInfo.hasApk;

        if (!canInAppDownload) {
          return Row(
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
                  onPressed: _handleBrowserDownload,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('浏览器打开'),
                ),
              ),
            ],
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _handleBrowserDownload,
                    icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                    label: const Text('浏览器下载'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _handleStartUpdate,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('应用内下载'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('暂不更新'),
            ),
          ],
        );

      case _DownloadState.downloading:
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _cancelDownload,
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('取消下载'),
          ),
        );

      case _DownloadState.completed:
        return Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('关闭'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _installApk,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('立即安装'),
              ),
            ),
          ],
        );

      case _DownloadState.failed:
        return Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () {
                  AppInstaller.openInBrowser(widget.updateInfo.originalDownloadUrl);
                },
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('浏览器下载'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _startDownload,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('重试'),
              ),
            ),
          ],
        );
    }
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

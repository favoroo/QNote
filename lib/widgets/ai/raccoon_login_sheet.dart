import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';

/// 商汤小浣熊账号登录弹层
///
/// 两种入口：
/// 1. 浏览器回环登录（Android/iOS/桌面）：打开授权页，厂商回调到本机端口后自动完成；
/// 2. 粘贴兜底（Web / 端口被占 / 远程调试）：粘贴 `office-raccoon://auth/callback?code=...`
///    或直接的 JWT / token JSON。
class RaccoonLoginSheet extends StatefulWidget {
  final String providerId;

  const RaccoonLoginSheet({super.key, required this.providerId});

  @override
  State<RaccoonLoginSheet> createState() => _RaccoonLoginSheetState();
}

class _RaccoonLoginSheetState extends State<RaccoonLoginSheet> {
  final TextEditingController _pasteCtl = TextEditingController();

  RaccoonLoginHandle? _handle;
  bool _waiting = false;
  bool _submittingPaste = false;
  bool _canceledByUser = false;
  String? _error;

  @override
  void dispose() {
    _handle?.cancel();
    _pasteCtl.dispose();
    super.dispose();
  }

  Future<void> _startBrowserLogin() async {
    if (_waiting) return;
    // 上一次尝试还在等回调：先取消，避免同时开两个回环端口
    _handle?.cancel();
    _handle = null;
    setState(() {
      _error = null;
      _waiting = true;
    });
    try {
      final handle =
          await RaccoonAuthService.instance.startBrowserLogin(widget.providerId);
      if (!mounted) {
        handle.cancel();
        return;
      }
      _handle = handle;
      final launched = await launchUrl(
        Uri.parse(handle.url),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError('无法打开系统浏览器，请复制链接后手动打开，或使用下方粘贴方式');
      }
      final account = await handle.result;
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } catch (e) {
      _handle?.cancel();
      _handle = null;
      if (!mounted) return;
      if (_canceledByUser) {
        _canceledByUser = false;
        setState(() {
          _waiting = false;
          _error = null;
        });
        return;
      }
      setState(() {
        _waiting = false;
        _error = _friendlyError(e);
      });
    }
  }

  Future<void> _submitPaste() async {
    if (_submittingPaste) return;
    setState(() {
      _error = null;
      _submittingPaste = true;
    });
    try {
      final account = await RaccoonAuthService.instance.loginWithPastedInput(
        widget.providerId,
        _pasteCtl.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submittingPaste = false;
        _error = _friendlyError(e);
      });
    }
  }

  void _cancelWaiting() {
    _canceledByUser = true;
    _handle?.cancel();
    setState(() => _waiting = false);
  }

  String _friendlyError(Object error) {
    if (error is UnsupportedError) {
      return '当前平台不支持浏览器回环登录，请使用下方「粘贴回调链接/Token」';
    }
    final message = error.toString().replaceFirst('Exception: ', '');
    return message.length > 160 ? '${message.substring(0, 160)}…' : message;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '登录商汤小浣熊',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '登录后小Q会使用这个账号的额度调用小浣熊模型；登录态只保存在本机，不随备份同步。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (!kIsWeb)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _waiting ? null : _startBrowserLogin,
                  icon: _waiting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_browser_rounded),
                  label: Text(_waiting ? '等待浏览器授权…' : '打开浏览器登录'),
                ),
              ),
            if (_waiting) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '授权完成后会自动返回。若浏览器没有反应，可取消后用下方粘贴方式。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _cancelWaiting,
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
            if (kIsWeb) ...[
              Text(
                'Web 端受浏览器限制，无法自动接收本机回调，请使用下方粘贴方式。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: Divider(color: colorScheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '或粘贴登录结果',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: Divider(color: colorScheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _pasteCtl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'office-raccoon://auth/callback?code=...\n或粘贴 access_token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _submittingPaste ? null : _submitPaste,
                icon: _submittingPaste
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.content_paste_go_rounded),
                label: const Text('使用粘贴内容登录'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '提示：如果浏览器跳转到 office-raccoon:// 开头但页面打不开，复制地址栏完整链接粘贴到上方即可。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

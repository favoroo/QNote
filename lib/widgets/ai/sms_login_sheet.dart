import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/ai/account_auth_types.dart';

/// 短信验证码登录弹层（AutoClaw / Loomy 共用）
///
/// 厂商短信登录都是两步：先按手机号发码，再用「手机号 + 厂商续接凭据
/// （device_id / msgid）+ 验证码」换登录态。凭据收在 [AccountSmsChallenge]
/// 里由弹层持有，避免重复发码时串用上一次的凭据。
class SmsLoginSheet extends StatefulWidget {
  final String providerId;

  /// 不为空表示「重新登录这个已有账号」（保留备注与轮换顺序）
  final String? accountId;

  /// 支持短信登录的厂商服务
  final AccountAuthService service;

  const SmsLoginSheet({super.key, required this.providerId, required this.service, this.accountId});

  @override
  State<SmsLoginSheet> createState() => _SmsLoginSheetState();
}

class _SmsLoginSheetState extends State<SmsLoginSheet> {
  final TextEditingController _phoneCtl = TextEditingController();
  final TextEditingController _codeCtl = TextEditingController();

  AccountSmsChallenge? _challenge;
  Timer? _countdown;
  int _secondsLeft = 0;
  bool _sending = false;
  bool _loggingIn = false;
  String? _error;

  bool get _canSendCode => !_sending && !_loggingIn && _phoneCtl.text.trim().length == 11;

  @override
  void dispose() {
    _countdown?.cancel();
    _phoneCtl.dispose();
    _codeCtl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!_canSendCode) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final challenge = await widget.service.sendLoginCode(widget.providerId, _phoneCtl.text);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _sending = false;
      });
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = _friendlyError(e);
      });
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    setState(() => _secondsLeft = 60);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) timer.cancel();
      });
    });
  }

  Future<void> _login() async {
    final challenge = _challenge;
    if (challenge == null || _loggingIn) return;
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      final account = await widget.service.verifyLoginCode(
        widget.providerId,
        challenge,
        _codeCtl.text,
        accountId: widget.accountId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst('FormatException: ', '').replaceFirst('Exception: ', '');
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final challenge = _challenge;
    final canLogin = challenge != null && !_loggingIn && !_sending;
    final vendor = widget.service.vendorLabel;
    final maxCodeLength = widget.service.smsCodeMaxLength;

    return SingleChildScrollView(
      padding: EdgeInsets.only(left: 20, right: 20, top: 12, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sms_outlined, size: 22, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.accountId == null ? '登录 $vendor 账号' : '重新登录 $vendor 账号',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '使用你自己的 $vendor 账号（+86 手机号）。登录后由账号额度对话，'
            'Token 只保存在本机，不参与备份与同步。',
            style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 18),
          Text('手机号', style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _phoneCtl,
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            onChanged: (value) {
              setState(() {
                // 手机号改了，已发的验证码就不再对应，收起验证码输入
                if (_challenge != null && value.trim() != _challenge!.phone) {
                  _challenge = null;
                  _countdown?.cancel();
                  _secondsLeft = 0;
                }
              });
            },
            decoration: const InputDecoration(
              isDense: true,
              prefixText: '+86  ',
              hintText: '13800138000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  challenge == null ? '验证码将发送到上面的手机号' : '验证码已发送至 ${_maskPhone(challenge.phone)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: _canSendCode && _secondsLeft == 0 ? _sendCode : null,
                child: _sending
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(
                        _secondsLeft > 0
                            ? '${_secondsLeft}s 后重发'
                            : challenge == null
                            ? '发送验证码'
                            : '重新发送',
                      ),
              ),
            ],
          ),
          if (challenge != null) ...[
            const SizedBox(height: 16),
            Text('短信验证码', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            TextField(
              controller: _codeCtl,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(maxCodeLength),
              ],
              onSubmitted: (_) => _login(),
              decoration: const InputDecoration(isDense: true, hintText: '请输入短信中的验证码', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canLogin ? _login : null,
                child: _loggingIn
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('登录'),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error)),
          ],
        ],
      ),
    );
  }

  static String _maskPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 11) return phone;
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qnote_flutter/widgets/debug_console.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  int _tapCount = 0;
  DateTime? _lastTapTime;

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_lastTapTime != null && now.difference(_lastTapTime!).inSeconds > 3) {
      _tapCount = 0;
    }
    _lastTapTime = now;
    _tapCount++;
    if (_tapCount >= 5) {
      _tapCount = 0;
      showDebugConsole(context);
    }
  }

  void _showPrivacyPolicy() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('隐私协议'),
        content: const SingleChildScrollView(
          child: Text(
            'QNote 隐私协议\n\n'
            '1. 数据收集\n'
            'QNote 不会收集任何用户的个人数据。所有数据均存储在您的本地设备上。\n\n'
            '2. 数据存储\n'
            '您的日记、笔记、待办等数据完全保存在本地数据库中，不会上传至任何服务器（除非您主动启用 WebDAV 同步功能）。\n\n'
            '3. 网络访问\n'
            '应用仅在您使用 AI 功能或 WebDAV 同步时才会访问网络，且仅与您配置的服务器通信。\n\n'
            '4. 数据安全\n'
            '我们建议您定期导出数据备份，以防数据丢失。WebDAV 同步使用加密传输协议保护您的数据安全。\n\n'
            '5. 权限使用\n'
            '应用仅申请必要的权限：存储权限用于数据备份，网络权限用于同步和 AI 功能，通知权限用于待办提醒。\n\n'
            '6. 第三方服务\n'
            'AI 功能由您自行配置的第三方 AI 服务提供，相关数据政策请参阅对应服务商的隐私协议。\n\n'
            '7. 协议更新\n'
            '如本协议发生变更，我们将在应用内通知您。继续使用即表示您同意更新后的协议。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest.withValues(alpha: 0.5),
      appBar: AppBar(
        title: const Text('关于 QNote'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 40),
            // App Icon Card
            Center(
              child: Container(
                width: 120,
                height: 120,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: SvgPicture.asset(
                  'assets/images/app_icon.svg',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'QNote',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '极简、纯净、强大的笔记应用',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 48),

            // To User Card
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '致用户',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'QNote 是一款专注于个人思考与状态记录的应用。我们致力于提供最流畅的输入体验，并配合 AI 技术，让您的记录更有价值。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Info List Card
            _buildCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('版本', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    trailing: GestureDetector(
                      onTap: _handleVersionTap,
                      child: Text('1.2.0', style: TextStyle(color: theme.hintColor, fontSize: 13)),
                    ),
                    onTap: _handleVersionTap,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    title: const Text('隐私协议', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    trailing: Icon(Icons.chevron_right, size: 18, color: theme.hintColor),
                    onTap: _showPrivacyPolicy,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 60),

            // Footer
            Text(
              '© 2026 QNote Team. All rights reserved.',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 4),
            Text(
              'Designed by HuangQian',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child, EdgeInsetsGeometry? padding}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}


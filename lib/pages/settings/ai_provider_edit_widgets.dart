part of 'ai_provider_edit_page.dart';
// 本文件从 ai_provider_edit_page.dart 机械拆出，仅承载页面 State 之外的辅助类与底部弹层。

/// 单个模型的测速结果。
///
/// 失败与耗时分开建模，避免用字符串「失败」当哨兵值再做字符串判断。
class _ModelLatency {
  const _ModelLatency.success(this.duration) : failed = false;
  const _ModelLatency.failure() : duration = null, failed = true;

  final Duration? duration;
  final bool failed;
}

/// 厂商模板选择器（底部弹层）
///
/// 与「添加模型服务」的选择器保持同一分区口径：账号登录型在上、API Key 型在下。
/// 这里额外显示单选态（当前模板）。
class _VendorPickerSheet extends StatelessWidget {
  final String selectedId;

  const _VendorPickerSheet({required this.selectedId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accountVendors = aiAccountProviders();
    final apiKeyVendors = aiApiKeyProviders();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('选择厂商', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                ),
                IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (accountVendors.isNotEmpty) ...[
                  _vendorSectionHeader(theme, title: '账号登录', subtitle: '登录账号即可使用，Token 由账号额度提供'),
                  ...accountVendors.map((spec) => _vendorTile(context, theme, spec)),
                ],
                if (apiKeyVendors.isNotEmpty) ...[
                  _vendorSectionHeader(theme, title: 'API Key', subtitle: '填写地址与密钥，多把自动轮询'),
                  ...apiKeyVendors.map((spec) => _vendorTile(context, theme, spec)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _vendorSectionHeader(ThemeData theme, {required String title, required String subtitle}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _vendorTile(BuildContext context, ThemeData theme, AiProviderConfig spec) {
    final selected = spec.id == selectedId;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
        size: 20,
      ),
      title: Text(
        spec.name,
        style: TextStyle(fontWeight: FontWeight.w600, color: selected ? theme.colorScheme.primary : null),
      ),
      subtitle: Text(
        spec.defaultBaseUrl.isEmpty ? '需要自己填写地址' : spec.defaultBaseUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      onTap: () => Navigator.of(context).pop(spec.id),
    );
  }
}

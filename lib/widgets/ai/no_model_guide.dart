import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';

/// 未配置模型时的统一引导弹窗
///
/// 内置服务不可用（未拉到配置 / 维护中）且用户没有自配模型时走这里：
/// 明确告知「去添加模型」而不是抛一段技术错误。
///
/// [scene] 用于文案定位（如「小Q 对话」「AI 评分」），可以留空。
Future<void> showNoModelConfiguredDialog(BuildContext context, {String scene = ''}) async {
  // 悬浮小Q 面板挂在全局 Overlay 上，用它的 context 弹窗可能被悬浮球遮挡；
  // 统一落到根导航器上下文，弹窗层级与路由页面一致。
  final hostContext = rootNavigatorKey.currentContext ?? context;
  if (!hostContext.mounted) return;

  final goAdd = await showDialog<bool>(
    context: hostContext,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        icon: Icon(Icons.extension_off_rounded, color: theme.colorScheme.primary),
        title: const Text('还没有可用的模型'),
        content: Text(
          scene.isEmpty
              ? '内置服务暂时不可用。添加自己的模型服务：填入 API 地址与密钥，扫描并启用模型即可使用。'
              : '$scene需要添加模型服务。\n到「小Q设置 → 模型」填入 API 地址与密钥，或稍后重试内置服务。',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('稍后')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('去添加模型')),
        ],
      );
    },
  );

  if (goAdd == true && hostContext.mounted) {
    hostContext.push('/settings/ai-config', extra: const AiConfigPageArgs(autoOpenAdd: true));
  }
}

/// 「去添加模型」入口参数（列表页据此自动打开厂商选择器）
class AiConfigPageArgs {
  final bool autoOpenAdd;

  const AiConfigPageArgs({this.autoOpenAdd = false});
}

/// 「当前模型不支持识图」引导弹窗
///
/// 内置识图模型下线后不再有「静默换模型」的兜底：要发图而绑定模型看不了图时，
/// 必须让用户显式换模型——否则模型会对着看不见的画面编造内容。
Future<void> showVisionUnsupportedDialog(
  BuildContext context, {
  required String modelName,
  String scene = '本次操作',
}) async {
  final hostContext = rootNavigatorKey.currentContext ?? context;
  if (!hostContext.mounted) return;

  final goSettings = await showDialog<bool>(
    context: hostContext,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        icon: Icon(Icons.image_not_supported_outlined, color: theme.colorScheme.error),
        title: const Text('当前模型不支持识图'),
        content: Text(
          '$scene需要识图，但「时间线提取」绑定的「$modelName」不支持图片输入。\n'
          '到「小Q设置 → 模型 → 模型分配」换成支持识图的模型'
          '（名字常含 vision / -vl / omni）；不需要图片就关闭「提取图片内容」后重试。',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('知道了')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('去换模型')),
        ],
      );
    },
  );

  if (goSettings == true && hostContext.mounted) {
    hostContext.push('/settings/ai-config');
  }
}

/// 内联引导卡：给整页空态（对话页、日记页、统计页）复用
class NoModelGuideCard extends StatelessWidget {
  final String scene;
  final EdgeInsetsGeometry padding;

  const NoModelGuideCard({
    super.key,
    this.scene = '',
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIconBadge(
                  icon: Icons.extension_rounded,
                  size: 38,
                  iconSize: 20,
                  borderRadius: BorderRadius.circular(10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('还没有可用的 AI 模型', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              scene.isEmpty ? '添加模型服务后，小Q 对话、日记提取与 AI 评分即可使用。' : '$scene需要调用 AI 模型，添加模型服务后即可使用。',
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => context.push('/settings/ai-config', extra: const AiConfigPageArgs(autoOpenAdd: true)),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('去添加模型'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

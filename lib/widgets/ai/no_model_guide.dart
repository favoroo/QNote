import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/router/app_router.dart';

/// 未配置模型时的统一引导弹窗
///
/// 内置免费模型下线后，App 不再自带任何可调用的模型：任何需要模型的功能在没有
/// 可用厂商条目时都应该走这里，明确告知「去添加模型」而不是抛一段技术错误。
///
/// [scene] 用于文案定位（如「小Q 对话」「AI 评分」），可以留空。
Future<void> showNoModelConfiguredDialog(
  BuildContext context, {
  String scene = '',
}) async {
  // 悬浮小Q 面板挂在全局 Overlay 上，用它的 context 弹窗可能被悬浮球遮挡；
  // 统一落到根导航器上下文，弹窗层级与路由页面一致。
  final hostContext = rootNavigatorKey.currentContext ?? context;
  if (!hostContext.mounted) return;

  final goAdd = await showDialog<bool>(
    context: hostContext,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        icon: Icon(
          Icons.extension_off_rounded,
          color: theme.colorScheme.primary,
        ),
        title: const Text('还没有可用的 AI 模型'),
        content: Text(
          scene.isEmpty
              ? 'QNote 不再内置模型，需要你先添加自己的模型服务：填入 API 地址与密钥，'
                  '扫描出模型后按需启用即可。\n\n整个过程一分钟左右，加密钥后即可正常使用。'
              : '$scene需要调用 AI 模型，但你现在还没有添加任何模型服务。\n\n'
                  '在「AI 模型配置」里填入 API 地址与密钥，扫描出模型后按需启用即可。',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去添加模型'),
          ),
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
        icon: Icon(
          Icons.image_not_supported_outlined,
          color: theme.colorScheme.error,
        ),
        title: const Text('当前模型不支持识图'),
        content: Text(
          '$scene需要把图片交给模型识别，但当前绑定的「$modelName」不支持图片输入。\n\n'
          '请切换到支持识图的模型：模型名通常含 vision / -vl / omni，或属于 '
          'Gemini / Claude 系列；也可以在设置页对该模型做一次「识图检测」确认能力。'
          '如果不需要图片，关闭「提取图片内容」后重试。',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去换模型'),
          ),
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
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.extension_rounded,
                    color: colorScheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '还没有可用的 AI 模型',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              scene.isEmpty
                  ? '添加你自己的模型服务（API 地址 + 密钥）后，小Q 对话、日记提取、AI 评分等功能即可使用。'
                  : '$scene需要调用 AI 模型。添加你自己的模型服务后即可使用。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => context.push(
                  '/settings/ai-config',
                  extra: const AiConfigPageArgs(autoOpenAdd: true),
                ),
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
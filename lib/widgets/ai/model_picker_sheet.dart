import 'package:flutter/material.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

/// 选择结果：`ref == null` 表示「不绑定（跟随默认厂商的首个模型）」
class ModelPickerResult {
  final AiModelRef? ref;

  const ModelPickerResult(this.ref);
}

/// 厂商条目里全部已启用模型（按厂商顺序展开）
List<({AiProvider provider, AiProviderModel model})> enabledModelEntries(
  List<AiProvider> providers,
) {
  final entries = <({AiProvider provider, AiProviderModel model})>[];
  for (final provider in providers) {
    for (final model in provider.models) {
      entries.add((provider: provider, model: model));
    }
  }
  return entries;
}

/// 模型引用 → 展示名（如「deepseek · deepseek-v4-flash」）
///
/// 厂商或模型已被删除时回退到裸模型名，保证界面不出现空标题。
String aiModelDisplayName(
  AiModelRef? ref,
  List<AiProvider> providers, {
  String fallback = '未配置模型',
}) {
  if (ref == null) return fallback;
  final provider = providers.where((p) => p.id == ref.providerId).firstOrNull;
  if (provider == null) return ref.modelName;
  final model = provider.models.where((m) => m.id == ref.modelName).firstOrNull;
  return '${provider.name} · ${model?.name ?? ref.modelName}';
}

/// 共享模型选择器：底部弹层，按厂商分组列出已启用模型，带搜索与空态引导
///
/// 返回值：null 表示用户取消；[ModelPickerResult] 携带选择结果（`ref` 为 null
/// 表示清空绑定，仅在 [allowUnbind] 为 true 时可能出现）。
Future<ModelPickerResult?> showModelPickerSheet(
  BuildContext context, {
  required List<AiProvider> providers,
  required AiModelRef? selected,
  String title = '选择模型',
  bool allowUnbind = false,
}) {
  return showModalBottomSheet<ModelPickerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ModelPickerSheet(
      providers: providers,
      selected: selected,
      title: title,
      allowUnbind: allowUnbind,
    ),
  );
}

class ModelPickerSheet extends StatefulWidget {
  final List<AiProvider> providers;
  final AiModelRef? selected;
  final String title;
  final bool allowUnbind;

  const ModelPickerSheet({
    super.key,
    required this.providers,
    required this.selected,
    this.title = '选择模型',
    this.allowUnbind = false,
  });

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  bool _matches(AiProvider provider, AiProviderModel model) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return model.id.toLowerCase().contains(q) ||
        model.name.toLowerCase().contains(q) ||
        provider.name.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final entries = enabledModelEntries(widget.providers);
    final hasModels = entries.isNotEmpty;
    // 模型少时不做搜索框，减少一个视觉层级
    final showSearch = entries.length > 8;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (showSearch && hasModels)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _searchCtl,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索模型或厂商',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchCtl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
          if (!hasModels)
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NoModelGuideCard(
                        scene: '',
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (widget.allowUnbind)
                    ListTile(
                      leading: Icon(
                        widget.selected == null
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: widget.selected == null
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                      title: const Text('跟随默认模型'),
                      subtitle: Text(
                        '使用默认厂商的首个已启用模型',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () => Navigator.of(context)
                          .pop(const ModelPickerResult(null)),
                    ),
                  ...widget.providers.expand((provider) {
                    final models = provider.models
                        .where((m) => _matches(provider, m))
                        .toList();
                    if (models.isEmpty) return const <Widget>[];
                    return <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                provider.name,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colorScheme.outline,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (provider.isDefault)
                              Text(
                                '默认',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.primary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      ...models.map((model) {
                        final ref = AiModelRef(
                          providerId: provider.id,
                          modelName: model.id,
                        );
                        final isSelected = ref == widget.selected;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: isSelected
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                            size: 20,
                          ),
                          title: Text(
                            model.name,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isSelected ? colorScheme.primary : null,
                            ),
                          ),
                          subtitle: model.name == model.id
                              ? null
                              : Text(
                                  model.id,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                          onTap: () => Navigator.of(context)
                              .pop(ModelPickerResult(ref)),
                        );
                      }),
                    ];
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
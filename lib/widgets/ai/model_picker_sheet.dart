import 'package:flutter/material.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

/// 选择结果：携带选中的 [AiModelRef]（可能指向具体模型，也可能指向路由组）
class ModelPickerResult {
  final AiModelRef ref;

  const ModelPickerResult(this.ref);
}

/// 取默认生效的模型引用（默认厂商首个已启用模型 → 首个可用厂商首个已启用模型）
AiModelRef? defaultModelRef(List<AiProvider> providers) {
  final provider =
      providers.where((p) => p.isDefault && p.isUsable).firstOrNull ??
      providers.where((p) => p.isUsable).firstOrNull;
  final model = provider?.firstModel;
  return model == null
      ? null
      : AiModelRef(providerId: provider!.id, modelName: model.id);
}

/// 厂商条目里全部已启用模型（按厂商顺序展开）
///
/// 已停用的厂商整条跳过：选择器、路由组成员源与页面空态判断都汇聚到这里，
/// 在入口过滤一次就不必各处再判 `provider.enabled`。
List<({AiProvider provider, AiProviderModel model})> enabledModelEntries(
  List<AiProvider> providers,
) {
  final entries = <({AiProvider provider, AiProviderModel model})>[];
  for (final provider in providers) {
    if (!provider.enabled) continue;
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

/// 组内「厂商未停用且模型都还在」的成员数（用于选择器里提示成员失效）
int routeGroupLiveMemberCount(AiRouteGroup group, List<AiProvider> providers) {
  var live = 0;
  for (final member in group.enabledMembers) {
    final provider = providers
        .where((p) => p.id == member.providerId)
        .firstOrNull;
    if (provider != null &&
        provider.enabled &&
        provider.hasModel(member.modelName)) {
      live++;
    }
  }
  return live;
}

/// 绑定引用 → 展示名：路由组显示组名，具体模型走 [aiModelDisplayName]
///
/// 顶部胶囊、角色行、选择器都要同时面对「模型」和「路由组」两种绑定，
/// 用这一个入口避免各处各写一遍分支（漏掉组会显示成裸 id）。
String aiBindingDisplayName(
  AiModelRef? ref,
  List<AiProvider> providers,
  List<AiRouteGroup> groups, {
  String fallback = '未配置模型',
}) {
  if (ref == null) return fallback;
  if (ref.isRouteGroup) {
    final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
    return group == null ? fallback : group.name;
  }
  return aiModelDisplayName(ref, providers, fallback: fallback);
}

/// 绑定引用 → 短展示名：具体模型只给模型名（不带厂商前缀），路由组给组名
///
/// 对话页输入区空间有限，厂商名对「当前用哪个模型」没有增量信息；
/// 需要完整归属时去模型选择器（那里按厂商分组）看。
String aiBindingShortName(
  AiModelRef? ref,
  List<AiProvider> providers,
  List<AiRouteGroup> groups, {
  String fallback = '未配置模型',
}) {
  if (ref == null) return fallback;
  if (ref.isRouteGroup) {
    final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
    return group == null ? fallback : group.name;
  }
  final provider = providers.where((p) => p.id == ref.providerId).firstOrNull;
  final model = provider?.models
      .where((m) => m.id == ref.modelName)
      .firstOrNull;
  return model?.name ?? ref.modelName;
}

/// 共享模型选择器：底部弹层，按厂商分组列出已启用模型，带搜索与空态引导
///
/// 绑定路由组时返回的 [ModelPickerResult.ref] 是组引用（[AiModelRef.isRouteGroup]）。
/// 返回值：null 表示用户取消。
Future<ModelPickerResult?> showModelPickerSheet(
  BuildContext context, {
  required List<AiProvider> providers,
  required AiModelRef? selected,
  List<AiRouteGroup> groups = const [],
  String title = '选择模型',
}) {
  return showModalBottomSheet<ModelPickerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ModelPickerSheet(
      providers: providers,
      groups: groups,
      selected: selected,
      title: title,
    ),
  );
}

class ModelPickerSheet extends StatefulWidget {
  final List<AiProvider> providers;

  /// 可选的路由组：渲染在厂商分组之上，选中即绑定整个组
  final List<AiRouteGroup> groups;
  final AiModelRef? selected;
  final String title;

  const ModelPickerSheet({
    super.key,
    required this.providers,
    this.groups = const [],
    required this.selected,
    this.title = '选择模型',
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

  bool _matchesGroup(AiRouteGroup group) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return group.name.toLowerCase().contains(q);
  }

  /// 路由组分区标题（与厂商分组标题同一样式，避免多出一套视觉体系）
  Widget _groupSectionHeader(ThemeData theme, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '路由组',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            '多模型轮流/故障转移',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final entries = enabledModelEntries(widget.providers);
    // 没有成员的组绑上也是坏体验，这里直接不出现在选择器里
    final groups = widget.groups
        .where((g) => g.enabledMembers.isNotEmpty && _matchesGroup(g))
        .toList();
    final hasModels = entries.isNotEmpty || groups.isNotEmpty;
    // 模型少时不做搜索框，减少一个视觉层级
    final showSearch = entries.length > 8 || groups.isNotEmpty;
    final effectiveSelected =
        widget.selected ?? defaultModelRef(widget.providers);

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
            const Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NoModelGuideCard(scene: '', padding: EdgeInsets.zero),
                      SizedBox(height: 8),
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
                  if (groups.isNotEmpty) ...[
                    _groupSectionHeader(theme, colorScheme),
                    ...groups.map((group) {
                      final ref = AiModelRef.routeGroup(group.id);
                      final isSelected = ref == effectiveSelected;
                      final live = routeGroupLiveMemberCount(
                        group,
                        widget.providers,
                      );
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.alt_route_rounded,
                          size: 20,
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        title: Text(
                          group.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: isSelected ? colorScheme.primary : null,
                          ),
                        ),
                        subtitle: Text(
                          live == 0
                              ? '${group.strategy.label} · 模型均已停用'
                              : '$live 个模型 · ${group.strategy.label}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: live == 0
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check_rounded,
                                size: 20,
                                color: colorScheme.primary,
                              )
                            : null,
                        onTap: () =>
                            Navigator.of(context).pop(ModelPickerResult(ref)),
                      );
                    }),
                    const SizedBox(height: 2),
                  ],
                  ...widget.providers.expand((provider) {
                    // 停用的厂商不出现在选择器里（模型仍在条目里保留着）
                    if (!provider.enabled) return const <Widget>[];
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
                        final isSelected = ref == effectiveSelected;
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
                          onTap: () =>
                              Navigator.of(context).pop(ModelPickerResult(ref)),
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

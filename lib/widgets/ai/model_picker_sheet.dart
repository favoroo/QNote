import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/utils/image_model_detection.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/widgets/ai/model_meta_badges.dart';
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
/// [imageGeneration] 为真时默认只列识别为生图的模型（生图角色专用），
/// 底部筛选条可切回全部模型，避免自定义中转的模型名没被识别后无从选择。
/// 返回值：null 表示用户取消。
Future<ModelPickerResult?> showModelPickerSheet(
  BuildContext context, {
  required List<AiProvider> providers,
  required AiModelRef? selected,
  List<AiRouteGroup> groups = const [],
  String title = '选择模型',
  bool imageGeneration = false,
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
      imageGeneration: imageGeneration,
    ),
  );
}

class ModelPickerSheet extends StatefulWidget {
  final List<AiProvider> providers;

  /// 可选的路由组：渲染在厂商分组之上，选中即绑定整个组
  final List<AiRouteGroup> groups;
  final AiModelRef? selected;
  final String title;

  /// 生图角色选择模式：默认过滤掉对话模型，只留生图模型
  final bool imageGeneration;

  const ModelPickerSheet({
    super.key,
    required this.providers,
    this.groups = const [],
    required this.selected,
    this.title = '选择模型',
    this.imageGeneration = false,
  });

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  /// 生图模式下是否只看生图模型；默认跟随 [ModelPickerSheet.imageGeneration]
  bool _onlyImageModels = true;

  @override
  void initState() {
    super.initState();
    _onlyImageModels = widget.imageGeneration;
  }

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
    final allEntries = enabledModelEntries(widget.providers);
    // 没有成员的组绑上也是坏体验，这里直接不出现在选择器里
    final allGroups = widget.groups
        .where((g) => g.enabledMembers.isNotEmpty && _matchesGroup(g))
        .toList();
    // 生图角色不套用默认对话模型，否则筛选后的列表里会多出一个
    // 被选中标记的对话模型，看起来像「已经选了它」
    final effectiveSelected =
        widget.selected ??
        (widget.imageGeneration ? null : defaultModelRef(widget.providers));
    final onlyImageModels = widget.imageGeneration && _onlyImageModels;
    final selected = effectiveSelected;
    // 已绑定的模型始终保留：即使它没被识别成生图模型，用户也能看到当前选择
    final entries = onlyImageModels
        ? allEntries
              .where(
                (entry) =>
                    isImageGenerationModel(entry.model) ||
                    (selected != null &&
                        !selected.isRouteGroup &&
                        selected.providerId == entry.provider.id &&
                        selected.modelName == entry.model.id),
              )
              .toList()
        : allEntries;
    // 路由组是对话模型的故障转移容器，生图筛选下先收起，切回全部再显示
    final groups = onlyImageModels ? const <AiRouteGroup>[] : allGroups;
    // 厂商分组按 ID 过滤：entries 已经决定了哪些模型可见（生图筛选/保留已绑定）
    final visibleIds = <String, Set<String>>{};
    for (final entry in entries) {
      visibleIds.putIfAbsent(entry.provider.id, () => <String>{}).add(
        entry.model.id,
      );
    }
    final imageModelCount = allEntries
        .where((entry) => isImageGenerationModel(entry.model))
        .length;
    final hasModels = entries.isNotEmpty || groups.isNotEmpty;
    // 模型少时不做搜索框，减少一个视觉层级
    final showSearch = allEntries.length > 8 || allGroups.isNotEmpty;

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
          if (widget.imageGeneration && allEntries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  selected: _onlyImageModels,
                  onSelected: (value) =>
                      setState(() => _onlyImageModels = value),
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    imageModelCount == 0
                        ? '仅看生图模型'
                        : '仅看生图模型（$imageModelCount）',
                  ),
                ),
              ),
            ),
          if (!hasModels)
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: allEntries.isEmpty && allGroups.isEmpty
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            NoModelGuideCard(scene: '', padding: EdgeInsets.zero),
                            SizedBox(height: 8),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '未识别到生图模型',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '厂商目录没声明生图能力，模型名里也没有生图关键词。'
                              '可以显示全部模型，手动选择你的生图中转。',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.tonal(
                              onPressed: () =>
                                  setState(() => _onlyImageModels = false),
                              child: const Text('显示全部模型'),
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
                    final visible = visibleIds[provider.id];
                    final models = provider.models
                        .where(
                          (m) =>
                              (visible != null && visible.contains(m.id)) &&
                              _matches(provider, m),
                        )
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
                          subtitle: _modelSubtitle(theme, model),
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

/// 模型行的副标题：模型 ID 与计费/能力徽标併成一行
///
/// 按积分计费的厂商（小浣熊、Loomy）里，倍率与限免状态直接决定一次对话花多少
/// 额度，选模型时必须和模型名一起看到；两者都没有时返回 null，不留空行。
Widget? _modelSubtitle(ThemeData theme, AiProviderModel model) {
  final line = [
    if (model.name != model.id) model.id,
    ...modelMetaBadges(model),
  ].join(' · ');
  if (line.isEmpty) return null;
  return Text(
    line,
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}

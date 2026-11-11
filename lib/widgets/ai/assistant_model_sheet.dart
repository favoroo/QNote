import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/widgets/ai/model_effort_levels_sheet.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/reasoning_effort_options.dart';

/// 思考强度的作用对象：某个厂商条目下的某个已启用模型
typedef ReasoningEffortTarget = ({AiProvider provider, AiProviderModel model});

/// 绑定引用 → 思考强度的作用对象
///
/// 具体模型就是它自己；路由组展开为组内全部启用成员——组内档位本来就可以不
/// 一致，发信层会对不支持的成员静默跳过。厂商或模型已被删除时返回空列表。
List<ReasoningEffortTarget> reasoningTargetsOf(AiModelRef? ref, List<AiProvider> providers, List<AiRouteGroup> groups) {
  if (ref == null) return const [];
  if (!ref.isRouteGroup) {
    final target = _targetOf(providers, ref.providerId, ref.modelName);
    return target == null ? const [] : [target];
  }

  final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
  if (group == null) return const [];
  final targets = <ReasoningEffortTarget>[];
  for (final member in group.enabledMembers) {
    final target = _targetOf(providers, member.providerId, member.modelName);
    if (target != null) targets.add(target);
  }
  return targets;
}

/// 厂商条目 + 模型 id → 目标；厂商或模型已被删除时返回 null
ReasoningEffortTarget? _targetOf(List<AiProvider> providers, String providerId, String modelName) {
  final provider = providers.where((p) => p.id == providerId).firstOrNull;
  final model = provider?.models.where((m) => m.id == modelName).firstOrNull;
  if (provider == null || model == null) return null;
  return (provider: provider, model: model);
}

/// 最近使用的一条绑定，已解析成可直接展示的信息
class RecentBindingEntry {
  /// 绑定引用（模型或路由组）
  final AiModelRef ref;

  /// 模型展示名；路由组为组名
  final String name;

  /// 所属厂商名；路由组为 null
  final String? providerName;

  /// 模型行的元数据（模型 ID、计费倍率等）；路由组为成员摘要
  final String? meta;

  final bool isGroup;

  const RecentBindingEntry({required this.ref, required this.name, this.providerName, this.meta, this.isGroup = false});
}

/// 最近使用 → 可展示条目
///
/// 已删除的厂商、已停用厂商下的模型、已删除或没有可用成员的组直接跳过：
/// 最近使用只是快捷入口，不能把已经选不中的东西摆回列表里。
List<RecentBindingEntry> recentBindingEntries(
  List<AiModelRef> refs,
  List<AiProvider> providers,
  List<AiRouteGroup> groups,
) {
  final entries = <RecentBindingEntry>[];
  for (final ref in refs) {
    if (ref.isRouteGroup) {
      final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
      if (group == null || group.enabledMembers.isEmpty) continue;
      final live = routeGroupLiveMemberCount(group, providers);
      entries.add(
        RecentBindingEntry(ref: ref, name: group.name, meta: '$live 个模型 · ${group.strategy.label}', isGroup: true),
      );
      continue;
    }
    final target = _targetOf(providers, ref.providerId, ref.modelName);
    if (target == null || !target.provider.enabled) continue;
    entries.add(
      RecentBindingEntry(
        ref: ref,
        name: target.model.name,
        providerName: target.provider.name,
        meta: modelMetaLine(target.model),
      ),
    );
  }
  return entries;
}

/// 一组思考强度目标的状态：可选档位 + 当前值
class ReasoningEffortState {
  /// 档位取值能力：决定界面展示哪些档位、用什么文案
  final ModelReasoningCapability capability;

  /// 当前档位；null 表示「自动」，或组内不一致（看 [mixed]）
  final ReasoningEffort? effort;

  /// 多个目标档位不一致：界面显示「混合」，不把某个成员的档位冒充成全局选择
  final bool mixed;

  /// 档位集合是否来自模型配置里的自定义勾选
  final bool customized;

  const ReasoningEffortState({required this.capability, this.effort, this.mixed = false, this.customized = false});
}

/// 目标集合 → 状态；空集合返回 null（没有可调对象，界面只给提示）
ReasoningEffortState? reasoningEffortStateOf(List<ReasoningEffortTarget> targets) {
  if (targets.isEmpty) return null;
  final first = targets.first;
  final capability = ModelReasoningCapability.forUi(
    modelName: first.model.id,
    providerType: first.provider.providerType,
    vendorId: first.provider.vendorId,
    customLevels: first.model.reasoningEfforts,
  );
  // 用户裁掉当前档位后，存储值可能已经发不出去；按「自动」展示才不撒谎
  ReasoningEffort? effectiveOf(ReasoningEffortTarget target) {
    final effort = target.model.reasoningEffort;
    if (effort == null) return null;
    final targetCapability = ModelReasoningCapability.forUi(
      modelName: target.model.id,
      providerType: target.provider.providerType,
      vendorId: target.provider.vendorId,
      customLevels: target.model.reasoningEfforts,
    );
    return targetCapability.supports(effort) ? effort : null;
  }

  final effort = effectiveOf(first);
  return ReasoningEffortState(
    capability: capability,
    effort: effort,
    mixed: targets.any((t) => effectiveOf(t) != effort),
    customized: first.model.reasoningEfforts != null,
  );
}

/// 弹出小Q 模型选择面板（一级模型 → 厂商浏览 → 某厂商的模型）
///
/// 绑定与思考强度都由调用方通过回调写库：面板只负责展示与收集选择，回调返回
/// false 表示没落库，面板保持原样（界面不能比库里的状态更超前）。
/// 面板本身不返回值——点选即生效，关闭面板不影响已经写入的选择。
Future<void> showAssistantModelSheet(
  BuildContext context, {
  required List<AiProvider> providers,
  required List<AiRouteGroup> groups,
  required AiModelRef? selected,
  required Future<bool> Function(AiModelRef ref) onSelectBinding,
  required Future<bool> Function(List<ReasoningEffortTarget> targets, ReasoningEffort? effort) onEffortChanged,
  // 调整某个模型的可选档位集合；不传则不显示「管理思考档位」入口
  Future<bool> Function(ReasoningEffortTarget target, List<ReasoningEffort>? levels)? onLevelsChanged,
  // 最近使用的绑定（最新在前），由调用方从本地偏好读出后传入
  List<AiModelRef> recentModels = const [],
  VoidCallback? onManageModels,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AssistantModelSheet(
      providers: providers,
      groups: groups,
      selected: selected,
      onSelectBinding: onSelectBinding,
      onEffortChanged: onEffortChanged,
      onLevelsChanged: onLevelsChanged,
      recentModels: recentModels,
      onManageModels: onManageModels,
    ),
  );
}

/// 面板当前层级
///
/// 切换模型的主路径是「看到模型名直接点」，所以一级直接平铺全部模型；
/// 厂商只作为浏览入口退到下一级，不再挡在选择路径上。
enum _SheetLevel {
  /// 一级：最近使用 + 路由组 + 全部模型
  root,

  /// 二级：厂商列表
  providers,

  /// 三级：某个厂商下的模型
  provider,

  /// 二级：某个路由组的成员
  group,
}

/// 小Q 模型选择面板：一级列模型，厂商与组内成员退到下一级
///
/// 参考 ZCode 的选择面板：思考强度跟着模型走，不再在输入区单独占一个胶囊。
/// 点模型即写库并保持面板打开——用户接着就能调它的思考强度，不用先关面板
/// 再点第二个入口。
class AssistantModelSheet extends StatefulWidget {
  final List<AiProvider> providers;
  final List<AiRouteGroup> groups;

  /// 打开面板时的绑定，用于勾选与「思考强度」的作用对象
  final AiModelRef? selected;

  /// 最近使用的绑定（最新在前）；已失效的引用在渲染时会被过滤
  final List<AiModelRef> recentModels;

  /// 点选模型/路由组：写库成功返回 true
  final Future<bool> Function(AiModelRef ref) onSelectBinding;

  /// 调整思考强度：写库成功返回 true
  final Future<bool> Function(List<ReasoningEffortTarget> targets, ReasoningEffort? effort) onEffortChanged;

  /// 调整某个模型的可选档位集合：写库成功返回 true
  final Future<bool> Function(ReasoningEffortTarget target, List<ReasoningEffort>? levels)? onLevelsChanged;

  /// 面板底部的「管理模型」入口
  final VoidCallback? onManageModels;

  const AssistantModelSheet({
    super.key,
    required this.providers,
    required this.groups,
    required this.selected,
    required this.onSelectBinding,
    required this.onEffortChanged,
    this.onLevelsChanged,
    this.recentModels = const [],
    this.onManageModels,
  });

  @override
  State<AssistantModelSheet> createState() => _AssistantModelSheetState();
}

class _AssistantModelSheetState extends State<AssistantModelSheet> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  /// 当前层级
  _SheetLevel _level = _SheetLevel.root;

  /// 二级/三级的作用对象 id：厂商 id 或路由组 id
  String? _scopeId;

  /// 面板打开期间的绑定：点选写库成功后立即移动勾选，不依赖外部重建
  late AiModelRef? _binding = widget.selected;

  /// 面板打开期间调过的思考强度（key 见 [_effortKey]）
  ///
  /// 外部传进来的 providers 是打开面板那一刻的快照，写库后不会自己更新，
  /// 所以本地记一份，避免档位「点了没反应」。
  final Map<String, ReasoningEffort?> _effortOverride = {};

  /// 面板打开期间改过的可选档位
  ///
  /// null 表示「恢复自动识别」，与「没改过」用 [Map.containsKey] 区分。
  final Map<String, List<ReasoningEffort>?> _levelsOverride = {};

  /// 有写库请求在飞：期间禁止重复点选，防止连点写乱绑定
  bool _busy = false;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  String _effortKey(String providerId, String modelName) => '$providerId::$modelName';

  bool _matches(String text) => _query.isEmpty || text.toLowerCase().contains(_query.toLowerCase());

  bool _matchesModel(AiProvider provider, AiProviderModel model) =>
      _matches(model.name) || _matches(model.id) || _matches(provider.name);

  /// 应用本地档位覆盖：思考强度区块读这一份，才和面板上的操作一致
  List<ReasoningEffortTarget> _withOverride(List<ReasoningEffortTarget> targets) {
    if (_effortOverride.isEmpty && _levelsOverride.isEmpty) return targets;
    return [for (final target in targets) _applyOverride(target)];
  }

  /// 给单个目标套上面板期间的档位/当前值覆盖
  ReasoningEffortTarget _applyOverride(ReasoningEffortTarget target) {
    final key = _effortKey(target.provider.id, target.model.id);
    var model = target.model;
    if (_levelsOverride.containsKey(key)) {
      model = model.copyWith(reasoningEfforts: _levelsOverride[key]);
    }
    if (_effortOverride.containsKey(key)) {
      model = model.copyWith(reasoningEffort: _effortOverride[key]);
    }
    return (provider: target.provider, model: model);
  }

  /// 「思考强度」的作用对象
  ///
  /// 一级/厂商列表：当前绑定（具体模型就是它自己，路由组展开为全部启用成员）；
  /// 厂商面板：只作用于当前选中的那个模型，还没选中该厂商下的模型时为空
  /// （面板提示先选模型）；路由组面板：作用于组内全部启用成员。
  List<ReasoningEffortTarget> _effortTargets() {
    switch (_level) {
      case _SheetLevel.group:
        return _withOverride(reasoningTargetsOf(AiModelRef.routeGroup(_scopeId!), widget.providers, widget.groups));
      case _SheetLevel.provider:
        final binding = _binding;
        if (binding == null || binding.isRouteGroup) return const [];
        if (binding.providerId != _scopeId) return const [];
        return _withOverride(reasoningTargetsOf(binding, widget.providers, widget.groups));
      case _SheetLevel.root:
      case _SheetLevel.providers:
        return _withOverride(reasoningTargetsOf(_binding, widget.providers, widget.groups));
    }
  }

  Future<void> _selectBinding(AiModelRef ref) async {
    if (_busy || ref == _binding) return;
    setState(() => _busy = true);
    final ok = await widget.onSelectBinding(ref);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _binding = ref;
    });
  }

  Future<void> _applyEffort(List<ReasoningEffortTarget> targets, ReasoningEffort? effort) async {
    if (_busy) return;
    // 点已选中的档位不做无意义的写库
    if (targets.every((t) => t.model.reasoningEffort == effort)) return;
    setState(() => _busy = true);
    final ok = await widget.onEffortChanged(targets, effort);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) return;
      for (final target in targets) {
        _effortOverride[_effortKey(target.provider.id, target.model.id)] = effort;
      }
    });
  }

  /// 打开某个模型的「思考档位」配置浮层，保存成功后同步本地覆盖
  Future<void> _openLevels(ReasoningEffortTarget target) async {
    final callback = widget.onLevelsChanged;
    if (callback == null || _busy) return;
    final key = _effortKey(target.provider.id, target.model.id);
    final current = _applyOverride(target).model;
    final result = await showModelEffortLevelsSheet(
      context,
      modelName: current.id,
      providerType: target.provider.providerType,
      vendorId: target.provider.vendorId,
      customLevels: current.reasoningEfforts,
    );
    if (result == null || !mounted) return;
    final levels = result.customLevels;
    if (_sameLevels(levels, current.reasoningEfforts)) return;

    setState(() => _busy = true);
    final ok = await callback(target, levels);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) return;
      _levelsOverride[key] = levels;
      // 当前档位被新集合裁掉时写库回调会一并清空；本地也回落「自动」
      final capability = ModelReasoningCapability.forUi(
        modelName: current.id,
        providerType: target.provider.providerType,
        vendorId: target.provider.vendorId,
        customLevels: levels,
      );
      final effort = _effortOverride.containsKey(key) ? _effortOverride[key] : current.reasoningEffort;
      if (effort != null && !capability.supports(effort)) {
        _effortOverride[key] = null;
      }
    });
  }

  /// 面板底部统一入口：单个目标直接配置，路由组先选成员
  Future<void> _manageLevels(List<ReasoningEffortTarget> targets) async {
    if (targets.length == 1) {
      await _openLevels(targets.first);
      return;
    }
    final picked = await showModalBottomSheet<ReasoningEffortTarget>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _buildTargetPicker(context, targets),
    );
    if (picked == null || !mounted) return;
    await _openLevels(picked);
  }

  /// 路由组成员 → 配置目标的二级选择浮层
  Widget _buildTargetPicker(BuildContext context, List<ReasoningEffortTarget> targets) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择要配置档位的模型', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final target in targets)
                    ListTile(
                      title: Text(target.model.name),
                      subtitle: Text(
                        '${target.provider.name} · ${_levelsSummary(target)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).pop(target),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 目标的档位概览，用于路由组选模型时区分成员
  String _levelsSummary(ReasoningEffortTarget target) {
    final model = _applyOverride(target).model;
    final capability = ModelReasoningCapability.forUi(
      modelName: model.id,
      providerType: target.provider.providerType,
      vendorId: target.provider.vendorId,
      customLevels: model.reasoningEfforts,
    );
    final labels = capability.levels.map(capability.labelFor).join(' / ');
    return model.reasoningEfforts == null ? '$labels（自动）' : '$labels（自定义）';
  }

  /// 两个档位集合是否一致（null 表示自动识别）
  bool _sameLevels(List<ReasoningEffort>? a, List<ReasoningEffort>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 进入某个层级；清空搜索，避免上一层的筛选条件把新列表滤空
  void _goTo(_SheetLevel level, {String? scopeId}) {
    FocusManager.instance.primaryFocus?.unfocus();
    _searchCtl.clear();
    setState(() {
      _query = '';
      _level = level;
      _scopeId = scopeId;
    });
  }

  void _goBack() {
    switch (_level) {
      case _SheetLevel.provider:
        _goTo(_SheetLevel.providers);
      case _SheetLevel.group:
      case _SheetLevel.providers:
        _goTo(_SheetLevel.root);
      case _SheetLevel.root:
        break;
    }
  }

  /// 点路由组：先写绑定再进成员面板（组内成员与档位都在那一屏里）
  Future<void> _openGroup(AiRouteGroup group) async {
    await _selectBinding(AiModelRef.routeGroup(group.id));
    if (!mounted) return;
    _goTo(_SheetLevel.group, scopeId: group.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showSearch = _searchableCount() > 6;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        children: [
          _buildHeader(theme),
          if (showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
          Expanded(child: _buildBody(scrollController, theme)),
          _buildEffortSection(theme),
        ],
      ),
    );
  }

  /// 当前层级的可搜索条目数，决定是否显示搜索框
  int _searchableCount() {
    switch (_level) {
      case _SheetLevel.root:
        return enabledModelEntries(widget.providers).length + widget.groups.length;
      case _SheetLevel.providers:
        return widget.providers.where((p) => p.enabled && p.models.isNotEmpty).length;
      case _SheetLevel.provider:
        final provider = _providerById(_scopeId);
        return provider?.models.length ?? 0;
      case _SheetLevel.group:
        final group = _groupById(_scopeId);
        return group?.members.length ?? 0;
    }
  }

  AiProvider? _providerById(String? id) => widget.providers.where((p) => p.id == id).firstOrNull;

  AiRouteGroup? _groupById(String? id) => widget.groups.where((g) => g.id == id).firstOrNull;

  /// 面板头部：一级是标题，二三级带「上一步」与当前范围名
  Widget _buildHeader(ThemeData theme) {
    if (_level == _SheetLevel.root) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
        child: Row(
          children: [
            Expanded(
              child: Text('选择小Q模型', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
            IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }

    final String title;
    final String? subtitle;
    switch (_level) {
      case _SheetLevel.providers:
        title = '按厂商选择';
        subtitle = '${widget.providers.where((p) => p.enabled).length} 家';
      case _SheetLevel.provider:
        final provider = _providerById(_scopeId);
        title = provider?.name ?? '已失效';
        subtitle = provider == null ? null : '${provider.models.length} 个模型';
      case _SheetLevel.group:
        final group = _groupById(_scopeId);
        title = group?.name ?? '已失效';
        subtitle = group == null ? null : '${group.enabledMembers.length} 个成员 · ${group.strategy.label}';
      case _SheetLevel.root:
        title = '';
        subtitle = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _goBack,
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
                label: const Text('上一步'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (subtitle != null)
                Text(subtitle, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(ScrollController controller, ThemeData theme) {
    switch (_level) {
      case _SheetLevel.root:
        return _buildRootList(controller, theme);
      case _SheetLevel.providers:
        return _buildProviderList(controller, theme);
      case _SheetLevel.provider:
        return _buildProviderModels(controller, theme);
      case _SheetLevel.group:
        return _buildGroupMembers(controller, theme);
    }
  }

  // ── 一级：最近使用 + 路由组 + 全部模型 ───────────────────

  Widget _buildRootList(ScrollController controller, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    // 没有成员的组绑上也是坏体验，这里直接不出现
    final groups = widget.groups.where((g) => g.enabledMembers.isNotEmpty).where((g) => _matches(g.name)).toList();
    final models = [
      for (final entry in enabledModelEntries(widget.providers))
        if (_matchesModel(entry.provider, entry.model)) entry,
    ];
    // 最近使用里已经出现的绑定不在下面重复列出，列表更短也更好扫
    final recent = recentBindingEntries(
      widget.recentModels,
      widget.providers,
      widget.groups,
    ).where(_matchesRecent).toList();
    final recentRefs = {for (final entry in recent) entry.ref};
    final otherModels = [
      for (final entry in models)
        if (!recentRefs.contains(AiModelRef(providerId: entry.provider.id, modelName: entry.model.id))) entry,
    ];
    final otherGroups = [
      for (final group in groups)
        if (!recentRefs.contains(AiModelRef.routeGroup(group.id))) group,
    ];
    final providerCount = widget.providers.where((p) => p.enabled && p.models.isNotEmpty).length;

    if (models.isEmpty && groups.isEmpty && recent.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text('没有匹配的模型或厂商', style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
        ),
      );
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (recent.isNotEmpty) ...[
          _sectionHeader(theme, '最近使用', trailing: '${recent.length} 个'),
          for (final entry in recent) _buildRecentTile(theme, entry),
        ],
        if (otherGroups.isNotEmpty) ...[
          _sectionHeader(theme, '路由组', trailing: '多模型轮流 / 故障转移'),
          for (final group in otherGroups) _buildGroupTile(theme, group),
        ],
        if (otherModels.isNotEmpty) ...[
          _sectionHeader(
            theme,
            '全部模型',
            trailing: '${otherModels.length} 个',
            action: providerCount > 0
                ? TextButton(
                    onPressed: () => _goTo(_SheetLevel.providers),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    child: Text('按厂商浏览（$providerCount）'),
                  )
                : null,
          ),
          for (final entry in otherModels) _buildModelTile(theme, entry.provider, entry.model, dense: true),
        ],
        if (widget.onManageModels != null) ...[
          const Divider(height: 24, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('管理模型'),
            subtitle: const Text('添加厂商、扫描并启用模型'),
            // 先关面板再跳转，避免弹层盖在设置页上
            onTap: () {
              Navigator.of(context).pop();
              widget.onManageModels!.call();
            },
          ),
        ],
      ],
    );
  }

  bool _matchesRecent(RecentBindingEntry entry) =>
      _matches(entry.name) || _matches(entry.providerName ?? '') || _matches(entry.ref.modelName);

  Widget _buildRecentTile(ThemeData theme, RecentBindingEntry entry) {
    final colorScheme = theme.colorScheme;
    final isSelected = entry.ref == _binding;
    final subtitle = [if (entry.providerName != null) entry.providerName, entry.meta].whereType<String>().join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(
        entry.isGroup ? Icons.alt_route_rounded : Icons.history_rounded,
        size: 20,
        color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: FontWeight.w600, color: isSelected ? colorScheme.primary : null),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
      trailing: isSelected ? Icon(Icons.check_rounded, size: 20, color: colorScheme.primary) : null,
      onTap: entry.isGroup ? () => _openGroupById(entry.ref.providerId) : () => _selectBinding(entry.ref),
    );
  }

  Future<void> _openGroupById(String groupId) async {
    final group = _groupById(groupId);
    if (group == null) return;
    await _openGroup(group);
  }

  Widget _buildGroupTile(ThemeData theme, AiRouteGroup group) {
    final colorScheme = theme.colorScheme;
    final ref = AiModelRef.routeGroup(group.id);
    final isSelected = ref == _binding;
    final live = routeGroupLiveMemberCount(group, widget.providers);
    return ListTile(
      leading: Icon(Icons.alt_route_rounded, color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant),
      title: Text(
        group.name,
        style: TextStyle(fontWeight: FontWeight.w600, color: isSelected ? colorScheme.primary : null),
      ),
      subtitle: Text(
        live == 0 ? '${group.strategy.label} · 模型均已停用' : '$live 个模型 · ${group.strategy.label}',
        style: theme.textTheme.bodySmall?.copyWith(color: live == 0 ? colorScheme.error : colorScheme.onSurfaceVariant),
      ),
      trailing: isSelected
          ? Icon(Icons.check_rounded, color: colorScheme.primary)
          : Icon(Icons.chevron_right_rounded, color: colorScheme.outline),
      onTap: () => _openGroup(group),
    );
  }

  // ── 二级：厂商列表 ──────────────────────────────────────

  Widget _buildProviderList(ScrollController controller, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final providers = widget.providers
        .where((p) => p.enabled && p.models.isNotEmpty)
        .where((p) => _matchesProvider(p))
        .toList();
    if (providers.isEmpty) {
      return Center(
        child: Text('没有匹配的厂商', style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 16),
      children: [for (final provider in providers) _buildProviderTile(theme, provider)],
    );
  }

  bool _matchesProvider(AiProvider provider) =>
      _matches(provider.name) || provider.models.any((m) => _matches(m.id) || _matches(m.name));

  Widget _buildProviderTile(ThemeData theme, AiProvider provider) {
    final colorScheme = theme.colorScheme;
    final binding = _binding;
    final inProvider = binding != null && !binding.isRouteGroup && binding.providerId == provider.id;
    final current = inProvider ? provider.models.where((m) => m.id == binding.modelName).firstOrNull : null;
    // 有当前选择时先说清「这家现在用的是谁」，没有就报该厂商的模型规模
    final subtitle = [
      if (current != null) '当前 ${current.name}' else '${provider.models.length} 个模型',
      if (provider.isDefault) '默认',
    ].join(' · ');
    return ListTile(
      leading: Icon(Icons.memory_rounded, color: inProvider ? colorScheme.primary : colorScheme.onSurfaceVariant),
      title: Text(
        provider.name,
        style: TextStyle(fontWeight: FontWeight.w600, color: inProvider ? colorScheme.primary : null),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: inProvider ? colorScheme.primary : colorScheme.outline),
      onTap: () => _goTo(_SheetLevel.provider, scopeId: provider.id),
    );
  }

  // ── 三级：某厂商的模型 ──────────────────────────────────

  Widget _buildProviderModels(ScrollController controller, ThemeData theme) {
    final provider = _providerById(_scopeId);
    if (provider == null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('这个绑定已经失效，请重新选择', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
      );
    }
    final models = provider.models.where((m) => _matches(m.id) || _matches(m.name)).toList();
    if (models.isEmpty) {
      return Center(
        child: Text('没有匹配的模型', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 16),
      children: [for (final model in models) _buildModelTile(theme, provider, model)],
    );
  }

  Widget _buildModelTile(ThemeData theme, AiProvider provider, AiProviderModel model, {bool dense = false}) {
    final colorScheme = theme.colorScheme;
    final ref = AiModelRef(providerId: provider.id, modelName: model.id);
    final isSelected = ref == _binding;
    // 一级是跨厂商平铺，副标题必须带厂商名才分得清同名模型
    final subtitle = [if (dense) provider.name, ?modelMetaLine(model)].join(' · ');
    return ListTile(
      dense: dense,
      title: Text(
        model.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: FontWeight.w600, color: isSelected ? colorScheme.primary : null),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
      trailing: isSelected ? Icon(Icons.check_rounded, size: 20, color: colorScheme.primary) : null,
      onTap: () => _selectBinding(ref),
    );
  }

  // ── 二级：路由组成员 ────────────────────────────────────

  Widget _buildGroupMembers(ScrollController controller, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final group = _groupById(_scopeId);
    if (group == null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('这个绑定已经失效，请重新选择', style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.error)),
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _sectionHeader(theme, '组内模型', trailing: '按「${group.strategy.label}」自动选择'),
        for (final member in group.members) _buildMemberTile(theme, group, member),
      ],
    );
  }

  /// 成员行是只读的：选了路由组就是选整组，成员由路由策略自动挑
  Widget _buildMemberTile(ThemeData theme, AiRouteGroup group, RouteGroupMember member) {
    final colorScheme = theme.colorScheme;
    final target = _targetOf(widget.providers, member.providerId, member.modelName);
    final provider = target?.provider;
    final model = target?.model;
    final broken = provider == null || model == null;
    final disabled = !member.enabled;
    final subtitle = [
      if (model == null || provider == null) '模型已删除',
      // 模型名与厂商名相同时不重复占一行
      if (provider != null && provider.name != model?.name) provider.name,
      if (disabled) '组内已停用',
      if (group.strategy == RouteStrategy.weight) '权重 ${member.weight}',
    ].join(' · ');
    final color = broken || disabled ? colorScheme.error : colorScheme.onSurfaceVariant;
    return ListTile(
      dense: true,
      title: Text(model?.name ?? member.modelName, style: TextStyle(color: broken || disabled ? color : null)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: color)),
    );
  }

  /// 分区标题；[action] 用于放一个内联操作（如「按厂商浏览」）
  Widget _sectionHeader(ThemeData theme, String title, {String? trailing, Widget? action}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (action != null)
            action
          else if (trailing != null)
            Text(trailing, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }

  // ── 思考强度 ────────────────────────────────────────────

  Widget _buildEffortSection(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final targets = _effortTargets();
    final state = reasoningEffortStateOf(targets);
    final first = targets.isEmpty ? null : targets.first;
    final options = first == null
        ? const <ReasoningEffortOption>[]
        : reasoningEffortOptions(
            modelName: first.model.id,
            providerType: first.provider.providerType,
            vendorId: first.provider.vendorId,
            customLevels: first.model.reasoningEfforts,
          );
    final hint = state == null ? '' : _effortHint(state, options);
    final showBinding = _level == _SheetLevel.root || _level == _SheetLevel.providers;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEffortTitleRow(theme, state, showBinding: showBinding),
            if (state == null) ...[
              const SizedBox(height: 6),
              Text(
                _level == _SheetLevel.provider
                    ? '选中模型后即可调整它的思考强度'
                    : (_level == _SheetLevel.group ? '组内没有可用模型' : '当前没有可调整的模型'),
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in options)
                    ChoiceChip(
                      label: Text(option.label),
                      selected: !state.mixed && option.effort == state.effort,
                      visualDensity: VisualDensity.compact,
                      onSelected: _busy ? null : (_) => _applyEffort(targets, option.effort),
                    ),
                ],
              ),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
              ],
              // 对话里也能改这个模型的档位集合，不用退回设置页
              if (widget.onLevelsChanged != null) ...[
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _busy ? null : () => _manageLevels(targets),
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: Text(targets.length > 1 ? '管理思考档位（${targets.length} 个模型）' : '管理思考档位'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 档位区块的标题行
  ///
  /// 一级显示「当前模型/当前路由组 + 绑定名」，二三级只写「思考强度」：
  /// 一级列表本身不说明当前绑的是哪个模型，这一行必须把名字带上。
  Widget _buildEffortTitleRow(ThemeData theme, ReasoningEffortState? state, {required bool showBinding}) {
    final colorScheme = theme.colorScheme;
    final bindingName = showBinding ? _bindingDisplayName() : null;
    final isGroup = _binding?.isRouteGroup ?? false;
    return Row(
      children: [
        Text(
          showBinding ? (isGroup ? '当前路由组' : '当前模型') : '思考强度',
          style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (showBinding) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              bindingName ?? '未选择',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ] else
          const Spacer(),
        if (state != null)
          Text(
            state.mixed ? '混合' : state.capability.labelFor(state.effort),
            style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }

  /// 当前绑定的展示名：路由组给组名，模型给模型名（厂商在这一行不重复）
  String? _bindingDisplayName() {
    final binding = _binding;
    if (binding == null) return null;
    if (binding.isRouteGroup) {
      return widget.groups.where((g) => g.id == binding.providerId).firstOrNull?.name;
    }
    final target = _targetOf(widget.providers, binding.providerId, binding.modelName);
    return target?.model.name ?? binding.modelName;
  }

  /// 档位说明：与单独弹层共用一套文案，再补充混合/通用参数的提醒
  String _effortHint(ReasoningEffortState state, List<ReasoningEffortOption> options) {
    final parts = <String>[];
    if (state.mixed) {
      parts.add('组内档位不一致，选择后统一写入全部启用成员');
    } else {
      final description = options.where((o) => o.effort == state.effort).map((o) => o.description).firstOrNull;
      if (description != null) parts.add(description);
    }
    if (state.capability.isGeneric) {
      parts.add('未收录该模型的思考参数，按通用字段发送，不支持时自动忽略');
    }
    if (state.capability.isBinary) {
      parts.add('该模型主要靠开关表达思考，中间档会附带 reasoning_effort 尽力传达');
    }
    if (state.customized) {
      parts.add('档位已按模型设置自定义');
    }
    return parts.join('；');
  }
}

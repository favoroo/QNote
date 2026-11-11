import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/ai/ai_route_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';

/// 路由组编辑页入参：`group` 为 null 表示新建
class AiRouteGroupEditArgs {
  final AiRouteGroup? group;

  const AiRouteGroupEditArgs({this.group});
}

/// 模型路由组编辑页
///
/// 移动端优先：策略用 ChoiceChip 换行排列（5 个中文标签在窄屏也不会溢出）、
/// 成员长按拖动改顺序（顺序即故障转移优先级）、权重只在权重策略下出现。
class AiRouteGroupEditPage extends ConsumerStatefulWidget {
  final AiRouteGroup? group;

  const AiRouteGroupEditPage({super.key, this.group});

  @override
  ConsumerState<AiRouteGroupEditPage> createState() => _AiRouteGroupEditPageState();
}

class _AiRouteGroupEditPageState extends ConsumerState<AiRouteGroupEditPage> {
  late final TextEditingController _nameCtl;
  late RouteStrategy _strategy;
  late List<RouteGroupMember> _members;
  String? _pinnedMember;
  late bool _preferVision;
  bool _saving = false;
  bool _dirty = false;

  AiRouteGroup? get _existing => widget.group;

  @override
  void initState() {
    super.initState();
    final group = _existing;
    _nameCtl = TextEditingController(text: group?.name ?? '');
    _strategy = group?.strategy ?? RouteStrategy.rotate;
    _members = List.of(group?.members ?? const []);
    _pinnedMember = group?.pinnedMember;
    _preferVision = group?.preferVision ?? true;
    _nameCtl.addListener(() => _markDirty());
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  // ── 成员编辑 ─────────────────────────────────────────────

  Future<void> _addMembers(List<AiProvider> providers) async {
    final picked = await showModalBottomSheet<List<AiModelRef>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AddMemberSheet(providers: providers, existing: _members.map((m) => m.encode()).toSet()),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      for (final ref in picked) {
        if (_members.any((m) => m.encode() == ref.encode())) continue;
        _members.add(RouteGroupMember(providerId: ref.providerId, modelName: ref.modelName));
      }
      _dirty = true;
    });
  }

  void _removeMember(RouteGroupMember member) {
    setState(() {
      _members.removeWhere((m) => m.encode() == member.encode());
      if (_pinnedMember == member.encode()) _pinnedMember = null;
      _dirty = true;
    });
  }

  void _setWeight(RouteGroupMember member, int weight) {
    setState(() {
      final index = _members.indexWhere((m) => m.encode() == member.encode());
      if (index < 0) return;
      _members[index] = _members[index].copyWith(weight: weight);
      _dirty = true;
    });
  }

  void _setEnabled(RouteGroupMember member, bool enabled) {
    setState(() {
      final index = _members.indexWhere((m) => m.encode() == member.encode());
      if (index < 0) return;
      _members[index] = _members[index].copyWith(enabled: enabled);
      _dirty = true;
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final moved = _members.removeAt(oldIndex);
      _members.insert(newIndex, moved);
      _dirty = true;
    });
  }

  // ── 保存 / 删除 ──────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      Toast.warning(context, '请填写名称');
      return;
    }
    if (_members.isEmpty) {
      Toast.warning(context, '请至少添加一个模型');
      return;
    }
    if (!_members.any((m) => m.enabled)) {
      Toast.warning(context, '请至少启用一个成员');
      return;
    }

    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final group = AiRouteGroup(
        id: _existing?.id ?? const Uuid().v4(),
        name: name,
        strategy: _strategy,
        members: _members,
        // 手动策略下固定成员，退出该策略后保留原值以备切回
        pinnedMember: _strategy == RouteStrategy.manual
            ? (_pinnedMember ?? _firstEnabledRef())
            : _existing?.pinnedMember,
        preferVision: _preferVision,
        createdAt: _existing?.createdAt ?? now,
        updatedAt: now,
      );
      await ref.read(aiRouteGroupListProvider.notifier).saveGroup(group);
      if (!mounted) return;
      Toast.success(context, '已保存');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) Toast.error(context, '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _firstEnabledRef() {
    for (final member in _members) {
      if (member.enabled) return member.encode();
    }
    return _members.isEmpty ? null : _members.first.encode();
  }

  Future<void> _delete() async {
    final group = _existing;
    if (group == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除路由组'),
        content: Text('删除「${group.name}」？绑定角色会回落到默认厂商的首个模型。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(aiRouteGroupListProvider.notifier).deleteGroup(group.id);
      if (!mounted) return;
      Toast.success(context, '已删除');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) Toast.error(context, '删除失败：$e');
    }
  }

  // ── 构建 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providersAsync = ref.watch(aiProviderListProvider);
    final providers = providersAsync.valueOrNull ?? const <AiProvider>[];

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || !_dirty) return;
        final discard = await _confirmDiscard();
        if (discard != true) return;
        if (!context.mounted) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_existing == null ? '新建路由组' : '编辑路由组'),
          actions: [
            if (_existing != null)
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  if (value == 'delete') _delete();
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('删除', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  ),
                ],
              ),
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(labelText: '名称', hintText: '如：小Q 主模型池', border: OutlineInputBorder()),
              maxLength: 24,
            ),
            _sectionTitle(theme, '调用策略', _strategy.description),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: RouteStrategy.values.map((strategy) {
                return ChoiceChip(
                  label: Text(strategy.label),
                  selected: _strategy == strategy,
                  onSelected: (selected) {
                    if (!selected) return;
                    setState(() {
                      _strategy = strategy;
                      if (strategy == RouteStrategy.manual) {
                        _pinnedMember ??= _firstEnabledRef();
                      }
                      _dirty = true;
                    });
                  },
                );
              }).toList(),
            ),
            if (_strategy == RouteStrategy.manual) ...[
              const SizedBox(height: 8),
              _buildPinnedSelector(theme, providers),
            ],
            _sectionTitle(
              theme,
              '成员（${_members.where((m) => m.enabled).length} 个启用）',
              '长按拖动调整顺序${_strategy == RouteStrategy.failover ? '（即优先级）' : ''}',
              action: TextButton.icon(
                onPressed: providers.isEmpty ? null : () => _addMembers(providers),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加模型'),
              ),
            ),
            if (_members.isEmpty) _buildEmptyMembers(theme) else _buildMemberList(theme, providers),
            if (_members.isNotEmpty && !_meetsStrategyMinimum()) ...[
              const SizedBox(height: 8),
              _hint(theme, '只有一个启用成员，当前策略不会生效。'),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              value: _preferVision,
              contentPadding: EdgeInsets.zero,
              title: const Text('优先选支持识图的成员'),
              subtitle: const Text('避免图片发给不支持识图的模型'),
              onChanged: (value) => setState(() {
                _preferVision = value;
                _dirty = true;
              }),
            ),
            _hint(
              theme,
              '组内模型需都能胜任该角色：小Q 对话需支持工具调用，'
              '生图需支持 images/generations。',
            ),
          ],
        ),
      ),
    );
  }

  bool _meetsStrategyMinimum() {
    if (!_strategy.needsMultipleMembers) return true;
    return _members.where((m) => m.enabled).length >= 2;
  }

  Future<bool?> _confirmDiscard() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃修改'),
        content: const Text('修改尚未保存，确定离开？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('继续编辑')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('放弃')),
        ],
      ),
    );
  }

  Widget _buildPinnedSelector(ThemeData theme, List<AiProvider> providers) {
    final options = _members.where((m) => m.enabled).toList();
    final value = options.any((m) => m.encode() == _pinnedMember)
        ? _pinnedMember
        : (options.isEmpty ? null : options.first.encode());
    return DropdownButtonFormField<String>(
      initialValue: value,
      borderRadius: BorderRadius.circular(12),
      decoration: const InputDecoration(labelText: '当前固定成员', border: OutlineInputBorder(), isDense: true),
      items: options
          .map(
            (m) => DropdownMenuItem(
              value: m.encode(),
              child: Text(aiModelDisplayName(m.ref, providers, fallback: m.modelName), overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: (selected) => setState(() {
        _pinnedMember = selected;
        _dirty = true;
      }),
    );
  }

  Widget _buildEmptyMembers(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Text(
        '还没有成员，点「添加模型」挑选',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildMemberList(ThemeData theme, List<AiProvider> providers) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: _reorder,
      children: [for (var i = 0; i < _members.length; i++) _memberTile(theme, providers, _members[i], i)],
    );
  }

  Widget _memberTile(ThemeData theme, List<AiProvider> providers, RouteGroupMember member, int index) {
    final colorScheme = theme.colorScheme;
    final provider = providers.where((p) => p.id == member.providerId).firstOrNull;
    final live = provider != null && provider.hasModel(member.modelName);
    final model = provider?.models.where((m) => m.id == member.modelName).firstOrNull;

    return Container(
      key: ValueKey(member.encode()),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
              child: Icon(Icons.drag_handle_rounded, size: 20, color: colorScheme.outline),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        model?.name ?? member.modelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: live ? null : colorScheme.error,
                        ),
                      ),
                    ),
                    if (!live) ...[const SizedBox(width: 6), _badge(theme, '已失效', colorScheme.error)],
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  provider?.name ?? '未知厂商',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (_strategy == RouteStrategy.weight) _weightStepper(theme, member),
          Switch(value: member.enabled, onChanged: (value) => _setEnabled(member, value)),
          IconButton(
            tooltip: '移除',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 18, color: colorScheme.outline),
            onPressed: () => _removeMember(member),
          ),
        ],
      ),
    );
  }

  Widget _weightStepper(ThemeData theme, RouteGroupMember member) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '减少权重',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: member.weight <= RouteGroupMember.minWeight ? null : () => _setWeight(member, member.weight - 1),
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
        Text('${member.weight}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
        IconButton(
          tooltip: '增加权重',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: member.weight >= RouteGroupMember.maxWeight ? null : () => _setWeight(member, member.weight + 1),
          icon: const Icon(Icons.add_circle_outline_rounded),
        ),
      ],
    );
  }

  Widget _badge(ThemeData theme, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _hint(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title, String subtitle, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// 添加成员弹层：按厂商分组多选已启用模型，已加入的置灰
class _AddMemberSheet extends StatefulWidget {
  final List<AiProvider> providers;
  final Set<String> existing;

  const _AddMemberSheet({required this.providers, required this.existing});

  @override
  State<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends State<_AddMemberSheet> {
  final TextEditingController _searchCtl = TextEditingController();
  final Set<String> _picked = {};
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
    final entries = enabledModelEntries(widget.providers);
    final showSearch = entries.length > 8;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('添加成员', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: TextField(
                controller: _searchCtl,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '搜索模型或厂商',
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                    child: Center(child: Text('还没有已启用的模型')),
                  ),
                for (final provider in widget.providers) ..._providerSection(theme, provider),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已选 ${_picked.length} 个',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  FilledButton(
                    onPressed: _picked.isEmpty
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop(_picked.map(AiModelRef.tryParse).whereType<AiModelRef>().toList()),
                    child: const Text('添加'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _providerSection(ThemeData theme, AiProvider provider) {
    final models = provider.models.where((m) => _matches(provider, m)).toList();
    if (models.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
        child: Text(
          provider.name,
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline, fontWeight: FontWeight.bold),
        ),
      ),
      ...models.map((model) {
        final ref = AiModelRef(providerId: provider.id, modelName: model.id);
        final encoded = ref.encode();
        final alreadyAdded = widget.existing.contains(encoded);
        final checked = _picked.contains(encoded);
        return CheckboxListTile(
          dense: true,
          value: alreadyAdded || checked,
          onChanged: alreadyAdded
              ? null
              : (value) => setState(() {
                  if (value == true) {
                    _picked.add(encoded);
                  } else {
                    _picked.remove(encoded);
                  }
                }),
          title: Text(model.name),
          subtitle: alreadyAdded ? const Text('已在组内') : (model.name == model.id ? null : Text(model.id)),
        );
      }),
    ];
  }
}

/// 组卡片摘要：「3 个模型 · 轮流 · 上次 A厂商 · m1」
///
/// 上次使用的成员只存在于进程内（[AiRouteService.lastUsedMember]），重启后消失，
/// 因此这里缺省不显示，避免出现「上次」字样却没有值。
String routeGroupSummary(AiRouteGroup group, List<AiProvider> providers) {
  final buffer = StringBuffer('${group.enabledMembers.length} 个模型 · ')..write(group.strategy.label);
  final lastRef = AiModelRef.tryParse(AiRouteService.instance.lastUsedMember(group.id));
  if (lastRef != null) {
    buffer.write(' · 上次 ${aiModelDisplayName(lastRef, providers, fallback: lastRef.modelName)}');
  }
  return buffer.toString();
}

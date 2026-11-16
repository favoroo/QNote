import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
import 'package:qnote_flutter/providers/quick_prompt_provider.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';

/// 常用提示词弹窗的选择结果
///
/// [text] 用来覆盖输入框；[skillNames] 是本轮要显式附加的技能主名，
/// 由发送侧注入技能手册，仅对这一条消息生效。
class QuickPromptSelection {
  const QuickPromptSelection({required this.text, this.skillNames = const []});

  final String text;
  final List<String> skillNames;
}

/// 常用提示词选择与管理弹窗
///
/// 点击列表项 → 回调 [onSelected] 覆盖填充输入框并关闭弹窗；
/// 弹窗内同时支持新增、编辑、删除提示词（含默认项），
/// 以及在发送前为本轮指定要附加的技能（默认带上 [initialSkillNames] 当前选择）。
Future<void> showQuickPromptDialog(
  BuildContext context,
  WidgetRef ref,
  void Function(QuickPromptSelection selection) onSelected, {
  List<String> initialSkillNames = const [],
  void Function(List<String> skillNames)? onSkillsChanged,
}) async {
  await AppMotion.showDialog<void>(
    context: context,
    builder: (dialogContext) => _QuickPromptDialog(
      onSelected: onSelected,
      initialSkillNames: initialSkillNames,
      onSkillsChanged: onSkillsChanged,
    ),
  );
}

class _QuickPromptDialog extends ConsumerStatefulWidget {
  const _QuickPromptDialog({required this.onSelected, this.initialSkillNames = const [], this.onSkillsChanged});

  final void Function(QuickPromptSelection selection) onSelected;

  /// 打开弹窗时已挂在本轮输入区的技能（重新打开时保持勾选状态）
  final List<String> initialSkillNames;

  /// 技能勾选变化即时回调：不选提示词直接关闭弹窗时，选择也能保留到本轮输入区
  final void Function(List<String> skillNames)? onSkillsChanged;

  @override
  ConsumerState<_QuickPromptDialog> createState() => _QuickPromptDialogState();
}

class _QuickPromptDialogState extends ConsumerState<_QuickPromptDialog> {
  /// 原地编辑共用一个控制器：同一时刻只允许一条在编辑
  final TextEditingController _editController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// 正在编辑的下标；null 表示没有正在编辑
  int? _editingIndex;

  /// 是否在列表末尾新增一条
  bool _isAdding = false;

  /// 保存中，防止连点造成重复新增
  bool _saving = false;

  /// 可选技能（内置 + 未归档的用户技能），异步加载完成前为空
  List<Map<String, String>> _skills = const [];

  /// 自定义技能 / 内置技能的折叠态：手风琴式，同一时间只展开一组，
  /// 避免 12 个内置技能全部铺开把弹窗撑高、把提示词列表挤到看不见
  bool _userSkillsExpanded = false;
  bool _builtinSkillsExpanded = true;

  /// 默认展开分组只在技能清单首次加载时决定一次，之后完全交给用户点击
  bool _skillGroupDefaultApplied = false;

  /// 本轮勾选的技能主名（有序去重）；弹窗关闭时随选中的提示词一起返回
  final List<String> _selectedSkillNames = [];

  /// 一次最多附加的手册数量：手册正文较长，选太多会挤占本轮上下文预算
  static const int _maxSelectedSkills = 3;

  bool get _editing => _editingIndex != null || _isAdding;

  @override
  void initState() {
    super.initState();
    // 初始选择先落位：技能清单异步加载后再过滤掉已删除/已归档的技能
    for (final raw in widget.initialSkillNames) {
      final name = raw.trim();
      if (name.isNotEmpty && !_selectedSkillNames.contains(name)) {
        _selectedSkillNames.add(name);
      }
    }
    _loadSkills();
  }

  Future<void> _loadSkills() async {
    await SkillRegistry.instance.ensureLoaded();
    final stats = await SkillUsageTracker.instance.getStats();
    if (!mounted) return;
    final skills = SkillRegistry.instance.listSkills();
    final available = {for (final skill in skills) skill['name'] ?? ''};
    // 组内排序：常用技能排在前面（次数相同保持注册表顺序），已选中的再整体提前，
    // 方便用户在同组内快速找到本轮要用的技能
    final indexed = [for (var i = 0; i < skills.length; i++) (index: i, skill: skills[i])];
    indexed.sort((a, b) {
      final byUsage = (stats[b.skill['name']]?.count ?? 0).compareTo(stats[a.skill['name']]?.count ?? 0);
      return byUsage != 0 ? byUsage : a.index.compareTo(b.index);
    });
    final ordered = [
      for (final entry in indexed)
        if (_selectedSkillNames.contains(entry.skill['name'])) entry.skill,
      for (final entry in indexed)
        if (!_selectedSkillNames.contains(entry.skill['name'])) entry.skill,
    ];
    final userSkills = ordered.where((skill) => skill['origin'] == AgentSkillOrigin.user).toList();
    final builtinSkills = ordered.where((skill) => skill['origin'] != AgentSkillOrigin.user).toList();
    final initialCount = _selectedSkillNames.length;
    setState(() {
      _skills = ordered;
      _selectedSkillNames.removeWhere((name) => !available.contains(name));
      if (!_skillGroupDefaultApplied) {
        _skillGroupDefaultApplied = true;
        final selectedUser = userSkills.any((skill) => _selectedSkillNames.contains(skill['name']));
        final selectedBuiltin = builtinSkills.any((skill) => _selectedSkillNames.contains(skill['name']));
        // 优先展开包含已选技能的分组；都没选时，有自定义技能就先展示自定义
        _userSkillsExpanded = selectedUser || (!selectedBuiltin && userSkills.isNotEmpty);
        _builtinSkillsExpanded = !_userSkillsExpanded;
      }
    });
    // 已删除/已归档的技能从本轮选择里剔除时，同步通知输入区，避免留下无效技能
    if (_selectedSkillNames.length != initialCount) _notifySkillsChanged();
  }

  /// 把当前勾选同步给输入区；技能是即时生效的，不依赖用户再点一条提示词
  void _notifySkillsChanged() => widget.onSkillsChanged?.call(List.unmodifiable(_selectedSkillNames));

  /// 勾选/取消一个技能；超过上限时提示而不是静默忽略
  void _toggleSkill(String name) {
    if (_selectedSkillNames.contains(name)) {
      HapticFeedback.selectionClick();
      setState(() => _selectedSkillNames.remove(name));
      _notifySkillsChanged();
      return;
    }
    if (_selectedSkillNames.length >= _maxSelectedSkills) {
      Toast.warning(context, '最多附加 $_maxSelectedSkills 个技能');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _selectedSkillNames.add(name));
    _notifySkillsChanged();
  }

  /// 折叠/展开技能分组：手风琴式，展开一组时自动收起另一组
  void _toggleSkillGroup({required bool userGroup}) {
    HapticFeedback.selectionClick();
    setState(() {
      if (userGroup) {
        _userSkillsExpanded = !_userSkillsExpanded;
        if (_userSkillsExpanded) _builtinSkillsExpanded = false;
      } else {
        _builtinSkillsExpanded = !_builtinSkillsExpanded;
        if (_builtinSkillsExpanded) _userSkillsExpanded = false;
      }
    });
  }

  @override
  void dispose() {
    _editController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final promptsAsync = ref.watch(quickPromptListProvider);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.large + 4)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme, promptsAsync),
            if (_skills.isNotEmpty) _buildSkillSection(theme),
            Flexible(child: _buildBody(theme, promptsAsync)),
            // 底部留白收窄到 12，避免列表最后一行的圆角与弹窗边缘之间空一大截
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// 头部：图标 + 标题/数量 + 圆形添加/关闭按钮
  Widget _buildHeader(ThemeData theme, AsyncValue<List<String>> promptsAsync) {
    final scheme = theme.colorScheme;
    final count = promptsAsync.valueOrNull?.length ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(Icons.bolt_rounded, size: 21, color: theme.accentInk),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '常用提示词',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.accentInk,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 原地编辑期间禁用新增，避免同时开两个编辑区
          Opacity(
            opacity: _editing ? 0.4 : 1,
            child: IgnorePointer(
              ignoring: _editing,
              child: AppIconBadge(icon: Icons.add_rounded, size: 36, iconSize: 20, tooltip: '添加提示词', onTap: _startAdd),
            ),
          ),
          const SizedBox(width: 4),
          _CircleAction(
            icon: Icons.close_rounded,
            tooltip: '关闭',
            background: scheme.onSurface.withValues(alpha: 0.06),
            foreground: scheme.onSurfaceVariant,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 本轮附加技能选择区：自定义技能与内置技能分组展示，各自可折叠
  ///
  /// 勾选结果是即时生效的，由 [onSkillsChanged] 同步到输入区；
  /// 点提示词时再随 [QuickPromptSelection] 一并返回，两条路径都能带上技能。
  Widget _buildSkillSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final selectedCount = _selectedSkillNames.length;
    final userSkills = _skills.where((skill) => skill['origin'] == AgentSkillOrigin.user).toList();
    final builtinSkills = _skills.where((skill) => skill['origin'] != AgentSkillOrigin.user).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 13, color: theme.accentInk),
              const SizedBox(width: 4),
              Text(
                '附加技能',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  selectedCount == 0 ? '可选，随提示词一起用于本轮' : '已选 $selectedCount/$_maxSelectedSkills，随下一条消息发送',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (selectedCount > 0)
                InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(_selectedSkillNames.clear);
                    _notifySkillsChanged();
                  },
                  borderRadius: BorderRadius.circular(999),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '清除',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.accentInk, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (userSkills.isNotEmpty)
            _buildSkillGroup(
              theme: theme,
              title: '自定义技能',
              icon: Icons.extension_rounded,
              skills: userSkills,
              expanded: _userSkillsExpanded,
              onToggle: () => _toggleSkillGroup(userGroup: true),
            ),
          if (userSkills.isNotEmpty && builtinSkills.isNotEmpty) const SizedBox(height: 6),
          if (builtinSkills.isNotEmpty)
            _buildSkillGroup(
              theme: theme,
              title: '内置技能',
              icon: Icons.auto_awesome_outlined,
              skills: builtinSkills,
              expanded: _builtinSkillsExpanded,
              onToggle: () => _toggleSkillGroup(userGroup: false),
            ),
        ],
      ),
    );
  }

  /// 单个技能分组：可点击的组头（名称 / 总数 / 已选数 / 箭头）+ 可折叠的胶囊列表
  Widget _buildSkillGroup({
    required ThemeData theme,
    required String title,
    required IconData icon,
    required List<Map<String, String>> skills,
    required bool expanded,
    required VoidCallback onToggle,
  }) {
    final scheme = theme.colorScheme;
    final selectedInGroup = skills.where((skill) => _selectedSkillNames.contains(skill['name'])).length;
    // 展开体高度跟随屏幕：小屏/横屏只露两三行，避免把下方提示词列表挤到看不见
    final bodyMaxHeight = (MediaQuery.sizeOf(context).height * 0.16).clamp(48.0, 120.0);

    return Material(
      // 分组只用浅色底区分层级：展开时略深，收起时更淡。
      // 胶囊自身用 surface 底，避免和分组卡片同色糊成一片
      color: expanded
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(AppRadius.small + 2),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: expanded ? theme.accentInk : scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: expanded ? scheme.onSurface : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _SkillCountPill(text: '${skills.length}'),
                  if (selectedInGroup > 0) ...[
                    const SizedBox(width: 6),
                    _SkillCountPill(text: '已选 $selectedInGroup', accent: true),
                  ],
                  const Spacer(),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.duration(context, AppDurations.normal),
            curve: AppCurves.emphasizedSpatial,
            alignment: Alignment.topCenter,
            child: expanded
                ? ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: bodyMaxHeight),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final skill in skills)
                            _SkillChoiceChip(
                              name: skill['name'] ?? '',
                              description: skill['description'] ?? '',
                              isUserSkill: skill['origin'] == AgentSkillOrigin.user,
                              selected: _selectedSkillNames.contains(skill['name']),
                              onTap: () => _toggleSkill(skill['name'] ?? ''),
                            ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// 列表区 / 空态 / 加载 / 错误
  Widget _buildBody(ThemeData theme, AsyncValue<List<String>> promptsAsync) {
    final scheme = theme.colorScheme;

    return promptsAsync.when(
      loading: () => const SizedBox(
        height: 96,
        child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4))),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
        child: Column(
          children: [
            Icon(Icons.error_outline_rounded, size: 26, color: scheme.error),
            const SizedBox(height: 6),
            Text(
              '加载失败：$e',
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            TextButton(onPressed: () => ref.invalidate(quickPromptListProvider), child: const Text('重试')),
          ],
        ),
      ),
      data: (prompts) {
        // 空列表但正在新增时仍要渲染列表，否则编辑器没有落脚处
        if (prompts.isEmpty && !_isAdding) {
          return _buildEmpty(theme);
        }
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
          child: ListView.separated(
            controller: _scrollController,
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            itemCount: prompts.length + (_isAdding ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              if (_isAdding && index == prompts.length) {
                return _buildEditorCard(theme, index: prompts.length, isNew: true);
              }
              if (!_isAdding && _editingIndex == index) {
                return _buildEditorCard(theme, index: index, isNew: false);
              }
              final row = _buildPromptRow(theme, index, prompts[index]);
              if (!_editing) {
                return row;
              }
              // 编辑期间其他条目降权：避免误触「选中并关闭」，丢掉未保存内容
              return Opacity(opacity: 0.55, child: IgnorePointer(child: row));
            },
          ),
        );
      },
    );
  }

  /// 空态
  Widget _buildEmpty(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.05), shape: BoxShape.circle),
            child: Icon(Icons.bolt_rounded, size: 24, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 10),
          Text('还没有常用提示词', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '点右上角 + 新建一条，下次一点就能填入',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 单条提示词：整卡点击选中 → 填充输入框；右侧圆形编辑/删除
  Widget _buildPromptRow(ThemeData theme, int index, String text) {
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.medium + 2),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          widget.onSelected(QuickPromptSelection(text: text, skillNames: List.unmodifiable(_selectedSkillNames)));
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            children: [
              // 序号圆标：弱化装饰，但让多条目列表有清晰的扫描锚点
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.10), shape: BoxShape.circle),
                child: Text(
                  '${index + 1}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.accentInk,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.35)),
                ),
              ),
              const SizedBox(width: 6),
              _CircleAction(
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                size: 32,
                iconSize: 17,
                background: scheme.surface,
                foreground: scheme.onSurfaceVariant,
                onPressed: () => _startEdit(index, text),
              ),
              const SizedBox(width: 6),
              _CircleAction(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                size: 32,
                iconSize: 17,
                background: scheme.error.withValues(alpha: 0.10),
                foreground: scheme.error,
                onPressed: () => _confirmDelete(context, ref, index, text),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 原地编辑卡：替换当前行，或在列表末尾新增一条
  Widget _buildEditorCard(ThemeData theme, {required int index, required bool isNew}) {
    final scheme = theme.colorScheme;
    final inputRadius = BorderRadius.circular(AppRadius.small + 2);

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.medium + 2),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          children: [
            // 新条目用「+」圆标，编辑现有条目沿用序号
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.10), shape: BoxShape.circle),
              child: isNew
                  ? Icon(Icons.add_rounded, size: 15, color: theme.accentInk)
                  : Text(
                      '${index + 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.accentInk,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                // key 保证在「编辑第 N 条」与「新增」之间切换时重建并重新聚焦
                key: ValueKey<String>(isNew ? 'quick-prompt-editor-new' : 'quick-prompt-editor-$index'),
                controller: _editController,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                cursorColor: theme.accentInk,
                decoration: InputDecoration(
                  hintText: '输入提示词内容',
                  hintStyle: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderRadius: inputRadius, borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: inputRadius,
                    borderSide: BorderSide(color: theme.accentInk, width: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _CircleAction(
              icon: Icons.check_rounded,
              tooltip: '保存',
              size: 32,
              iconSize: 18,
              background: scheme.primary,
              foreground: scheme.onPrimary,
              onPressed: _saveInlineEdit,
            ),
            const SizedBox(width: 6),
            _CircleAction(
              icon: Icons.close_rounded,
              tooltip: '取消',
              size: 32,
              iconSize: 17,
              background: scheme.surface,
              foreground: scheme.onSurfaceVariant,
              onPressed: _cancelInlineEdit,
            ),
          ],
        ),
      ),
    );
  }

  /// 进入某条的原地编辑态
  void _startEdit(int index, String text) {
    if (_editing) return;
    _editController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _editingIndex = index;
      _isAdding = false;
    });
  }

  /// 在列表末尾展开一条空编辑卡，并滚到底部
  void _startAdd() {
    if (_editing) return;
    _editController.clear();
    setState(() {
      _isAdding = true;
      _editingIndex = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// 取消原地编辑，不改动已保存内容
  void _cancelInlineEdit() {
    FocusScope.of(context).unfocus();
    _editController.clear();
    setState(() {
      _isAdding = false;
      _editingIndex = null;
    });
  }

  /// 保存原地编辑：新增追加到列表末尾，编辑按原下标替换
  Future<void> _saveInlineEdit() async {
    if (_saving) return;
    final text = _editController.text.trim();
    if (text.isEmpty) {
      Toast.warning(context, '提示词不能为空');
      return;
    }

    final isAdding = _isAdding;
    final editingIndex = _editingIndex;
    _saving = true;
    try {
      final notifier = ref.read(quickPromptListProvider.notifier);
      if (isAdding) {
        await notifier.addPrompt(text);
      } else if (editingIndex != null) {
        await notifier.updatePrompt(editingIndex, text);
      }
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      _editController.clear();
      setState(() {
        _isAdding = false;
        _editingIndex = null;
      });
      Toast.success(context, isAdding ? '已添加' : '已更新');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    } finally {
      _saving = false;
    }
  }

  /// 删除提示词（二次确认）
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, int index, String text) async {
    final confirmed = await AppMotion.showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除提示词'),
        content: Text('删除「$text」？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(quickPromptListProvider.notifier).deletePrompt(index);
      if (!context.mounted) return;
      Toast.success(context, '已删除');
    } catch (e) {
      if (!context.mounted) return;
      Toast.error(context, '删除失败：$e');
    }
  }
}

/// 技能分组的小号计数徽标（总数 / 组内已选数）
class _SkillCountPill extends StatelessWidget {
  const _SkillCountPill({required this.text, this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent ? scheme.primary.withValues(alpha: 0.14) : scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: AppTypography.caption,
          color: accent ? theme.accentInk : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }
}

/// 技能选择胶囊：未选为中性底，选中后切换为主题色淡底 + 对勾
///
/// 长按显示技能名与描述：分组区宽度有限，名称之外的信息放到 tooltip 里，
/// 不额外占一行高度。
class _SkillChoiceChip extends StatelessWidget {
  const _SkillChoiceChip({
    required this.name,
    required this.description,
    required this.isUserSkill,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String description;
  final bool isUserSkill;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(999);

    return Tooltip(
      message: description.isEmpty ? name : '$name\n${isUserSkill ? '自定义技能' : '内置技能'}：$description',
      triggerMode: TooltipTriggerMode.longPress,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.12) : scheme.surface,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: selected
                    ? theme.accentInk.withValues(alpha: 0.45)
                    : scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_rounded : Icons.auto_awesome_outlined,
                  size: 13,
                  color: selected ? theme.accentInk : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: selected ? theme.accentInk : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆形底色小按钮：编辑 / 删除 / 关闭共用，保证三处触控面积与形状一致
class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onPressed,
    this.size = 36,
    this.iconSize = 19,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: iconSize),
      style: IconButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
        minimumSize: Size.square(size),
        maximumSize: Size.square(size),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

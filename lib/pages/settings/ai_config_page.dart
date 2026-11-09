import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/agent/services/agent_tool_config.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/core/ai/vision_capability_probe.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/pages/settings/ai_provider_edit_page.dart';
import 'package:qnote_flutter/pages/settings/ai_route_group_edit_page.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/ai/token_usage_card.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';

/// AI 模型配置页：服务商列表 + 三个角色的模型分配 + 工具开关
///
/// 数据模型是「厂商条目」：一个条目 = 一个 URL + 一组 API Key + 一组已启用模型。
/// 因此这一页只做两件事：
/// 1. 管理条目（增删改、设为默认、进详情页管密钥与模型）；
/// 2. 把已启用模型分配给角色（小Q 对话 / 时间线提取 / 生图）。
///
/// 温度 / 最大 tokens / 提取图片等运行参数不在此页暴露：调参对普通用户学习成本
/// 过高，统一走 [AiRoleSettings] 的内置默认值（老用户存量配置仍生效）。
class AiConfigPage extends ConsumerStatefulWidget {
  final bool autoOpenAdd;

  const AiConfigPage({super.key, this.autoOpenAdd = false});

  @override
  ConsumerState<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends ConsumerState<AiConfigPage> {
  AiRoles _roles = const AiRoles();
  Set<String> _disabledTools = {};
  bool _toolsLoaded = false;
  bool _testingImageRecognition = false;

  /// 各角色的「识图检测」结论（roleKey → 文案）
  final Map<String, String> _imageTestByRole = {};

  bool _autoAddHandled = false;

  @override
  void initState() {
    super.initState();
    _loadRoles();
    _loadDisabledTools();
    _restoreImageTestResults();
    // 统计卡的数据由发信热路径后台累加，进入页面时重新聚合一次才看得到最新值
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(aiTokenUsageSummaryProvider);
    });
    if (widget.autoOpenAdd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _autoAddHandled) return;
        _autoAddHandled = true;
        _addProvider();
      });
    }
  }

  Future<void> _loadRoles() async {
    final roles = await AiRoleService.instance.getRoles();
    if (!mounted) return;
    setState(() {
      _roles = roles;
    });
    _restoreImageTestResults();
  }

  Future<void> _restoreImageTestResults() async {
    _imageTestByRole.clear();
    for (final roleKey in const ['assistant', 'timelineOptimization']) {
      final ref0 = roleKey == 'assistant' ? _roles.assistant : _roles.timelineOptimization;
      if (ref0 == null) continue;
      // 路由组没有单一模型名可查：识图结论按成员模型名持久化，组本身不落结论
      if (ref0.isRouteGroup) continue;
      final known = ModelVisionCapability.probeConclusion(ref0.modelName);
      if (known != null) {
        _imageTestByRole[roleKey] = known ? '支持识别' : '不支持图片识别';
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadDisabledTools() async {
    final disabled = await AgentToolConfig.instance.getDisabledTools();
    if (!mounted) return;
    setState(() {
      _disabledTools = disabled;
      _toolsLoaded = true;
    });
  }

  Future<void> _toggleTool(String name, bool enabled) async {
    setState(() {
      if (enabled) {
        _disabledTools.remove(name);
      } else {
        _disabledTools.add(name);
      }
    });
    try {
      await AgentToolConfig.instance.setToolDisabled(name, !enabled);
    } catch (e) {
      if (!mounted) return;
      // 保存失败时回滚开关状态，保证界面与持久化一致
      setState(() {
        if (enabled) {
          _disabledTools.add(name);
        } else {
          _disabledTools.remove(name);
        }
      });
      Toast.error(context, '保存失败：$e');
    }
  }

  // ── 服务商管理 ───────────────────────────────────────────

  Future<void> _addProvider() async {
    final vendorId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _VendorPickerSheet(),
    );
    if (vendorId == null || !mounted) return;
    await context.push(
      '/settings/ai-config/provider',
      extra: AiProviderEditArgs(initialVendorId: vendorId),
    );
    if (mounted) {
      await _loadRoles();
    }
  }

  Future<void> _editProvider(AiProvider provider) async {
    await context.push(
      '/settings/ai-config/provider',
      extra: AiProviderEditArgs(provider: provider),
    );
    if (mounted) await _loadRoles();
  }

  Future<void> _deleteProvider(AiProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型服务'),
        content: Text(
          provider.usesAccountAuth
              ? '将删除「${provider.name}」及其本地登录态、'
                  '${provider.models.length} 个已启用模型，引用它的角色绑定会被清空。'
              : '将删除「${provider.name}」及其 ${provider.apiKeys.length} 把密钥、'
                  '${provider.models.length} 个已启用模型，引用它的角色绑定会被清空。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      // deleteProvider 内部会一并清掉该厂商下的全部账号登录态（可能是多个账号）
      await ref.read(aiProviderListProvider.notifier).deleteProvider(provider.id);
      await AiRoleService.instance.pruneStaleRoleBindings();
      ref.invalidate(aiRolesProvider);
      await _loadRoles();
      if (mounted) Toast.success(context, '已删除');
    } catch (e) {
      if (mounted) Toast.error(context, '删除失败：$e');
    }
  }

  Future<void> _setDefaultProvider(AiProvider provider) async {
    await ref.read(aiProviderListProvider.notifier).setDefault(provider.id);
    if (mounted) Toast.success(context, '已将「${provider.name}」设为默认');
  }

  // ── 角色模型分配 ─────────────────────────────────────────

  Future<void> _pickRoleModel(String roleKey) async {
    final providers = await ref.read(aiProviderListProvider.future);
    final groups = await ref.read(aiRouteGroupListProvider.future);
    if (!mounted) return;
    if (enabledModelEntries(providers).isEmpty && groups.isEmpty) {
      await showNoModelConfiguredDialog(context, scene: _roleLabel(roleKey));
      return;
    }
    final current = switch (roleKey) {
      'assistant' => _roles.assistant,
      'timelineOptimization' => _roles.timelineOptimization,
      _ => _roles.imageGeneration,
    };
    final effective = isBindingUsable(current, providers, groups)
        ? current
        : (roleKey == 'imageGeneration' ? null : defaultModelRef(providers));
    final result = await showModelPickerSheet(
      context,
      providers: providers,
      groups: groups,
      selected: effective,
      title: '选择${_roleLabel(roleKey)}',
    );
    if (result == null || result.ref == current || !mounted) return;

    await AiRoleService.instance.bindRole(roleKey, result.ref);
    ref.invalidate(aiRolesProvider);
    await _loadRoles();
  }

  String _roleLabel(String roleKey) => switch (roleKey) {
        'assistant' => '小Q 对话模型',
        'timelineOptimization' => '时间线提取模型',
        _ => '生图模型',
      };

  /// 角色当前生效的展示名：绑定（模型或路由组）→ 默认/首个可用厂商的首个模型 → 未配置
  String _roleDisplayName(
    String roleKey,
    List<AiProvider> providers,
    List<AiRouteGroup> groups,
  ) {
    final bound = switch (roleKey) {
      'assistant' => _roles.assistant,
      'timelineOptimization' => _roles.timelineOptimization,
      _ => _roles.imageGeneration,
    };
    if (isBindingUsable(bound, providers, groups)) {
      return aiBindingDisplayName(bound, providers, groups);
    }
    // 生图刻意不回落对话模型：对话模型通常不支持 images/generations
    if (roleKey == 'imageGeneration') return '未配置（生图暂不可用）';
    final provider = providers.where((p) => p.isDefault && p.isUsable).firstOrNull ??
        providers.where((p) => p.isUsable).firstOrNull;
    final model = provider?.firstModel;
    return model == null ? '未配置' : '跟随默认 · ${model.name}';
  }

  Future<void> _testModelImageRecognition(String roleKey) async {
    // 按该角色**实际生效**的配置来测：检测结论按模型名持久化，
    // 测错对象会被一直显示在徽标上。
    final AiConfig effective;
    try {
      effective = await AiRoleService.instance.getEffectiveConfigForRole(roleKey);
    } on NoModelConfiguredException {
      if (mounted) await showNoModelConfiguredDialog(context, scene: _roleLabel(roleKey));
      return;
    } catch (e) {
      if (mounted) Toast.warning(context, '读取当前绑定模型失败：$e');
      return;
    }

    if (mounted) {
      setState(() {
        _testingImageRecognition = true;
        _imageTestByRole.remove(roleKey);
      });
    }

    try {
      final imgBase64 = await VisionCapabilityProbe.generateProbeImageBase64();
      final service = AiService();
      final success = await service.checkImageRecognition(effective, imgBase64);
      // 结论按模型名落盘：下次进页面直接回显，不必重发这张探测图
      await ModelVisionCapability.recordProbeResult(effective.modelName, success);
      if (mounted) {
        setState(() {
          _imageTestByRole[roleKey] = success ? '支持识别' : '不支持图片识别';
        });
      }
    } catch (e) {
      // 失败**不写缓存**：网络断、额度耗尽、端点故障都不说明该模型没有视觉能力
      if (mounted) setState(() => _imageTestByRole[roleKey] = '测试失败: $e');
    } finally {
      if (mounted) setState(() => _testingImageRecognition = false);
    }
  }

  // ── 构建 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final providersAsync = ref.watch(aiProviderListProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('AI 模型配置')),
      floatingActionButton: providersAsync.valueOrNull?.isNotEmpty == true
          ? FloatingActionButton.extended(
              onPressed: _addProvider,
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加模型服务'),
            )
          : null,
      body: providersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(aiProviderListProvider),
        ),
        data: (providers) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            const TokenUsageCard(),
            _buildProvidersSection(theme, providers),
            const SizedBox(height: 4),
            _buildRouteGroupsSection(theme, providers),
            const SizedBox(height: 4),
            _buildRoleSection(
              theme,
              providers,
              ref.watch(aiRouteGroupListProvider).valueOrNull ??
                  const <AiRouteGroup>[],
            ),
            const SizedBox(height: 4),
            _buildToolSwitchCard(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildProvidersSection(ThemeData theme, List<AiProvider> providers) {
    if (providers.isEmpty) {
      return const NoModelGuideCard(
        scene: '',
        padding: EdgeInsets.symmetric(vertical: 16),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '模型服务', '点击卡片管理密钥与已启用模型'),
        ...providers.map((provider) => _providerCard(theme, provider)),
      ],
    );
  }

  Widget _providerCard(ThemeData theme, AiProvider provider) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _editProvider(provider),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.hub_rounded,
                    color: colorScheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              provider.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (provider.isDefault) ...[
                            const SizedBox(width: 6),
                            _badge(theme, '默认', colorScheme.primary),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        provider.baseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        provider.usesAccountAuth
                            ? '账号登录 · ${AccountRouting.fromId(provider.accountRouting).label} · '
                                  '${provider.models.length} 个模型已启用'
                            : '${provider.apiKeys.length} 把密钥 · ${provider.models.length} 个模型已启用',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    switch (value) {
                      case 'default':
                        _setDefaultProvider(provider);
                      case 'delete':
                        _deleteProvider(provider);
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (!provider.isDefault)
                      const PopupMenuItem(
                        value: 'default',
                        child: Text('设为默认'),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        '删除',
                        style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 模型路由组 ───────────────────────────────────────────

  Widget _buildRouteGroupsSection(ThemeData theme, List<AiProvider> providers) {
    final groupsAsync = ref.watch(aiRouteGroupListProvider);
    final groups = groupsAsync.valueOrNull ?? const <AiRouteGroup>[];
    final canCreate = enabledModelEntries(providers).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          theme,
          '模型路由组',
          '把多个模型组成一个「虚拟模型」，按策略轮流调用以分散限流',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton.icon(
              onPressed: canCreate ? () => _editRouteGroup(null) : null,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新建路由组'),
            ),
          ),
        ),
        if (groups.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              canCreate
                  ? '还没有路由组。勾选多个已启用模型即可建立一个组，'
                      '之后在「模型分配」里把角色指向这个组。'
                  : '先添加模型服务并启用至少一个模型，才能建立路由组。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ...groups.map((group) => _routeGroupCard(theme, providers, group)),
      ],
    );
  }

  Future<void> _editRouteGroup(AiRouteGroup? group) async {
    await context.push(
      '/settings/ai-config/route-group',
      extra: AiRouteGroupEditArgs(group: group),
    );
    if (mounted) await _loadRoles();
  }

  Widget _routeGroupCard(
    ThemeData theme,
    List<AiProvider> providers,
    AiRouteGroup group,
  ) {
    final colorScheme = theme.colorScheme;
    final liveMembers = group.enabledMembers
        .map((m) => aiModelDisplayName(m.ref, providers, fallback: m.modelName))
        .toList();
    final preview = liveMembers.take(3).toList();
    final remaining = liveMembers.length - preview.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _editRouteGroup(group),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.alt_route_rounded,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    _badge(theme, group.strategy.label, colorScheme.primary),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  routeGroupSummary(group, providers),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (liveMembers.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '成员模型均已停用，绑定它的角色会回落到默认模型',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ...preview.map(
                        (name) => _badge(
                          theme,
                          name,
                          colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (remaining > 0)
                        _badge(theme, '+$remaining', colorScheme.outline),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(ThemeData theme, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildRoleSection(
    ThemeData theme,
    List<AiProvider> providers,
    List<AiRouteGroup> groups,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '模型分配', '同一个模型/路由组可分配给多个角色'),
        Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            children: [
              _roleTile(theme, 'assistant', providers, groups),
              _divider(theme),
              _roleTile(theme, 'timelineOptimization', providers, groups),
              _divider(theme),
              _roleTile(theme, 'imageGeneration', providers, groups),
            ],
          ),
        ),
      ],
    );
  }

  Widget _divider(ThemeData theme) {
    return Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
  }

  Widget _roleTile(
    ThemeData theme,
    String roleKey,
    List<AiProvider> providers,
    List<AiRouteGroup> groups,
  ) {
    final colorScheme = theme.colorScheme;
    final display = _roleDisplayName(roleKey, providers, groups);
    final configured = !display.startsWith('未配置');
    final isAssistant = roleKey == 'assistant';
    final rawTest = _imageTestByRole[roleKey];
    final imageTestOk = rawTest == '支持识别';

    return InkWell(
      onTap: () => _pickRoleModel(roleKey),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(
              isAssistant
                  ? Icons.chat_bubble_outline_rounded
                  : roleKey == 'timelineOptimization'
                      ? Icons.auto_awesome_motion_rounded
                      : Icons.image_outlined,
              size: 20,
              color: isAssistant ? colorScheme.primary : Colors.purple.shade400,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _roleLabel(roleKey),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: configured
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            if (configured && roleKey != 'imageGeneration') ...[
              if (rawTest != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _badge(
                    theme,
                    imageTestOk ? '支持识图' : '不支持识图',
                    imageTestOk ? Colors.green.shade700 : colorScheme.error,
                  ),
                ),
              IconButton(
                tooltip: '识图检测',
                visualDensity: VisualDensity.compact,
                icon: _testingImageRecognition
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_camera_front_outlined, size: 18),
                onPressed: _testingImageRecognition
                    ? null
                    : () => _testModelImageRecognition(roleKey),
              ),
            ],
            Icon(Icons.chevron_right_rounded, color: colorScheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _buildToolSwitchCard(ThemeData theme) {
    const toolMeta = {
      'fetch_url': '网页阅读',
      'web_search': '网页搜索',
      'generate_image': '图片生成',
      'describe_image': '图片识别',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '小Q工具能力', '按需关闭以节省额度'),
        Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            children: [
              if (!_toolsLoaded)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                for (final entry in toolMeta.entries) ...[
                  SwitchListTile(
                    value: !_disabledTools.contains(entry.key),
                    title: Text(entry.value),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    onChanged: (enabled) => _toggleTool(entry.key, enabled),
                  ),
                  if (entry.key != toolMeta.keys.last) _divider(theme),
                ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 厂商模板选择器（添加服务商第一步）
///
/// 按凭证类型分区：账号登录型（小浣熊这类订阅账号）在上，API Key 型在下。
/// 两类厂商的「添加流程」完全不同（一个要登录、一个要粘密钥），混在一张平铺
/// 列表里会让人以为登录型也要填 Key。
class _VendorPickerSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 延迟到运行时读取，避免在 const 语境里依赖 config 列表
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
                  child: Text(
                    '选择厂商',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (accountVendors.isNotEmpty) ...[
                  _vendorSectionHeader(
                    theme,
                    title: '账号登录',
                    subtitle: '登录厂商账号即可使用，凭证自动续期',
                  ),
                  ...accountVendors.map(
                    (spec) => _vendorTile(context, theme, spec),
                  ),
                ],
                if (apiKeyVendors.isNotEmpty) ...[
                  _vendorSectionHeader(
                    theme,
                    title: 'API Key',
                    subtitle: '填写服务地址与密钥，多把密钥自动轮询',
                  ),
                  ...apiKeyVendors.map(
                    (spec) => _vendorTile(context, theme, spec),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _vendorSectionHeader(
    ThemeData theme, {
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _vendorTile(
    BuildContext context,
    ThemeData theme,
    AiProviderConfig spec,
  ) {
    return ListTile(
      title: Text(spec.name),
      subtitle: Text(
        spec.defaultBaseUrl.isEmpty ? '需要自己填写地址' : spec.defaultBaseUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => Navigator.of(context).pop(spec.id),
    );
  }
}

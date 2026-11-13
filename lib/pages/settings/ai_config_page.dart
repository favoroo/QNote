import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/config/ai_vendors.dart';
import 'package:qnote_flutter/core/agent/services/agent_tool_config.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/builtin_provider.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/core/ai/vision_capability_probe.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/pages/settings/ai_provider_edit_page.dart';
import 'package:qnote_flutter/pages/settings/ai_route_group_edit_page.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/builtin_service_card.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/ai/token_usage_card.dart';
import 'package:qnote_flutter/widgets/ai/vendor_logo.dart';
import 'package:qnote_flutter/widgets/ai/vendor_picker_sheet.dart';
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
///
/// 现在这一页作为「小Q设置 → 模型」分段嵌入综合页；添加入口是「模型服务」
/// 标题右侧的圆形「+」，[embedded] 为 true 时不再重复生成 AppBar。
class AiConfigPage extends ConsumerStatefulWidget {
  final bool autoOpenAdd;

  /// 嵌入模式：由「小Q设置」承载时为 true
  final bool embedded;

  const AiConfigPage({super.key, this.autoOpenAdd = false, this.embedded = false});

  @override
  ConsumerState<AiConfigPage> createState() => AiConfigPageState();
}

class AiConfigPageState extends ConsumerState<AiConfigPage> {
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
    final vendorId = await VendorPickerSheet.show(context);
    if (vendorId == null || !mounted) return;
    await context.push('/settings/ai-config/provider', extra: AiProviderEditArgs(initialVendorId: vendorId));
    if (mounted) {
      await _loadRoles();
    }
  }

  Future<void> _editProvider(AiProvider provider) async {
    await context.push('/settings/ai-config/provider', extra: AiProviderEditArgs(provider: provider));
    if (mounted) await _loadRoles();
  }

  Future<void> _deleteProvider(AiProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型服务'),
        content: Text(
          provider.usesAccountAuth
              ? '将删除「${provider.name}」及登录态和 ${provider.models.length} 个模型，角色绑定会清空。'
              : '将删除「${provider.name}」及 ${provider.apiKeys.length} 把密钥和 '
                    '${provider.models.length} 个模型，角色绑定会清空。',
        ),
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

  /// 停用/启用整个厂商条目（可逆，不动密钥、模型与角色绑定）
  Future<void> _setProviderEnabled(AiProvider provider, bool enabled) async {
    try {
      await ref.read(aiProviderListProvider.notifier).setProviderEnabled(provider.id, enabled);
      // 该厂商不再参与选路，角色行的生效模型会跟着回落，重新算一次展示名
      await _loadRoles();
      if (mounted) {
        Toast.success(context, enabled ? '已启用「${provider.name}」' : '已停用「${provider.name}」');
      }
    } catch (e) {
      if (mounted) Toast.error(context, '${enabled ? '启用' : '停用'}失败：$e');
    }
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
      imageGeneration: roleKey == 'imageGeneration',
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

  /// 绑定仍指向存在的模型/组，但所属厂商被手动停用时的提示文案
  ///
  /// 与「未配置」区分开：绑定没丢，重新启用厂商即恢复，不提示会让用户以为
  /// 自己配的模型凭空消失了。
  String? _disabledBindingHint(AiModelRef? ref, List<AiProvider> providers, List<AiRouteGroup> groups) {
    if (ref == null) return null;
    // 真失效（厂商/模型已删）由陈旧绑定清理负责，这里不管
    if (!isBindingResolvable(ref, providers, groups)) return null;
    if (isBindingUsable(ref, providers, groups)) return null;
    final name = ref.isRouteGroup
        ? groups.where((g) => g.id == ref.providerId).firstOrNull?.name
        : providers.where((p) => p.id == ref.providerId).firstOrNull?.name;
    return name == null ? null : '「$name」已停用';
  }

  /// 角色当前生效的展示名：绑定（模型或路由组）→ 默认/首个可用厂商的首个模型 → 未配置
  String _roleDisplayName(String roleKey, List<AiProvider> providers, List<AiRouteGroup> groups) {
    final bound = switch (roleKey) {
      'assistant' => _roles.assistant,
      'timelineOptimization' => _roles.timelineOptimization,
      _ => _roles.imageGeneration,
    };
    if (isBindingUsable(bound, providers, groups)) {
      return aiBindingDisplayName(bound, providers, groups);
    }
    final hint = _disabledBindingHint(bound, providers, groups);
    // 生图刻意不回落对话模型：对话模型通常不支持 images/generations
    if (roleKey == 'imageGeneration') {
      return hint == null ? '未配置（生图不可用）' : '$hint，生图不可用';
    }
    final provider =
        providers.where((p) => p.isDefault && p.isUsable).firstOrNull ?? providers.where((p) => p.isUsable).firstOrNull;
    final model = provider?.firstModel;
    if (model == null) return hint ?? '未配置';
    return hint == null ? '跟随默认 · ${model.name}' : '$hint，暂用 ${model.name}';
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
      if (mounted) Toast.warning(context, '读取模型失败：$e');
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
      if (mounted) setState(() => _imageTestByRole[roleKey] = '测试失败：$e');
    } finally {
      if (mounted) setState(() => _testingImageRecognition = false);
    }
  }

  // ── 构建 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final providersAsync = ref.watch(aiProviderListProvider);
    final theme = Theme.of(context);

    final body = providersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => AppErrorState(error: e, onRetry: () => ref.invalidate(aiProviderListProvider)),
      data: (providers) => ListView(
        // 添加入口已内联在「模型服务」标题右侧，不再有浮动按钮遮挡，
        // 底部只留常规留白
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const TokenUsageCard(),
          _buildProvidersSection(theme, providers),
          const SizedBox(height: 4),
          _buildRouteGroupsSection(theme, providers),
          const SizedBox(height: 4),
          _buildRoleSection(
            theme,
            providers,
            ref.watch(aiRouteGroupListProvider).valueOrNull ?? const <AiRouteGroup>[],
          ),
          const SizedBox(height: 4),
          _buildToolSwitchCard(theme, providers),
        ],
      ),
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('AI 模型配置')),
      body: body,
    );
  }

  Widget _buildProvidersSection(ThemeData theme, List<AiProvider> providers) {
    // 内置免费模型是虚拟条目：始终显示在列表首位，且不参与用户厂商的增删改
    final userProviders = providers.where((p) => !BuiltinProvider.isBuiltin(p)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 添加入口贴在区块标题右侧：顶栏那个「+」离列表内容太远，看不出加的是什么；
        // 放到「模型服务」标题旁，语义与位置才对得上
        _sectionTitle(theme, '模型服务', null, trailing: _addProviderButton(theme)),
        const BuiltinServiceCard(),
        ...userProviders.map((provider) => _providerCard(theme, provider)),
      ],
    );
  }

  /// 「模型服务」标题右侧的圆形添加入口
  Widget _addProviderButton(ThemeData theme) {
    final scheme = theme.colorScheme;
    return IconButton(
      onPressed: _addProvider,
      tooltip: '添加模型服务',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.add_rounded, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(38, 38),
        shape: const CircleBorder(),
      ),
    );
  }

  Widget _providerCard(ThemeData theme, AiProvider provider) {
    // 内置条目用独立的只读卡片渲染，绝不走可编辑的用户厂商卡片
    if (BuiltinProvider.isBuiltin(provider)) return const SizedBox.shrink();
    final colorScheme = theme.colorScheme;
    final disabled = !provider.enabled;
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
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                VendorLogo(vendorId: provider.vendorId, fallbackLabel: provider.name, disabled: disabled),
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
                                color: disabled ? colorScheme.onSurfaceVariant : null,
                              ),
                            ),
                          ),
                          if (disabled) ...[const SizedBox(width: 6), _badge(theme, '已停用', colorScheme.outline)],
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
                        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        provider.usesAccountAuth
                            ? '账号登录 · ${AccountRouting.fromId(provider.accountRouting).label} · '
                                  '${provider.models.length} 个模型'
                            // 免密钥服务（免费网关）没有密钥是正常状态，
                            // 显示「0 把密钥」会让人以为配错了
                            : provider.apiKeys.isEmpty && vendorAllowsKeyless(provider.vendorId)
                            ? '免密钥 · ${provider.models.length} 个模型'
                            : '${provider.apiKeys.length} 把密钥 · ${provider.models.length} 个模型',
                        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
                      case 'toggle':
                        _setProviderEnabled(provider, disabled);
                      case 'delete':
                        _deleteProvider(provider);
                    }
                  },
                  itemBuilder: (ctx) => [
                    // 停用的厂商不参与选路，设为默认没有意义
                    if (provider.enabled && !provider.isDefault)
                      const PopupMenuItem(value: 'default', child: Text('设为默认')),
                    PopupMenuItem(value: 'toggle', child: Text(disabled ? '启用' : '停用')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('删除', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
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
        _sectionTitle(theme, '模型路由组', '多个模型轮流调用，分散限流'),
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
              border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Text(
              canCreate ? '还没有路由组，勾选多个模型建立，再到「模型分配」绑定角色。' : '先添加并启用至少一个模型，才能建立路由组。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          ...groups.map((group) => _routeGroupCard(theme, providers, group)),
      ],
    );
  }

  Future<void> _editRouteGroup(AiRouteGroup? group) async {
    await context.push('/settings/ai-config/route-group', extra: AiRouteGroupEditArgs(group: group));
    if (mounted) await _loadRoles();
  }

  Widget _routeGroupCard(ThemeData theme, List<AiProvider> providers, AiRouteGroup group) {
    final colorScheme = theme.colorScheme;
    final liveMembers = group.enabledMembers
        .map((m) => aiModelDisplayName(m.ref, providers, fallback: m.modelName))
        .toList();
    // 成员是否还能解析出来要另算：厂商被停用/模型被停用的成员名字照旧显示，
    // 但它们已经不参与选路，组其实处于「绑了也用不上」的状态
    final liveCount = routeGroupLiveMemberCount(group, providers);
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
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.alt_route_rounded, size: 20, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    _badge(theme, group.strategy.label, colorScheme.primary),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  routeGroupSummary(group, providers),
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                if (liveCount == 0) ...[
                  const SizedBox(height: 4),
                  Text('成员均已停用，绑定角色会回落默认模型', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error)),
                ] else ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ...preview.map((name) => _badge(theme, name, colorScheme.onSurfaceVariant)),
                      if (remaining > 0) _badge(theme, '+$remaining', colorScheme.outline),
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildRoleSection(ThemeData theme, List<AiProvider> providers, List<AiRouteGroup> groups) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '模型分配', '同一模型或路由组可分给多个角色'),
        // 底色放在 Material 上：角色行是 InkWell，若中间夹一层带底色的 Container，
        // 水波纹会被盖住；只用 Container 画描边
        Material(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
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

  Widget _roleTile(ThemeData theme, String roleKey, List<AiProvider> providers, List<AiRouteGroup> groups) {
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
                  Text(_roleLabel(roleKey), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 1),
                  Text(
                    display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: configured ? colorScheme.onSurfaceVariant : colorScheme.error,
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
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.photo_camera_front_outlined, size: 18),
                onPressed: _testingImageRecognition ? null : () => _testModelImageRecognition(roleKey),
              ),
            ],
            Icon(Icons.chevron_right_rounded, color: colorScheme.outline),
          ],
        ),
      ),
    );
  }

  /// 小Q 助手当前绑定的模型是否走 Anthropic Messages 协议
  ///
  /// Messages 协议本次不支持工具调用：请求里根本不带 `tools`，开关开着也不生效。
  /// 这里判定出来是为了「提示 + 置灰」，而不是让用户对着四个没反应的开关猜。
  /// 路由组可能混装多种协议，只有直接绑定到 anthropic 厂商时才判定。
  bool _assistantUsesAnthropic(List<AiProvider> providers) {
    final ref = _roles.assistant;
    if (ref == null || ref.isRouteGroup) return false;
    return providers.where((p) => p.id == ref.providerId).firstOrNull?.providerType == 'anthropic';
  }

  Widget _buildToolSwitchCard(ThemeData theme, List<AiProvider> providers) {
    const toolMeta = {
      'fetch_url': '网页阅读',
      'web_search': '网页搜索',
      'skill_market': '技能市场',
      'generate_image': '图片生成',
      'describe_image': '图片识别',
    };
    final anthropicAssistant = _assistantUsesAnthropic(providers);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '小Q工具能力', '按需关闭以节省额度'),
        // SwitchListTile 的水波纹同样画在最近的 Material 上，底色不能放在
        // 中间的 Container 上（会触发「ink splashes may be invisible」断言）
        Material(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                if (anthropicAssistant)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '当前对话模型使用 Anthropic 原生接口，该接口暂不支持小Q工具，'
                            '以下开关不生效；换用 OpenAI 兼容模型即恢复。',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!_toolsLoaded)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                else
                  for (final entry in toolMeta.entries) ...[
                    SwitchListTile(
                      value: !_disabledTools.contains(entry.key),
                      title: Text(entry.value),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      // 不生效的开关直接置灰：可点却无效果比不可点更让人困惑
                      onChanged: anthropicAssistant ? null : (enabled) => _toggleTool(entry.key, enabled),
                    ),
                    if (entry.key != toolMeta.keys.last) _divider(theme),
                  ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, String title, String? subtitle, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                // 副标题可选：传 null 时只显示标题，避免留下空行
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }
}

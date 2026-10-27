import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/agent/services/agent_tool_config.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/pages/settings/ai_provider_edit_page.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';

/// AI 模型配置页：服务商列表 + 三个角色的模型分配 + 参数与工具开关
///
/// 数据模型是「厂商条目」：一个条目 = 一个 URL + 一组 API Key + 一组已启用模型。
/// 因此这一页只做两件事：
/// 1. 管理条目（增删改、设为默认、进详情页管密钥与模型）；
/// 2. 把已启用模型分配给角色（小Q 对话 / 时间线提取 / 生图）。
class AiConfigPage extends ConsumerStatefulWidget {
  final bool autoOpenAdd;

  const AiConfigPage({super.key, this.autoOpenAdd = false});

  @override
  ConsumerState<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends ConsumerState<AiConfigPage> {
  AiRoles _roles = const AiRoles();
  AiTemperatures _roleSettings = const AiTemperatures();
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
    final temps = await AiRoleService.instance.getTemperatures();
    if (!mounted) return;
    setState(() {
      _roles = roles;
      _roleSettings = temps;
    });
    _restoreImageTestResults();
  }

  Future<void> _restoreImageTestResults() async {
    _imageTestByRole.clear();
    for (final roleKey in const ['assistant', 'timelineOptimization']) {
      final ref0 = roleKey == 'assistant' ? _roles.assistant : _roles.timelineOptimization;
      if (ref0 == null) continue;
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
          '将删除「${provider.name}」及其 ${provider.apiKeys.length} 把密钥、'
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
    if (!mounted) return;
    if (enabledModelEntries(providers).isEmpty) {
      await showNoModelConfiguredDialog(context, scene: _roleLabel(roleKey));
      return;
    }
    final current = switch (roleKey) {
      'assistant' => _roles.assistant,
      'timelineOptimization' => _roles.timelineOptimization,
      _ => _roles.imageGeneration,
    };
    final result = await showModelPickerSheet(
      context,
      providers: providers,
      selected: current,
      title: '选择${_roleLabel(roleKey)}',
      allowUnbind: current != null,
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

  /// 角色当前生效的展示名：绑定 → 默认/首个可用厂商的首个模型 → 未配置
  String _roleDisplayName(String roleKey, List<AiProvider> providers) {
    final bound = switch (roleKey) {
      'assistant' => _roles.assistant,
      'timelineOptimization' => _roles.timelineOptimization,
      _ => _roles.imageGeneration,
    };
    if (bound != null &&
        providers.any(
          (p) => p.id == bound.providerId && p.hasModel(bound.modelName),
        )) {
      return aiModelDisplayName(bound, providers);
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
      final imgBase64 = await _generateTestImageBase64();
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

  /// 生成「白底黑字 11」的探测图：数字短、对比强，模型看得见就一定能答对
  Future<String> _generateTestImageBase64() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 100, 100));
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 100, 100),
      Paint()..color = Colors.white,
    );
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '11',
        style: TextStyle(
          color: Colors.black,
          fontSize: 60,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(10, 10));
    final image = await recorder.endRecording().toImage(100, 100);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return base64Encode(bytes!.buffer.asUint8List());
  }

  // ── 角色参数 ─────────────────────────────────────────────

  Future<void> _editRoleParameters(String roleKey) async {
    final settings = roleKey == 'assistant'
        ? _roleSettings.assistant
        : _roleSettings.timelineOptimization;
    final tokensCtl = TextEditingController(text: settings.maxTokens.toString());
    var temperature = settings.temperature;
    var extractImages = settings.extractImages;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Text('${_roleLabel(roleKey)}参数'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('温度', style: theme.textTheme.labelMedium),
                      const Spacer(),
                      Text(
                        temperature.toStringAsFixed(2),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: temperature.clamp(0.0, 2.0),
                    min: 0,
                    max: 2,
                    divisions: 40,
                    onChanged: (v) => setDialogState(() => temperature = v),
                  ),
                  const SizedBox(height: 4),
                  Text('最大输出 tokens', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  TextField(
                    controller: tokensCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (roleKey == 'timelineOptimization') ...[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: extractImages,
                      title: const Text('提取图片内容'),
                      subtitle: const Text('上传图片时一并交给模型识别'),
                      onChanged: (v) => setDialogState(() => extractImages = v),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) {
      tokensCtl.dispose();
      return;
    }

    final parsedTokens = int.tryParse(tokensCtl.text.trim());
    tokensCtl.dispose();
    if (parsedTokens == null || parsedTokens <= 0) {
      Toast.warning(context, '最大输出 tokens 需为正整数');
      return;
    }

    final newSettings = settings.copyWith(
      temperature: temperature,
      maxTokens: parsedTokens,
      extractImages: extractImages,
    );
    final updated = roleKey == 'assistant'
        ? _roleSettings.copyWith(assistant: newSettings)
        : _roleSettings.copyWith(timelineOptimization: newSettings);
    await AiRoleService.instance.saveTemperatures(updated);
    ref.invalidate(aiTemperaturesProvider);
    if (mounted) setState(() => _roleSettings = updated);
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
            _buildIntroCard(theme),
            const SizedBox(height: 8),
            _buildProvidersSection(theme, providers),
            const SizedBox(height: 4),
            _buildRoleSection(theme, providers),
            const SizedBox(height: 4),
            _buildParametersSection(theme),
            const SizedBox(height: 4),
            _buildToolSwitchCard(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'QNote 不再内置模型。添加你自己的模型服务（API 地址 + 密钥）后，'
              '扫描出模型并按需启用即可；同一地址可以填多把密钥自动轮询。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProvidersSection(ThemeData theme, List<AiProvider> providers) {
    if (providers.isEmpty) {
      return NoModelGuideCard(
        scene: '',
        padding: const EdgeInsets.symmetric(vertical: 16),
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
                        '${provider.apiKeys.length} 把密钥 · ${provider.models.length} 个模型已启用',
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

  Widget _buildRoleSection(ThemeData theme, List<AiProvider> providers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '模型分配', '同一个模型可分配给多个角色'),
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
              _roleTile(theme, 'assistant', providers),
              _divider(theme),
              _roleTile(theme, 'timelineOptimization', providers),
              _divider(theme),
              _roleTile(theme, 'imageGeneration', providers),
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

  Widget _roleTile(ThemeData theme, String roleKey, List<AiProvider> providers) {
    final colorScheme = theme.colorScheme;
    final display = _roleDisplayName(roleKey, providers);
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
            if (configured) ...[
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

  Widget _buildParametersSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(theme, '角色参数', '温度、输出长度与图片提取'),
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
              _parameterTile(theme, 'assistant'),
              _divider(theme),
              _parameterTile(theme, 'timelineOptimization'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _parameterTile(ThemeData theme, String roleKey) {
    final settings = roleKey == 'assistant'
        ? _roleSettings.assistant
        : _roleSettings.timelineOptimization;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(
        roleKey == 'assistant'
            ? Icons.tune_rounded
            : Icons.tune_rounded,
        size: 20,
      ),
      title: Text(_roleLabel(roleKey), style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        '温度 ${settings.temperature.toStringAsFixed(2)} · '
        '最大 ${settings.maxTokens} tokens'
        '${roleKey == 'timelineOptimization' ? ' · ${settings.extractImages ? '提取图片' : '不提取图片'}' : ''}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _editRoleParameters(roleKey),
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
class _VendorPickerSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 延迟到运行时读取，避免在 const 语境里依赖 config 列表
    final vendors = _vendors();
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
            child: ListView.builder(
              controller: controller,
              itemCount: vendors.length,
              itemBuilder: (context, index) {
                final spec = vendors[index];
                return ListTile(
                  title: Text(spec.name),
                  subtitle: Text(
                    spec.defaultBaseUrl.isEmpty
                        ? '需要自己填写地址'
                        : spec.defaultBaseUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () => Navigator.of(context).pop(spec.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 避免在 widget 文件顶部固化配置引用（测试可替换）
List<AiProviderConfig> _vendors() => aiProviders;
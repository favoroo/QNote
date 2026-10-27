import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/core/ai/model_fetch_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/unsaved_changes_dialog.dart';

/// 路由参数：编辑既有厂商条目，或按厂商模板新建
class AiProviderEditArgs {
  final AiProvider? provider;
  final String? initialVendorId;

  const AiProviderEditArgs({this.provider, this.initialVendorId});
}

/// 模型服务详情页：基础信息 + API 密钥池 + 模型扫描与按需启用
///
/// 这里取代了旧版「一个模型一个对话框」的编辑方式：
/// - 一个厂商条目只管一个 URL，密钥属于厂商，多把自动轮询；
/// - 模型只是条目下的勾选项——扫描出全量模型后按需启用，同一条目可以同时
///   启用多个模型供小Q、时间线提取、生图分别绑定；
/// - 全屏页面承载这些分组，移动端不再把十几个字段塞进一个 AlertDialog。
class AiProviderEditPage extends ConsumerStatefulWidget {
  /// 编辑既有厂商条目；为 null 时是新建
  final AiProvider? provider;

  /// 新建时预选的厂商模板（来自「添加模型服务」的厂商选择器）
  final String? initialVendorId;

  const AiProviderEditPage({
    super.key,
    this.provider,
    this.initialVendorId,
  });

  @override
  ConsumerState<AiProviderEditPage> createState() => _AiProviderEditPageState();
}

class _AiProviderEditPageState extends ConsumerState<AiProviderEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _baseUrlCtl;
  final TextEditingController _modelSearchCtl = TextEditingController();

  late String _vendorId;
  late String _providerType;
  late List<String> _keys;
  late List<AiProviderModel> _models;
  late List<AiProviderModel> _catalog;
  DateTime? _catalogUpdatedAt;

  bool _dirty = false;
  bool _saving = false;
  bool _scanning = false;
  String? _scanMessage;
  bool _scanMessageIsError = false;
  String _modelQuery = '';

  /// 密钥明文显隐（按索引，默认全部掩码）
  final Set<int> _revealedKeys = {};
  final Map<String, String> _keyTestResults = {};
  final Set<String> _testingKeys = {};
  final Map<String, String> _modelLatency = {};
  final Set<String> _testingModels = {};

  bool get _isEditing => widget.provider != null;

  AiProviderConfig? get _vendorSpec => getProviderById(_vendorId);

  String get _vendorLabel => _vendorSpec?.name ?? '自定义服务';

  @override
  void initState() {
    super.initState();
    final existing = widget.provider;
    _vendorId = existing?.vendorId ??
        widget.initialVendorId ??
        aiProviders.first.id;
    final spec = getProviderById(_vendorId);
    _providerType = existing?.providerType ?? spec?.provider ?? 'openai';
    _nameCtl = TextEditingController(text: existing?.name ?? spec?.name ?? '');
    _baseUrlCtl = TextEditingController(
      text: existing?.baseUrl ?? spec?.defaultBaseUrl ?? '',
    );
    _keys = List<String>.from(existing?.apiKeys ?? const <String>[]);
    _models = List<AiProviderModel>.from(existing?.models ?? const []);
    _catalog = List<AiProviderModel>.from(existing?.modelCatalog ?? const []);
    _catalogUpdatedAt = existing?.catalogUpdatedAt;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _baseUrlCtl.dispose();
    _modelSearchCtl.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _handleBack() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final canLeave = await promptUnsavedChanges(
      context,
      content: '模型服务还有未保存的改动，离开后将丢失。',
      onSave: _save,
    );
    if (canLeave && mounted) Navigator.of(context).pop();
  }

  // ── 基础信息 ─────────────────────────────────────────────

  Future<void> _pickVendor() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _VendorPickerSheet(selectedId: _vendorId),
    );
    if (selected == null || selected == _vendorId || !mounted) return;

    final previousSpec = _vendorSpec;
    final nextSpec = getProviderById(selected);
    setState(() {
      _vendorId = selected;
      _providerType = nextSpec?.provider ?? 'openai';
      // 只有用户没改过默认值时，才跟着厂商模板切换地址与名称
      if (_baseUrlCtl.text.trim().isEmpty ||
          _baseUrlCtl.text.trim() ==
              (previousSpec?.defaultBaseUrl ?? '').trim()) {
        _baseUrlCtl.text = nextSpec?.defaultBaseUrl ?? '';
      }
      if (_nameCtl.text.trim().isEmpty ||
          _nameCtl.text.trim() == (previousSpec?.name ?? '').trim()) {
        _nameCtl.text = nextSpec?.name ?? '';
      }
      _dirty = true;
    });
  }

  // ── 密钥池 ───────────────────────────────────────────────

  Future<void> _addKeys() async {
    final controller = TextEditingController();
    final added = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加 API 密钥'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: '每行一个密钥，可一次粘贴多行\nsk-xxxx\nsk-yyyy',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final keys = controller.text
                  .split(RegExp(r'[\s,，;；]+'))
                  .map((k) => k.trim())
                  .where((k) => k.isNotEmpty)
                  .toList();
              Navigator.of(ctx).pop(keys);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (added == null || !mounted) return;
    final fresh = added.where((k) => !_keys.contains(k)).toList();
    if (fresh.isEmpty) {
      Toast.warning(context, '这些密钥都已经在列表里了');
      return;
    }
    setState(() {
      _keys.addAll(fresh);
      _dirty = true;
    });
  }

  void _removeKey(int index) {
    setState(() {
      _keys.removeAt(index);
      _revealedKeys.clear();
      _dirty = true;
    });
  }

  /// 逐把测试密钥连通性：用当前启用的第一个模型发一句「Hi」
  Future<void> _testKeys() async {
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (keys.isEmpty) {
      Toast.warning(context, '请先添加 API 密钥');
      return;
    }
    final modelName = _testModelName();
    if (modelName == null) {
      Toast.warning(context, '请先扫描并启用一个模型，再测试密钥');
      return;
    }

    for (final key in keys) {
      if (_testingKeys.contains(key)) continue;
      setState(() => _testingKeys.add(key));
      final sw = Stopwatch()..start();
      try {
        final config = AiConfig(
          providerId: widget.provider?.id ?? 'test',
          name: modelName,
          provider: _providerType,
          modelName: modelName,
          apiKey: key,
          baseUrl: _baseUrlCtl.text.trim(),
          vendorId: _vendorId,
        );
        final service = AiService();
        // pinApiKey：锁定这一把测试，不参与池轮换
        service.updateConfig(config, pinApiKey: true);
        await service.chat([
          ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now()),
        ]);
        sw.stop();
        if (mounted) {
          setState(() => _keyTestResults[key] = '正常 · ${sw.elapsedMilliseconds}ms');
        }
      } catch (e) {
        if (mounted) setState(() => _keyTestResults[key] = '失败：${_formatTestError(e)}');
      } finally {
        if (mounted) setState(() => _testingKeys.remove(key));
      }
    }
  }

  String? _testModelName() {
    if (_models.isNotEmpty) return _models.first.id;
    if (_catalog.isNotEmpty) return _catalog.first.id;
    return null;
  }

  // ── 模型扫描与启用 ───────────────────────────────────────

  Future<void> _scanModels() async {
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    final spec = _vendorSpec;
    final authType = spec?.authType ?? 'bearer';
    if (keys.isEmpty && authType != 'none') {
      Toast.warning(context, '请先添加 API 密钥再扫描模型');
      return;
    }
    if (_baseUrlCtl.text.trim().isEmpty) {
      Toast.warning(context, '请先填写 Base URL');
      return;
    }

    setState(() {
      _scanning = true;
      _scanMessage = null;
      _scanMessageIsError = false;
    });

    final endpoint = (spec?.modelsEndpoint.isNotEmpty ?? false)
        ? spec!.modelsEndpoint
        : '/v1/models';
    final candidates = keys.isEmpty ? [null] : keys;
    Object? lastError;
    List<String>? fetched;

    for (final key in candidates) {
      try {
        fetched = await ModelFetchService().fetchModels(
          vendorId: _vendorId,
          baseUrl: _baseUrlCtl.text.trim(),
          apiKey: key,
          authType: authType,
          modelsEndpoint: endpoint,
        );
        break;
      } catch (e) {
        lastError = e;
        // 第一把密钥被限流/失效时自动换下一把，和发信层同一语义
        final message = _formatTestError(e);
        if (key != null) {
          setState(() => _keyTestResults[key] = '扫描失败：$message');
        }
      }
    }

    if (!mounted) return;
    if (fetched == null) {
      setState(() {
        _scanning = false;
        _scanMessage = '扫描失败：${_formatTestError(lastError ?? '未知错误')}';
        _scanMessageIsError = true;
      });
      return;
    }

    final merged = <AiProviderModel>[];
    final seen = <String>{};
    for (final id in fetched) {
      final trimmed = id.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      // 保留已启用模型的自定义展示名
      final existing = _models.where((m) => m.id == trimmed).firstOrNull;
      merged.add(existing ?? AiProviderModel.of(trimmed));
    }
    // 目录里已有的、但这次扫描没返回的模型继续保留（部分厂商按权限返回子集）
    for (final model in _catalog) {
      if (seen.add(model.id)) merged.add(model);
    }

    final fetchedCount = fetched.length;
    setState(() {
      _scanning = false;
      _catalog = merged;
      _catalogUpdatedAt = DateTime.now();
      _scanMessage = '扫描到 $fetchedCount 个模型，已启用 ${_models.length} 个';
      _scanMessageIsError = false;
      _dirty = true;
    });
  }

  void _toggleModel(String id, bool enabled) {
    setState(() {
      if (enabled) {
        final model = _catalog.where((m) => m.id == id).firstOrNull;
        if (model != null && !_models.any((m) => m.id == id)) {
          _models.add(model);
        }
      } else {
        _models.removeWhere((m) => m.id == id);
      }
      _dirty = true;
    });
  }

  void _setAllModels(bool enabled) {
    setState(() {
      if (enabled) {
        _models = List<AiProviderModel>.from(_catalog);
      } else {
        _models = [];
      }
      _dirty = true;
    });
  }

  Future<void> _addModelManually() async {
    final controller = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动添加模型'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '填写模型 ID，例如 gpt-4o-mini',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (id == null || id.isEmpty || !mounted) return;
    if (_catalog.any((m) => m.id == id)) {
      Toast.info(context, '该模型已在列表中');
      return;
    }
    setState(() {
      final model = AiProviderModel.of(id);
      _catalog = [..._catalog, model];
      _models = [..._models, model];
      _dirty = true;
    });
  }

  Future<void> _testModel(AiProviderModel model) async {
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (keys.isEmpty) {
      Toast.warning(context, '请先添加 API 密钥');
      return;
    }
    if (_testingModels.contains(model.id)) return;
    setState(() => _testingModels.add(model.id));
    final sw = Stopwatch()..start();
    try {
      final config = AiConfig(
        providerId: widget.provider?.id ?? 'test',
        name: model.name,
        provider: _providerType,
        modelName: model.id,
        apiKey: keys.first,
        baseUrl: _baseUrlCtl.text.trim(),
        vendorId: _vendorId,
      );
      final service = AiService();
      service.updateConfig(config, pinApiKey: true);
      await service.chat([
        ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now()),
      ]);
      sw.stop();
      if (mounted) {
        setState(() => _modelLatency[model.id] = '${sw.elapsedMilliseconds}ms');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _modelLatency[model.id] = '失败');
        Toast.error(context, '${model.id} 测试失败：${_formatTestError(e)}');
      }
    } finally {
      if (mounted) setState(() => _testingModels.remove(model.id));
    }
  }

  // ── 保存 / 删除 ──────────────────────────────────────────

  Future<bool> _save() async {
    if (_saving) return false;
    final name = _nameCtl.text.trim();
    final baseUrl = _baseUrlCtl.text.trim();
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();

    if (baseUrl.isEmpty) {
      Toast.warning(context, '请填写 Base URL');
      return false;
    }
    if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
      Toast.warning(context, 'Base URL 必须以 http:// 或 https:// 开头');
      return false;
    }
    if (keys.isEmpty) {
      Toast.warning(context, '请至少添加一把 API 密钥');
      return false;
    }
    if (_models.isEmpty) {
      Toast.warning(context, '请至少启用一个模型（可先扫描模型列表）');
      return false;
    }

    setState(() => _saving = true);
    try {
      final existing = widget.provider;
      final now = DateTime.now();
      final provider = AiProvider(
        id: existing?.id ?? const Uuid().v4(),
        vendorId: _vendorId,
        name: name.isEmpty ? _vendorLabel : name,
        providerType: _providerType,
        baseUrl: baseUrl,
        apiKeys: keys,
        models: _models,
        modelCatalog: _catalog,
        catalogUpdatedAt: _catalogUpdatedAt,
        isDefault: existing?.isDefault ?? false,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );

      final notifier = ref.read(aiProviderListProvider.notifier);
      if (existing == null) {
        final saved = await notifier.addProvider(provider);
        final all = ref.read(aiProviderListProvider).valueOrNull ?? const [];
        // 第一个厂商自动成为默认，避免「有模型但没有默认」的空窗
        if (all.length == 1) await notifier.setDefault(saved.id);
      } else {
        await notifier.updateProvider(provider);
      }

      // 模型被停用/厂商被改址后，旧绑定可能失效：统一收敛
      await AiRoleService.instance.pruneStaleRoleBindings();
      ref.invalidate(aiRolesProvider);
      // 密钥列表变了，轮换游标与冷却表跟着重来
      ApiKeyPool.instance.reset(provider.id);

      _dirty = false;
      if (mounted) Toast.success(context, '已保存');
      return true;
    } catch (e) {
      if (mounted) Toast.error(context, '保存失败：$e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAndPop() async {
    final ok = await _save();
    if (ok && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.provider;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型服务'),
        content: Text(
          '将删除「${existing.name}」及其 ${existing.apiKeys.length} 把密钥、'
          '${existing.models.length} 个已启用模型。'
          '引用它的角色绑定会被清空，未绑定角色的功能将回落到默认厂商。',
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
      await ref.read(aiProviderListProvider.notifier).deleteProvider(existing.id);
      await AiRoleService.instance.pruneStaleRoleBindings();
      ref.invalidate(aiRolesProvider);
      ApiKeyPool.instance.reset(existing.id);
      if (mounted) {
        Toast.success(context, '已删除');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) Toast.error(context, '删除失败：$e');
    }
  }

  String _formatTestError(Object? e) {
    if (e == null) return '未知错误';
    final msg = e.toString();
    if (kIsWeb &&
        (msg.contains('XMLHttpRequest') ||
            msg.contains('connection error') ||
            msg.contains('CORS') ||
            msg.contains('onError'))) {
      return '浏览器限制：Web 端无法直接调用外部 API（CORS），请用真机测试';
    }
    if (msg.contains('401') || msg.contains('403')) {
      return '认证失败，请检查 API Key';
    }
    if (msg.contains('timeout') || msg.contains('超时')) return '请求超时';
    if (msg.contains('SocketException') || msg.contains('NetworkException')) {
      return '网络连接失败，请检查网络与 Base URL';
    }
    return msg.length > 80 ? '${msg.substring(0, 80)}…' : msg;
  }

  // ── 构建 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? '编辑模型服务' : '添加模型服务'),
          actions: [
            if (_isEditing)
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: _delete,
              ),
            TextButton(
              onPressed: _saving ? null : _saveAndPop,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            _sectionTitle(theme, '基础信息', '模型服务地址与名称'),
            _buildBasicCard(theme),
            _sectionTitle(theme, 'API 密钥', '同一地址的密钥自动轮询使用'),
            _buildKeysCard(theme),
            _sectionTitle(theme, '模型', '扫描后按需启用，可同时启用多个'),
            _buildModelsCard(theme),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
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

  Widget _card(ThemeData theme, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _buildBasicCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _pickVendor,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.hub_outlined,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _vendorLabel,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '点击更换厂商模板',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
          const Divider(height: 20),
          Text('显示名称', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          TextField(
            controller: _nameCtl,
            onChanged: (_) => _markDirty(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '例如：公司中转 / 我的 OpenAI',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('Base URL', style: theme.textTheme.labelSmall),
              const Spacer(),
              if (_vendorId == 'chatanywhere') ...[
                _urlChip('国内中转', 'https://api.chatanywhere.tech/v1', theme),
                const SizedBox(width: 6),
                _urlChip('国外', 'https://api.chatanywhere.org/v1', theme),
              ],
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _baseUrlCtl,
            onChanged: (_) => _markDirty(),
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'https://api.example.com/v1',
            ),
          ),
          if (_vendorId == 'custom') ...[
            const SizedBox(height: 14),
            Text('接口类型', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _providerType,
              decoration: const InputDecoration(isDense: true),
              items: const [
                DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容')),
                DropdownMenuItem(value: 'gemini', child: Text('Gemini 原生')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _providerType = value;
                  _dirty = true;
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _urlChip(String label, String url, ThemeData theme) {
    final selected = _baseUrlCtl.text == url;
    return InkWell(
      onTap: () {
        setState(() {
          _baseUrlCtl.text = url;
          _dirty = true;
        });
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.2)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildKeysCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_keys.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '还没有密钥。添加后即可扫描模型并开始使用。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._keys.asMap().entries.map((entry) {
              final index = entry.key;
              final key = entry.value;
              final revealed = _revealedKeys.contains(index);
              final result = _keyTestResults[key];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.key_rounded,
                            size: 16,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              revealed ? key : ApiKeyPool.maskKey(key),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            tooltip: revealed ? '隐藏' : '显示',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              revealed
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                              size: 18,
                            ),
                            onPressed: () {
                              setState(() {
                                if (revealed) {
                                  _revealedKeys.remove(index);
                                } else {
                                  _revealedKeys.add(index);
                                }
                              });
                            },
                          ),
                          IconButton(
                            tooltip: '删除',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: colorScheme.error,
                            ),
                            onPressed: () => _removeKey(index),
                          ),
                        ],
                      ),
                      if (_testingKeys.contains(key))
                        Padding(
                          padding: const EdgeInsets.only(left: 24, top: 2),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '测试中…',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (result != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 24, top: 2),
                          child: Text(
                            result,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: result.startsWith('正常')
                                  ? Colors.green.shade700
                                  : colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _addKeys,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加密钥'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _testingKeys.isEmpty ? _testKeys : null,
                icon: const Icon(Icons.bolt_rounded, size: 18),
                label: const Text('逐把测试'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '多把密钥会在每次请求时自动轮换；某把密钥被限流（429）或额度用尽时进入冷却，'
            '自动切到下一把，冷却结束自动回池。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelsCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final models = _catalog
        .where((m) =>
            _modelQuery.isEmpty ||
            m.id.toLowerCase().contains(_modelQuery.toLowerCase()) ||
            m.name.toLowerCase().contains(_modelQuery.toLowerCase()))
        .toList();
    final enabledIds = _models.map((m) => m.id).toSet();
    final showSearch = _catalog.length > 10;

    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _scanning ? null : _scanModels,
                icon: _scanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar_rounded, size: 18),
                label: Text(_scanning ? '扫描中…' : '扫描模型'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _addModelManually,
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: const Text('手动添加'),
              ),
              const Spacer(),
              Text(
                '已启用 ${_models.length}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (_scanMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _scanMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _scanMessageIsError
                      ? colorScheme.error
                      : Colors.green.shade700,
                ),
              ),
            ),
          if (_catalog.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '还没有模型列表。填好 Base URL 与密钥后点「扫描模型」拉取该服务的全部模型，'
              '也可以手动添加模型 ID。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (showSearch)
                  Expanded(
                    child: TextField(
                      controller: _modelSearchCtl,
                      onChanged: (v) => setState(() => _modelQuery = v.trim()),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '搜索模型',
                        prefixIcon: Icon(Icons.search_rounded, size: 18),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _setAllModels(true),
                  child: const Text('全部启用'),
                ),
                TextButton(
                  onPressed: _models.isEmpty ? null : () => _setAllModels(false),
                  child: const Text('全部停用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (models.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '没有匹配的模型',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ...models.map((model) {
                final enabled = enabledIds.contains(model.id);
                final latency = _modelLatency[model.id];
                final testing = _testingModels.contains(model.id);
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: enabled,
                  onChanged: (value) => _toggleModel(model.id, value),
                  title: Text(
                    model.name,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    model.name == model.id
                        ? (latency ?? '')
                        : '${model.id}${latency == null ? '' : ' · $latency'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: latency != null && latency == '失败'
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                  secondary: IconButton(
                    tooltip: '测试',
                    visualDensity: VisualDensity.compact,
                    icon: testing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt_rounded, size: 18),
                    onPressed: testing ? null : () => _testModel(model),
                  ),
                );
              }),
          ],
        ],
      ),
    );
  }
}

/// 厂商模板选择器（底部弹层）
class _VendorPickerSheet extends StatelessWidget {
  final String selectedId;

  const _VendorPickerSheet({required this.selectedId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              itemCount: aiProviders.length,
              itemBuilder: (context, index) {
                final spec = aiProviders[index];
                final selected = spec.id == selectedId;
                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  title: Text(
                    spec.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                  subtitle: Text(
                    spec.defaultBaseUrl,
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
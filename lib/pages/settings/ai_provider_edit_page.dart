import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/core/ai/model_fetch_service.dart';
import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/raccoon_account_quota.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/raccoon_login_sheet.dart';
import 'package:qnote_flutter/widgets/ai/reasoning_effort_sheet.dart';
import 'package:qnote_flutter/widgets/unsaved_changes_dialog.dart';

/// 路由参数：编辑既有厂商条目，或按厂商模板新建
class AiProviderEditArgs {
  final AiProvider? provider;
  final String? initialVendorId;

  const AiProviderEditArgs({this.provider, this.initialVendorId});
}

/// 模型服务详情页：基础信息 +（API 密钥池 / 订阅账号登录）+ 模型扫描与按需启用
///
/// 这里取代了旧版「一个模型一个对话框」的编辑方式：
/// - 一个厂商条目只管一个 URL，密钥属于厂商，多把自动轮询；
/// - 订阅账号型（商汤小浣熊）改为登录账号，token 由账号服务现取，不配置 API Key；
/// - 模型只是条目下的勾选项——扫描出全量模型后按需启用，同一条目可以同时
///   启用多个模型供小Q、时间线提取、生图分别绑定；
/// - 全屏页面承载这些分组，移动端不再把十几个字段塞进一个 AlertDialog。
class AiProviderEditPage extends ConsumerStatefulWidget {
  /// 编辑既有厂商条目；为 null 时是新建
  final AiProvider? provider;

  /// 新建时预选的厂商模板（来自「添加模型服务」的厂商选择器）
  final String? initialVendorId;

  const AiProviderEditPage({super.key, this.provider, this.initialVendorId});

  @override
  ConsumerState<AiProviderEditPage> createState() => _AiProviderEditPageState();
}

class _AiProviderEditPageState extends ConsumerState<AiProviderEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _baseUrlCtl;
  final TextEditingController _modelSearchCtl = TextEditingController();

  late String _vendorId;
  late String _providerType;
  late String _authMode;
  late String _providerId;
  late List<String> _keys;
  late List<AiProviderModel> _models;
  late List<AiProviderModel> _catalog;
  DateTime? _catalogUpdatedAt;

  /// 订阅账号型厂商的登录态（多账号，按轮换顺序；非账号型为空）
  List<AiAccount> _accounts = const [];
  bool _accountLoading = false;

  /// 账号选号策略与亲和时长（账号型专用，随条目保存）
  late String _accountRouting;
  late String _accountAffinity;

  /// 账号额度：accountId → 本次打开编辑页期间的查询结果/进行中/错误
  final Map<String, RaccoonAccountQuota> _quotas = {};
  final Set<String> _quotaLoading = {};
  final Map<String, String> _quotaErrors = {};

  /// 正在签到的账号（避免重复点击把同一个账号签到请求打两遍）
  final Set<String> _checkingIn = {};

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
    _vendorId =
        existing?.vendorId ?? widget.initialVendorId ?? aiProviders.first.id;
    final spec = getProviderById(_vendorId);
    _providerType = existing?.providerType ?? spec?.provider ?? 'openai';
    _authMode =
        existing?.authMode ?? spec?.authMode ?? AiProvider.authModeApiKey;
    // 新建时先生成 id：登录态按 providerId 落库，不能等保存时才生成
    _providerId = existing?.id ?? const Uuid().v4();
    _nameCtl = TextEditingController(text: existing?.name ?? spec?.name ?? '');
    _baseUrlCtl = TextEditingController(
      text: existing?.baseUrl ?? spec?.defaultBaseUrl ?? '',
    );
    _keys = List<String>.from(existing?.apiKeys ?? const <String>[]);
    _models = List<AiProviderModel>.from(existing?.models ?? const []);
    _catalog = List<AiProviderModel>.from(existing?.modelCatalog ?? const []);
    _catalogUpdatedAt = existing?.catalogUpdatedAt;
    _accountRouting =
        existing?.accountRouting ?? AiProvider.defaultAccountRouting;
    _accountAffinity =
        existing?.accountAffinity ?? AiProvider.defaultAccountAffinity;
    if (_authMode == AiProvider.authModeRaccoon) {
      _loadAccounts();
    }
  }

  Future<void> _loadAccounts() async {
    _accountLoading = true;
    try {
      final accounts = await RaccoonAuthService.instance.accountsFor(
        _providerId,
        forceReload: true,
      );
      if (!mounted) return;
      // 退出登录/换账号后，旧账号的额度与错误不该继续挂在界面上
      final ids = accounts.map((account) => account.id).toSet();
      _quotas.removeWhere((id, _) => !ids.contains(id));
      _quotaErrors.removeWhere((id, _) => !ids.contains(id));
      setState(() {
        _accounts = accounts;
        _accountLoading = false;
      });
      _autoFetchQuotas();
    } catch (_) {
      if (!mounted) return;
      setState(() => _accountLoading = false);
    }
  }

  /// 首次进入（或刚登录完）给每个可用账号自动查一次额度；
  /// 已查过的账号不重复打接口，避免改备注/切启停时反复触发网络请求
  void _autoFetchQuotas() {
    for (final account in _accounts) {
      if (!account.enabled || account.isExpired) continue;
      if (_quotas.containsKey(account.id) ||
          _quotaErrors.containsKey(account.id)) {
        continue;
      }
      if (_quotaLoading.contains(account.id)) continue;
      _fetchQuota(account);
    }
  }

  /// 查询/刷新单个账号的积分
  Future<void> _fetchQuota(AiAccount account) async {
    if (_quotaLoading.contains(account.id)) return;
    setState(() {
      _quotaLoading.add(account.id);
      _quotaErrors.remove(account.id);
    });
    try {
      final quota = await RaccoonAuthService.instance.fetchQuota(account);
      if (!mounted) return;
      final stillListed = _accounts.any((item) => item.id == account.id);
      setState(() {
        _quotaLoading.remove(account.id);
        if (stillListed) _quotas[account.id] = quota;
      });
    } catch (e) {
      if (!mounted) return;
      final stillListed = _accounts.any((item) => item.id == account.id);
      setState(() {
        _quotaLoading.remove(account.id);
        if (stillListed) _quotaErrors[account.id] = _quotaErrorMessage(e);
      });
      if (e is RaccoonAuthRequiredException) {
        // 登录态被服务端拒绝：拉一次账号列表，让「已过期」状态立刻显示出来
        await _loadAccounts();
      }
    }
  }

  /// 刷新全部可用账号的积分
  Future<void> _refreshAllQuotas() async {
    final targets = _accounts
        .where((account) => account.enabled && !account.isExpired)
        .toList();
    await Future.wait(targets.map(_fetchQuota));
  }

  /// 手动签到：成功后顺手刷新一次积分，让新到账的数字立刻可见
  Future<void> _checkIn(AiAccount account) async {
    if (_checkingIn.contains(account.id)) return;
    setState(() => _checkingIn.add(account.id));
    try {
      final result = await RaccoonAuthService.instance.checkIn(account);
      if (!mounted) return;
      setState(() => _checkingIn.remove(account.id));
      if (result.claimed) {
        Toast.success(context, '签到成功：${result.message}');
        await _fetchQuota(account);
      } else {
        Toast.info(context, result.message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingIn.remove(account.id));
      Toast.error(context, '签到失败：${_quotaErrorMessage(e)}');
      if (e is RaccoonAuthRequiredException) {
        // 登录态被服务端拒绝：拉一次账号列表，让「已过期」状态立刻显示出来
        await _loadAccounts();
      }
    }
  }

  String _quotaErrorMessage(Object error) {
    final text = error
        .toString()
        .replaceFirst('FormatException: ', '')
        .replaceFirst('Exception: ', '');
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
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
    final nextAuthMode = nextSpec?.authMode ?? AiProvider.authModeApiKey;
    setState(() {
      _vendorId = selected;
      _providerType = nextSpec?.provider ?? 'openai';
      _authMode = nextAuthMode;
      // 只有用户没改过默认值时，才跟着厂商模板切换地址与名称；
      // 账号型厂商的地址是固定接口，必须强制换成模板地址，否则会带着旧厂商的
      // Base URL 去调小浣熊的账号 token
      if (nextAuthMode != AiProvider.authModeApiKey ||
          _baseUrlCtl.text.trim().isEmpty ||
          _baseUrlCtl.text.trim() ==
              (previousSpec?.defaultBaseUrl ?? '').trim()) {
        _baseUrlCtl.text = nextSpec?.defaultBaseUrl ?? '';
      }
      if (_nameCtl.text.trim().isEmpty ||
          _nameCtl.text.trim() == (previousSpec?.name ?? '').trim()) {
        _nameCtl.text = nextSpec?.name ?? '';
      }
      if (_authMode != AiProvider.authModeRaccoon) {
        _accounts = const [];
      }
      // 换厂商模板后旧模型 id 已不属于新地址，保留会让用户误存一批无效模型
      _models = [];
      _catalog = [];
      _catalogUpdatedAt = null;
      _dirty = true;
    });
    if (_authMode == AiProvider.authModeRaccoon) {
      await _loadAccounts();
    }
  }

  // ── 订阅账号登录 ─────────────────────────────────────────

  /// 新增一个账号（[accountId] 为空）或重新登录指定账号
  Future<void> _openLoginSheet({String? accountId}) async {
    final account = await showModalBottomSheet<AiAccount>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          RaccoonLoginSheet(providerId: _providerId, accountId: accountId),
    );
    if (account == null || !mounted) return;
    // 重新登录可能换成了另一个厂商账号：旧积分属于上一个账号，不能继续展示
    setState(() {
      _quotas.remove(account.id);
      _quotaErrors.remove(account.id);
    });
    await _loadAccounts();
    if (!mounted) return;
    setState(() => _dirty = true);
    Toast.success(context, '已登录：${account.label}');
    // 首次登录后直接拉一次模型目录，省掉用户再点一次「扫描」
    if (_models.isEmpty) await _scanModels();
  }

  Future<void> _logoutAccount(AiAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出「${account.label}」'),
        content: Text(
          _accounts.length <= 1
              ? '这是当前唯一的账号，退出后该模型服务将无法调用，直到重新登录。已启用的模型与角色绑定会保留。'
              : '退出后这个账号不再参与轮换，其余账号不受影响。已启用的模型与角色绑定会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await RaccoonAuthService.instance.logout(account.id);
    await _loadAccounts();
    if (!mounted) return;
    Toast.info(context, '已退出「${account.label}」');
  }

  /// 修改账号备注（「工作号」「小号」这类，便于在轮换里分辨）
  Future<void> _renameAccount(AiAccount account) async {
    final controller = TextEditingController(text: account.alias);
    final alias = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('账号备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '例如：工作号 / 小号',
            helperText:
                '留空则显示手机号（${account.phone.isEmpty ? account.label : account.phone}）',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (alias == null || !mounted) return;
    await RaccoonAuthService.instance.updateAccount(account, alias: alias);
    await _loadAccounts();
  }

  /// 账号参与/退出轮换（关掉保留登录态，但不被选中）
  Future<void> _toggleAccountEnabled(AiAccount account, bool enabled) async {
    await RaccoonAuthService.instance.updateAccount(account, enabled: enabled);
    await _loadAccounts();
  }

  /// 调整账号顺序（「顺序」策略的优先级 = 这个顺序）
  Future<void> _moveAccount(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _accounts.length) return;
    final ordered = List<AiAccount>.from(_accounts);
    final moved = ordered.removeAt(index);
    ordered.insert(target, moved);
    // 先本地重排让界面立刻响应，再落库（失败时 _loadAccounts 会拉回真实顺序）
    setState(() => _accounts = ordered);
    await RaccoonAuthService.instance.reorderAccounts(
      _providerId,
      ordered.map((a) => a.id).toList(),
    );
    await _loadAccounts();
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
          reasoningEffort: _models
              .where((m) => m.id == modelName)
              .firstOrNull
              ?.reasoningEffort,
        );
        final service = AiService();
        // pinApiKey：锁定这一把测试，不参与池轮换
        service.updateConfig(config, pinApiKey: true);
        await service.chat([
          ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now()),
        ]);
        sw.stop();
        if (mounted) {
          setState(
            () => _keyTestResults[key] = '正常 · ${sw.elapsedMilliseconds}ms',
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _keyTestResults[key] = '失败：${_formatTestError(e)}');
        }
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
    if (_authMode == AiProvider.authModeRaccoon) {
      await _scanRaccoonModels();
      return;
    }
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

  /// 账号型厂商的模型扫描：目录接口要带 access token，401 会自动刷新一次
  Future<void> _scanRaccoonModels() async {
    if (_accounts.isEmpty) {
      Toast.warning(context, '请先登录小浣熊账号，再扫描模型');
      return;
    }
    setState(() {
      _scanning = true;
      _scanMessage = null;
      _scanMessageIsError = false;
    });
    try {
      final models = await RaccoonAuthService.instance.fetchModelsForProvider(
        _providerId,
      );
      if (!mounted) return;
      final merged = <AiProviderModel>[];
      final seen = <String>{};
      for (final model in models) {
        if (!seen.add(model.id)) continue;
        // 保留已启用模型的自定义展示名
        final existing = _models.where((m) => m.id == model.id).firstOrNull;
        merged.add(existing ?? model);
      }
      for (final model in _catalog) {
        if (seen.add(model.id)) merged.add(model);
      }
      // 首次扫描（还没有任何目录）时默认启用第一个模型，避免用户还要再去勾一次；
      // 已有目录说明用户自己管理过勾选，哪怕现在一个都没启用也照他的意愿来
      if (_models.isEmpty && _catalog.isEmpty && merged.isNotEmpty) {
        _models.add(merged.first);
      }
      setState(() {
        _scanning = false;
        _catalog = merged;
        _catalogUpdatedAt = DateTime.now();
        _scanMessage = '扫描到 ${models.length} 个模型，已启用 ${_models.length} 个';
        _scanMessageIsError = false;
        _dirty = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = '扫描失败：${_formatTestError(e)}';
        _scanMessageIsError = true;
      });
    }
  }

  void _toggleModel(String id, bool enabled) {
    setState(() {
      if (enabled) {
        final model = _catalog.where((m) => m.id == id).firstOrNull;
        if (model != null && !_models.any((m) => m.id == id)) {
          _models.add(model);
        }
      } else {
        // 停用前把模型级设置写回目录：再次启用时不会丢思考强度
        final removed = _models.where((m) => m.id == id).firstOrNull;
        _models.removeWhere((m) => m.id == id);
        if (removed != null) {
          final catalogIndex = _catalog.indexWhere((m) => m.id == id);
          if (catalogIndex != -1) _catalog[catalogIndex] = removed;
        }
      }
      _dirty = true;
    });
  }

  /// 调整某个已启用模型的思考强度
  Future<void> _editModelReasoning(AiProviderModel model) async {
    final result = await showReasoningEffortSheet(
      context,
      modelName: model.id,
      providerType: _providerType,
      vendorId: _vendorId,
      selected: model.reasoningEffort,
    );
    if (result == null || !mounted) return;
    setState(() {
      final index = _models.indexWhere((m) => m.id == model.id);
      if (index == -1) return;
      final updated = _models[index].copyWith(reasoningEffort: result.effort);
      _models[index] = updated;
      // 目录条目保持同步，停用再启用时档位不丢
      final catalogIndex = _catalog.indexWhere((m) => m.id == model.id);
      if (catalogIndex != -1) _catalog[catalogIndex] = updated;
      _dirty = true;
    });
  }

  void _setAllModels(bool enabled) {
    setState(() {
      if (enabled) {
        _models = List<AiProviderModel>.from(_catalog);
      } else {
        // 全部停用前把模型级设置写回目录，便于之后恢复
        for (final model in _models) {
          final catalogIndex = _catalog.indexWhere((m) => m.id == model.id);
          if (catalogIndex != -1) _catalog[catalogIndex] = model;
        }
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
    final usesAccount = _authMode == AiProvider.authModeRaccoon;
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (!usesAccount && keys.isEmpty) {
      Toast.warning(context, '请先添加 API 密钥');
      return;
    }
    if (usesAccount && _accounts.isEmpty) {
      Toast.warning(context, '请先登录小浣熊账号');
      return;
    }
    if (_testingModels.contains(model.id)) return;
    setState(() => _testingModels.add(model.id));
    final sw = Stopwatch()..start();
    try {
      final config = AiConfig(
        providerId: _providerId,
        name: model.name,
        provider: _providerType,
        modelName: model.id,
        apiKey: usesAccount ? '' : keys.first,
        baseUrl: _baseUrlCtl.text.trim(),
        authMode: _authMode,
        accountRouting: _accountRouting,
        accountAffinity: _accountAffinity,
        vendorId: _vendorId,
        reasoningEffort: model.reasoningEffort,
      );
      final service = AiService();
      service.updateConfig(config, pinApiKey: !usesAccount);
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
    final usesAccount = _authMode == AiProvider.authModeRaccoon;

    if (baseUrl.isEmpty) {
      Toast.warning(context, '请填写 Base URL');
      return false;
    }
    if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
      Toast.warning(context, 'Base URL 必须以 http:// 或 https:// 开头');
      return false;
    }
    if (!usesAccount && keys.isEmpty) {
      Toast.warning(context, '请至少添加一把 API 密钥');
      return false;
    }
    if (usesAccount && _accountLoading) {
      Toast.warning(context, '正在读取登录态，请稍候');
      return false;
    }
    if (usesAccount && _accounts.isEmpty) {
      Toast.warning(context, '请先登录小浣熊账号');
      return false;
    }
    if (usesAccount && _accounts.every((a) => !a.enabled)) {
      Toast.warning(context, '请至少启用一个账号，否则无法调用');
      return false;
    }
    // 刻意允许「一个模型都不启用」：停用全部模型 = 让这个厂商暂时退出选路，
    // 密钥与目录都留着，下次勾回来即可。绑定失效的角色会在下面被自动收敛。

    setState(() => _saving = true);
    try {
      final existing = widget.provider;
      final now = DateTime.now();
      final provider = AiProvider(
        id: _providerId,
        vendorId: _vendorId,
        name: name.isEmpty ? _vendorLabel : name,
        providerType: _providerType,
        baseUrl: baseUrl,
        authMode: _authMode,
        accountRouting: _accountRouting,
        accountAffinity: _accountAffinity,
        apiKeys: usesAccount ? const <String>[] : keys,
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
      // 从账号型切回 API Key 型：清掉这个条目残留的全部登录态，
      // 避免留下不用的长期凭据
      if (!usesAccount) {
        await RaccoonAuthService.instance.logoutProvider(_providerId);
      }
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
    final usesAccount = existing.authMode == AiProvider.authModeRaccoon;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型服务'),
        content: Text(
          usesAccount
              ? '将删除「${existing.name}」及其本地登录态、'
                    '${existing.models.length} 个已启用模型。'
                    '引用它的角色绑定会被清空，未绑定角色的功能将回落到默认厂商。'
              : '将删除「${existing.name}」及其 ${existing.apiKeys.length} 把密钥、'
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
      // deleteProvider 内部会一并清掉该厂商下的全部账号登录态
      await ref
          .read(aiProviderListProvider.notifier)
          .deleteProvider(existing.id);
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
      return _authMode == AiProvider.authModeRaccoon
          ? '登录已失效，请重新登录小浣熊账号'
          : '认证失败，请检查 API Key';
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
            if (_authMode == AiProvider.authModeRaccoon) ...[
              _sectionTitle(theme, '账号登录', '用商汤小浣熊账号的额度调用'),
              _buildAccountCard(theme),
            ] else ...[
              _sectionTitle(theme, 'API 密钥', '同一地址的密钥自动轮询使用'),
              _buildKeysCard(theme),
            ],
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
            readOnly: _authMode == AiProvider.authModeRaccoon,
            onChanged: (_) => _markDirty(),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://api.example.com/v1',
              helperText: _authMode == AiProvider.authModeRaccoon
                  ? '账号登录固定使用小浣熊官方接口'
                  : null,
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
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
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

  /// 账号列表卡片：多账号增删、备注、启停、排序 + 选号策略与亲和
  Widget _buildAccountCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    if (_accountLoading) {
      return _card(
        theme,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }

    final multi = _accounts.length >= 2;
    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_accounts.isNotEmpty) ...[
            Row(
              children: [
                Text(
                  '小浣熊账号',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _quotaLoading.isEmpty ? _refreshAllQuotas : null,
                  icon: _quotaLoading.isEmpty
                      ? const Icon(Icons.refresh_rounded, size: 16)
                      : const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                  label: Text(_quotaLoading.isEmpty ? '刷新额度' : '查询中'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          if (_accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '还没有登录账号。登录后即可扫描模型、用小浣熊额度对话；登录多个账号后可按下方策略轮换。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._accounts.asMap().entries.map(
              (entry) => _accountRow(theme, entry.key, entry.value),
            ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openLoginSheet(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(_accounts.isEmpty ? '登录小浣熊账号' : '添加另一个账号'),
            ),
          ),
          if (multi) ...[
            const Divider(height: 26),
            Text(
              '多账号轮换',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '登录了 ${_accounts.length} 个账号，按下面的策略分配请求',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text('选号策略', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: AccountRouting.values
                  .map(
                    (routing) => ChoiceChip(
                      label: Text(routing.label),
                      selected: _accountRouting == routing.id,
                      onSelected: (_) =>
                          setState(() => _accountRouting = routing.id),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 4),
            Text(
              AccountRouting.fromId(_accountRouting).description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text('会话亲和', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: AccountAffinity.values
                  .map(
                    (affinity) => ChoiceChip(
                      label: Text(affinity.label),
                      selected: _accountAffinity == affinity.id,
                      onSelected: (_) =>
                          setState(() => _accountAffinity = affinity.id),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 4),
            Text(
              AccountAffinity.fromId(_accountAffinity).description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 单个账号行：头像 + 名称 + 状态 + 备注/启停/上移下移/退出
  Widget _accountRow(ThemeData theme, int index, AiAccount account) {
    final colorScheme = theme.colorScheme;
    final expired = account.isExpired;
    final cooling = RaccoonAuthService.instance.isAccountCooling(account.id);
    final statusText = expired
        ? '登录已过期，请重新登录'
        : cooling
        ? '限流冷却中，暂时跳过'
        : (account.enabled ? '登录有效 · 自动续期' : '已停用，不参与轮换');
    final statusColor = expired
        ? colorScheme.error
        : cooling
        ? colorScheme.tertiary
        : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  account.enabled
                      ? Icons.verified_user_outlined
                      : Icons.person_off_outlined,
                  size: 20,
                  color: account.enabled
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              account.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_accounts.length >= 2) ...[
                            const SizedBox(width: 6),
                            Text(
                              '#${index + 1}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        statusText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: account.enabled,
                  onChanged: (value) => _toggleAccountEnabled(account, value),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (value) {
                    switch (value) {
                      case 'rename':
                        _renameAccount(account);
                        break;
                      case 'relogin':
                        _openLoginSheet(accountId: account.id);
                        break;
                      case 'up':
                        _moveAccount(index, -1);
                        break;
                      case 'down':
                        _moveAccount(index, 1);
                        break;
                      case 'logout':
                        _logoutAccount(account);
                        break;
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: 'rename', child: Text('修改备注')),
                    const PopupMenuItem(value: 'relogin', child: Text('重新登录')),
                    if (index > 0)
                      const PopupMenuItem(value: 'up', child: Text('上移')),
                    if (index < _accounts.length - 1)
                      const PopupMenuItem(value: 'down', child: Text('下移')),
                    const PopupMenuItem(value: 'logout', child: Text('退出登录')),
                  ],
                ),
              ],
            ),
            if (account.expiresAt != null)
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 2),
                child: Text(
                  '凭证有效期至 ${_formatAccountTime(account.expiresAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 2),
              child: _quotaLine(theme, account),
            ),
          ],
        ),
      ),
    );
  }

  /// 账号行里的额度：积分 + 套餐 + 更新时间，右侧是签到与单账号刷新
  Widget _quotaLine(ThemeData theme, AiAccount account) {
    final colorScheme = theme.colorScheme;
    final quota = _quotas[account.id];
    final loading = _quotaLoading.contains(account.id);
    final checkingIn = _checkingIn.contains(account.id);
    final error = _quotaErrors[account.id];

    final String text;
    if (quota != null) {
      final parts = <String>['积分 ${_formatPoints(quota.availablePoints)}'];
      if (quota.hasPlan) parts.add(quota.plan);
      final expires = quota.planExpiresAt;
      if (expires != null) parts.add('至 ${_formatQuotaDate(expires)}');
      parts.add('${_formatQuotaClock(quota.fetchedAt)} 更新');
      text = parts.join(' · ');
    } else if (loading) {
      text = '正在查询积分…';
    } else if (error != null) {
      text = '额度查询失败：$error';
    } else {
      text = '积分未查询';
    }

    return Row(
      children: [
        Icon(
          Icons.toll_outlined,
          size: 14,
          color: error != null
              ? colorScheme.error
              : colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: error != null
                  ? colorScheme.error
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (!account.isExpired)
          SizedBox(
            height: 32,
            child: TextButton.icon(
              onPressed: checkingIn ? null : () => _checkIn(account),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              icon: checkingIn
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.event_available_outlined, size: 14),
              label: Text(
                checkingIn ? '签到中' : '签到',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
        SizedBox(
          width: 32,
          height: 32,
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: '查询这个账号的积分',
                  onPressed: () => _fetchQuota(account),
                  icon: const Icon(Icons.refresh_rounded),
                ),
        ),
      ],
    );
  }

  String _formatPoints(int value) {
    final text = value.abs().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
      buffer.write(text[i]);
    }
    return value < 0 ? '-$buffer' : buffer.toString();
  }

  String _formatQuotaDate(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  String _formatQuotaClock(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatAccountTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final local = time.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
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
        .where(
          (m) =>
              _modelQuery.isEmpty ||
              m.id.toLowerCase().contains(_modelQuery.toLowerCase()) ||
              m.name.toLowerCase().contains(_modelQuery.toLowerCase()),
        )
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
              _authMode == AiProvider.authModeRaccoon
                  ? '还没有模型列表。登录小浣熊账号后点「扫描模型」拉取该账号可用的全部模型，'
                        '也可以手动添加模型 ID。'
                  : '还没有模型列表。填好 Base URL 与密钥后点「扫描模型」拉取该服务的全部模型，'
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
                  onPressed: _models.isEmpty
                      ? null
                      : () => _setAllModels(false),
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
                final enabledModel = _models
                    .where((m) => m.id == model.id)
                    .firstOrNull;
                final latency = _modelLatency[model.id];
                final testing = _testingModels.contains(model.id);
                // 已启用的模型都展示思考强度入口：能力表未收录时用通用兜底，
                // 与 ZCode 一致——用户总能自己调，选错由发信层降级兜住
                final capability = enabled
                    ? ModelReasoningCapability.forUi(
                        modelName: model.id,
                        providerType: _providerType,
                        vendorId: _vendorId,
                      )
                    : null;
                final effort = enabledModel?.reasoningEffort;
                final effortLabel = capability == null
                    ? null
                    : (effort == null ? '自动' : capability.labelFor(effort));
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: enabled,
                  onChanged: (value) => _toggleModel(model.id, value),
                  title: Text(model.name, style: const TextStyle(fontSize: 14)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.name == model.id
                            ? (latency ?? '')
                            : '${model.id}${latency == null ? '' : ' · $latency'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: latency != null && latency == '失败'
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (effortLabel != null)
                        InkWell(
                          onTap: enabledModel == null
                              ? null
                              : () => _editModelReasoning(enabledModel),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.tune_rounded,
                                  size: 12,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '思考强度：$effortLabel',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
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
///
/// 与「添加模型服务」的选择器保持同一分区口径：账号登录型在上、API Key 型在下。
/// 这里额外显示单选态（当前模板）。
class _VendorPickerSheet extends StatelessWidget {
  final String selectedId;

  const _VendorPickerSheet({required this.selectedId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final selected = spec.id == selectedId;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
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

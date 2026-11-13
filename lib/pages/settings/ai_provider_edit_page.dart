import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/ai/account_auth_registry.dart';
import 'package:qnote_flutter/core/ai/account_auth_types.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/core/ai/model_fetch_service.dart';
import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/utils/image_model_detection.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/account_quota.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_effort_levels_sheet.dart';
import 'package:qnote_flutter/widgets/ai/model_meta_badges.dart';
import 'package:qnote_flutter/widgets/ai/raccoon_login_sheet.dart';
import 'package:qnote_flutter/widgets/ai/sms_login_sheet.dart';
import 'package:qnote_flutter/widgets/ai/vendor_logo.dart';
import 'package:qnote_flutter/widgets/ai/vendor_picker_sheet.dart';
import 'package:qnote_flutter/widgets/unsaved_changes_dialog.dart';

part 'ai_provider_edit_widgets.dart';

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
/// - 订阅账号型（小浣熊 / AutoClaw）改为登录账号，token 由账号服务现取，不配置 API Key；
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
  final Map<String, AccountQuota> _quotas = {};
  final Set<String> _quotaLoading = {};
  final Map<String, String> _quotaErrors = {};

  /// 正在签到的账号（避免重复点击把同一个账号签到请求打两遍）
  final Set<String> _checkingIn = {};

  /// 订阅账号型厂商走统一接口，具体实现按厂商模板分发
  AccountAuthService get _accountService => AccountAuthRegistry.forVendor(_vendorId);

  bool get _usesAccount => _authMode != AiProvider.authModeApiKey;

  String get _accountKindLabel => '${_accountService.vendorLabel} 账号';

  String get _accountLoginLabel => '登录 ${_accountService.vendorLabel} 账号';

  String get _accountLoginHint => '请先登录 ${_accountService.vendorLabel} 账号';

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
  final Map<String, _ModelLatency> _modelLatency = {};
  final Set<String> _testingModels = {};

  bool get _isEditing => widget.provider != null;

  AiProviderConfig? get _vendorSpec => getProviderById(_vendorId);

  String get _vendorLabel => _vendorSpec?.name ?? '自定义服务';

  @override
  void initState() {
    super.initState();
    final existing = widget.provider;
    _vendorId = existing?.vendorId ?? widget.initialVendorId ?? aiProviders.first.id;
    final spec = getProviderById(_vendorId);
    _providerType = existing?.providerType ?? spec?.provider ?? 'openai';
    _authMode = existing?.authMode ?? spec?.authMode ?? AiProvider.authModeApiKey;
    // 新建时先生成 id：登录态按 providerId 落库，不能等保存时才生成
    _providerId = existing?.id ?? const Uuid().v4();
    _nameCtl = TextEditingController(text: existing?.name ?? spec?.name ?? '');
    _baseUrlCtl = TextEditingController(text: existing?.baseUrl ?? spec?.defaultBaseUrl ?? '');
    _keys = List<String>.from(existing?.apiKeys ?? const <String>[]);
    _models = List<AiProviderModel>.from(existing?.models ?? const []);
    _catalog = List<AiProviderModel>.from(existing?.modelCatalog ?? const []);
    _catalogUpdatedAt = existing?.catalogUpdatedAt;
    _accountRouting = existing?.accountRouting ?? AiProvider.defaultAccountRouting;
    _accountAffinity = existing?.accountAffinity ?? AiProvider.defaultAccountAffinity;
    if (_usesAccount) {
      _loadAccounts();
    }
  }

  Future<void> _loadAccounts() async {
    _accountLoading = true;
    try {
      final accounts = await _accountService.accountsFor(_providerId, forceReload: true);
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
      if (_quotas.containsKey(account.id) || _quotaErrors.containsKey(account.id)) {
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
      final quota = await _accountService.fetchQuota(account);
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
      if (e is AccountAuthRequiredException) {
        // 登录态被服务端拒绝：拉一次账号列表，让「已过期」状态立刻显示出来
        await _loadAccounts();
      }
    }
  }

  /// 刷新全部可用账号的积分
  Future<void> _refreshAllQuotas() async {
    final targets = _accounts.where((account) => account.enabled && !account.isExpired).toList();
    await Future.wait(targets.map(_fetchQuota));
  }

  /// 手动签到：成功后顺手刷新一次积分，让新到账的数字立刻可见
  Future<void> _checkIn(AiAccount account) async {
    if (_checkingIn.contains(account.id)) return;
    setState(() => _checkingIn.add(account.id));
    try {
      final result = await _accountService.checkIn(account);
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
      if (e is AccountAuthRequiredException) {
        // 登录态被服务端拒绝：拉一次账号列表，让「已过期」状态立刻显示出来
        await _loadAccounts();
      }
    }
  }

  String _quotaErrorMessage(Object error) {
    final text = error.toString().replaceFirst('FormatException: ', '').replaceFirst('Exception: ', '');
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
    final canLeave = await promptUnsavedChanges(context, content: '还有未保存的改动，离开将丢失。', onSave: _save);
    if (canLeave && mounted) Navigator.of(context).pop();
  }

  // ── 基础信息 ─────────────────────────────────────────────

  Future<void> _pickVendor() async {
    final selected = await VendorPickerSheet.show(context, selectedId: _vendorId);
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
      // Base URL 去调账号型厂商的 token
      if (nextAuthMode != AiProvider.authModeApiKey ||
          _baseUrlCtl.text.trim().isEmpty ||
          _baseUrlCtl.text.trim() == (previousSpec?.defaultBaseUrl ?? '').trim()) {
        _baseUrlCtl.text = nextSpec?.defaultBaseUrl ?? '';
      }
      if (_nameCtl.text.trim().isEmpty || _nameCtl.text.trim() == (previousSpec?.name ?? '').trim()) {
        _nameCtl.text = nextSpec?.name ?? '';
      }
      if (!_usesAccount || previousSpec?.authMode != nextAuthMode) {
        // 换账号型厂商时旧账号不属于新厂商，不能继续挂着
        _accounts = const [];
      }
      // 换厂商模板后旧模型 id 已不属于新地址，保留会让用户误存一批无效模型
      _models = [];
      _catalog = [];
      _catalogUpdatedAt = null;
      _dirty = true;
    });
    if (_usesAccount) {
      await _loadAccounts();
    }
  }

  // ── 订阅账号登录 ─────────────────────────────────────────

  /// 新增一个账号（[accountId] 为空）或重新登录指定账号
  Future<void> _openLoginSheet({String? accountId}) async {
    final service = _accountService;
    final account = await showModalBottomSheet<AiAccount>(
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // 短信型厂商（AutoClaw / Loomy）共用同一个弹层，小浣熊走浏览器回环
      builder: (_) => service.supportsSmsLogin
          ? SmsLoginSheet(providerId: _providerId, service: service, accountId: accountId)
          : RaccoonLoginSheet(providerId: _providerId, accountId: accountId),
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
        content: Text(_accounts.length <= 1 ? '唯一账号，退出后无法调用，需重新登录。模型与绑定会保留。' : '退出后不再参与轮换，其他账号不受影响。模型与绑定会保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('退出登录')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _accountService.logout(account.id);
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
            hintText: '如：工作号 / 小号',
            helperText: '留空显示手机号（${account.phone.isEmpty ? account.label : account.phone}）',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (alias == null || !mounted) return;
    await _accountService.updateAccount(account, alias: alias);
    await _loadAccounts();
  }

  /// 账号参与/退出轮换（关掉保留登录态，但不被选中）
  Future<void> _toggleAccountEnabled(AiAccount account, bool enabled) async {
    await _accountService.updateAccount(account, enabled: enabled);
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
    await _accountService.reorderAccounts(_providerId, ordered.map((a) => a.id).toList());
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
          decoration: const InputDecoration(hintText: '每行一个，可粘贴多行\nsk-xxxx\nsk-yyyy', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
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
      Toast.warning(context, '密钥已在列表中');
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
      Toast.warning(context, '请先添加密钥');
      return;
    }
    final modelName = _testModelName();
    if (modelName == null) {
      Toast.warning(context, '请先扫描并启用模型');
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
          reasoningEffort: _models.where((m) => m.id == modelName).firstOrNull?.reasoningEffort,
        );
        final service = AiService();
        // pinApiKey：锁定这一把测试，不参与池轮换
        service.updateConfig(config, pinApiKey: true);
        await service.chat([ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now())]);
        sw.stop();
        if (mounted) {
          setState(() => _keyTestResults[key] = '正常 · ${_formatLatency(sw.elapsed)}');
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
    if (_usesAccount) {
      await _scanAccountModels();
      return;
    }
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    final spec = _vendorSpec;
    // 免密钥厂商（免费网关）扫描时无需凭证，按无鉴权发请求；
    // 否则「允许留空密钥却又不让扫描」会让条目停在 0 个模型上无法使用
    final keyless = spec?.keyOptional ?? false;
    final authType = keyless && keys.isEmpty ? 'none' : (spec?.authType ?? 'bearer');
    if (keys.isEmpty && authType != 'none') {
      Toast.warning(context, '请先添加密钥再扫描');
      return;
    }
    if (_baseUrlCtl.text.trim().isEmpty) {
      Toast.warning(context, '请填写 Base URL');
      return;
    }

    setState(() {
      _scanning = true;
      _scanMessage = null;
      _scanMessageIsError = false;
    });

    final endpoint = (spec?.modelsEndpoint.isNotEmpty ?? false) ? spec!.modelsEndpoint : '/v1/models';
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
      // 保留本地设置（展示名、思考档位）；生图标识按目录 ID 重新推断，
      // 这样用户不用停用再启用一遍才能看到「生图」徽标。已停用的模型设置
      // 留在目录里，扫描时也要认，否则停用期间扫一次就把配置冲掉了
      final existing =
          _models.where((m) => m.id == trimmed).firstOrNull ?? _catalog.where((m) => m.id == trimmed).firstOrNull;
      final fresh = AiProviderModel.of(
        trimmed,
        supportsImageGeneration: looksLikeImageGenerationModel(trimmed) ? true : null,
      );
      merged.add(existing == null ? fresh : existing.withMetadataFrom(fresh));
    }
    // 目录里已有的、但这次扫描没返回的模型继续保留（部分厂商按权限返回子集）
    for (final model in _catalog) {
      if (seen.add(model.id)) merged.add(model);
    }

    final fetchedCount = fetched.length;
    setState(() {
      // 已启用模型同步刷新元数据：模型选择器读的是这份列表，
      // 只更新目录的话选择器里看不到新标识
      for (var i = 0; i < _models.length; i++) {
        final fresh = merged.where((m) => m.id == _models[i].id).firstOrNull;
        if (fresh != null) _models[i] = _models[i].withMetadataFrom(fresh);
      }
      _scanning = false;
      _catalog = merged;
      _catalogUpdatedAt = DateTime.now();
      _scanMessage = '扫描到 $fetchedCount 个模型';
      _scanMessageIsError = false;
      _dirty = true;
    });
  }

  /// 账号型厂商的模型扫描：目录接口要带 access token，401 会自动刷新一次
  Future<void> _scanAccountModels() async {
    if (_accounts.isEmpty) {
      Toast.warning(context, _accountLoginHint);
      return;
    }
    setState(() {
      _scanning = true;
      _scanMessage = null;
      _scanMessageIsError = false;
    });
    try {
      final models = await _accountService.fetchModelsForProvider(_providerId);
      if (!mounted) return;
      final merged = <AiProviderModel>[];
      final seen = <String>{};
      for (final model in models) {
        if (!seen.add(model.id)) continue;
        // 名称与思考档位是用户本地设置，保留；倍率/上下文这类厂商元数据
        // 每次扫描都跟着目录刷新。已停用的模型设置也在 catalog 里，一并认。
        final existing =
            _models.where((m) => m.id == model.id).firstOrNull ?? _catalog.where((m) => m.id == model.id).firstOrNull;
        merged.add(existing == null ? model : existing.withMetadataFrom(model));
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
        // 已启用模型也刷新元数据：模型选择器直接读这份列表，只更新目录的话
        // 用户在选择器里仍然看不到新倍率/限免状态
        for (var i = 0; i < _models.length; i++) {
          final fresh = models.where((m) => m.id == _models[i].id).firstOrNull;
          if (fresh != null) _models[i] = _models[i].withMetadataFrom(fresh);
        }
        _scanning = false;
        _catalog = merged;
        _catalogUpdatedAt = DateTime.now();
        _scanMessage = '扫描到 ${models.length} 个模型';
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

  /// 模型行的元数据徽标：免费 / 倍率 / 上下文 / 生图 / 识图 / 限免说明
  ///
  /// 数据来自厂商目录（小浣熊的 `billing_*`、Loomy 的 `output_modalities` 与
  /// 展示名尾部的 `xN.N`）。倍率直接决定一次对话花多少积分，选模型时要一眼看到；
  /// 「生图」与对话模型混在同一个列表里时，靠它区分该勾哪一个给生图角色。
  Widget? _modelMetaRow(ThemeData theme, AiProviderModel model) {
    final colorScheme = theme.colorScheme;
    final children = <Widget>[];

    for (final label in modelMetaBadges(model)) {
      final isFree = label == '免费';
      final isOriginalRate = label.startsWith('原 ');
      final isImageGen = label == '生图';
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: isFree
                  ? Colors.green.shade700
                  : isImageGen
                  ? Colors.purple.shade400
                  : (isOriginalRate ? colorScheme.onSurfaceVariant : null),
              decoration: isOriginalRate ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      );
    }
    final note = model.rateNote;
    if (note != null && note.isNotEmpty) {
      children.add(Text(note, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: Colors.orange.shade700)));
    }
    if (children.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: children),
    );
  }

  /// 可选档位的一行文案；没有能力（模型未启用）时返回 null
  String? _levelsLabel(ModelReasoningCapability? capability) {
    if (capability == null) return null;
    return capability.levels.map(capability.labelFor).join(' / ');
  }

  /// 档位来源徽标：自定义 / 通用兜底 / 自动识别
  String? _levelsBadge(ModelReasoningCapability? capability, List<ReasoningEffort>? customLevels) {
    if (capability == null) return null;
    if (customLevels != null) return '自定义';
    return capability.isGeneric ? '通用' : '自动识别';
  }

  /// 配置某个已启用模型在对话里可选的思考档位
  ///
  /// 这里只编辑「有哪些档位」，不设置当前用哪一档：当前档位统一在对话的模型
  /// 面板里调整，避免同一设置两处入口打架。取消正在使用的档位时回到「自动」，
  /// 否则界面会留下一个已经发不出去的档位。
  Future<void> _editModelEffortLevels(AiProviderModel model) async {
    final result = await showModelEffortLevelsSheet(
      context,
      modelName: model.id,
      providerType: _providerType,
      vendorId: _vendorId,
      customLevels: model.reasoningEfforts,
    );
    if (result == null || !mounted) return;

    final levels = result.customLevels;
    final capability = ModelReasoningCapability.forUi(
      modelName: model.id,
      providerType: _providerType,
      vendorId: _vendorId,
      customLevels: levels,
    );
    final current = _models.where((m) => m.id == model.id).firstOrNull;
    final currentEffort = current?.reasoningEffort;
    final resetCurrent = currentEffort != null && !capability.supports(currentEffort);

    setState(() {
      void apply(List<AiProviderModel> models) {
        final index = models.indexWhere((m) => m.id == model.id);
        if (index == -1) return;
        final item = models[index];
        final keepCurrent = item.reasoningEffort == null || capability.supports(item.reasoningEffort!);
        models[index] = item.copyWith(
          reasoningEfforts: levels,
          reasoningEffort: keepCurrent ? item.reasoningEffort : null,
        );
      }

      // 已启用列表与扫描目录保持同步，停用再启用时配置不丢
      apply(_models);
      apply(_catalog);
      _dirty = true;
    });

    if (resetCurrent) {
      Toast.info(context, '当前档位已回到「自动」');
    }
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
          decoration: const InputDecoration(hintText: '模型 ID，如 gpt-4o-mini', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('添加')),
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

  /// 测速耗时的可读文本：1 秒内保留毫秒，超过 1 秒转成秒并保留一位小数。
  ///
  /// 原始毫秒（如 13942ms）位数太多，扫列表时难以快速比较。
  String _formatLatency(Duration duration) {
    final ms = duration.inMilliseconds;
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  /// 按耗时快慢分级着色：绿=快、橙=一般、红=慢。
  ///
  /// 深浅色主题各取一档，避免浅色下的深绿/深橙在暗色卡片上对比度不足。
  Color _latencyColor(ThemeData theme, _ModelLatency result) {
    if (result.failed) return theme.colorScheme.error;
    final isDark = theme.brightness == Brightness.dark;
    final ms = result.duration!.inMilliseconds;
    if (ms <= 1000) {
      return isDark ? Colors.green.shade400 : Colors.green.shade700;
    }
    if (ms <= 3000) {
      return isDark ? Colors.orange.shade300 : Colors.orange.shade800;
    }
    return theme.colorScheme.error;
  }

  Future<void> _testModel(AiProviderModel model) async {
    final usesAccount = _usesAccount;
    final keys = _keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (!usesAccount && keys.isEmpty) {
      Toast.warning(context, '请先添加密钥');
      return;
    }
    if (usesAccount && _accounts.isEmpty) {
      Toast.warning(context, _accountLoginHint);
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
      await service.chat([ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now())]);
      sw.stop();
      if (mounted) {
        setState(() => _modelLatency[model.id] = _ModelLatency.success(sw.elapsed));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _modelLatency[model.id] = const _ModelLatency.failure());
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
    final usesAccount = _usesAccount;

    if (baseUrl.isEmpty) {
      Toast.warning(context, '请填写 Base URL');
      return false;
    }
    if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
      Toast.warning(context, 'Base URL 必须以 http:// 或 https:// 开头');
      return false;
    }
    if (!usesAccount && keys.isEmpty && !(_vendorSpec?.keyOptional ?? false)) {
      Toast.warning(context, '请至少添加一把密钥');
      return false;
    }
    if (usesAccount && _accountLoading) {
      Toast.warning(context, '正在读取登录态');
      return false;
    }
    if (usesAccount && _accounts.isEmpty) {
      Toast.warning(context, _accountLoginHint);
      return false;
    }
    if (usesAccount && _accounts.every((a) => !a.enabled)) {
      Toast.warning(context, '请至少启用一个账号');
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
        await AccountAuthRegistry.logoutProvider(_providerId);
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
    final usesAccount = existing.usesAccountAuth;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型服务'),
        content: Text(
          usesAccount
              ? '将删除「${existing.name}」及登录态和 ${existing.models.length} 个模型，角色绑定会清空。'
              : '将删除「${existing.name}」及 ${existing.apiKeys.length} 把密钥和 '
                    '${existing.models.length} 个模型，角色绑定会清空。',
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
      // deleteProvider 内部会一并清掉该厂商下的全部账号登录态
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
      return '浏览器限制：Web 端无法调用外部 API（CORS），请用真机测试';
    }
    if (msg.contains('401') || msg.contains('403')) {
      return _usesAccount ? '登录已失效，请重新登录' : '认证失败，请检查 API Key';
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
              IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
            TextButton(
              onPressed: _saving ? null : _saveAndPop,
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            _sectionTitle(theme, '基础信息', '模型服务地址与名称'),
            _buildBasicCard(theme),
            if (_usesAccount) ...[
              _sectionTitle(theme, '账号登录', '用账号额度调用'),
              _buildAccountCard(theme),
            ] else ...[
              _sectionTitle(theme, 'API 密钥', '密钥自动轮询'),
              _buildKeysCard(theme),
            ],
            _sectionTitle(theme, '模型', '扫描后按需启用'),
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
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _card(ThemeData theme, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _buildBasicCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final regions = _vendorSpec?.regions ?? const <AiVendorRegion>[];
    final selectedRegionId = _vendorSpec?.regionFor(_baseUrlCtl.text)?.id;
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
                  VendorLogo(vendorId: _vendorId, fallbackLabel: _vendorLabel, size: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_vendorLabel, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        Text('更换厂商模板', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
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
            decoration: const InputDecoration(isDense: true, hintText: '如：公司中转 / 我的 OpenAI'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('Base URL', style: theme.textTheme.labelSmall),
              const Spacer(),
              if (regions.isNotEmpty)
                Text(
                  _vendorSpec!.regionTitle,
                  style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          // 多接入点的厂商（国内/国际、按量/套餐）在这里一键切换地址，
          // 不拆成多个厂商条目，避免选择器里出现一长串「某厂商（国内）」
          if (regions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final region in regions)
                  ChoiceChip(
                    label: Text(region.name),
                    selected: selectedRegionId == region.id,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _selectRegion(region),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          TextField(
            controller: _baseUrlCtl,
            readOnly: _usesAccount,
            onChanged: (_) => _markDirty(),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://api.example.com/v1',
              helperText: _usesAccount ? '账号登录使用官方接口' : null,
            ),
          ),
          if (_vendorId == 'custom') ...[
            const SizedBox(height: 14),
            Text('接口类型', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _providerType,
              borderRadius: BorderRadius.circular(12),
              decoration: const InputDecoration(isDense: true),
              items: const [
                DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容')),
                DropdownMenuItem(value: 'anthropic', child: Text('Anthropic 原生（/v1/messages）')),
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

  /// 切换厂商接入点（地区 / 套餐）：写入该端点的地址，并按需同步协议
  void _selectRegion(AiVendorRegion region) {
    setState(() {
      _baseUrlCtl.text = region.baseUrl;
      final provider = region.provider;
      if (provider != null) _providerType = provider;
      _dirty = true;
    });
  }

  /// 账号列表卡片：多账号增删、备注、启停、排序 + 选号策略与亲和
  Widget _buildAccountCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    if (_accountLoading) {
      return _card(
        theme,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
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
                Text(_accountKindLabel, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _quotaLoading.isEmpty ? _refreshAllQuotas : null,
                  icon: _quotaLoading.isEmpty
                      ? const Icon(Icons.refresh_rounded, size: 16)
                      : const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
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
                '还没有登录账号。登录后可扫描模型、使用账号额度对话。',
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            )
          else
            ..._accounts.asMap().entries.map((entry) => _accountRow(theme, entry.key, entry.value)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openLoginSheet(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(_accounts.isEmpty ? _accountLoginLabel : '添加另一个账号'),
            ),
          ),
          if (multi) ...[
            const Divider(height: 26),
            Text('多账号轮换', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              '共 ${_accounts.length} 个账号，按下方策略分配请求',
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
                      onSelected: (_) => setState(() => _accountRouting = routing.id),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 4),
            Text(
              AccountRouting.fromId(_accountRouting).description,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
                      onSelected: (_) => setState(() => _accountAffinity = affinity.id),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 4),
            Text(
              AccountAffinity.fromId(_accountAffinity).description,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
    final cooling = _accountService.isAccountCooling(account.id);
    final statusText = expired
        ? '登录已过期，请重新登录'
        : cooling
        ? '限流冷却中'
        : (account.enabled ? '登录有效' : '已停用');
    final statusColor = expired
        ? colorScheme.error
        : cooling
        ? colorScheme.tertiary
        : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(color: colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  account.enabled ? Icons.verified_user_outlined : Icons.person_off_outlined,
                  size: 20,
                  color: account.enabled ? colorScheme.primary : colorScheme.onSurfaceVariant,
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
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (_accounts.length >= 2) ...[
                            const SizedBox(width: 6),
                            Text(
                              '#${index + 1}',
                              style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(statusText, style: theme.textTheme.bodySmall?.copyWith(color: statusColor)),
                    ],
                  ),
                ),
                Switch(value: account.enabled, onChanged: (value) => _toggleAccountEnabled(account, value)),
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
                    if (index > 0) const PopupMenuItem(value: 'up', child: Text('上移')),
                    if (index < _accounts.length - 1) const PopupMenuItem(value: 'down', child: Text('下移')),
                    const PopupMenuItem(value: 'logout', child: Text('退出登录')),
                  ],
                ),
              ],
            ),
            if (account.expiresAt != null)
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 2),
                child: Text(
                  '有效期至 ${_formatAccountTime(account.expiresAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            Padding(padding: const EdgeInsets.only(left: 30, top: 2), child: _quotaLine(theme, account)),
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
      final parts = <String>['积分 ${_formatPoints(quota.balance)}'];
      if (quota.hasDetail) parts.add(quota.detail);
      if (quota.hasPlan) parts.add(quota.plan);
      final expires = quota.planExpiresAt;
      if (expires != null) parts.add('至 ${_formatQuotaDate(expires)}');
      parts.add('${_formatQuotaClock(quota.fetchedAt)} 更新');
      text = parts.join(' · ');
    } else if (loading) {
      text = '查询中…';
    } else if (error != null) {
      text = '额度查询失败：$error';
    } else {
      text = '未查询';
    }

    return Row(
      children: [
        Icon(Icons.toll_outlined, size: 14, color: error != null ? colorScheme.error : colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: error != null ? colorScheme.error : colorScheme.onSurfaceVariant,
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
                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.event_available_outlined, size: 14),
              label: Text(checkingIn ? '签到中' : '签到', style: theme.textTheme.labelSmall),
            ),
          ),
        SizedBox(
          width: 32,
          height: 32,
          child: loading
              ? const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: '查询积分',
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
                // 本机服务与免密钥网关允许空密钥：这里的文案必须跟着变，
                // 否则用户会以为必填而卡在保存上
                (_vendorSpec?.keyOptional ?? false) ? '该服务可以留空密钥，直接扫描模型即可。' : '还没有密钥，添加后即可扫描模型。',
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.key_rounded, size: 16, color: colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(revealed ? key : ApiKeyPool.maskKey(key), style: theme.textTheme.bodySmall),
                          ),
                          IconButton(
                            tooltip: revealed ? '隐藏' : '显示',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(revealed ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 18),
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
                            icon: Icon(Icons.delete_outline_rounded, size: 18, color: colorScheme.error),
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
                                child: CircularProgressIndicator(strokeWidth: 1.6, color: colorScheme.primary),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '测试中…',
                                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
                              color: result.startsWith('正常') ? Colors.green.shade700 : colorScheme.error,
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
            '多把密钥自动轮换；限流或额度用尽时冷却，结束后自动回池。',
            style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.5),
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
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
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
                style: theme.textTheme.labelMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (_scanMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _scanMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _scanMessageIsError ? colorScheme.error : Colors.green.shade700,
                ),
              ),
            ),
          if (_catalog.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _usesAccount ? '还没有模型列表，登录后点「扫描模型」获取，也可手动添加。' : '还没有模型列表，填好地址与密钥后点「扫描模型」获取。',
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.5),
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
                TextButton(onPressed: () => _setAllModels(true), child: const Text('全部启用')),
                TextButton(onPressed: _models.isEmpty ? null : () => _setAllModels(false), child: const Text('全部停用')),
              ],
            ),
            const SizedBox(height: 4),
            if (models.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('没有匹配的模型', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
              )
            else
              ...models.map((model) {
                final enabled = enabledIds.contains(model.id);
                final enabledModel = _models.where((m) => m.id == model.id).firstOrNull;
                final latency = _modelLatency[model.id];
                final testing = _testingModels.contains(model.id);
                // 已启用的模型都展示思考档位配置：能力表未收录时用通用兜底，
                // 与 ZCode 一致——用户总能自己调，选错由发信层降级兜住
                final capability = enabled
                    ? ModelReasoningCapability.forUi(
                        modelName: model.id,
                        providerType: _providerType,
                        vendorId: _vendorId,
                        customLevels: enabledModel?.reasoningEfforts,
                      )
                    : null;
                final customLevels = enabledModel?.reasoningEfforts;
                final metaRow = _modelMetaRow(theme, model);
                final levelLabels = _levelsLabel(capability);
                final levelBadge = _levelsBadge(capability, customLevels);
                final latencyLabel = latency == null
                    ? null
                    : (latency.failed ? '失败' : _formatLatency(latency.duration!));
                final latencyColor = latency == null ? null : _latencyColor(theme, latency);
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: enabled,
                  onChanged: (value) => _toggleModel(model.id, value),
                  title: Text(model.name, style: const TextStyle(fontSize: 14)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            if (model.name != model.id)
                              TextSpan(text: latencyLabel == null ? model.id : '${model.id} · '),
                            if (latencyLabel != null)
                              TextSpan(
                                text: latencyLabel,
                                style: TextStyle(color: latencyColor, fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      ?metaRow,
                      if (levelLabels != null)
                        InkWell(
                          onTap: enabledModel == null ? null : () => _editModelEffortLevels(enabledModel),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Icon(Icons.tune_rounded, size: 12, color: colorScheme.onSurfaceVariant),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    '可选档位：$levelLabels',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontSize: 11,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  levelBadge ?? '',
                                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, color: colorScheme.outline),
                                ),
                                Icon(Icons.chevron_right_rounded, size: 14, color: colorScheme.outline),
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
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
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

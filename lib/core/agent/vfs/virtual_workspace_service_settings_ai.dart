/// ai.json 的 providers 写处理：让小Q 通过写 `/settings/ai.json` 直接增改模型
/// 服务厂商条目（Base URL + API Key 池 + 已启用模型），实现「用户发 URL/Key/
/// 模型名 → 小Q 全自动配置」，无需引导去设置页。
///
/// 拆分说明：`virtual_workspace_service_parts.dart` 已近行数上限，本文件作为
/// 同库 `part` 单独承载 providers 写逻辑（不写 import，共享主文件依赖）。
part of 'virtual_workspace_service.dart';

/// 掩码密钥特征：与 [ApiKeyPool.maskKey] 的输出形态一致（4位...4位 或 ***）。
/// 小Q 常把读取快照里的掩码串原样写回，必须过滤掉，否则会覆盖真实密钥。
final RegExp _maskedKeyPattern = RegExp(r'^.{4}\.{3}.{4}$');

/// 判断密钥串是否为读取快照里的掩码形态（非明文，禁止落库）
bool _looksLikeMaskedKey(String key) {
  final trimmed = key.trim();
  return trimmed == '***' || _maskedKeyPattern.hasMatch(trimmed);
}

/// 取非空字符串（trim 后为空视为未提供）
String? _nonEmptyString(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

/// 处理 ai.json 写入中的 providers 数组，逐条 upsert 厂商条目
///
/// 返回每条的处理结果（含新厂商 id 与可用状态，供小Q 后续绑定角色）；
/// 校验失败抛出中文异常，与同库其他配置写处理惯例一致。
Future<List<Map<String, dynamic>>> _applyAiProvidersWrite(Map<String, dynamic> decoded) async {
  final list = decoded['providers'];
  if (list is! List) {
    throw Exception(
      'providers 必须是数组，例如: {"providers": [{"name": "中转站", '
      '"baseUrl": "https://api.example.com/v1", "apiKeys": ["sk-xxx"], "models": ["gpt-4o"]}]}',
    );
  }
  final repo = AiProviderRepository.instance;
  final results = <Map<String, dynamic>>[];
  var touched = false;
  for (final item in list) {
    if (item is! Map<String, dynamic>) {
      results.add({'status': 'skipped', 'note': '条目不是 JSON 对象，已跳过'});
      continue;
    }
    final result = await _upsertProviderFromJson(item, repo);
    results.add(result);
    if (result['status'] == 'created' || result['status'] == 'updated') touched = true;
  }
  // 厂商变更可能使角色绑定失效（如 baseUrl/模型被换），与设置页保存行为一致做一次收敛
  if (touched) {
    await AiRoleService.instance.pruneStaleRoleBindings();
  }
  return results;
}

/// 解析并落库单个 provider 条目（按 id 判定新增或更新）
Future<Map<String, dynamic>> _upsertProviderFromJson(Map<String, dynamic> item, AiProviderRepository repo) async {
  final rawId = _nonEmptyString(item['id']);
  if (rawId == kBuiltinVendorId) {
    throw Exception('内置免费服务（qnote_builtin）不可通过 ai.json 修改');
  }
  final existing = rawId == null ? null : await repo.getById(rawId);
  final now = DateTime.now();

  // vendorId：显式传入 > 沿用旧值 > custom
  final vendorId = _nonEmptyString(item['vendorId']) ?? existing?.vendorId ?? 'custom';
  final spec = getProviderById(vendorId);

  // providerType：显式 > 旧值 > 模板 > openai
  final providerType = _nonEmptyString(item['providerType']) ?? existing?.providerType ?? spec?.provider ?? 'openai';
  const allowedTypes = {'openai', 'anthropic', 'gemini'};
  if (!allowedTypes.contains(providerType)) {
    throw Exception('providerType 仅支持 openai / anthropic / gemini，收到: $providerType');
  }

  // 账号型厂商的凭证来自登录态，智能体无法代配置
  final authMode = _nonEmptyString(item['authMode']) ?? existing?.authMode ?? AiProvider.authModeApiKey;
  if (authMode != AiProvider.authModeApiKey) {
    throw Exception('订阅账号型厂商（$authMode）需要登录授权，智能体无法代配置，请引导用户到「小Q设置 → 模型」操作');
  }

  // baseUrl：显式 > 旧值；必须带协议前缀（与设置页保存校验一致）
  final baseUrl = _nonEmptyString(item['baseUrl']) ?? existing?.baseUrl ?? '';
  if (baseUrl.isEmpty) {
    throw Exception('providers 条目缺少 baseUrl，例如: {"baseUrl": "https://api.example.com/v1"}');
  }
  if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
    throw Exception('baseUrl 必须以 http:// 或 https:// 开头，收到: $baseUrl');
  }

  // 名称：显式 > 旧值 > 模板名 > 自定义
  final name =
      _nonEmptyString(item['name']) ?? ((existing?.name.isNotEmpty ?? false) ? existing!.name : (spec?.name ?? '自定义'));

  // 密钥：明文新密钥与现有池合并去重（replaceKeys: true 时全量替换）；
  // 掩码串（来自读取快照）一律过滤，防止覆盖真实密钥
  final existingKeys = existing?.apiKeys ?? const <String>[];
  final replaceKeys = item['replaceKeys'] == true;
  final freshKeys = <String>[];
  if (item.containsKey('apiKeys') && item['apiKeys'] is List) {
    for (final k in item['apiKeys'] as List) {
      if (k is! String) continue;
      final trimmed = k.trim();
      if (trimmed.isEmpty || _looksLikeMaskedKey(trimmed) || freshKeys.contains(trimmed)) continue;
      freshKeys.add(trimmed);
    }
  }
  final List<String> apiKeys;
  if (replaceKeys) {
    apiKeys = freshKeys;
  } else {
    apiKeys = [...existingKeys];
    for (final k in freshKeys) {
      if (!apiKeys.contains(k)) apiKeys.add(k);
    }
  }
  if (!vendorAllowsKeyless(vendorId) && apiKeys.isEmpty) {
    throw Exception(
      'providers 条目缺少 API Key，请在 apiKeys 中提供至少一把明文密钥'
      '（读取快照里的掩码串会被自动忽略，不能当作现有密钥回写）',
    );
  }

  // 已启用模型：显式传入 > 扫描结果（新建且未传时）> 旧值；更新未传 models 时保持不变
  final providedModels = _parseProviderModels(item);
  final wantsScan = item['scan'] == true || (existing == null && providedModels.isEmpty && item['scan'] != false);
  final List<AiProviderModel> known = [
    ...(existing?.models ?? const <AiProviderModel>[]),
    ...(existing?.modelCatalog ?? const <AiProviderModel>[]),
  ];
  var scannedCatalog = const <AiProviderModel>[];
  String? scanNote;
  if (wantsScan) {
    final scanResult = await _scanProviderModels(vendorId, spec, baseUrl, apiKeys);
    // 同 id 保留本地已自定义的名称与档位，只刷新元数据
    scannedCatalog = [for (final m in scanResult.$1) _withKnownMetadata(m, known)];
    scanNote = scanResult.$2;
  }
  final enabledModels = providedModels.isNotEmpty
      ? [for (final m in providedModels) _withKnownMetadata(m, known)]
      : (existing != null ? existing.models : scannedCatalog);
  final catalog = _mergeCatalog(existing?.modelCatalog ?? const [], scannedCatalog, enabledModels);
  final catalogUpdatedAt = scannedCatalog.isNotEmpty ? now : existing?.catalogUpdatedAt;

  final enabled = item.containsKey('enabled') ? item['enabled'] == true : (existing?.enabled ?? true);
  final isDefault = item['isDefault'] == true || (existing?.isDefault ?? false);

  final provider = AiProvider(
    id: existing?.id ?? (rawId ?? const Uuid().v4()),
    vendorId: vendorId,
    name: name,
    providerType: providerType,
    baseUrl: baseUrl,
    authMode: authMode,
    accountRouting: existing?.accountRouting ?? AiProvider.defaultAccountRouting,
    accountAffinity: existing?.accountAffinity ?? AiProvider.defaultAccountAffinity,
    apiKeys: apiKeys,
    models: enabledModels,
    modelCatalog: catalog,
    catalogUpdatedAt: catalogUpdatedAt,
    isDefault: isDefault,
    enabled: enabled,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  );
  final saved = await repo.upsert(provider);
  // 密钥池有按厂商的冷却/游标缓存，条目变更后重置，避免沿用旧状态
  ApiKeyPool.instance.reset(saved.id);

  final notes = <String>[?scanNote];
  var effectiveDefault = saved.isDefault;
  if (!effectiveDefault && existing == null) {
    // 首个用户厂商自动设为默认（与设置页「新增首条设默认」行为一致）
    final currentDefault = await repo.getDefault();
    if (currentDefault == null) {
      await repo.setDefault(saved.id);
      effectiveDefault = true;
      notes.add('已设为默认厂商');
    }
  }

  return {
    'id': saved.id,
    'name': saved.name,
    'status': existing == null ? 'created' : 'updated',
    'baseUrl': saved.baseUrl,
    'enabled': saved.enabled,
    'isDefault': effectiveDefault,
    'keyCount': saved.apiKeys.length,
    'models': [for (final m in saved.models) m.id],
    'usable': saved.isUsable,
    if (saved.models.isEmpty)
      'note':
          '未启用任何模型，该厂商不会参与选路'
          '${notes.isEmpty ? '' : '；${notes.join('；')}'}'
    else if (notes.isNotEmpty)
      'note': notes.join('；'),
  };
}

/// 解析条目里的 models 字段：支持字符串数组或 {id, name} 对象数组，按 id 去重
List<AiProviderModel> _parseProviderModels(Map<String, dynamic> item) {
  if (!item.containsKey('models') || item['models'] is! List) return const [];
  final result = <AiProviderModel>[];
  final seen = <String>{};
  for (final m in item['models'] as List) {
    String? id;
    String? name;
    if (m is String) {
      id = m.trim();
    } else if (m is Map<String, dynamic>) {
      id = _nonEmptyString(m['id']);
      name = m['name'] as String?;
    }
    if (id == null || id.isEmpty || seen.contains(id)) continue;
    seen.add(id);
    result.add(AiProviderModel.of(id, name: name));
  }
  return result;
}

/// 扫描厂商可用模型列表；返回 (目录条目, 失败原因)。失败不阻断主流程，
/// 条目仍会保存（例如用户只提供了模型名而服务暂时不可达）
Future<(List<AiProviderModel>, String?)> _scanProviderModels(
  String vendorId,
  AiProviderConfig? spec,
  String baseUrl,
  List<String> apiKeys,
) async {
  final authType = spec?.authType ?? 'bearer';
  final endpoint = (spec?.modelsEndpoint.isNotEmpty ?? false) ? spec!.modelsEndpoint : '/v1/models';
  final fetcher = ModelFetchService();
  List<String>? fetched;
  String? lastError;
  if (authType == 'none' || (apiKeys.isEmpty && vendorAllowsKeyless(vendorId))) {
    try {
      fetched = await fetcher.fetchModels(
        vendorId: vendorId,
        baseUrl: baseUrl,
        apiKey: null,
        authType: 'none',
        modelsEndpoint: endpoint,
      );
    } catch (e) {
      lastError = e.toString();
    }
  } else {
    // 多把密钥依次尝试，与设置页扫描行为一致
    for (final key in apiKeys) {
      try {
        fetched = await fetcher.fetchModels(
          vendorId: vendorId,
          baseUrl: baseUrl,
          apiKey: key,
          authType: authType,
          modelsEndpoint: endpoint,
        );
        break;
      } catch (e) {
        lastError = e.toString();
      }
    }
  }
  if (fetched == null) {
    return (<AiProviderModel>[], '模型扫描失败: ${lastError ?? '未知错误'}');
  }
  final catalog = <AiProviderModel>[];
  final seen = <String>{};
  for (final id in fetched) {
    final trimmed = id.trim();
    if (trimmed.isEmpty || seen.contains(trimmed)) continue;
    seen.add(trimmed);
    catalog.add(AiProviderModel.of(trimmed));
  }
  if (catalog.isEmpty) {
    return (<AiProviderModel>[], '模型扫描成功但结果为空');
  }
  return (catalog, null);
}

/// 同 id 优先复用本地条目（保留用户改过的名称/档位），元数据取最新扫描值
AiProviderModel _withKnownMetadata(AiProviderModel fresh, List<AiProviderModel> known) {
  for (final k in known) {
    if (k.id == fresh.id) return k.withMetadataFrom(fresh);
  }
  return fresh;
}

/// 合并模型目录：旧目录 + 扫描结果 + 本次启用，同 id 以本地为基、元数据取最新
List<AiProviderModel> _mergeCatalog(
  List<AiProviderModel> base,
  List<AiProviderModel> scanned,
  List<AiProviderModel> enabled,
) {
  final byId = <String, AiProviderModel>{for (final m in base) m.id: m};
  for (final m in scanned) {
    byId[m.id] = byId.containsKey(m.id) ? byId[m.id]!.withMetadataFrom(m) : m;
  }
  for (final m in enabled) {
    byId[m.id] = byId.containsKey(m.id) ? byId[m.id]!.withMetadataFrom(m) : m;
  }
  return byId.values.toList();
}

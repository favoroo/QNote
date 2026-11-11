import 'dart:convert';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 厂商条目下的一个模型（已启用列表与扫描目录共用同一结构）
class AiProviderModel {
  /// 发给网关的模型 ID（如 `gpt-5.4-mini`）
  final String id;

  /// 展示名，默认与 [id] 相同，可保留旧配置的自定义名
  final String name;

  /// 思考强度；null 表示「自动」（不额外干预，由模型服务决定）
  final ReasoningEffort? reasoningEffort;

  /// 自定义可选档位；null 表示按模型族自动识别
  ///
  /// 只决定对话面板里出现哪些档位，不决定当前用哪一档。用户可以在模型配置
  /// 里裁掉模型不认的档位，或补上自动识别没覆盖的档位。
  final List<ReasoningEffort>? reasoningEfforts;

  /// 实际生效的计费倍率（0 = 当前免费）；null 表示厂商没给这项信息
  ///
  /// 按积分计费的厂商（小浣熊、Loomy）用倍率决定一次对话花多少额度，
  /// 选模型时必须看得见。只随目录缓存，不参与选路逻辑。
  final num? rate;

  /// 折扣前的原倍率（限时折扣/限免时才有值，用于展示「原 0.5×」）
  final num? rateWas;

  /// 上下文窗口（tokens）；仅用于界面提示
  final int? contextWindow;

  /// 厂商对计费的补充说明（如「限免至11月30日」）
  final String? rateNote;

  /// 厂商 tags 声明的视觉能力；null 表示厂商没声明
  final bool? supportsVision;

  /// 是否生图模型：厂商目录声明（Loomy 的 `output_modalities`）优先，
  /// 没声明时按模型 ID 推断（与 magpie 的 DrawsID 同口径）；null 表示未知
  ///
  /// 只用于展示「生图」徽标和生图角色的候选过滤，不阻止用户手动绑定。
  final bool? supportsImageGeneration;

  const AiProviderModel({
    required this.id,
    required this.name,
    this.reasoningEffort,
    this.reasoningEfforts,
    this.rate,
    this.rateWas,
    this.contextWindow,
    this.rateNote,
    this.supportsVision,
    this.supportsImageGeneration,
  });

  /// 当前是否免费（厂商明说倍率为 0；没给倍率时不算，避免误标「免费」）
  bool get isFree => rate != null && rate == 0;

  /// 是否正在打折（实际倍率低于原倍率）
  bool get hasDiscount => rate != null && rateWas != null && rate! < rateWas!;

  /// 展示名缺省时回落到模型 ID，避免界面出现空标题
  factory AiProviderModel.of(
    String id, {
    String? name,
    ReasoningEffort? reasoningEffort,
    List<ReasoningEffort>? reasoningEfforts,
    num? rate,
    num? rateWas,
    int? contextWindow,
    String? rateNote,
    bool? supportsVision,
    bool? supportsImageGeneration,
  }) {
    final trimmed = (name ?? '').trim();
    return AiProviderModel(
      id: id,
      name: trimmed.isEmpty ? id : trimmed,
      reasoningEffort: reasoningEffort,
      reasoningEfforts: _normalizeEfforts(reasoningEfforts),
      rate: rate,
      rateWas: rateWas,
      contextWindow: contextWindow,
      rateNote: rateNote,
      supportsVision: supportsVision,
      supportsImageGeneration: supportsImageGeneration,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    if (reasoningEffort != null) 'reasoning_effort': reasoningEffort!.wireName,
    if (reasoningEfforts != null) 'reasoning_efforts': [for (final effort in reasoningEfforts!) effort.wireName],
    if (rate != null) 'rate': rate,
    if (rateWas != null) 'rate_was': rateWas,
    if (contextWindow != null) 'context_window': contextWindow,
    if (rateNote != null && rateNote!.isNotEmpty) 'rate_note': rateNote,
    if (supportsVision != null) 'vision': supportsVision,
    if (supportsImageGeneration != null) 'image_gen': supportsImageGeneration,
  };

  factory AiProviderModel.fromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString();
    final note = map['rate_note']?.toString().trim();
    return AiProviderModel.of(
      id,
      name: map['name'] as String?,
      reasoningEffort: ReasoningEffort.tryParse(map['reasoning_effort']?.toString()),
      reasoningEfforts: ReasoningEffort.tryParseList(map['reasoning_efforts']),
      rate: _numOf(map['rate']),
      rateWas: _numOf(map['rate_was']),
      contextWindow: _intOf(map['context_window']),
      rateNote: note == null || note.isEmpty ? null : note,
      supportsVision: map['vision'] is bool ? map['vision'] as bool : null,
      supportsImageGeneration: map['image_gen'] is bool ? map['image_gen'] as bool : null,
    );
  }

  static num? _numOf(dynamic raw) {
    if (raw is num) return raw;
    return num.tryParse(raw?.toString().trim() ?? '');
  }

  static int? _intOf(dynamic raw) => _numOf(raw)?.floor();

  /// 复制并修改思考强度 / 自定义档位
  ///
  /// 用哨兵区分「不传该字段」与「显式置空（恢复自动）」，避免 `copyWith`
  /// 无法清空选择。自定义档位会去重并按由弱到强排序。
  AiProviderModel copyWith({
    Object? reasoningEffort = _unsetReasoningEffort,
    Object? reasoningEfforts = _unsetReasoningEfforts,
  }) {
    return AiProviderModel(
      id: id,
      name: name,
      reasoningEffort: identical(reasoningEffort, _unsetReasoningEffort)
          ? this.reasoningEffort
          : reasoningEffort as ReasoningEffort?,
      reasoningEfforts: identical(reasoningEfforts, _unsetReasoningEfforts)
          ? this.reasoningEfforts
          : _normalizeEfforts(reasoningEfforts as List<ReasoningEffort>?),
      rate: rate,
      rateWas: rateWas,
      contextWindow: contextWindow,
      rateNote: rateNote,
      supportsVision: supportsVision,
      supportsImageGeneration: supportsImageGeneration,
    );
  }

  /// 保留本地的展示名、思考档位与自定义档位，只把计费/能力元数据换成最新扫描结果
  ///
  /// 扫描合并时若整体沿用旧条目，用户改过的名称与档位能留住，但厂商新调的
  /// 倍率、限免说明就永远刷不进来了。
  AiProviderModel withMetadataFrom(AiProviderModel fresh) => AiProviderModel(
    id: id,
    name: name,
    reasoningEffort: reasoningEffort,
    reasoningEfforts: reasoningEfforts,
    rate: fresh.rate,
    rateWas: fresh.rateWas,
    contextWindow: fresh.contextWindow,
    rateNote: fresh.rateNote,
    supportsVision: fresh.supportsVision,
    supportsImageGeneration: fresh.supportsImageGeneration,
  );

  static const Object _unsetReasoningEffort = Object();
  static const Object _unsetReasoningEfforts = Object();

  /// 档位集合归一：去重、按枚举顺序（由弱到强）排序，空集合回落到自动识别
  static List<ReasoningEffort>? _normalizeEfforts(List<ReasoningEffort>? levels) {
    if (levels == null || levels.isEmpty) return null;
    final set = levels.toSet();
    return List.unmodifiable([
      for (final effort in ReasoningEffort.values)
        if (set.contains(effort)) effort,
    ]);
  }

  /// 两个档位集合是否内容一致（顺序已在构造时归一）
  static bool _sameEfforts(List<ReasoningEffort>? a, List<ReasoningEffort>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<AiProviderModel> listFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <AiProviderModel>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final model = AiProviderModel.fromMap(Map<String, dynamic>.from(item));
        if (model.id.isEmpty || !seen.add(model.id)) continue;
        result.add(model);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<AiProviderModel> models) => jsonEncode(models.map((m) => m.toMap()).toList());

  @override
  bool operator ==(Object other) =>
      other is AiProviderModel &&
      other.id == id &&
      other.name == name &&
      other.reasoningEffort == reasoningEffort &&
      _sameEfforts(other.reasoningEfforts, reasoningEfforts);

  @override
  int get hashCode =>
      Object.hash(id, name, reasoningEffort, reasoningEfforts == null ? null : Object.hashAll(reasoningEfforts!));

  @override
  String toString() => 'AiProviderModel($id)';
}

/// 厂商条目：一个 URL + 一组 API Key + 一组已启用模型
///
/// 取代旧版「一个模型 = 一行 `ai_configs`」的模型级配置：密钥与地址属于厂商，
/// 模型只是厂商下的勾选项，因此「同一厂商多把 Key 轮询」与「扫描后按需启用多个
/// 模型」都落在同一条目上，与 CLIProxyAPI 的 provider + api-keys 语义一致。
class AiProvider {
  /// 凭证类型：普通 API Key 池
  static const String authModeApiKey = 'api_key';

  /// 订阅账号登录（商汤小浣熊）：密钥来自账号 token，不写 `api_keys`
  static const String authModeRaccoon = 'raccoon';

  /// 订阅账号登录（AutoClaw 国内版）：手机验证码登录，密钥来自账号 token
  static const String authModeAutoClaw = 'autoclaw';

  /// 订阅账号登录（Loomy 讯飞）：短信登录，session 14 天且无续期接口
  static const String authModeLoomy = 'loomy';

  /// 多账号选号策略默认值（与 [AccountRouting.rotate] 一致，避免模型层依赖枚举）
  static const String defaultAccountRouting = 'rotate';

  /// 会话亲和默认值（与 [AccountAffinity.session] 一致）
  static const String defaultAccountAffinity = 'session';

  final String id;

  /// 指向 `lib/config/models.dart` 的厂商模板（自定义地址为 `custom`）
  final String? vendorId;

  /// 展示名，默认取厂商模板名
  final String name;

  /// 接口类型：`openai` | `gemini`
  final String providerType;

  final String baseUrl;

  /// 凭证类型：`api_key`（默认）、`raccoon` 或 `autoclaw`
  ///
  /// 订阅账号型厂商的 token 由对应的 `AccountAuthService` 在每次发信前现取，
  /// 不落在 `api_keys` 里，也不会随备份导出。
  final String authMode;

  /// 多账号选号策略：`rotate` | `failover` | `smart`
  ///
  /// 只在 [usesAccountAuth] 且登录了 2 个以上账号时才有意义；单账号时
  /// 选号器会直接返回那一个账号。
  final String accountRouting;

  /// 一段对话在同一账号上待多久：`session` | `turn` | `off` | `strict`
  ///
  /// 语义对齐 magpie 的 `Provider.Affinity`：同一对话固定账号能命中厂商侧的
  /// prompt cache，比每个请求都换账号省上下文费用。
  final String accountAffinity;

  /// API Key 池（普通厂商至少一把；订阅账号型为空）
  final List<String> apiKeys;

  /// 已启用模型（会出现在所有模型选择器里）
  final List<AiProviderModel> models;

  /// 最近一次「扫描模型」的结果缓存（含未启用的候选）
  final List<AiProviderModel> modelCatalog;

  final DateTime? catalogUpdatedAt;

  /// 未绑定角色的回落顺序上，默认厂商优先
  final bool isDefault;

  /// 条目是否参与选路：false 表示用户手动「停用」了整个厂商
  ///
  /// 与逐模型停用的区别在于**保留意图**：停用不会动密钥、已启用模型与角色绑定，
  /// 只是把这个条目从选路与选择器里摘出去（例如额度用尽想先晾一阵），再次启用
  /// 即恢复原样。因此判定绑定是否「失效可清理」时不看这个开关。
  final bool enabled;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AiProvider({
    required this.id,
    this.vendorId,
    required this.name,
    required this.providerType,
    required this.baseUrl,
    this.authMode = authModeApiKey,
    this.accountRouting = defaultAccountRouting,
    this.accountAffinity = defaultAccountAffinity,
    required this.apiKeys,
    this.models = const [],
    this.modelCatalog = const [],
    this.catalogUpdatedAt,
    this.isDefault = false,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 是否由订阅账号提供凭证
  bool get usesAccountAuth => authMode != authModeApiKey;

  /// 是否已有可用凭证（账号型交给登录态判断，发信层再校验）
  bool get hasCredentials => usesAccountAuth || apiKeys.any((key) => key.trim().isNotEmpty);

  /// 厂商下是否还有可用的「地址 + 凭证 + 模型」组合（已停用的厂商一律不可用）
  bool get isUsable => enabled && baseUrl.trim().isNotEmpty && hasCredentials && models.isNotEmpty;

  /// 首个已启用模型，作为未绑定角色时的默认选择
  AiProviderModel? get firstModel => models.isEmpty ? null : models.first;

  AiModelRef refFor(String modelName) => AiModelRef(providerId: id, modelName: modelName);

  bool hasModel(String modelName) => models.any((m) => m.id == modelName);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'vendor_id': vendorId,
      'name': name,
      'provider_type': providerType,
      'base_url': baseUrl,
      'auth_mode': authMode,
      'account_routing': accountRouting,
      'account_affinity': accountAffinity,
      'api_keys': jsonEncode(apiKeys),
      'models': AiProviderModel.listToJson(models),
      'model_catalog': AiProviderModel.listToJson(modelCatalog),
      'catalog_updated_at': catalogUpdatedAt?.toIso8601String(),
      'is_default': isDefault ? 1 : 0,
      'enabled': enabled ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AiProvider.fromMap(Map<String, dynamic> map) {
    return AiProvider(
      id: map['id'] as String,
      vendorId: map['vendor_id'] as String?,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? (map['name'] as String).trim()
          : ((map['vendor_id'] as String?) ?? '自定义'),
      providerType: (map['provider_type'] as String?) ?? 'openai',
      baseUrl: (map['base_url'] as String?) ?? '',
      authMode: (map['auth_mode'] as String?)?.trim().isNotEmpty == true
          ? (map['auth_mode'] as String).trim()
          : authModeApiKey,
      accountRouting: (map['account_routing'] as String?)?.trim().isNotEmpty == true
          ? (map['account_routing'] as String).trim()
          : defaultAccountRouting,
      accountAffinity: (map['account_affinity'] as String?)?.trim().isNotEmpty == true
          ? (map['account_affinity'] as String).trim()
          : defaultAccountAffinity,
      apiKeys: _decodeKeys(map['api_keys']),
      models: AiProviderModel.listFromJson(map['models'] as String?),
      modelCatalog: AiProviderModel.listFromJson(map['model_catalog'] as String?),
      catalogUpdatedAt: _parseTime(map['catalog_updated_at'] as String?),
      isDefault: (map['is_default'] as int? ?? 0) == 1,
      // 缺列（老库/旧备份）时按「启用」处理，避免升级后所有厂商集体失效
      enabled: (map['enabled'] as int? ?? 1) == 1,
      createdAt: _parseTime(map['created_at'] as String?) ?? DateTime.now(),
      updatedAt: _parseTime(map['updated_at'] as String?) ?? DateTime.now(),
    );
  }

  AiProvider copyWith({
    String? id,
    Object? vendorId = _unset,
    String? name,
    String? providerType,
    String? baseUrl,
    String? authMode,
    String? accountRouting,
    String? accountAffinity,
    List<String>? apiKeys,
    List<AiProviderModel>? models,
    List<AiProviderModel>? modelCatalog,
    Object? catalogUpdatedAt = _unset,
    bool? isDefault,
    bool? enabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AiProvider(
      id: id ?? this.id,
      vendorId: identical(vendorId, _unset) ? this.vendorId : vendorId as String?,
      name: name ?? this.name,
      providerType: providerType ?? this.providerType,
      baseUrl: baseUrl ?? this.baseUrl,
      authMode: authMode ?? this.authMode,
      accountRouting: accountRouting ?? this.accountRouting,
      accountAffinity: accountAffinity ?? this.accountAffinity,
      apiKeys: apiKeys ?? this.apiKeys,
      models: models ?? this.models,
      modelCatalog: modelCatalog ?? this.modelCatalog,
      catalogUpdatedAt: identical(catalogUpdatedAt, _unset) ? this.catalogUpdatedAt : catalogUpdatedAt as DateTime?,
      isDefault: isDefault ?? this.isDefault,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const Object _unset = Object();

  static List<String> _decodeKeys(dynamic raw) {
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is! List) return const [];
      final keys = <String>[];
      for (final item in decoded) {
        final key = item?.toString().trim() ?? '';
        if (key.isNotEmpty && !keys.contains(key)) keys.add(key);
      }
      return keys;
    } catch (_) {
      return const [];
    }
  }

  static DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 旧备份/旧库里的 `ai_configs` 行 → 厂商条目（同 URL 归并密钥与模型）
  ///
  /// 迁移与「导入旧格式备份」共用这一条路径，保证两种来源得到一致结果。
  static List<AiProvider> fromLegacyConfigMaps(List<Map<String, dynamic>> configs) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    final order = <String>[];
    for (final map in configs) {
      final vendorId = (map['vendor_id'] as String?)?.trim() ?? '';
      final baseUrl = ((map['base_url'] as String?) ?? '').trim();
      final providerType = ((map['provider'] as String?) ?? 'openai').trim();
      final groupKey = '${vendorId.isEmpty ? 'custom' : vendorId}|$baseUrl|$providerType';
      if (!grouped.containsKey(groupKey)) {
        grouped[groupKey] = [];
        order.add(groupKey);
      }
      grouped[groupKey]!.add(map);
    }

    final providers = <AiProvider>[];
    for (final groupKey in order) {
      final rows = grouped[groupKey]!;
      final first = rows.first;
      final keys = <String>[];
      final models = <AiProviderModel>[];
      final modelIds = <String>{};
      var isDefault = false;
      DateTime? createdAt;
      DateTime? updatedAt;

      for (final row in rows) {
        final key = ((row['api_key'] as String?) ?? '').trim();
        if (key.isNotEmpty && !keys.contains(key)) keys.add(key);

        final modelName = ((row['model_name'] as String?) ?? '').trim();
        if (modelName.isNotEmpty && modelIds.add(modelName)) {
          models.add(AiProviderModel.of(modelName, name: row['name'] as String?));
        }

        if ((row['is_default'] as int? ?? 0) == 1) isDefault = true;
        final rowCreated = _parseTime(row['created_at'] as String?);
        if (rowCreated != null && (createdAt == null || rowCreated.isBefore(createdAt))) {
          createdAt = rowCreated;
        }
        final rowUpdated = _parseTime(row['updated_at'] as String?);
        if (rowUpdated != null && (updatedAt == null || rowUpdated.isAfter(updatedAt))) {
          updatedAt = rowUpdated;
        }
      }

      if (keys.isEmpty && models.isEmpty) continue;

      final vendorId = (first['vendor_id'] as String?)?.trim();
      providers.add(
        AiProvider(
          id: (first['id'] as String?) ?? '',
          vendorId: (vendorId == null || vendorId.isEmpty) ? 'custom' : vendorId,
          name: vendorId == null || vendorId.isEmpty ? '自定义服务' : vendorId,
          providerType: ((first['provider'] as String?) ?? 'openai'),
          baseUrl: ((first['base_url'] as String?) ?? '').trim(),
          apiKeys: keys,
          models: models,
          isDefault: isDefault,
          createdAt: createdAt ?? DateTime.now(),
          updatedAt: updatedAt ?? createdAt ?? DateTime.now(),
        ),
      );
    }
    return providers;
  }
}

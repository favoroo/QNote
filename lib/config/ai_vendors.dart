/// 厂商模板目录：一个厂商 = 一个接口协议 + 一套（或多套）官方地址 + 一批种子模型
///
/// 口径对齐 magpie 的 `internal/provider/presets.go`（58 个 preset，四类分组 +
/// 图标 + 每协议独立 base URL）与 models.dev 的厂商目录；地址与型号 ID 均以这两处
/// 为准，不要凭印象新增。App 侧只保留「能用 OpenAI 兼容 / Anthropic / Gemini
/// 三种协议直连」的厂商，需要 OAuth（Vertex ADC）、SigV4（Bedrock）、自填
/// resource（Azure）的复杂接入不在内。
///
/// 字段约定：
/// - [AiProviderConfig.provider] 是接口协议（`openai` / `anthropic` / `gemini`），
///   与「厂商」是两个维度：同一厂商可能只支持其中一种；
/// - [AiProviderConfig.regions] 表达「同一厂商多套端点」（国内/国际、按量/套餐），
///   由编辑页的选择器切换 baseUrl，而不是拆成多个厂商条目；
/// - [AiProviderConfig.icon] 是 `assets/images/vendors/` 下的图标文件名（不含扩展名），
///   空串表示无官方图标，界面回落到名称首字母。
library;

/// 厂商分组：驱动「添加模型服务」选择器的分区与筛选 chips
///
/// 顺序即展示顺序：先按凭证类型（账号登录 / API Key），再按地理与服务形态。
enum VendorCategory {
  account('account', '账号登录', '登录账号即可使用，Token 由账号额度提供'),
  cn('cn', '国内厂商', '厂商自有接口，密钥在其控制台申请'),
  intl('intl', '国际厂商', '官方接口，通常需要海外网络环境'),
  relay('relay', '聚合中转', '一把密钥调用多家模型'),
  local('local', '本地部署', '跑在本机的推理服务，通常无需密钥'),
  custom('custom', '自定义', '自建或未收录的服务，手动填写地址与协议');

  const VendorCategory(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static VendorCategory fromId(String? id) =>
      values.firstWhere((category) => category.id == id, orElse: () => VendorCategory.custom);
}

/// 厂商模板下的一套端点（地区 / 套餐 / 按量）
///
/// 同一个厂商的不同端点可能连协议都不同（如 GLM 的按量与编码套餐走的都是
/// OpenAI 兼容，但火山方舟的 Coding Plan 另有 Anthropic 入口），因此允许
/// [provider] 覆盖模板级协议；为空表示沿用模板的 [AiProviderConfig.provider]。
class AiVendorRegion {
  final String id;
  final String name;
  final String baseUrl;
  final String? provider;

  const AiVendorRegion({required this.id, required this.name, required this.baseUrl, this.provider});
}

class AiProviderConfig {
  final String id;
  final String name;
  final String provider;
  final String defaultBaseUrl;
  final bool urlRequired;
  final String placeholder;
  final List<String> models;
  final bool supportsSse;

  // 新增字段
  final String modelsEndpoint; // 模型列表接口路径
  final String authType; // 'bearer' | 'query' | 'none' | 'x_api_key'
  final bool requiresApiKeyForFetch; // 获取模型列表是否需要 API Key
  final String? defaultReasoningEffort; // 默认推理强度（low/medium/high/none）

  /// 凭证类型：`api_key`（默认）、`raccoon`、`autoclaw` 或 `loomy`（订阅账号登录）
  final String authMode;

  /// 分组：决定选择器的分区、筛选与排序
  final VendorCategory category;

  /// 图标文件名（`assets/images/vendors/<icon>.svg`），空串表示无图标
  final String icon;

  /// 一行补充说明（选择器卡片与编辑页展示）
  final String note;

  /// 是否允许不填密钥（本机服务与免密钥网关）
  final bool keyOptional;

  /// 多端点：为空表示只有 [defaultBaseUrl] 一套
  final List<AiVendorRegion> regions;

  /// 端点选择器的标题（如「套餐」「地区」），为空时用「接入点」
  final String regionLabel;

  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.provider,
    required this.defaultBaseUrl,
    this.urlRequired = true,
    this.placeholder = '请输入模型名称或从下拉列表选择',
    required this.models,
    this.supportsSse = true,
    this.modelsEndpoint = '',
    this.authType = 'bearer',
    this.requiresApiKeyForFetch = true,
    this.defaultReasoningEffort,
    this.authMode = 'api_key',
    this.category = VendorCategory.custom,
    this.icon = '',
    this.note = '',
    this.keyOptional = false,
    this.regions = const [],
    this.regionLabel = '',
  });

  /// 端点选择器的标题，未声明时用一个中性词
  String get regionTitle => regionLabel.isEmpty ? '接入点' : regionLabel;

  /// 与某个地址对应的端点；没有声明多端点或都不匹配时返回 null
  ///
  /// 比较时忽略末尾斜杠：老条目的 GLM 地址带尾斜杠（`.../v4/`），
  /// 而端点声明不带，不归一化会让选择器认不出当前选的是哪一套。
  AiVendorRegion? regionFor(String baseUrl) {
    final target = _normalizeUrl(baseUrl);
    if (target.isEmpty) return null;
    for (final region in regions) {
      if (_normalizeUrl(region.baseUrl) == target) return region;
    }
    return null;
  }

  static String _normalizeUrl(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');
}

/// 全部厂商模板，顺序即选择器中的展示顺序
final aiProviders = <AiProviderConfig>[
  // ── 账号登录（订阅凭证，不填 API Key）────────────────────────
  const AiProviderConfig(
    id: 'raccoon',
    name: '商汤小浣熊',
    category: VendorCategory.account,
    provider: 'openai',
    defaultBaseUrl: 'https://xiaohuanxiong.com/api/web/llm/v2',
    models: [
      'raccoon-8c4485',
      'sn-sensenova-6-8-flash',
      'sn-sensenova-6-8-flash-lite',
      'sn-glm-5-3',
      'sn-kimi-k3',
      'sn-glm-5-3-flash',
      'sn-deepseek-v4-1-flash',
      'raccoon-chat-ml-5-5',
    ],
    modelsEndpoint: '/model_catalog',
    authType: 'bearer',
    requiresApiKeyForFetch: false,
    authMode: 'raccoon',
    note: '账号登录 · 按积分计费',
  ),
  const AiProviderConfig(
    id: 'autoclaw-cn',
    name: 'AutoClaw（智谱·国内）',
    category: VendorCategory.account,
    provider: 'openai',
    icon: 'chatglm-color',
    // 对话基址固定走国内积分制通道；发信层再拼 chat/completions
    defaultBaseUrl: 'https://autoglm-acceleration-api.zhipuai.cn/autoclaw-proxy/proxy/autoclaw',
    models: ['zai_auto', 'zai_auto-fast', 'zaicoding_glm-5.3', 'zai_glm-5.3-flash'],
    modelsEndpoint: '',
    authType: 'bearer',
    requiresApiKeyForFetch: false,
    authMode: 'autoclaw',
    note: '账号登录 · 手机验证码',
  ),
  const AiProviderConfig(
    id: 'loomy',
    name: 'Loomy（讯飞）',
    category: VendorCategory.account,
    provider: 'openai',
    icon: 'spark-color',
    // 聊天与生图都在同一个网关；发信层再拼 chat/completions、images/generations
    defaultBaseUrl: 'https://loomyad.xunfei.cn/api/v1',
    models: [
      'DeepSeek-V4.1-Flash',
      'deepseek-v4-flash-0731',
      'MiniMax-M3',
      'Kimi-k2.6',
      'qwen-3.8-max',
      'GLM-5.3-Flash',
      'qwen3.8-flash',
      'spark-x',
      'mimo-v2.5',
      'auto',
    ],
    modelsEndpoint: '',
    authType: 'bearer',
    requiresApiKeyForFetch: false,
    authMode: 'loomy',
    note: '账号登录 · 短信验证码',
  ),

  // ── 国内厂商 ────────────────────────────────────────────────
  const AiProviderConfig(
    id: 'deepseek',
    name: 'DeepSeek',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'deepseek-color',
    defaultBaseUrl: 'https://api.deepseek.com',
    models: [
      'deepseek-v4-pro',
      'deepseek-v4-flash',
      'deepseek-flash',
      'deepseek-v3.2',
      'deepseek-chat',
      'deepseek-reasoner',
    ],
    modelsEndpoint: '/v1/models',
    note: '官方接口',
  ),
  const AiProviderConfig(
    id: 'qwen',
    name: 'Qwen（通义千问）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'qwen-color',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    models: ['qwen3.8-max', 'qwen3.8-flash', 'qwen3.7-max', 'qwen3.7-plus', 'qwen3.6-flash', 'qwen3-vl-30b-a3b'],
    modelsEndpoint: '/v1/models',
    note: '阿里云百炼 DashScope 兼容模式',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
      AiVendorRegion(id: 'intl', name: '国际', baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'zhipu',
    name: 'GLM（智谱）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'zhipu-color',
    defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4/',
    models: ['glm-4.7', 'glm-4.7-flash', 'glm-4.6v', 'glm-4.5-air', 'glm-5.3', 'glm-5'],
    modelsEndpoint: '/api/paas/v4/models',
    note: '智谱开放平台',
    regionLabel: '套餐',
    regions: [
      AiVendorRegion(id: 'api', name: '按量付费', baseUrl: 'https://open.bigmodel.cn/api/paas/v4'),
      AiVendorRegion(id: 'coding', name: '编码套餐', baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4'),
    ],
  ),
  const AiProviderConfig(
    id: 'zai',
    name: 'GLM（Z.ai 国际站）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'zai',
    defaultBaseUrl: 'https://api.z.ai/api/paas/v4',
    models: ['glm-4.7', 'glm-4.7-flash', 'glm-4.6v', 'glm-4.5-air', 'glm-5.3', 'glm-5'],
    modelsEndpoint: '/api/paas/v4/models',
    note: '智谱国际站 · 通常需要海外网络',
    regionLabel: '套餐',
    regions: [
      AiVendorRegion(id: 'api', name: '按量付费', baseUrl: 'https://api.z.ai/api/paas/v4'),
      AiVendorRegion(id: 'coding', name: '编码套餐', baseUrl: 'https://api.z.ai/api/coding/paas/v4'),
    ],
  ),
  const AiProviderConfig(
    id: 'moonshot',
    name: 'Kimi（Moonshot）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'kimi',
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
    models: ['kimi-k3.1-pro', 'kimi-k3', 'kimi-k2.7-code', 'kimi-k2.6', 'kimi-k2.5', 'kimi-k2'],
    modelsEndpoint: '/v1/models',
    note: '月之暗面开放平台',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://api.moonshot.cn/v1'),
      AiVendorRegion(id: 'intl', name: '国际', baseUrl: 'https://api.moonshot.ai/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'minimax',
    name: 'MiniMax',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'minimax-color',
    defaultBaseUrl: 'https://api.minimaxi.com/v1',
    models: [
      'MiniMax-M3',
      'MiniMax-M3.1-Flash',
      'MiniMax-M2.7',
      'MiniMax-M2.7-highspeed',
      'MiniMax-M2.5',
      'MiniMax-M2.1',
    ],
    modelsEndpoint: '/v1/models',
    note: '稀宇科技开放平台',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://api.minimaxi.com/v1'),
      AiVendorRegion(id: 'intl', name: '国际', baseUrl: 'https://api.minimax.io/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'mimo',
    name: 'MiMo（小米）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'mimocode',
    defaultBaseUrl: 'https://api.xiaomimimo.com/v1',
    models: ['mimo-v2.6-pro', 'mimo-v2.6-flash', 'mimo-v2.5-pro', 'mimo-v2.5', 'mimo-v2.5-tts', 'mimo-v2-omni'],
    modelsEndpoint: '/v1/models',
    note: '小米 MiMo 开放平台',
  ),
  const AiProviderConfig(
    id: 'longcat',
    name: 'LongCat（美团）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'longcat',
    defaultBaseUrl: 'https://api.longcat.chat/openai/v1',
    models: [
      'LongCat-Flash-Chat',
      'LongCat-Flash-Thinking-2601',
      'LongCat-2.5-Preview',
      'LongCat-2.0',
      'LongCat-Flash-Omni-2603',
      'LongCat-Flash-Lite',
    ],
    modelsEndpoint: '/v1/models',
    note: '美团 LongCat 开放接口',
  ),
  const AiProviderConfig(
    id: 'sensenova',
    name: 'SenseNova（商汤）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'sensenova-color',
    defaultBaseUrl: 'https://token.sensenova.cn/v1',
    models: ['sensenova-6.8-flash-lite', 'deepseek-v4.1-flash', 'deepseek-v4-pro', 'deepseek-v4-flash', 'glm-5.2'],
    modelsEndpoint: '/v1/models',
    defaultReasoningEffort: 'none',
    note: '商汤日日新 Token 服务',
  ),
  const AiProviderConfig(
    id: 'volcengine',
    name: '火山方舟（豆包）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'volcengine-color',
    defaultBaseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    models: [
      'doubao-seed-2-1-pro-260628',
      'doubao-seed-2-1-lite-260428',
      'doubao-seed-2-1-turbo-260628',
      'doubao-seed-2-0-code-preview-260215',
      'deepseek-v4-pro-ga-260813',
    ],
    modelsEndpoint: '/api/v3/models',
    note: '字节跳动火山方舟 · 豆包与第三方模型',
    regionLabel: '套餐',
    regions: [
      AiVendorRegion(id: 'api', name: '按量付费', baseUrl: 'https://ark.cn-beijing.volces.com/api/v3'),
      AiVendorRegion(id: 'coding', name: 'Coding Plan', baseUrl: 'https://ark.cn-beijing.volces.com/api/coding/v3'),
    ],
  ),
  const AiProviderConfig(
    id: 'stepfun',
    name: '阶跃星辰 StepFun',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'stepfun-color',
    defaultBaseUrl: 'https://api.stepfun.com/v1',
    models: ['step-3.7-flash', 'step-3.5-flash', 'step-3.5-flash-2603', 'step-5-preview'],
    modelsEndpoint: '/v1/models',
    note: '阶跃星辰开放平台',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://api.stepfun.com/v1'),
      AiVendorRegion(id: 'intl', name: '国际', baseUrl: 'https://api.stepfun.ai/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'tencent-cloud',
    name: '腾讯云 TokenHub',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'tencentcloud-color',
    defaultBaseUrl: 'https://tokenhub.tencentmaas.com/v1',
    models: ['hy4', 'hy4-preview', 'hy3', 'hy3-preview'],
    modelsEndpoint: '/v1/models',
    note: '腾讯云 · 一把密钥调用多家模型',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://tokenhub.tencentmaas.com/v1'),
      AiVendorRegion(id: 'intl', name: '国际', baseUrl: 'https://tokenhub-intl.tencentmaas.com/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'baidu-qianfan',
    name: '百度千帆（文心）',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'baiducloud-color',
    defaultBaseUrl: 'https://qianfan.baidubce.com/v2',
    models: ['qianfan-code-latest', 'deepseek-v4-pro', 'deepseek-v4-flash-0731', 'glm-5.3', 'glm-5.3-flash'],
    modelsEndpoint: '/v2/models',
    note: '百度智能云千帆 · 文心与第三方模型',
    regionLabel: '套餐',
    regions: [
      AiVendorRegion(id: 'api', name: '按量付费', baseUrl: 'https://qianfan.baidubce.com/v2'),
      AiVendorRegion(
        id: 'personal',
        name: 'Token Plan 个人版',
        baseUrl: 'https://qianfan.baidubce.com/v2/tokenplan/personal',
      ),
      AiVendorRegion(id: 'team', name: 'Token Plan 企业版', baseUrl: 'https://qianfan.baidubce.com/v2/tokenplan/team'),
    ],
  ),
  const AiProviderConfig(
    id: 'huawei-cloud',
    name: '华为云 MaaS',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'huaweicloud-color',
    defaultBaseUrl: 'https://api.modelarts-maas.com/openai/v1',
    models: ['glm-5.3', 'glm-5.1', 'kimi-k2.6', 'deepseek-v4.1-flash', 'deepseek-v4-flash'],
    modelsEndpoint: '',
    note: '华为云 ModelArts Studio',
    regionLabel: '套餐',
    regions: [
      AiVendorRegion(id: 'api', name: '按量付费', baseUrl: 'https://api.modelarts-maas.com/openai/v1'),
      AiVendorRegion(id: 'plan', name: 'Token Plan', baseUrl: 'https://api.modelarts-maas.com/plan/v2'),
    ],
  ),
  const AiProviderConfig(
    id: 'siliconflow',
    name: '硅基流动 SiliconFlow',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'siliconcloud-color',
    defaultBaseUrl: 'https://api.siliconflow.cn/v1',
    models: [
      'Pro/moonshotai/Kimi-K2.6',
      'Pro/deepseek-ai/DeepSeek-V3.2',
      'zai-org/GLM-5',
      'Qwen/Qwen3-VL-32B-Instruct',
      'stepfun-ai/Step-3.5-Flash',
    ],
    modelsEndpoint: '/v1/models',
    note: '硅基流动 · 多厂商开源模型聚合',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://api.siliconflow.cn/v1'),
      AiVendorRegion(id: 'intl', name: '国际', baseUrl: 'https://api.siliconflow.com/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'modelscope',
    name: '魔搭 ModelScope',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'modelscope-color',
    defaultBaseUrl: 'https://api-inference.modelscope.cn/v1',
    models: [
      'Qwen/Qwen3-235B-A22B-Instruct-2507',
      'ZhipuAI/GLM-4.6',
      'Qwen/Qwen3-Coder-30B-A3B-Instruct',
      'deepseek-ai/DeepSeek-V3.2',
    ],
    modelsEndpoint: '/v1/models',
    note: '魔搭 API-Inference · 用访问令牌当密钥',
  ),
  const AiProviderConfig(
    id: 'qiniu',
    name: '七牛云 AI',
    category: VendorCategory.cn,
    provider: 'openai',
    icon: 'qiniu-color',
    defaultBaseUrl: 'https://api.qnaigc.com/v1',
    models: ['qwen3-max', 'deepseek-v3', 'doubao-seed-1.6', 'glm-4.5', 'claude-4.5-opus'],
    modelsEndpoint: '/v1/models',
    note: '七牛云 AI 推理 · 多厂商模型聚合',
  ),
  const AiProviderConfig(
    id: 'ant-ling',
    name: '蚂蚁百灵 (AntLing)',
    category: VendorCategory.cn,
    provider: 'openai',
    defaultBaseUrl: 'https://api.ant-ling.com/v1',
    urlRequired: true,
    placeholder: '请输入模型名称，或从下拉列表选择',
    models: ['Ling-2.6-flash', 'Ling-2.5-1T', 'Ring-2.6-1T', 'Ring-2.5-1T', 'Ming-Flash-Omni-2.0', 'Ming-lite-omni'],
    modelsEndpoint: '',
    note: '蚂蚁百灵官方接口',
  ),
  const AiProviderConfig(
    id: 'agnes',
    name: 'Agnes AI',
    category: VendorCategory.cn,
    provider: 'openai',
    defaultBaseUrl: 'https://apihub.agnes-ai.com/v1',
    urlRequired: true,
    models: ['agnes-2.0-flash', 'agnes-1.5-flash', 'agnes-image-2.1-flash', 'agnes-image-2.0-flash', 'agnes-video-2.0'],
    modelsEndpoint: '/v1/models',
    note: 'Agnes AI 官方接口',
  ),
  const AiProviderConfig(
    id: 'chatanywhere',
    name: 'ChatAnywhere',
    category: VendorCategory.cn,
    provider: 'openai',
    defaultBaseUrl: 'https://api.chatanywhere.tech/v1',
    urlRequired: true,
    placeholder: '请输入模型名称，或点击「获取模型列表」',
    models: ['gpt-3.5-turbo', 'gpt-4o-mini', 'gpt-4o', 'deepseek-chat', 'deepseek-coder'],
    modelsEndpoint: '/models',
    note: '第三方中转 · 低价 GPT 通道',
    regionLabel: '地区',
    regions: [
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://api.chatanywhere.tech/v1'),
      AiVendorRegion(id: 'intl', name: '国外', baseUrl: 'https://api.chatanywhere.org/v1'),
    ],
  ),

  // ── 国际厂商 ────────────────────────────────────────────────
  const AiProviderConfig(
    id: 'openai',
    name: 'OpenAI',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'openai',
    defaultBaseUrl: 'https://api.openai.com/v1',
    models: ['gpt-5.6', 'gpt-5.6-luna', 'gpt-5.4-mini', 'gpt-5.3-codex', 'gpt-5.2-pro'],
    modelsEndpoint: '/v1/models',
    note: '官方接口',
  ),
  const AiProviderConfig(
    id: 'anthropic',
    name: 'Anthropic（Claude）',
    category: VendorCategory.intl,
    provider: 'anthropic',
    icon: 'claude-color',
    defaultBaseUrl: 'https://api.anthropic.com',
    models: ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-opus-4-7', 'claude-haiku-4-5', 'claude-sonnet-4-5'],
    modelsEndpoint: '/v1/models',
    // Messages 接口用 x-api-key 鉴权，不走 Bearer
    authType: 'x_api_key',
    note: 'Claude 官方 Messages 接口',
  ),
  const AiProviderConfig(
    id: 'gemini',
    name: 'Gemini（Google）',
    category: VendorCategory.intl,
    provider: 'gemini',
    icon: 'gemini-color',
    defaultBaseUrl: '',
    urlRequired: false,
    placeholder: '内置官方接口，无需填写URL(或填写自定义url)',
    models: [
      'gemini-3.5-flash',
      'gemini-3.1-pro',
      'gemini-3.1-flash-lite',
      'gemini-3-flash-preview',
      'gemini-flash-latest',
      'gemini-flash-lite-latest',
      'gemini-pro-latest',
      'gemma-4-31b-it',
      'gemma-4-26b-a4b-it',
    ],
    modelsEndpoint: '/v1beta/models',
    authType: 'query',
    note: '原生 Gemini 协议',
  ),
  const AiProviderConfig(
    id: 'xai',
    name: 'xAI（Grok）',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'xai',
    defaultBaseUrl: 'https://api.x.ai/v1',
    models: ['grok-4.7', 'grok-4.6', 'grok-4.5', 'grok-4.3', 'grok-build-0.1'],
    modelsEndpoint: '/v1/models',
    note: 'Grok 官方接口',
  ),
  const AiProviderConfig(
    id: 'mistral',
    name: 'Mistral',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'mistral-color',
    defaultBaseUrl: 'https://api.mistral.ai/v1',
    models: [
      'mistral-large-2512',
      'mistral-medium-2604',
      'mistral-small-latest',
      'devstral-latest',
      'ministral-8b-2512',
    ],
    modelsEndpoint: '/v1/models',
    note: 'Mistral 官方接口',
  ),
  const AiProviderConfig(
    id: 'groq',
    name: 'Groq',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'groq',
    defaultBaseUrl: 'https://api.groq.com/openai/v1',
    models: ['openai/gpt-oss-120b', 'openai/gpt-oss-20b', 'llama-3.3-70b-versatile', 'qwen/qwen3.8-27b'],
    modelsEndpoint: '/v1/models',
    note: '极速推理，托管多家开源模型',
  ),
  const AiProviderConfig(
    id: 'together',
    name: 'Together AI',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'together-color',
    defaultBaseUrl: 'https://api.together.xyz/v1',
    models: ['moonshotai/Kimi-K3', 'Qwen/Qwen3.7-Max', 'openai/gpt-oss-120b', 'meta-models/Muse-Spark-Open-816B-A42B'],
    modelsEndpoint: '/v1/models',
    note: '托管开源模型',
  ),
  const AiProviderConfig(
    id: 'fireworks',
    name: 'Fireworks',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'fireworks-color',
    defaultBaseUrl: 'https://api.fireworks.ai/inference/v1',
    models: [
      'accounts/fireworks/routers/kimi-k3-fast',
      'accounts/fireworks/routers/glm-5p3-spot',
      'accounts/fireworks/routers/deepseek-v4p1-flash-spot',
      'accounts/fireworks/routers/qwen-max-latest',
    ],
    modelsEndpoint: '/v1/models',
    note: '托管开源模型',
  ),
  const AiProviderConfig(
    id: 'nvidia',
    name: 'NVIDIA NIM',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'nvidia-color',
    defaultBaseUrl: 'https://integrate.api.nvidia.com/v1',
    models: ['meta/muse-glimmer-30b', 'minimaxai/minimax-m3.1-flash', 'meta/llama-3.2-90b-vision-instruct'],
    modelsEndpoint: '/v1/models',
    note: 'NVIDIA 托管 NIM 端点',
  ),
  const AiProviderConfig(
    id: 'deepinfra',
    name: 'DeepInfra',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'deepinfra-color',
    defaultBaseUrl: 'https://api.deepinfra.com/v1/openai',
    models: [
      'anthropic/claude-fable-5',
      'Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo',
      'XiaomiMiMo/MiMo-V2.6-Pro',
      'ByteDance/Seed-2.0-pro',
    ],
    modelsEndpoint: '/v1/openai/models',
    note: '托管开源模型',
  ),
  const AiProviderConfig(
    id: 'novita',
    name: 'Novita AI',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'novita-color',
    defaultBaseUrl: 'https://api.novita.ai/openai',
    models: ['qwen/qwen3.8-max', 'qwen/qwen3.7-max', 'qwen/qwen3.5-397b-a17b', 'qwen/qwen3.8-27b'],
    modelsEndpoint: '/openai/models',
    note: '托管开源模型',
  ),
  const AiProviderConfig(
    id: 'cerebras',
    name: 'Cerebras',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'cerebras',
    defaultBaseUrl: 'https://api.cerebras.ai/v1',
    models: ['qwen-3.8-27b', 'gpt-oss-120b'],
    modelsEndpoint: '/v1/models',
    note: '晶圆级推理，速度极快',
  ),
  const AiProviderConfig(
    id: 'ollama-cloud',
    name: 'Ollama Cloud',
    category: VendorCategory.intl,
    provider: 'openai',
    icon: 'ollama',
    defaultBaseUrl: 'https://ollama.com/v1',
    models: ['kimi-k3.1-pro', 'deepseek-v4-pro:0813', 'minimax-m3.1-flash', 'gpt-oss:120b', 'nemotron-3-super'],
    modelsEndpoint: '/v1/models',
    note: 'Ollama 官方云托管模型',
  ),

  // ── 聚合中转 ────────────────────────────────────────────────
  const AiProviderConfig(
    id: 'openrouter',
    name: 'OpenRouter',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'openrouter',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    urlRequired: false,
    placeholder: '请输入模型名称 (例如 anthropic/claude-3-opus)',
    models: [
      'inclusionai/ring-2.6-1t:free',
      'nvidia/nemotron-3-super-120b-a12b:free',
      'poolside/laguna-m.1:free',
      'openai/gpt-oss-120b:free',
      'z-ai/glm-4.5-air:free',
      'minimax/minimax-m2.5:free',
      'nvidia/nemotron-3-nano-30b-a3b:free',
      'google/gemma-4-31b-it:free',
      'nvidia/nemotron-nano-12b-v2-vl:free',
      'nvidia/nemotron-nano-9b-v2:free',
    ],
    modelsEndpoint: '/api/frontend/models/find?active=true&fmt=cards&q=free',
    authType: 'none',
    requiresApiKeyForFetch: false,
    note: '全球最大模型聚合站',
  ),
  const AiProviderConfig(
    id: 'aihubmix',
    name: 'AiHubMix',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'aihubmix-color',
    defaultBaseUrl: 'https://aihubmix.com/v1',
    models: ['gpt-6-sol', 'claude-opus-4-7-think', 'gemini-3-flash-preview', 'qwen3-max', 'deepseek-v3.2'],
    modelsEndpoint: '/v1/models',
    note: '一把密钥调用多家模型',
  ),
  const AiProviderConfig(
    id: 'newapi',
    name: '自建中转（New API / One API）',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'newapi-color',
    defaultBaseUrl: '',
    urlRequired: true,
    placeholder: '如 https://api.example.com/v1',
    models: [],
    modelsEndpoint: '/v1/models',
    note: '自建中转站，需填自己的地址',
  ),
  const AiProviderConfig(
    id: '302ai',
    name: '302.AI',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'ai302-color',
    defaultBaseUrl: 'https://api.302.ai/v1',
    models: ['gpt-6-sol', 'claude-opus-4-7', 'gemini-3.6-flash', 'qwen3.7-plus', 'kimi-k2.7-code'],
    modelsEndpoint: '/v1/models',
    note: '按量付费的中转聚合',
  ),
  const AiProviderConfig(
    id: 'cherryin',
    name: 'CherryIN',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'cherryin-color',
    defaultBaseUrl: 'https://open.cherryin.ai/v1',
    models: ['claude-opus-4-7', 'gpt-5.6', 'gemini-3.6-flash', 'deepseek-v3.2'],
    modelsEndpoint: '/v1/models',
    note: 'Cherry Studio 官方中转',
  ),
  const AiProviderConfig(
    id: 'yylx',
    name: '鱼鱼连线',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'yylx',
    defaultBaseUrl: 'https://app.yylx.io/v1',
    models: ['claude-opus-4-7', 'gpt-5.6', 'gemini-3.6-flash'],
    modelsEndpoint: '/v1/models',
    note: '按量付费的中转聚合',
    regionLabel: '线路',
    regions: [
      AiVendorRegion(id: 'auto', name: '自动', baseUrl: 'https://app.yylx.io/v1'),
      AiVendorRegion(id: 'global', name: '国际', baseUrl: 'https://global.yylx.io/v1'),
      AiVendorRegion(id: 'cn', name: '国内', baseUrl: 'https://cn.yylx.io/v1'),
    ],
  ),
  const AiProviderConfig(
    id: 'kilo',
    name: 'Kilo Gateway',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'kilo',
    defaultBaseUrl: 'https://api.kilo.ai/api/openrouter',
    models: ['anthropic/claude-sonnet-5', 'openai/gpt-5.6', 'z-ai/glm-5.3', 'moonshotai/kimi-k3'],
    modelsEndpoint: '',
    requiresApiKeyForFetch: false,
    keyOptional: true,
    note: '免费模型无需密钥',
  ),
  const AiProviderConfig(
    id: 'opencode-zen',
    name: 'OpenCode Zen',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'opencode',
    defaultBaseUrl: 'https://opencode.ai/zen/v1',
    models: ['claude-opus-4-5', 'gpt-5.6-luna', 'qwen3-coder', 'glm-4.7-free', 'minimax-m2.1-free'],
    modelsEndpoint: '/v1/models',
    requiresApiKeyForFetch: false,
    keyOptional: true,
    note: '免费模型无需密钥',
  ),
  const AiProviderConfig(
    id: 'clinepass',
    name: 'ClinePass',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'cline',
    defaultBaseUrl: 'https://api.cline.bot/api/v1',
    models: ['cline-pass/glm-5.3', 'cline-pass/kimi-k2.7-code', 'cline-pass/qwen3.8-max', 'cline-pass/deepseek-v4-pro'],
    modelsEndpoint: '/api/v1/models',
    note: 'Cline 订阅制套餐',
  ),
  const AiProviderConfig(
    id: 'commandcode',
    name: 'Command Code',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'commandcode',
    defaultBaseUrl: 'https://api.commandcode.ai/provider/v1',
    models: ['gpt-6-sol', 'claude-sonnet-5-5', 'claude-opus-5', 'gpt-5.6-terra'],
    modelsEndpoint: '/provider/v1/models',
    note: '编码向模型聚合',
  ),
  const AiProviderConfig(
    id: 'chutes',
    name: 'Chutes',
    category: VendorCategory.relay,
    provider: 'openai',
    icon: 'chutes',
    defaultBaseUrl: 'https://llm.chutes.ai/v1',
    models: ['zai-org/GLM-5.3', 'moonshotai/Kimi-K2.7-Code', 'Qwen/Qwen3.8-Max-0902', 'tencent/Hy4'],
    modelsEndpoint: '/v1/models',
    note: '去中心化算力聚合',
  ),

  // ── 本地部署（无需密钥）────────────────────────────────────
  const AiProviderConfig(
    id: 'ollama',
    name: 'Ollama（本机）',
    category: VendorCategory.local,
    provider: 'openai',
    icon: 'ollama',
    defaultBaseUrl: 'http://localhost:11434/v1',
    models: [],
    modelsEndpoint: '/v1/models',
    authType: 'none',
    requiresApiKeyForFetch: false,
    keyOptional: true,
    placeholder: '请输入本机已拉取的模型名（ollama list 可查）',
    note: '本机 Ollama，默认端口 11434',
  ),
  const AiProviderConfig(
    id: 'lmstudio',
    name: 'LM Studio（本机）',
    category: VendorCategory.local,
    provider: 'openai',
    icon: 'lmstudio',
    defaultBaseUrl: 'http://localhost:1234/v1',
    models: [],
    modelsEndpoint: '/v1/models',
    authType: 'none',
    requiresApiKeyForFetch: false,
    keyOptional: true,
    placeholder: '请输入 LM Studio 已加载的模型名',
    note: '本机 LM Studio，默认端口 1234',
  ),
  const AiProviderConfig(
    id: 'vllm',
    name: 'vLLM（本机）',
    category: VendorCategory.local,
    provider: 'openai',
    icon: 'vllm-color',
    defaultBaseUrl: 'http://localhost:8000/v1',
    models: [],
    modelsEndpoint: '/v1/models',
    authType: 'none',
    requiresApiKeyForFetch: false,
    keyOptional: true,
    placeholder: '请输入 vLLM 已加载的模型名',
    note: '自建 vLLM 服务，默认端口 8000',
  ),

  // ── 自定义 ──────────────────────────────────────────────────
  const AiProviderConfig(
    id: 'custom',
    name: '自定义 (Custom)',
    category: VendorCategory.custom,
    provider: 'openai',
    defaultBaseUrl: '',
    urlRequired: true,
    placeholder: '请手动输入自定义模型的标识符',
    models: [],
    modelsEndpoint: '',
    note: '自填地址、协议与模型',
  ),
];

AiProviderConfig? getProviderById(String id) {
  try {
    return aiProviders.firstWhere((p) => p.id == id);
  } catch (_) {
    return null;
  }
}

/// 按分组取厂商模板（选择器分区用）
List<AiProviderConfig> aiVendorsOf(VendorCategory category) =>
    aiProviders.where((p) => p.category == category).toList();

/// 需要账号登录的厂商模板（凭证来自登录态，不填 API Key）
///
/// 「添加模型服务」的厂商选择器据此把两类厂商分区展示：账号型要点登录，
/// 密钥型要粘 Key，混在一张列表里容易让人以为登录型也要填密钥。
List<AiProviderConfig> aiAccountProviders() => aiProviders.where((p) => p.authMode != 'api_key').toList();

/// 走 API Key 的厂商模板（含「自定义」）
List<AiProviderConfig> aiApiKeyProviders() => aiProviders.where((p) => p.authMode == 'api_key').toList();

/// 该厂商是否允许不填密钥（本机服务与免密钥网关）
///
/// 保存校验、条目可用性与发信层的「缺少凭证」判断共用这一处口径，避免三处
/// 各写一份判断后出现「能存不能发」。
bool vendorAllowsKeyless(String? vendorId) {
  if (vendorId == null || vendorId.isEmpty) return false;
  return getProviderById(vendorId)?.keyOptional ?? false;
}

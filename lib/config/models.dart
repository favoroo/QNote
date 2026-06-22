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
  final String modelsEndpoint;       // 模型列表接口路径
  final String authType;             // 'bearer' | 'query' | 'none'
  final bool requiresApiKeyForFetch; // 获取模型列表是否需要 API Key

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
  });
}

final aiProviders = <AiProviderConfig>[
  const AiProviderConfig(
    id: 'deepseek',
    name: 'DeepSeek',
    provider: 'openai',
    defaultBaseUrl: 'https://api.deepseek.com',
    models: [
      'deepseek-v4-pro',
      'deepseek-v4-flash',
      'deepseek-v3.2',
      'deepseek-chat',
      'deepseek-reasoner',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'openai',
    name: 'OpenAI',
    provider: 'openai',
    defaultBaseUrl: 'https://api.openai.com/v1',
    models: [
      'gpt-5.4-pro',
      'gpt-5.4-mini',
      'gpt-5.4-thinking',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'moonshot',
    name: 'Kimi (Moonshot)',
    provider: 'openai',
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
    models: [
      'kimi-k2.6',
      'kimi-k2.5',
      'kimi-k2',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'mimo',
    name: 'MiMo (小米)',
    provider: 'openai',
    defaultBaseUrl: 'https://api.xiaomimimo.com/v1',
    models: [
      'mimo-v2.5-pro',
      'mimo-v2.5',
      'mimo-v2.5-tts',
      'mimo-v2-pro',
      'mimo-v2-omni',
      'mimo-v2-flash',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'longcat',
    name: 'LongCat (美团)',
    provider: 'openai',
    defaultBaseUrl: 'https://api.longcat.chat/openai/v1',
    models: [
      'LongCat-Flash-Chat',
      'LongCat-Flash-Thinking-2601',
      'LongCat-2.0-Preview',
      'LongCat-Flash-Omni-2603',
      'LongCat-Flash-Lite',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'zhipu',
    name: 'GLM (智谱)',
    provider: 'openai',
    defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4/',
    models: [
      'glm-4.7-flash',
      'glm-4.6v-flash',
      'glm-4.7',
      'glm-4.5-air',
      'glm-4-flashx-250414',
      'glm-4-32b-0414',
      'cogvideox-3',
    ],
    modelsEndpoint: '/api/paas/v4/models',
  ),
  const AiProviderConfig(
    id: 'gemini',
    name: 'Gemini (Google)',
    provider: 'gemini',
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
  ),
  const AiProviderConfig(
    id: 'openrouter',
    name: 'OpenRouter',
    provider: 'openai',
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
  ),
  const AiProviderConfig(
    id: 'chatanywhere',
    name: 'ChatAnywhere',
    provider: 'openai',
    defaultBaseUrl: 'https://api.chatanywhere.tech/v1',
    urlRequired: true,
    placeholder: '请输入模型名称，或点击“获取模型列表”',
    models: [
      'gpt-3.5-turbo',
      'gpt-4o-mini',
      'gpt-4o',
      'deepseek-chat',
      'deepseek-coder',
    ],
    modelsEndpoint: '/models',
  ),
  const AiProviderConfig(
    id: 'ant-ling',
    name: '蚂蚁百灵 (AntLing)',
    provider: 'openai',
    defaultBaseUrl: 'https://api.ant-ling.com/v1',
    urlRequired: true,
    placeholder: '请输入模型名称，或从下拉列表选择',
    models: [
      'Ling-2.6-flash',
      'Ling-2.5-1T',
      'Ring-2.6-1T',
      'Ring-2.5-1T',
      'Ming-Flash-Omni-2.0',
      'Ming-lite-omni',
    ],
    modelsEndpoint: '',
  ),
  const AiProviderConfig(
    id: 'agnes',
    name: 'Agnes AI',
    provider: 'openai',
    defaultBaseUrl: 'https://apihub.agnes-ai.com/v1',
    urlRequired: true,
    models: [
      'agnes-2.0-flash',
      'agnes-1.5-flash',
      'agnes-image-2.1-flash',
      'agnes-image-2.0-flash',
      'agnes-video-2.0',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'sensenova',
    name: 'SenseNova (商汤)',
    provider: 'openai',
    defaultBaseUrl: 'https://token.sensenova.cn/v1',
    models: [
      'sensenova-6.7-flash-lite',
      'deepseek-v4-flash',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'minimax',
    name: 'MiniMax',
    provider: 'openai',
    defaultBaseUrl: 'https://api.minimaxi.com/v1',
    models: [
      'MiniMax-M3',
      'MiniMax-M2.7',
      'MiniMax-M2.7-highspeed',
      'MiniMax-M2.5',
      'MiniMax-M2.5-highspeed',
      'MiniMax-M2.1',
      'MiniMax-M2.1-highspeed',
      'MiniMax-M2',
    ],
    modelsEndpoint: '/v1/models',
  ),
  const AiProviderConfig(
    id: 'custom',
    name: '自定义 (Custom)',
    provider: 'openai',
    defaultBaseUrl: '',
    urlRequired: true,
    placeholder: '请手动输入自定义模型的标识符',
    models: [],
    modelsEndpoint: '',
  ),
];

AiProviderConfig? getProviderById(String id) {
  try {
    return aiProviders.firstWhere((p) => p.id == id);
  } catch (_) {
    return null;
  }
}

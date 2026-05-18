class AiProviderConfig {
  final String id;
  final String name;
  final String provider;
  final String defaultBaseUrl;
  final bool urlRequired;
  final String placeholder;
  final List<String> models;
  final bool supportsSse;

  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.provider,
    required this.defaultBaseUrl,
    this.urlRequired = true,
    this.placeholder = '请输入模型名称或从下拉列表选择',
    required this.models,
    this.supportsSse = true,
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
  ),
  const AiProviderConfig(
    id: 'gemini',
    name: 'Gemini (Google)',
    provider: 'gemini',
    defaultBaseUrl: '',
    urlRequired: false,
    placeholder: '内置官方接口，无需填写URL(或填写自定义url)',
    models: [
      'gemini-3.1-pro',
      'gemini-flash-lite-latest',
      'gemini-flash-latest',
      'gemini-pro-latest',
      'gemma-4-26b-a4b-it',
      'gemma-4-31b-it',
    ],
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
  ),
  const AiProviderConfig(
    id: 'custom',
    name: '自定义 (Custom)',
    provider: 'openai',
    defaultBaseUrl: '',
    urlRequired: true,
    placeholder: '请手动输入自定义模型的标识符',
    models: [],
  ),
];

AiProviderConfig? getProviderById(String id) {
  try {
    return aiProviders.firstWhere((p) => p.id == id);
  } catch (_) {
    return null;
  }
}

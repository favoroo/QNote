import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

final defaultSystemPrompts = <String, String>{
  'assistant_greeting': '你可以切换顶部的分析范围（日期/笔记）来获得更精准的专业建议，或直接提问',
  'analysis_system':
      '你是一个专业的智能个人助手和生活数据分析师。\n\n==== [任务要求] ====\n1. 如果包含日记或笔记记录，请结合用户的身体数据（如身高体重），提供专业的建议、趋势发现和定性定量分析。\n2. 发现数据之间的关联（例如：吃了高热量食物 but 有运动，或者睡眠不好导致活动量低）。\n3. 语气保持亲切、鼓励。使用 Markdown 格式排版，重点内容加粗。',
  'diary_extraction':
      '你是一个智能自然语言解析助手。你的任务是将用户的自然语言日记记录，准确地提取和映射到给定的 Schema 中。如果用户一次输入了多个无关或顺序发生的事件（例如"先...然后...接着..."），你需要提取出多个事件的数组。\n{{contextStr}}\n==== [可用的分类和字段 Schema] ====\n{{schemaContext}}\n\n==== [提取规范] ====\n1. 时间默认规则（硬性）：若遇到模糊时间词，请使用标准默认值（早上=08:00，中午=12:30，晚上=19:00，宵夜=23:00）。\n2. 严格留空原则（硬性）：如果提供的 Schema 字段在用户输入中完全没有提及（如没有提到喝水），**绝对不能**在 fields 中编造并输出该字段。\n3. 兜底备注规则（硬性）：所有无法映射到具体 field 的细节（如食物口味、心情），必须全部合并填入 notes 字段中。\n4. "date" 应当是该记录逻辑上归属的日期（格式为 "yyyy-MM-dd"）。基于真实时间上下文计算。\n5. "time" 对象中的 "start" 和 "end" 必须是 "HH:mm"。睡眠记录的时间应特别注意区分是否在昨晚（如果是昨晚入睡并跨天，对应的 startOffset 设为 -1，endOffset 设为 0。并在 fields 中准确计算 duration 时长，如 10）。\n6. 将用户的输入映射到最佳分类（Shortcut）中。如果输入包含"钱/元/花费/收入/买/卖/花了/收入了"等财务意向，优先匹配到"记账"（consumption）。如果 Shortcut 包含 `categories`，必须在返回的 `fields` 内添加 `_category` 字段标明子分类 of the id（如：若是支出，则 `_category: "expense"`）。\n\n==== [例子] ====\n[Example 1]\nUser: 昨晚11点半才睡，睡得极差\nAssistant: [{"shortcutId": "sleep", "time": {"start": "23:30", "startOffset": -1}, "fields": {"quality": "较差"}}]\n\n[Example 2]\nUser: 我昨天晚上吃了一碗邵阳米粉，有点辣\nAssistant: [{"shortcutId": "diet", "date": "2026-05-12", "time": {"start": "19:00"}, "fields": {"item": "正餐"}, "notes": "一碗邵阳米粉，有点辣"}]\n\n[Example 3]\nUser: 昨晚十点睡的，一共睡了十个小时，睡得极好\nAssistant: [{"shortcutId": "sleep", "time": {"start": "22:00", "end": "08:00", "startOffset": -1, "endOffset": 0}, "fields": {"duration": 10, "quality": "极好"}}]\n\n==== [当前真实任务] ====\nUser: {{text}}\nAssistant: ',
  'image_extraction_base':
      '{{prompt}}\n当前可用的所需填写的字段和选项如下：\n{{schema}}\n\n==== [提取准则] ====\n1. 严格按照提供的字段 id 作为 JSON 的 key。\n2. 必须返回纯 JSON 对象，严禁包含任何 Markdown 标记（如 ```json）或解释性文字。\n3. 如果图片中没有匹配某项字段的信息，请直接忽略该字段。\n4. **备注（remark）字段处理**:\n   - 仅用于记录 Schema 之外的、图片中存在的关键核心信息。\n   - **严禁重复**：不要记录已经映射到具体字段的信息（如金额、种类等）。\n   - **风格要求**: 极简关键词/短语，剥离所有修饰性、功能性词汇。\n   - **长度限制**: 建议在 10 个字以内。\n\n请开始处理图片任务并直接输出 JSON：',
  'global_image_extraction':
      '{{prompt}}\n========== [可用的分类和字段 Schema] ==========\n{{schema}}\n\n========== [上下文] ==========\n{{contextStr}}\n\n========== [提取规范] ==========\n1. 将图片中的内容与用户输入的附言（即上面的文本）相结合，映射到给出的最佳分类（Shortcut）中。如果包含多个分类或多段事件的信息（无论是图里体现还是文里描述），请提取出**多个**事件的数组。\n2. 只能使用 schema 中提供的 key。提取的值必须属于选项列表。\n3. "date" 格式为 "yyyy-MM-dd"。优先使用上下文计算的逻辑日期。\n4. "time" 对象中的 "start" 和 "end" 必须是 "HH:mm"。如果是昨晚入睡并跨天，对应的 startOffset 设为 -1，endOffset 设为 0。并在 fields 中准确计算 duration 时长。\n5. **备注（notes）字段逻辑**：\n   - 仅保留未被分类和字段捕获的辅助信息（如餐点描述、消费商户等）。\n   - 剥离冗余：如果已识别出是"饮食 - 正餐"，不要在 notes 里写"吃饭"或"午餐"。\n   - 保持极简。\n\n========== [例子] ==========\n[Example 1]\nUser Text (prompt): "今天下午喝的，一大杯美式，花了18元"\nImage Content: (一张星巴克杯子的照片)\nAssistant: [{"shortcutId": "diet", "time": {"start": "15:00"}, "fields": {"item": "咖啡"}, "notes": "一大杯美式"}, {"shortcutId": "consumption", "time": {"start": "15:00"}, "fields": {"_category": "expense", "type": "饮食", "amount": 18}, "notes": "星巴克美式咖啡"}]\n\n[Example 2]\nUser Text (prompt): "昨晚1点才睡着，今天早上吃了这个"\nImage Content: (一碗粉的照片)\nAssistant: [{"shortcutId": "sleep", "time": {"start": "01:00", "startOffset": -1}, "fields": {"quality": "一般"}}, {"shortcutId": "diet", "time": {"start": "08:30"}, "fields": {"item": "正餐"}, "notes": "一碗粉"}]\n\n==== [当前真实任务] ====\n请结合用户附言文本与图片内容进行智能提取，直接输出严格的 JSON 数组结果：',
};

final defaultShortcutConfigs = <ShortcutConfig>[
  ShortcutConfig(
    id: 'sleep',
    name: '睡眠',
    hasPopup: true,
    fields: [
      ShortcutField(
        id: 'fallAsleepTime',
        label: '入睡时间',
        type: 'time',
        options: [],
      ),
      ShortcutField(
        id: 'duration',
        label: '时长 (小时)',
        type: 'number',
        options: [],
      ),
      ShortcutField(
        id: 'quality',
        label: '睡眠质量',
        type: 'select',
        options: ['极好', '良好', '一般', '较差'],
      ),
    ],
    imageExtractionPrompt: '请从图片中提取可能与睡眠相关的信息。',
    sortOrder: 0,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'diet',
    name: '饮食',
    hasPopup: false,
    fields: [
      ShortcutField(
        id: 'item',
        label: '种类',
        type: 'select',
        options: ['正餐', '零食', '喝水', '喝茶', '咖啡'],
      ),
      ShortcutField(
        id: 'amount',
        label: '水量',
        type: 'select',
        options: ['100ml', '200ml', '300ml', '500ml'],
      ),
    ],
    imageExtractionPrompt:
        '请从图片中提取食物信息，包含菜品名称、估算卡路里、健康度评价等。如果图片是营养标签，请提取其中的热量和营养素。',
    sortOrder: 1,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'activity',
    name: '活动',
    hasPopup: false,
    fields: [
      ShortcutField(
        id: 'item',
        label: '项目',
        type: 'select',
        options: ['玩手机', '玩电脑', '运动', '阅读'],
      ),
    ],
    imageExtractionPrompt: '请从图片中提取活动相关的信息，例如运动步数、里程、消耗卡路里等。',
    sortOrder: 2,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'consumption',
    name: '记账',
    hasPopup: true,
    fields: [],
    categories: [
      ShortcutCategory(
        id: 'expense',
        name: '支出',
        fields: [
          ShortcutField(
            id: 'type',
            label: '支出类型',
            type: 'select',
            options: [
              '饮食',
              '交通',
              '购物',
              '娱乐',
              '居家',
              '人情',
              '医疗',
              '房租',
              '数码',
              '其他',
            ],
          ),
          ShortcutField(id: 'amount', label: '金额', type: 'number', options: []),
        ],
      ),
      ShortcutCategory(
        id: 'income',
        name: '收入',
        fields: [
          ShortcutField(
            id: 'incomeType',
            label: '收入类型',
            type: 'select',
            options: ['工资', '奖金', '红包', '兼职', '理财', '其他'],
          ),
          ShortcutField(id: 'amount', label: '金额', type: 'number', options: []),
        ],
      ),
    ],
    imageExtractionPrompt: '从图片中提取收据、账单 or 订单信息，包含消费金额、消费类型、商品名称或商家名称等。',
    sortOrder: 3,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'other',
    name: '其他',
    hasPopup: false,
    fields: [],
    sortOrder: 4,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
];

final defaultAiConfigs = <AiConfig>[
  AiConfig(
    id: 'longcat-flash',
    name: 'LongCat Flash',
    provider: 'openai',
    modelName: 'LongCat-Flash-Thinking-2601',
    apiKey: 'ak_2o89sS1gm81S8b90Lp7Oq2PZ9j14L',
    baseUrl: 'https://api.longcat.chat/openai/v1',
    isDefault: true,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  AiConfig(
    id: 'gemini-preset',
    name: 'Google Gemini Flash',
    provider: 'gemini',
    modelName: 'gemini-1.5-flash-latest',
    apiKey: '',
    baseUrl: '',
    isDefault: false,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
];

const defaultAiRoles = AiRoles(
  imageExtraction: null,
  assistant: null,
  timelineOptimization: null,
);

const defaultAiTemperatures = AiTemperatures();

const defaultActiveShortcuts = ['睡眠', '饮食', '活动', '记账', '其他'];

const defaultMoodLabels = ['很差', '较差', '一般', '较好', '很好'];
const defaultWeatherOptions = ['晴天', '多云', '阴天', '小雨', '大雨', '雪', '雾'];
const defaultPriorityLabels = ['低', '中', '高'];
const defaultSymptomTypes = ['脑雾', '疲劳', '头痛', '胃胀'];

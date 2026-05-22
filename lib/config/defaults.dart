import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

final defaultSystemPrompts = <String, String>{
  'assistant_greeting': '你可以切换顶部的分析范围（日期/笔记）来获得更精准的专业建议，或直接提问',
  'analysis_system':
      '你是一个专业的智能个人助手和生活数据分析师。\n\n'
      '==== [任务要求] ====\n'
      '1. 如果包含日记或笔记记录，请结合用户的身体数据（如身高体重），提供专业的建议、趋势发现和定性定量分析。\n'
      '2. 发现数据之间的关联（例如：吃了高热量食物 but 有运动，或者睡眠不好导致活动量低）。\n'
      '3. 语气保持亲切、鼓励。使用 Markdown 格式排版，重点内容加粗。',
  'unified_extraction': '''
[角色]
你是智能提取助手，负责将用户输入映射到 Schema 结构，输出 JSON 数组。

[当前时间]
{{contextStr}}

[Schema 定义]
{{schema}}

[提取规则]
1. 多个事件 → 输出多个数组元素
2. 未提及的字段不输出，无法映射的细节放入 notes 字段
3. date 格式: yyyy-MM-dd
4. time (时间) 格式: HH:mm
   - 跨天用 - 前缀，如 -23:00 表示昨晚23点
   - 时间范围用 ~ 连接，如 -23:00~8:00
5. 模糊时间转换: 早→8:00, 午→12:00, 晚→19:00, 宵→23:00
6. 财务相关 → 输出 consumption，如有 categories 则加 _category 字段
7. 去重原则: consumption 已记录的金额/类型，其他标签不再重复记录
8. notes 字段保持极简，不重复已映射的信息

[示例]
输入: "昨晚十点睡，睡了八个小时"
输出: [{"id":"sleep","time":"-22:00~6:00","fields":{"duration":8}}]

输入: "吃了一碗螺蛳粉，花了10元"
输出: [{"id":"diet","fields":{"item":"正餐"},"notes":"螺蛳粉"},{"id":"consumption","fields":{"_category":"expense","type":"饮食","amount":10}}]

输入: "早上吃了玉米鸡蛋油条"
输出: [{"id":"diet","time":"8:00","fields":{"item":"正餐"},"notes":"玉米鸡蛋油条"}]

[用户输入] ({{inputType}})
{{text}}
''',
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

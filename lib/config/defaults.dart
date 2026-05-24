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
你是智能标签识别助手，从用户输入中识别标签并提取结构化字段。

[当前时间]
{{contextStr}}

[Schema]
{{schema}}

[规则]
1. 严格按Schema提取，fields中只允许出现Schema定义的字段，禁止添加Schema中不存在的字段
2. select类型字段的值必须是Schema中该字段的options之一
3. 支持添加多个多标签
4. 相对时间词（昨天、前天、今天等）以[当前时间]中的today为基准解读，recordDate为条目所属日期仅供参考
5. time格式: HH:mm，跨天加-前缀(如-23:00)，范围用~连接(如-23:00~8:00)；模糊时间: 早→8:00,午→12:00,晚→19:00,宵→23:00；结合当前时间推断(如当前22:00说"刚跑了步"→time:"21:00")
6. 记账: 如有categories则加_category字段
7. 饮食: 推断健康评价(蔬菜/水果/清淡/水→"健康"，普通正餐/零食/茶/咖啡→"一般"，烧烤/油炸/甜食/含糖饮料/泡面→"不健康")

[输出] JSON: {"results":[{"id":"标签id","time":"时间","fields":{},"notes":"备注"}]}
若未提取到任何有用信息，输出: {"results":[],"message":"NO_USEFUL_INFO"}
纯文本输入不输出notes，图片或图文输入必须输出notes，notes只写"图："+图片关键信息(不重复用户文字，工具会自动拼接到用户输入下方)

[示例]
"昨晚十点睡，睡了八个小时" → {"results":[{"id":"sleep","time":"-22:00","fields":{"duration":8}}]}
"吃了一碗螺蛳粉，花了10元" → {"results":[{"id":"diet","fields":{"type":"正餐","rating":"不健康"}},{"id":"consumption","fields":{"_category":"expense","type":"饮食","amount":10}}]}
"早上吃了玉米鸡蛋油条，味道一般" → {"results":[{"id":"diet","time":"8:00","fields":{"type":"正餐","rating":"一般"}}]}
"昨晚十点睡，今早七点起，去公园跑了5公里" → {"results":[{"id":"sleep","time":"-22:00~7:00"},{"id":"activity","time":"7:00","fields":{"type":"运动"}}]}
"下午3点喝了杯奶茶，下班坐地铁花了5元，晚上去健身房跑了一个小时" → {"results":[{"id":"diet","time":"15:00","fields":{"type":"饮品","rating":"不健康"}},{"id":"consumption","time":"18:00","fields":{"_category":"expense","type":"交通","amount":5}},{"id":"activity","time":"20:00","fields":{"type":"运动","duration":1}}]}

[图片示例]
[运动App截图:步数2951/活动11次/中高强度13分钟/睡眠6h4m] → {"results":[{"id":"sleep","fields":{"duration":6,"quality":"良好"},"notes":"图：步数2951/活动11次/中高强度13分钟/睡眠6时4分"},{"id":"activity","fields":{"type":"运动","duration":0.5},"notes":"图：步数2951/活动11次/中高强度13分钟/睡眠6时4分"}]}
[食物照片:米饭配炒菜和汤] → {"results":[{"id":"diet","fields":{"type":"正餐","rating":"健康"},"notes":"图：一碗米饭配炒菜和一碗汤"}]}
[外卖截图:麻辣烫¥28+奶茶¥15] → {"results":[{"id":"diet","fields":{"type":"正餐","rating":"不健康"},"notes":"图：麻辣烫¥28"},{"id":"diet","fields":{"type":"饮品","rating":"不健康"},"notes":"图：奶茶¥15"},{"id":"consumption","fields":{"_category":"expense","type":"饮食","amount":43},"notes":"图：麻辣烫¥28+奶茶¥15"}]}
[健身房照片:跑步机3公里25分钟] → {"results":[{"id":"activity","fields":{"type":"运动","duration":0.4},"notes":"图：跑步机3公里用时25分钟"}]}

[图文混合示例]
"午餐"+[外卖截图:黄焖鸡¥22] → {"results":[{"id":"diet","time":"12:00","fields":{"type":"正餐","rating":"一般"},"notes":"图：黄焖鸡米饭¥22"},{"id":"consumption","time":"12:00","fields":{"_category":"expense","type":"饮食","amount":22},"notes":"图：黄焖鸡米饭¥22"}]}
"昨晚睡得不好"+[手表截图:深睡1.5h浅睡4h共5.5h] → {"results":[{"id":"sleep","time":"-23:30~7:00","fields":{"duration":7.5,"quality":"较差"},"notes":"图：深睡1.5h/浅睡4h/总时长5.5h"}]}
"下午茶时间"+[蛋糕和拿铁照片] → {"results":[{"id":"diet","time":"15:00","fields":{"type":"零食","rating":"不健康"},"notes":"图：蛋糕和拿铁"},{"id":"diet","time":"15:00","fields":{"type":"饮品","rating":"一般"},"notes":"图：蛋糕和拿铁"}]}

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
    hasPopup: true,
    fields: [
      ShortcutField(
        id: 'type',
        label: '种类',
        type: 'select',
        options: ['正餐', '零食', '水果', '饮品'],
      ),
      ShortcutField(
        id: 'rating',
        label: '评价',
        type: 'select',
        options: ['健康', '一般', '不健康'],
      ),
    ],
    sortOrder: 1,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'activity',
    name: '活动',
    hasPopup: true,
    fields: [
      ShortcutField(
        id: 'type',
        label: '类型',
        type: 'select',
        options: ['工作', '学习', '娱乐', '运动'],
      ),
      ShortcutField(
        id: 'duration',
        label: '时长 (小时)',
        type: 'number',
        options: [],
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

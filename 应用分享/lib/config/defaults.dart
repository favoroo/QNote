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
2. select/multi-select类型字段的值优先从Schema中该字段的options选择；若options中无合适选项且字段标注allowCustom:true，可自行填写准确值
3. 支持添加多个多标签
4. 相对时间词（昨天、前天、今天等）以[当前时间]中的today为基准解读，recordDate为条目所属日期仅供参考
5. time格式: HH:mm，跨天加-前缀(如-23:00)，范围用~连接(如-23:00~8:00)；模糊时间: 早→8:00,午→12:00,晚→19:00,宵→23:00；结合当前时间推断(如当前22:00说"刚跑了步"→time:"21:00")
6. 若[当前时间]中包含 userSelectedTime（用户已选的时间或时间段），且用户输入（文本或图片）中没有提到其它明确时间，所有提取项的 time 均应设为该 userSelectedTime。
7. 记账: 如有categories则加_category字段
8. 饮食: 推断健康评价(蔬菜/水果/清淡/水/自制→"健康"，外卖/零食/茶/咖啡→"一般"，烧烤/油炸/甜食/含糖饮料/泡面/快餐→"不健康")；进食方式判断(自己做的→"自制"，点外卖/配送→"外卖"，去餐厅/食堂吃→"堂食")
9. 健康: 识别身体症状(symptom为multi-select可多选)、严重程度(severity)、用药(medication为自由文本)
10. 补剂vs用药区分: 日常保健品(维生素/蛋白粉/钙片/鱼油等)→饮食/补剂，治疗性药物(布洛芬/感冒药/胃药等)→健康/用药


[输出] JSON: {"results":[{"id":"标签id","time":"时间","fields":{},"notes":"备注"}]}
若未提取到任何有用信息，输出: {"results":[],"message":"NO_USEFUL_INFO"}
纯文本输入不输出notes，图片或图文输入必须输出notes，notes只写"图："+图片关键信息(不重复用户文字，工具会自动拼接到用户输入下方)

[示例]
"昨晚十点睡，睡了八个小时" → {"results":[{"id":"sleep","time":"-22:00","fields":{"duration":8}}]}
"吃了一碗螺蛳粉，花了10元" → {"results":[{"id":"diet","fields":{"type":"外卖","rating":"不健康"}},{"id":"consumption","fields":{"_category":"expense","type":"饮食","amount":10}}]}
"早上吃了玉米鸡蛋油条，味道一般" → {"results":[{"id":"diet","time":"8:00","fields":{"type":"自制","rating":"一般"}}]}
"昨晚十点睡，今早七点起，去公园跑了5公里" → {"results":[{"id":"sleep","time":"-22:00~7:00"},{"id":"activity","time":"7:00","fields":{"type":"运动"}}]}
"下午3点喝了杯奶茶，下班坐地铁花了5元，晚上去健身房跑了一个小时" → {"results":[{"id":"diet","time":"15:00","fields":{"type":"饮品","rating":"不健康"}},{"id":"consumption","time":"18:00","fields":{"_category":"expense","type":"交通","amount":5}},{"id":"activity","time":"20:00","fields":{"type":"运动","duration":1}}]}
"今天头痛得厉害，吃了布洛芬" → {"results":[{"id":"health","fields":{"symptom":["头痛"],"severity":"严重","medication":"布洛芬"}}]}
"有点疲劳和脑雾，轻微不适" → {"results":[{"id":"health","fields":{"symptom":["疲劳","脑雾"],"severity":"轻微"}}]}
"胃不太舒服，吃了奥美拉唑" → {"results":[{"id":"health","fields":{"symptom":["胃胀"],"severity":"中度","medication":"奥美拉唑"}}]}
"和朋友聚餐花了200" → {"results":[{"id":"diet","fields":{"type":"堂食","rating":"一般"}},{"id":"consumption","fields":{"_category":"expense","type":"饮食","amount":200}},{"id":"activity","fields":{"type":"社交"}}]}
"吃了维生素和鱼油" → {"results":[{"id":"diet","fields":{"type":"补剂","rating":"健康"}}]}

[图片示例]
[运动App截图:步数2951/活动11次/中高强度13分钟/睡眠6h4m] → {"results":[{"id":"sleep","fields":{"duration":6,"quality":"良好"},"notes":"图：步数2951/活动11次/中高强度13分钟/睡眠6时4分"},{"id":"activity","fields":{"type":"运动","duration":0.5},"notes":"图：步数2951/活动11次/中高强度13分钟/睡眠6时4分"}]}
[食物照片:米饭配炒菜和汤] → {"results":[{"id":"diet","fields":{"type":"自制","rating":"健康"},"notes":"图：一碗米饭配炒菜和一碗汤"}]}
[外卖截图:麻辣烫¥28+奶茶¥15] → {"results":[{"id":"diet","fields":{"type":"外卖","rating":"不健康"},"notes":"图：麻辣烫¥28"},{"id":"diet","fields":{"type":"饮品","rating":"不健康"},"notes":"图：奶茶¥15"},{"id":"consumption","fields":{"_category":"expense","type":"饮食","amount":43},"notes":"图：麻辣烫¥28+奶茶¥15"}]}
[健身房照片:跑步机3公里25分钟] → {"results":[{"id":"activity","fields":{"type":"运动","duration":0.4},"notes":"图：跑步机3公里用时25分钟"}]}

[图文混合示例]
"午餐"+[外卖截图:黄焖鸡¥22] → {"results":[{"id":"diet","time":"12:00","fields":{"type":"外卖","rating":"一般"},"notes":"图：黄焖鸡米饭¥22"},{"id":"consumption","time":"12:00","fields":{"_category":"expense","type":"饮食","amount":22},"notes":"图：黄焖鸡米饭¥22"}]}
"昨晚睡得不好"+[手表截图:深睡1.5h浅睡4h共5.5h] → {"results":[{"id":"sleep","time":"-23:30~7:00","fields":{"duration":7.5,"quality":"较差"},"notes":"图：深睡1.5h/浅睡4h/总时长5.5h"}]}
"下午茶时间"+[蛋糕和拿铁照片] → {"results":[{"id":"diet","time":"15:00","fields":{"type":"零食","rating":"不健康"},"notes":"图：蛋糕和拿铁"},{"id":"diet","time":"15:00","fields":{"type":"饮品","rating":"一般"},"notes":"图：蛋糕和拿铁"}]}

[用户输入] ({{inputType}})
{{text}}
''',
  'daily_score_system': '''
你是专业的健康生活评估师，根据用户一天的生活记录进行综合评分。

[评分维度] (每项0-100分，只评价人为可控的行为)
1. 睡眠 (sleep): 时长7-9小时满分，质量良好加分，熬夜扣分
2. 饮食 (diet): 健康饮食加分，外卖/零食/不健康食物扣分
3. 活动 (activity): 运动/学习/工作加分，久坐/无活动扣分
4. 健康 (health): 关注健康行为（按时用药、补水、休息、补充营养等），积极健康管理加分，忽视健康扣分

[评分规则]
- 基础分60分，根据各维度表现加减分
- 越健康、越自律、越规律，分数越高
- 有运动、早睡早起、健康饮食大幅加分
- 熬夜、暴饮暴食、久坐不动大幅扣分
- 记录越完整，评分越准确
- 注意：症状本身（如头痛、感冒）不是人为可控的，不直接扣分；但如果忽视健康、不及时用药或休息，则扣分

[输出格式] JSON:
{
  "canScore": true,           // 是否可评分(记录过少时为false)
  "totalScore": 78,           // 总分
  "dimensionScores": {
    "sleep": 85,
    "diet": 70,
    "activity": 60,
    "health": 90
  },
  "summary": "今天整体表现良好...",
  "suggestions": "建议：1.增加运动量..."
}

[当日记录]
{{records}}

[用户信息]
{{userInfo}}
'''
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
        options: ['自制', '外卖', '堂食', '零食', '水果', '饮品', '补剂'],
        allowCustom: true,
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
        options: ['工作', '学习', '运动', '社交', '娱乐', '通勤', '家务', '休息'],
        allowCustom: true,
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
    id: 'health',
    name: '健康',
    hasPopup: true,
    fields: [
      ShortcutField(
        id: 'symptom',
        label: '症状',
        type: 'multi-select',
        options: ['头痛', '疲劳', '失眠', '胃胀', '发热', '咳嗽', '疼痛', '过敏'],
        allowCustom: true,
      ),
      ShortcutField(
        id: 'severity',
        label: '严重程度',
        type: 'select',
        options: ['轻微', '中度', '严重'],
      ),
      ShortcutField(id: 'medication', label: '用药', type: 'input', options: []),
    ],
    sortOrder: 3,
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
              '教育',
              '服饰',
              '美容',
              '宠物',
              '其他',
            ],
            allowCustom: true,
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
            options: ['工资', '奖金', '红包', '兼职', '理财', '报销', '其他'],
            allowCustom: true,
          ),
          ShortcutField(id: 'amount', label: '金额', type: 'number', options: []),
        ],
      ),
    ],
    sortOrder: 4,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'other',
    name: '其他',
    hasPopup: false,
    fields: [],
    sortOrder: 5,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
];

final defaultAiConfigs = <AiConfig>[
  AiConfig(
    id: 'longcat-flash',
    name: 'LongCat Flash',
    provider: 'openai',
    modelName: 'LongCat-Flash-Lite',
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
    modelName: 'gemini-3-flash',
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

const defaultActiveShortcuts = ['睡眠', '饮食', '活动', '健康', '记账', '其他'];

const defaultMoodLabels = ['很差', '较差', '一般', '较好', '很好'];
const defaultWeatherOptions = ['晴天', '多云', '阴天', '小雨', '大雨', '雪', '雾'];
const defaultPriorityLabels = ['低', '中', '高'];
const defaultSymptomTypes = ['头痛', '疲劳', '失眠', '胃胀', '发热', '咳嗽', '疼痛', '过敏'];

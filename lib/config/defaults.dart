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

[提取规则]
1. 严禁虚构/改写字段名：只提取Schema中定义的ID和字段，且fields内部的键名（Key）必须严格与Schema定义的字段ID完全一致。无有用信息输出 {"results":[]}。
2. 选项匹配：select尽量用给定选项，allowCustom=true时才可自定义。
3. 时间推断：基准为[当前时间]中的today。时间格式 HH:mm (跨天加-，如-23:00，范围用~连接)。早8:00,午12:00,晚19:00,宵23:00。若提供 userSelectedTime 且无其他明确时间，则强制使用该时间。
4. 业务逻辑：
   - 饮食：蔬菜/水/自制->健康；外卖/零食/咖啡->一般；油炸/甜食/快餐->不健康。日常维C/鱼油属补剂(diet)，治病药(如布洛芬)属用药(health)。
   - 图片处理：截图提核心数据和指标(如深睡1.5h)；食物图必须提具体食物、菜品名称及配料信息(如：香菇滑鸡、白灼生菜、玄米饭)。
   - 精神状态/身体感受：状态不错、头脑清醒、精力充沛->健康标签，severity="轻微"或空；疲惫、头晕、乏力、犯困->健康标签，symptom=["疲劳"]，severity根据描述定(严重/中度/轻微)。

[输出格式] JSON: {"results":[{"id":"标签id","time":"时间","fields":{},"notes":"备注"}]}
若未提取到任何有用信息, 输出: {"results":[]}
纯文本输入不输出notes，图片或图文输入必须输出notes。
notes规则：
- 只在results数组的第一个元素上输出一个notes字段，多标签场景汇总所有图片信息到这一个notes中，后续结果不要重复输出notes。
- 格式必须为"图："+图片具体信息（如是食物图，详细列出识别到的所有具体食物和菜品名称）。
- 不要重复用户已输入的文字内容，工具会自动将notes拼接到用户正文下方。

[示例]
- 昨晚十点睡，睡了八个小时 → {"results":[{"id":"sleep","time":"-22:00","fields":{"duration":8}}]}
- 下午3点喝奶茶，地铁5元，健身房跑1小时 → {"results":[{"id":"diet","time":"15:00","fields":{"type":"饮品","rating":"不健康"}},{"id":"consumption","time":"18:00","fields":{"_category":"expense","type":"交通","amount":5}},{"id":"activity","time":"20:00","fields":{"type":"运动","duration":1}}]}
- 今天头痛得厉害，吃了布洛芬 → {"results":[{"id":"health","fields":{"symptom":["头痛"],"severity":"严重","medication":"布洛芬"}}]}
- 状态不错，头脑清醒 → {"results":[{"id":"health","fields":{}}]}
- 感觉有点累，头有点晕 → {"results":[{"id":"health","fields":{"symptom":["疲劳","头晕"],"severity":"轻微"}}]}
- [食物照片:米饭、香菇滑鸡和白灼生菜] → {"results":[{"id":"diet","fields":{"type":"自制","rating":"健康"},"notes":"图：香菇滑鸡、白灼生菜、一碗米饭"}]}
- [健康App截图:睡眠6h46min质量一般、步数5047/6000、卡路里294/300kcal、中高强度活动21min、心率84次/分] → {"results":[{"id":"sleep","fields":{"duration":6.77,"quality":"一般"},"notes":"图：睡眠6时46分质量一般，步数5047/6000步，卡路里294/300千卡，中高强度活动21分钟，心率84次/分"},{"id":"activity","fields":{"type":"运动","duration":0.35}},{"id":"health","fields":{}}]}
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
    id: 'agnes-2.0-flash',
    name: 'Agnes 2.0 Flash',
    provider: 'openai',
    modelName: 'agnes-2.0-flash',
    apiKey: 'sk-ywtKENdgygWK82Rx5ZPI6QLp5hJZ5EIdXgSL4SJ1fu4OAcJG',
    baseUrl: 'https://apihub.agnes-ai.com/v1',
    vendorId: 'agnes',
    isDefault: true,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
];

const defaultAiRoles = AiRoles(assistant: null, timelineOptimization: null);

const defaultAiTemperatures = AiTemperatures();

const defaultActiveShortcuts = ['睡眠', '饮食', '活动', '健康', '记账', '其他'];

const defaultMoodLabels = ['很差', '较差', '一般', '较好', '很好'];

const defaultPriorityLabels = ['低', '中', '高'];
const defaultSymptomTypes = ['头痛', '疲劳', '失眠', '胃胀', '发热', '咳嗽', '疼痛', '过敏'];

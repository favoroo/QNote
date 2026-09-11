import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

final defaultSystemPrompts = <String, String>{
  'note_image_analysis': '''
你是图片内容识别助手，请仔细识别图片并用一句话概括图片中的关键信息。

[输出要求]
1. 必须输出为一段连续文本，不要换行，不要使用多个段落。
2. 输出纯文本，不要使用 Markdown 格式（如 #、**、-、> 等），不要输出 JSON。
3. 内容控制在 200 字以内，优先包含以下关键信息：
   - 场景与主体（如食物、风景、文档、截图等）
   - 可识别的文字或数据（如有）
   - 具体物品、菜品、人物等关键元素
4. 不要输出"食物名称：""文字内容："等分类总结。
5. 不要添加推测、建议、评价或与图片无关的内容。

[示例]
食物图 → 俯拍视角的一碗螺蛳粉，碗中有米粉、卤蛋、云吞、炸腐竹和豆芽，碗沿印有"云饺"字样，配黑色筷子和白色勺子。
健康App截图 → 手机健康App截图显示睡眠6小时46分钟质量一般，步数5047/6000步，卡路里294/300千卡，中高强度活动21分钟，心率84次/分。
文档照片 → 一份白色A4纸打印的会议纪要，标题为"2024年Q3产品规划会"，可见"用户增长""留存率""迭代排期"等关键词，手写批注标注了三个优先级。
风景照片 → 湖边日落风景，前景是木质栈道和芦苇，湖面倒映橙红色晚霞，远处有连绵山脉轮廓，天空有少量云层。
''',
  'assistant_greeting': '你好！我是你的全能助手「小Q」。你可以直接向我提问，或者让我帮你添加待办、记录流水、修改笔记与设置等。',
  'analysis_system': QSystemPrompt.prompt,
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
   - 心情/情绪：被骂、不开心、难过、焦虑、愤怒、委屈等情绪类表达->活动标签，type="情绪"；"开心""感动""兴奋"等积极情绪同理。如同时包含具体活动和情绪（如"和朋友聊天很开心"），归为对应活动类型即可。

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
- 今天被领导骂了，不开心 → {"results":[{"id":"activity","fields":{"type":"情绪"}}]}
- 感觉有点焦虑 → {"results":[{"id":"activity","fields":{"type":"情绪"}}]}
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

[输出格式] JSON（summary 和 suggestions 字段必须使用 Markdown 格式，支持换行、列表、加粗等）:
{
  "canScore": true,           // 是否可评分(记录过少时为false)
  "totalScore": 78,           // 总分
  "dimensionScores": {
    "sleep": 85,
    "diet": 70,
    "activity": 60,
    "health": 90
  },
  "summary": "今天整体生活规律度尚可，但存在明显的饮食结构和久坐隐患。\n\n睡眠达标（8小时）且入睡时间较早，值得肯定；健康管理上按时服药，表现优秀。\n\n主要扣分点在于晚餐外卖过于丰盛且热量较高，与午餐的健康自制形成反差。",
  "suggestions": "**1. 晚餐需严格控制**：今晚尽量清淡，减少高蛋白和高GI食物摄入。\n\n**2. 打破久坐模式**：建议在午休后或工作间隙增加5-10分钟的轻体力活动。\n\n**3. 增加日常运动**：周末可适当增加有氧运动（如快走30分钟以上）。\n\n**4. 饮食均衡**：继续保持早餐和午餐的良好习惯。"
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
        options: ['工作', '学习', '运动', '社交', '娱乐', '通勤', '家务', '休息', '情绪'],
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

// 已移除默认 AI 配置，使用免费模型

const defaultAiRoles = AiRoles(assistant: null, timelineOptimization: null);

const defaultAiTemperatures = AiTemperatures();

const defaultActiveShortcuts = ['睡眠', '饮食', '活动', '健康', '记账', '其他'];

const defaultMoodLabels = ['很差', '较差', '一般', '较好', '很好'];

const defaultPriorityLabels = ['低', '中', '高'];
const defaultSymptomTypes = ['头痛', '疲劳', '失眠', '胃胀', '发热', '咳嗽', '疼痛', '过敏'];

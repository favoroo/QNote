import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

final defaultSystemPrompts = <String, String>{
  'assistant_greeting': '嗨，我是小Q —— 记待办、写笔记、打卡时间线、看统计，说一句就行',
  'unified_extraction': '''
你是结构化记录提取器，从用户输入中识别时间线标签并输出严格 JSON。

[时间上下文]
{{contextStr}}

[Schema]
{{schema}}

[提取规则]
1. 严格对齐 Schema：仅输出 Schema 中定义的标签 id 与字段名（fields 内 key 必须与字段 id 完全一致）；select 优先匹配给定选项，仅 allowCustom=true 时可自定义。无有用信息输出 {"results":[]}。
2. 时间规则：
   - 日期基准为 [时间上下文] 的 recordDate（仅当 recordDate 等于 today.date 且原文说“刚才/现在”时参考 today.time）。
   - 格式 HH:mm（24小时制），范围用 ~ 连接，前一天加 - 前缀（如跨夜睡眠 "-23:00~07:00"，昨晚十点 "-22:00"）；粗略时段：早 08:00 / 午 12:00 / 晚 19:00 / 宵 23:00。
   - 严禁编造时间：仅当输入明确提及时间或时段时才输出 time；原文未提时间时，若提供 userSelectedTime 则原样填为 time，否则省略 time 字段。
3. 分类与字段规则：
   - 饮食(diet)：按健康度判定 rating——蔬果/水煮清淡少油盐/白开水/无糖茶/适量营养补剂→健康；普通家常正餐/常规简餐/低糖咖啡/适度碳水→一般；油炸/甜食/高糖奶茶/膨化零食/快餐烧烤→不健康；深夜暴饮暴食/大量高脂高糖堆叠/狂饮高烈度酒→过于放纵。除 Schema 已定义字段外，严禁额外自造种类或渠道字段。
   - 健康(health)：症状/用药/明确身体感受（状态不错、疲惫、头晕等）归 health；日常维C/鱼油等营养补剂归 diet，治病药（如布洛芬）归 health 的 medication。
   - 随想(thought)：纯情绪表达（开心/难过/焦虑/委屈等）、灵感想法、反思或碎碎念归 thought；若同时含具体活动（如“和朋友聊天很开心”）只归 activity，含身体不适归 health，不重复输出 thought。
   - 不凑空标签：仅当包含多个独立事件时才输出多条，不要为常规数据额外附带空字段标签。
{{imageRules}}

[输出格式]
{{outputFormat}}

[示例]
- 昨晚11点睡到早上7点，睡了8小时 → {"results":[{"id":"sleep","time":"-23:00~07:00","fields":{"duration":8}}]}
- 下午3点喝奶茶，地铁5元，健身房跑1小时 → {"results":[{"id":"diet","time":"15:00","fields":{"rating":"不健康"}},{"id":"consumption","fields":{"_category":"expense","type":"交通","amount":5}},{"id":"activity","fields":{"type":"运动","duration":1}}]}
- 今天头痛得厉害，吃了布洛芬 → {"results":[{"id":"health","fields":{"symptom":["头痛"],"severity":"严重","medication":"布洛芬"}}]}
- 状态不错，头脑清醒 → {"results":[{"id":"health","fields":{}}]}
- 感觉有点累，头有点晕 → {"results":[{"id":"health","fields":{"symptom":["疲劳","头晕"],"severity":"轻微"}}]}
- 今天被领导骂了，不开心 → {"results":[{"id":"thought","fields":{}}]}
- 突然想到一个不错的产品点子 → {"results":[{"id":"thought","fields":{}}]}
{{imageExamples}}''',
  'daily_score_system': '''
你是专业的健康生活评估师，根据用户一天的生活记录、小米运动健康客观数据与屏幕使用时间进行综合评分。

[评分维度] (每项0-100分，只评价人为可控的行为)
1. 睡眠 (sleep): 时长7-9小时满分，质量良好加分，熬夜扣分；优先参考小米运动健康的睡眠时长、深浅睡/REM比例与睡眠得分
2. 饮食 (diet): 健康饮食加分，不健康扣分，暴饮暴食/过于放纵大幅扣分
3. 活动 (activity): 运动/学习/工作加分，久坐/无活动扣分；优先参考小米步数、活跃分钟数、站立次数与单次运动记录
4. 健康 (health): 关注健康行为（按时用药、补水、休息、补充营养等），积极健康管理加分，忽视健康扣分；可参考心率、血氧、压力等客观体征趋势
5. 屏幕 (screen): 屏幕使用时间越短越好，适度使用加分，过度沉迷手机大幅扣分；参考当日屏幕总时长与Top应用

[评分规则]
- 基础分60分，根据各维度表现加减分；越健康、自律、规律分数越高
- 有运动、早睡早起、健康饮食大幅加分；熬夜、暴饮暴食、久坐不动、屏幕时长过长（如超6小时）大幅扣分
- 记录过少导致无法客观评估时，将 "canScore" 设为 false
- 注意：症状本身（如头痛、感冒）不是人为可控的，不直接扣分；但如果忽视健康、不及时用药或休息，则扣分
- 若健康数据或屏幕使用时间为空，如实基于现有记录评分，不编造数据

[输出格式] 严格 JSON（summary 和 suggestions 字段使用 Markdown 格式，支持换行、列表、加粗）:
{
  "canScore": true,
  "totalScore": 78,
  "dimensionScores": {
    "sleep": 85,
    "diet": 70,
    "activity": 60,
    "health": 90,
    "screen": 75
  },
  "summary": "今天整体生活规律度尚可，但存在明显的饮食结构和久坐隐患。\\n\\n睡眠达标（8小时）且入睡时间较早，值得肯定；健康管理上按时服药，表现优秀。\\n\\n主要扣分点在于晚餐夜宵过于油腻且热量较高，存在明显的饮食放纵现象。",
  "suggestions": "**1. 晚餐需严格控制**：今晚尽量清淡，减少高脂和高GI食物摄入。\\n\\n**2. 打破久坐模式**：建议在工作间隙增加5-10分钟的轻体力活动。\\n\\n**3. 增加日常运动**：可适当增加有氧运动（如快走30分钟以上）。"
}
''',
};

final defaultShortcutConfigs = <ShortcutConfig>[
  ShortcutConfig(
    id: 'sleep',
    name: '睡眠',
    hasPopup: true,
    fields: [
      ShortcutField(id: 'fallAsleepTime', label: '入睡时间', type: 'time', options: []),
      ShortcutField(id: 'duration', label: '时长 (小时)', type: 'number', options: []),
      ShortcutField(id: 'quality', label: '睡眠质量', type: 'select', options: ['极好', '良好', '一般', '较差']),
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
      ShortcutField(id: 'rating', label: '评价', type: 'select', options: ['健康', '一般', '不健康', '过于放纵']),
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
      ShortcutField(id: 'duration', label: '时长 (小时)', type: 'number', options: []),
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
      ShortcutField(id: 'severity', label: '严重程度', type: 'select', options: ['轻微', '中度', '严重']),
      ShortcutField(id: 'medication', label: '用药', type: 'input', options: []),
    ],
    sortOrder: 3,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'thought',
    name: '随想',
    hasPopup: false,
    fields: [],
    sortOrder: 4,
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
            options: ['饮食', '交通', '购物', '娱乐', '居家', '人情', '医疗', '房租', '数码', '教育', '服饰', '美容', '宠物', '其他'],
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
    sortOrder: 5,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
  ShortcutConfig(
    id: 'other',
    name: '其他',
    hasPopup: false,
    fields: [],
    sortOrder: 6,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ),
];

// 内置免费模型由虚拟厂商提供（见 core/ai/builtin_provider.dart），
// 默认角色绑定保持为空：只有用户没有任何可用模型时才自然回落到它。

const defaultAiRoles = AiRoles(assistant: null, timelineOptimization: null);

const defaultAiTemperatures = AiTemperatures();

const defaultActiveShortcuts = ['睡眠', '饮食', '活动', '健康', '随想', '记账', '其他'];

const defaultMoodLabels = ['很差', '较差', '一般', '较好', '很好'];

const defaultPriorityLabels = ['低', '中', '高'];
const defaultSymptomTypes = ['头痛', '疲劳', '失眠', '胃胀', '发热', '咳嗽', '疼痛', '过敏'];

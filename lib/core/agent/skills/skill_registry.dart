import 'dart:async';

import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/agent_skill.dart';

/// QNote 内置 Agent 专业技能注册表与手册加载中心
///
/// 技能分两层：
/// - **内置技能**：本文件内的 Dart 字符串常量，随 App 发行版本更新，对用户与小Q均只读；
/// - **用户技能**：持久化于 app_configs（键前缀 `agent_skill_`），可由用户在
///   「小Q技能」管理页或小Q经 VFS `/skills/<name>.md` 增删改，App 更新不会覆盖。
class SkillRegistry {
  static final SkillRegistry instance = SkillRegistry._();
  SkillRegistry._();

  /// 用户技能内存缓存（ensureLoaded 后可用；写操作即时同步）
  final List<AgentSkill> _userSkills = [];
  bool _loaded = false;
  Future<void>? _loadingFuture;

  static const String todoManagerDoc = '''---
name: todo-manager
description: 待办事项管理技能：待办分类（今日/长期/工作/学习等）、GTD任务规划、优先级标记与状态切换
---

# 待办事项管理技能 (Todo Manager)

在 QNote 中，所有待办事项均组织在 `/todos/` 虚拟目录下，子目录即为分类文件夹。

## 1. 目录与路径规则
- 路径格式：`/todos/<分类名称>/<待办标题>.md`
- 常用分类：
  - `/todos/今日/`: 当天需要处理的紧急、日常待办
  - `/todos/长期/`: 长期目标、无固定时限的任务
  - `/todos/工作/`: 职业、项目与业务开发待办
  - `/todos/学习/`: 阅读、考证、技能提升清单
  - *注*：若写入一个新分类目录（例如 `/todos/旅行/订机票.md`），系统会自动创建该待办分类！

## 2. 文件内容规范 (Markdown Frontmatter)
每个待办文件采用 YAML Frontmatter 存储元数据，正文存储详细备注：

```markdown
---
status: pending          # pending(未完成) | completed(已完成)
priority: normal         # normal(普通) | important(高优/重要，底层落库保留)
repeat_rule: none        # none | daily(每天) | workday(工作日) | weekly(每周) | monthly(每月) | yearly(每年)
tags: "学习,技术"        # 待办标签(选填，逗号分隔或字符串数组)
reminder_time: "09-11 19:00" # 提醒时间(选填，格式 MM-DD HH:mm，到点推送通知)
due_date: "2026-09-11 19:00" # 截止时间(选填，仅作记录，不触发通知)
is_long_term: false      # 是否为长期待办(选填)
---
这里是待办事项的详细说明、执行步骤或备注信息。
```

## 3. 核心操作规范
- **界面交互认知**：当前待办界面已全新升级为仿小米极简悬浮卡片风格（无冗余三点按钮与红点）。点击卡片弹出底部大窗编辑与设提醒，长按卡片可调出操作菜单（含「给小Q」），已完成待办在列表下方折叠展示。不要指导用户找「三点菜单」或「红点星标」。
- **新建待办**：使用 `write_file(path: "/todos/分类/标题.md", content: "...")`。
  - 用户说“帮我加个中午拿快递的待办”，未指定分类时，默认写入 `/todos/今日/拿快递.md`。
  - 用户说“在工作待办里添加准备周报”，写入 `/todos/工作/准备周报.md`。
  - 循环习惯待办：用户说“每天早上八点晨跑”，写入 `repeat_rule: daily`；工作日待办写入 `repeat_rule: workday`。
- **设置提醒（关键）**：QNote 的到点提醒**只认 `reminder_time`**。`due_date` 只是截止时间记录，不会推送通知、也不在待办列表里展示。
  - 用户说“提醒我晚上去拿快递”“七点叫我”“明天上午十点提醒我开会”这类话，必须在写待办时带上 `reminder_time`。
  - 格式 `MM-DD HH:mm`（当天/今年可省略年份）：晚上 19:00 → `reminder_time: "09-11 19:00"`。
  - 用户既要求截止又要求提醒时，两个字段都写，取值一致即可。
  - 写完以后核对工具回显里的「提醒时间」，缺失就是没写进去，必须补写后重试，严禁口头声称已设置提醒。
  - 只写 `due_date` 而不写 `reminder_time` 是**错误示范**，会造成「AI 说设置了提醒，用户却收不到任何通知」。
- **标记完成**：使用 `edit_file` 将 `status: pending` 替换为 `status: completed`。
- **修改分类**：使用 `move_file(from: "/todos/今日/拿快递.md", to: "/todos/工作/拿快递.md")` 一步完成，**不要**用「新建一条 + 删掉旧的」——中途失败会留下重复待办。
- **追加备注**：使用 `write_file(path: ..., content: "...", mode: "append")` 在正文末尾续写，无需先读取整篇。
- **查看待办**：使用 `list_dir(path: "/todos")` 查看分类；使用 `list_dir(path: "/todos/今日")` 查看分类下的所有待办；不知道待办在哪个分类时，用 `grep(query: "关键词", scope: "todos")` 直接定位（返回的路径可直接用于改写）。

## 4. GTD 四象限速查
- 重要且紧急 → `/todos/今日/` 并必须设置 `reminder_time` 触发系统级闹钟提醒，标记 `priority: important`
- 重要不紧急 → `/todos/长期/`
- 紧急不重要 → `/todos/今日/`（普通优先级）
- 不重要不紧急 → 建议不记录，或归入 `/todos/学习/` 等低优先级分类

## 5. 批量操作
- **批量新建**（一条指令要加好几条待办，如从笔记提取行动项）：使用 `write_files(files: [{path: "/todos/今日/A.md", content: "..."}, {path: "/todos/今日/B.md", content: "..."}])` 一次写入，比逐条 `write_file` 省轮次；
- **批量完成**：逐个 `edit_file` 将 `status: pending` 替换为 `status: completed`（可在同一条回复里并列多个调用）；
- **批量移动/改分类**：逐个 `move_file`，或整理整个分类时直接用 `folder-manager` 的重命名能力；
- **批量删除**：属不可逆操作，必须先 `ask_user` 二次确认，确认后才逐个执行。
''';

  static const String noteManagerDoc = '''---
name: note-manager
description: 笔记与知识库管理技能：多层笔记本分类、Markdown 深度排版、标签管理与置顶
---

# 笔记与知识库管理技能 (Note Manager)

在 QNote 中，知识库与长文笔记组织在 `/notes/` 虚拟目录下，子目录对应笔记本分类。

## 1. 目录与路径规则
- 路径格式：`/notes/<笔记本名称>/<笔记标题>.md`
- 根目录笔记：`/notes/<笔记标题>.md`

## 2. 文件内容规范
```markdown
---
tags: ["ai", "flutter"] # 标签数组
pinned: false           # 是否置顶
---
# 笔记主标题

这里是笔记的 Markdown 正文，支持完整的标题、引用、代码块、列表和表格。
```

## 3. 核心操作规范
- **新建笔记**：使用 `write_file(path: "/notes/笔记本/标题.md", content: ...)`。若笔记本不存在将自动创建。
- **检索笔记**：使用 `grep(query: "关键词", scope: "notes")` 进行跨笔记检索（`scope` 可选 `all` / `notes` / `todos` / `timeline` / `journal` / `memory` / `settings` / `chats`，附 `max_results` 控制返回条数；注意 grep 没有 path 参数）。返回的 `path` 可直接用于 `read_file` / `edit_file`，不用再猜路径。
- **局部修改**：使用 `edit_file(path: ..., old_text: ..., new_text: ...)` 进行高精度修改。
- **追加内容**：使用 `write_file(path: ..., content: "...", mode: "append")` 在正文末尾续写；`mode` 缺省为 `overwrite`（整篇覆写）。
- **移动/换笔记本/改名**：使用 `move_file(from: "/notes/临时/方案.md", to: "/notes/技术/方案.md")` 一步完成；写到 `/notes/<标题>.md`（不带笔记本段）表示移出到根目录。

## 4. 多文件类型支持
- 除 `.md` 外，`/notes/` 下还支持写入 `.html` 网页、`.svg` 矢量图、`.json` 数据文件及常见代码文件，App 内会按后缀自动渲染预览。
- 生成展示型内容（卡片、海报、可视化页面）时，优先写入**带内联样式的单文件 HTML**，美学与移动端适配规范详见 `frontend-design` 技能。
- 非 `.md` 文件的扩展名会保留在笔记标题中（`.md` 后缀会被自动去掉）。

## 5. 图片插入规范
- 正文图片独立成行写 `![image](<路径>)`；路径必须来自 `generate_image` 工具回显或已有记录中的真实路径，**严禁编造**。
- 上述写法仅针对**写入文件**的正文；对话回复里不要重复贴同一张图（生图卡片已自动展示，再写一遍会显示两次）。
- 插入后系统会自动回填图片索引供云同步识别，无需额外操作。

## 6. 长文排版模板
```markdown
# 笔记主标题
> 一句话导语：本文解决什么问题、结论是什么。

## 一、背景与问题
段落正文……每节结尾配一两句小结。

## 二、核心方案
- 要点一
- 要点二

| 方案 | 优点 | 缺点 |
| --- | --- | --- |

## 三、行动与后续
- [ ] 待跟进事项
```
- 标题层级不超过三级（`#` ~ `###`）；长文建议开头导语点题、每节收尾小结。
''';

  static const String timelineManagerDoc = '''---
name: timeline-manager
description: 时间线流水记录技能：每日流水记事、时间戳打卡、情绪与身体状态追踪
---

# 时间线流水记录技能 (Timeline Manager)

在 QNote 中，每天的时序流水记录存放在 `/timeline/YYYY-MM-DD.md` 中。

## 1. 路径与时序格式
- 路径格式：`/timeline/YYYY-MM-DD.md`
- 内部格式为按时序追加的二级标题块。`read_file` 输出中每个已有事件块的标题末尾带有 `<!-- id: xxx -->` 隐藏注释，它是事件与数据库记录的唯一关联标识：

```markdown
# 2026-09-11 时间线

## [08:30] 晨间咖啡与早餐打卡 <!-- id: 5e9f8a3b-1c2d-3e4f-5a6b-7c8d9e0f1a2b -->
- 分类: 饮食
- 心情: 4
- 消费金额: 25.0
- 内容: 喝了一杯拿铁，吃全麦面包，精神饱满。

## [14:00 - 16:30] 技术评审会议 <!-- id: 9a8b7c6d-5e4f-3a2b-1c0d-9e8f7a6b5c4d -->
- 分类: 工作
- 心情: 5
- 内容: 完成了全能小Q架构方案的确认与评审。
```

> **支持时间段与结构化打卡**：标题行支持 `## [HH:MM] 标题` 或 `## [HH:MM - HH:MM] 标题`。块内支持任意自定义指标行（如 `- 饮水: 500ml`、`- 消费金额: 35.0`、`- 天气: 晴`），系统会自动解析为结构化指标供首页图表识别。
> **严禁使用 YAML Frontmatter 描述时间事件**。时间事件只有「二级时间标题 + 字段行」这一种合法格式。

## 2. 核心操作规范
- **追加流水（首选）**：直接用 `write_file(path: "/timeline/YYYY-MM-DD.md", content: "## [HH:MM] 标题\n- 分类: ...", mode: "append")` 追加新时间块，一步到位、无需先读文件；新块无需 id 注释。仅当需要改已有事件内容时才先 `read_file`。
- **不追加时避免整篇重写**：整篇 `write_file` 覆写若漏掉某个块的 `<!-- id: xxx -->`，该事件会被判定为新事件而重复创建——追加与局部编辑正是为了绕开这个坑。
- **id 注释必须原样保留（最高优先级）**：重写或整理当天文件时，已有块的 `<!-- id: xxx -->` 必须一字不差地带回。若 id 丢失，对应记录会被判定为新事件而重复创建，造成时间线出现重复条目！
- **修改与删除单条事件**：
  - 修改：优先使用 `edit_file` 精准替换对应行。
  - 删除：可以使用 `edit_file` 将该事件整块替换为空字符串（或用 `write_file` 写回剔除该事件后的文本），底层系统会自动差量软删除对应数据库记录；亦可直接调用 `delete_file(path: "/timeline/<id>.md")` 精确删除。
- **删除整天流水**：调用 `delete_file(path: "/timeline/YYYY-MM-DD.md")`。

## 3. 标准分类与标签规范体系
QNote 时间线卡片有严格的主题色与字段呈现体系。记录流水或打标签时，**一级分类必须对齐标准分类，二级标签优先使用标准字段名**；在标准字段的值中允许自由发挥与细化，兼顾规范与灵活。

### 3.1 核心一级分类（对应卡片专属主题色与图标）
1. **`饮食`**（黄色/餐饮图标）：早餐、午餐、晚餐、下午茶、夜宵、零食水果、饮品咖啡等
2. **`活动`**（绿色/运动图标）：工作、学习、运动、社交、娱乐、通勤、家务、休息、情绪体验等
3. **`睡眠`**（紫色/月亮图标）：夜间睡眠、午休、小憩
4. **`健康`**（专属图标）：身体不适、症状记录、用药、就医、体检
5. **`记账`**（红色/钱包图标）：各类日常消费支出或收入记录
6. **`日常`**（灰色/默认文档）：其他通用日常备忘或未归类生活琐事

### 3.2 标准字段与建议取值（自动渲染为卡片胶囊标签 Pill）
在时间块内使用 `- 字段名: 字段值` 格式，系统会自动将标准字段提炼为卡片上的彩色标签：

- **饮食事件**：
  - `- 评价:` 标准四档：`健康` / `一般` / `不健康` / `过于放纵`（严禁输出无意义的自制/堂食/外卖等渠道种类）。
  - *示例*：
    ```markdown
    ## [12:30] 丰盛双人午餐
    - 分类: 饮食
    - 评价: 一般
    - 内容: 葱姜剁椒清蒸鲈鱼、青菜煎蛋豆腐热汤、辣椒炒肉沫、凉拌猪耳朵拼盘，饭后红豆芋圆西米烧仙草。
    ```
- **活动事件**：
  - `- 类型:` 基础类型 `工作` / `学习` / `运动` / `社交` / `娱乐` / `通勤` / `家务` / `休息` / `情绪`，亦可自由发挥具体项目（如 `羽毛球` / `朋友聚餐` / `架构设计`）。
  - `- 时长:` 如 `1.5小时`。
- **记账事件**：
  - `- 支出类型:` `饮食` / `交通` / `购物` / `娱乐` / `居家` / `人情` / `医疗` / `房租` / `数码` / `教育` / `其他`。
  - `- 收入类型:` `工资` / `奖金` / `红包` / `兼职` / `理财` / `报销` / `其他`。
  - `- 金额:` 数值或带单位，如 `45.5`、`120元`。
- **睡眠事件**：
  - `- 时长:` 如 `7.5小时`。
  - `- 睡眠质量:` `极好` / `良好` / `一般` / `较差`。
  - `- 入睡时间:` 如 `23:30`。
- **健康事件**：
  - `- 症状:` `头痛` / `疲劳` / `失眠` / `胃胀` / `发热` / `咳嗽` / `疼痛` / `过敏` 等。
  - `- 严重程度:` `轻微` / `中度` / `严重`。
  - `- 用药:` 具体药物名称（如 `布洛芬缓释胶囊`）。

### 3.3 自由发挥与标准规范的平衡准则
- **严禁生造一级分类**：不要把“聚餐”、“家常菜”、“甜品”、“羽毛球”直接作为 `- 分类:`，否则卡片会失去颜色和图标；分类必须归入上述六大类之一（如聚餐归入 `饮食` 或 `活动`）。
- **不要写无意义的 `- 标签:` 长串**：不要直接写 `- 标签: 午餐, 家常菜, 聚餐, 甜品`，这样会导致界面把一整段文本作为孤立字段展示；应当拆入标准维度，如 `- 分类: 饮食`、`- 评价: 一般`、详细菜品放入 `- 内容:`。
- **自由细化的正确位置**：允许在 `- 类型:` 的值中个性化填写（例如 `- 类型: 户外徒步`），也可以增加具体自定义指标（如 `- 步数: 8500`、`- 饮水: 600ml`），系统均能智能识别并良好兼容。严禁在饮食中随意添加自制/堂食等无效渠道标签。
''';

  static const String journalManagerDoc = '''---
name: journal-manager
description: 每日深度日记技能：长篇日记、反思复盘、情绪体察与九宫格总结
---

# 每日深度日记技能 (Journal Manager)

在 QNote 中，每天的长篇深度日记保存在 `/journal/YYYY-MM-DD.md` 中。

## 1. 路径规则
- 路径格式：`/journal/YYYY-MM-DD.md`

## 2. 写作前素材准备（联动时间线与健康数据）
- 用户说「帮我写今天的日记」时，先 `read_file(path: "/timeline/YYYY-MM-DD.md")` 获取当天流水事实素材。
- 若用户接入了运动健康设备，还可主动读取 `read_file(path: "/health/YYYY-MM-DD.json")` 获取客观运动步数、睡眠时长、深睡/浅睡比例与静息心率，将身心体感与客观生理数据结合展开深度复盘。
- 周记/月记则读取对应多天的流水与 `/health/recent.json`，**严禁凭空虚构当天事件**。
- 分工：时间线是**客观流水**（何时做了什么），健康数据是**客观生理指标**，日记是**主观深度复盘**（感受、原因、领悟）——日记应引用事实、升华洞察，而不是重复流水。

## 3. 内容结构（按需选择）
### 3.1 默认三段结构
- **今日亮点**：1~3 件最值得称赞或有成就感的事
- **反思与觉察**：遇到的阻碍、情绪波动与应对策略
- **明日期待**：明天最重要的一件事

### 3.2 GRAI 复盘法（目标导向，适合项目/学习复盘）
- **G**oal 回顾目标：当初要达成什么
- **R**esult 对比结果：实际达成与差距
- **A**nalysis 分析原因：主观/客观因素各是什么
- **I**nsight 总结规律：下次可复用的经验

### 3.3 KPT 复盘法（轻量，适合日常迭代）
- **Keep**：今天做得好、要保持的
- **Problem**：遇到的问题
- **Try**：明天想尝试的改进

### 3.4 九宫格总结（快速全景复盘）
用 Markdown 表格呈现 3×3 主题格，主题可按当天情况调整：
```markdown
| 今日亮点 | 情绪 | 健康 |
| --- | --- | --- |
| 学习成长 | 人际 | 消费 |
| 时间利用 | 反思 | 明日期待 |
```

## 4. 情绪记录维度建议
写情绪相关内容时建议覆盖四要素：**心情分（1~5）**、**触发事件**（什么引发的情绪）、**身体感受**（疲惫/紧绷/轻松等）、**应对方式**（做了什么缓解）。

## 5. 核心操作
- **查看日记**：`read_file(path: "/journal/YYYY-MM-DD.md")`
- **编写/覆写**：`write_file(path: "/journal/YYYY-MM-DD.md", content: ...)`
- **追加感悟**：`write_file(path: "/journal/YYYY-MM-DD.md", content: "## 晚间补充\n...", mode: "append")` 直接追加到文末，无需先读整篇；
- **日记不可移动**：日记按日期自动归档，`move_file` 会拒绝——需要改的就直接编辑正文。
''';

  static const String settingsManagerDoc = '''---
name: settings-manager
description: 系统偏好与配置技能：个性化外观、AI模型分配与参数、快捷打卡按键、固定作息、个人画像与云同步配置
---

# 系统配置与偏好管理技能 (Settings Manager)

在 QNote 中，所有系统配置与个性化偏好均组织在 `/settings/` 虚拟目录下，支持直接读取与写入，修改后应用界面将自动实时生效：

## 1. 配置文件清单与格式规范

### 1.1 `/settings/appearance.json`（个性化外观）
控制应用的主题模式与主色调：
```json
{
  "themeMode": "system",   // 可选: "system"(跟随系统) | "light"(浅色模式) | "dark"(深色模式)
  "accentColor": "#005BCB"  // 16 进制颜色（如 #005BCB 经典蓝、#C5E803 荧光黄绿、#E91E8C 玫瑰粉红、#00E676 春天亮绿）
}
```
**场景示例**：
- 用户：“帮我开启深色模式” → 写入 `{"themeMode": "dark"}`
- 用户：“把界面主题色换成粉色” → 写入 `{"accentColor": "#E91E8C"}`

### 1.2 `/settings/ai.json`（AI 模型、角色与参数）
管理小Q自身及时间线提纯所绑定的模型、温度与 Token 预算：
```json
{
  "roles": {
    "assistant": {
      "useFreeModel": true,
      "freeModelId": "gemini-3.5-flash-lite-mix",
      "customModelId": null
    },
    "timelineOptimization": {
      "useFreeModel": true,
      "freeModelId": "gemini-3.5-flash-lite-mix",
      "customModelId": null
    }
  },
  "temperatures": {
    "assistant": {
      "temperature": 0.7,
      "maxTokens": 4096
    },
    "timelineOptimization": {
      "temperature": 0.01,
      "maxTokens": 2048,
      "extractImages": true
    }
  }
}
```
**场景示例**：
- 用户：“把你的温度降低点，回答更严谨” → 写入 `{"temperatures": {"assistant": {"temperature": 0.2}}}`
- 用户：“把小Q切换到 GLM 5.2 模型” → 写入 `{"roles": {"assistant": {"useFreeModel": true, "freeModelId": "glm-5.2"}}}`

### 1.3 `/settings/personality.json`（小Q个性）
读取或切换小Q的人格设定（只改身份与语气，不影响能力）：
```json
{
  "activeId": "default",     // 可选: "default"(经典管家) | "energetic"(活泼元气) | "concise"(简洁干练) | "gentle"(温柔陪伴) | "custom"(自定义)
  "customPrompt": ""         // activeId 为 "custom" 时的人格描述（3~6 句）
}
```
**场景示例**：
- 用户：“你以后说话活泼一点” → 写入 `{"activeId": "energetic"}`
- 用户：“我希望你简洁干练一些” → 写入 `{"activeId": "concise"}`
- 修改后**下轮对话生效**；写入前先 `read_file` 查看 `availablePersonalities` 可选项。

### 1.4 `/settings/shortcuts.json`（首页快捷记录按钮）
定制首页的打卡快捷按键，支持新增、修改与排序：
```json
[
  {
    "id": "shortcut_water",
    "name": "喝水打卡",
    "hasPopup": false,
    "sortOrder": 0,
    "isVisible": true
  }
]
```
- 写入仅支持 `id` / `name` / `hasPopup`（兼容 `has_popup`）/ `sortOrder` / `isVisible`；读取输出中的 `fields`（弹窗预设字段）与 `categories` **写入不会持久化**，需要修改弹窗字段时提醒用户在 App 设置页手动操作。

### 1.5 `/settings/fixed_events.json`（每日固定作息与习惯模板）
管理每天的固定时间段模板（如睡眠、就餐、工作）：
```json
[
  {
    "id": "fixed_sleep",
    "name": "夜间睡眠",
    "isTimePoint": false,
    "timePeriods": [
      { "startTime": "23:30", "endTime": "07:30" }
    ],
    "content": "睡眠",
    "tags": ["shortcut_sleep"],
    "isEnabled": true,
    "sortOrder": 0
  },
  {
    "id": "fixed_work",
    "name": "上班",
    "isTimePoint": false,
    "timePeriods": [
      { "startTime": "08:30", "endTime": "12:00" },
      { "startTime": "13:30", "endTime": "18:00" }
    ],
    "content": "日常工作",
    "tags": ["shortcut_work"],
    "isEnabled": true,
    "sortOrder": 1
  }
]
```
- `timePeriods`: 时间段数组（支持一天内多个时段，如上午和下午分段打卡）；每一项包含 `startTime`（开始 "HH:mm"）和 `endTime`（结束 "HH:mm"）。
- `isTimePoint`: `true` 为单时间点打卡（如早起打卡），此时 `timePeriods` 中只需提供 `startTime`，`endTime` 留空；`false` 为时间段事件。
- `content`: 打卡时默认写入时间线的备注内容（选填）。不需要写入 `icon` 字段。
- `tags`: **必填**，关联标签 ID 数组。每个固定事件必须绑定至少一个快捷标签 ID，否则该事件在日记录入时无法生成带分类的记录。标签 ID 取自 `/settings/shortcuts.json` 中各快捷按钮的 `id` 字段（可通过读取该文件查询可用标签）。新增固定事件时务必填写；编辑现有事件时若未提供 `tags`，将沿用该事件原有标签。

### 1.6 `/settings/profile.json`（个人画像资料）
管理个人昵称、生日、身高、体重、生活目标：
```json
{
  "nickname": "阿强",
  "birthday": "1998-06-18",
  "height": 178.0,
  "otherInfo": "保持健康规律的生活"
}
```

### 1.7 `/settings/webdav.json`（WebDAV 云端同步）
配置 WebDAV 服务器地址、账号与自动同步（字段为下划线风格，`auto_sync` 用 1/0 整数）：
```json
{
  "server_url": "https://dav.example.com",
  "username": "user",
  "password": "pass",
  "remote_path": "QNote",
  "auto_sync": 0,
  "sync_interval": 30
}
```
- `sync_interval` 为自动同步间隔（分钟）；未配置时读取返回 `{"enabled": false}`；写入支持增量合并，只传要改的字段即可。

### 1.8 `/settings/weight.json`（体重与身体健康）
读取当前体重测量历史、BMI 与趋势，写入时可快捷追加一条打卡：`{"weight": 68.5}`。

### 1.9 `/settings/color_marks.json`（日历日期高光打点）
读取或设置特定日期的日历标记圆点。支持 `{"date": "2026-09-11", "color": "红色"}`（支持红色、绿色、蓝色、橙色、紫色或十六进制，传入 "none" 可清除标记）。

## 2. 核心操作
- **读取**：调用 `read_file(path: "/settings/xxx.json")` 获悉当前设置；
- **增量或全量保存**：调用 `write_file(path: "/settings/xxx.json", content: "...")` 或 `edit_file` 精准替换。底层 VFS 会自动做增量合并（Partial Merge），无需担心丢失未修改的字段。
- **配置类文件不支持追加模式**：`/settings/*.json`、`/folders/*.json`、`/chats/*.json` 属结构化数据，`mode: "append"` 会写出非法 JSON 而被拒绝——改配置一律用全量覆写或 `edit_file` 定点修改。
- **不要移动配置文件**：`move_file` 仅支持待办与笔记，配置类路径会直接报错。
''';

  static const String folderManagerDoc = '''---
name: folder-manager
description: 分类与笔记本目录管理技能：查看待办/笔记分类树、重命名分类、调整排序、级联软删除与整理
---

# 分类与笔记本目录管理技能 (Folder Manager)

在 QNote 中，分类与笔记本组织在 `/folders/` 虚拟目录下：

## 1. 虚拟文件清单
- `/folders/todos.json`: 待办分类列表（`id`, `name`, `sortOrder`, `isExpanded`）
- `/folders/notes.json`: 笔记本目录列表（同上字段，另含 `parentId`：父笔记本 id，为 null 即顶层，构成树形嵌套层级）

## 2. 系统默认分类（不可删除）
- 待办分类 `今日`、`长期` 为系统内置默认分类（id 形如 `todo_default_*`），删除操作对其自动跳过；其余分类删除时会级联软删除下属所有条目。

## 3. 核心操作规范
- **查看分类**：使用 `read_file(path: "/folders/todos.json")` 或 `/folders/notes.json`；
- **重命名分类**：使用 `write_file(path: "/folders/todos.json", content: ...)` 传入包含原 ID 和新名称的请求体，系统会保持下属已有待办/笔记关联：
  `[{"id": "原分类ID", "name": "新名称"}]`
- **新增分类**：传入不带 ID 的对象，系统自动生成 ID：
  `[{"name": "投资理财", "sortOrder": 3}]`
- **调整排序**：传入 `[{"id": "xxx", "sortOrder": 5}]`，或传整个数组按新顺序重排（每项含 `id` 与新 `sortOrder`）；
- **把条目移到别的分类/笔记本**：用 `move_file(from: "/todos/今日/周报.md", to: "/todos/工作/周报.md")`（笔记同理，`/notes/<笔记本>/<标题>.md`）；目标分类不存在会自动创建。批量整理时逐个调用，**不要**新建+删除；
- **删除分类目录**：直接调用 `delete_file(path: "/todos/<分类名>/")` 或 `/notes/<笔记本名>/`，底层会自动级联软删除该分类及其下属的所有条目（系统默认分类除外）。
''';

  static const String statsAnalystDoc = '''---
name: stats-analyst
description: 数据洞察与生活评分分析技能：调阅待办完成率、近期作息生活统计、每日AI生活健康评分与改进建议、支持评分与修改
---

# 数据洞察与生活评分分析技能 (Stats Analyst)

在 QNote 中，统计数据组织在 `/stats/` 虚拟目录下：

## 1. 数据端点与字段
- `/stats/summary.json`（近 7 天宏观概览，只读）：
  - `todos`: `total` 总数 / `completed` 已完成 / `pending` 待办 / `completionRate` 完成率
  - `timeline`: `recent7DaysRecordCount` 打卡总数 / `averageMood` 平均情绪 / `categoryDistribution` 分类分布
  - `timeRange`: 统计区间
- `/stats/daily_scores.json`（近 14 天评分数组，只读）：每项含 `date`、`totalScore`（0-100）、`dimensionScores`、`summary`、`suggestions`、`recordCount`
- `/stats/scores/YYYY-MM-DD.json`（单日评分数据，**可读可写可修改**）：
  ```json
  {
    "date": "2026-09-14",
    "totalScore": 86,
    "dimensionScores": {
      "sleep": 88,
      "diet": 82,
      "activity": 85,
      "health": 90,
      "screen": 75
    },
    "summary": "作息规律，晨间运动充足，今日整体状态饱满健康。",
    "suggestions": "晚餐偏晚，建议尽量在 19:30 前完成用餐。",
    "recordCount": 5
  }
  ```

## 2. 评分维度（dimensionScores 键名）
- `sleep` 睡眠：时长 7-9 小时满分，质量良好加分，熬夜扣分；参考小米睡眠时长/深浅REM/得分
- `diet` 饮食：健康饮食加分，不健康扣分，暴饮暴食/过于放纵大幅扣分
- `activity` 活动：运动/学习/工作加分，久坐/无活动扣分；参考小米步数/活跃分钟/站立次数/单次运动
- `health` 健康：按时用药、补水、休息等健康管理行为加分；参考心率/血氧/压力等客观体征
- `screen` 屏幕：屏幕使用时间越短越好，适度使用加分，过度沉迷大幅扣分；参考屏幕总时长与Top应用
- 评分规则：基础分 60 加减分；总分与各维度分范围均为 0~100；症状本身（头痛、感冒等非人为可控因素）不扣分，但忽视健康、不及时处理会扣分。

## 3. 评分与修改指南
- **给当天评分**：先读取 `/timeline/YYYY-MM-DD.md` 提取全天打卡与流水，再读取 `/health/YYYY-MM-DD.json` 小米运动健康客观数据与 `/stats/screen_time.json` 屏幕使用时间作为评分依据；综合评出总分与各维度分（含 sleep/diet/activity/health/screen 五维），调用 `write_file(path: "/stats/scores/YYYY-MM-DD.json", content: ...)` 写入。写入后应用内的环形分值与图表会自动热刷新。
- **微调分数或评语**：用户要求修改某项分数或重新生成评语时，使用 `edit_file` 精准替换对应键值，或用 `write_file` 覆写更新。
- **重置评分**：调用 `delete_file(path: "/stats/scores/YYYY-MM-DD.json")` 删除该天评分记录。

## 4. 空数据处理
- 流水数据完全为空、完成率为 0 或时间线事件不足 3 条时，如实告知「记录不足，暂无法有效分析打分」，并建议用户先记录时间线/待办；**严禁编造数据或评分**，必须基于真实流水依据。

## 5. 典型使用场景
- 用户：“给今天的生活打个分吧” → 先读 `/timeline/YYYY-MM-DD.md` 分析全天记录，计算得分后写入 `/stats/scores/YYYY-MM-DD.json`
- 用户：“总结下我这周的工作和生活” → 查阅 `/stats/summary.json`，根据客观数据总结
- 用户：“我最近作息健康吗？有什么建议？” → 查阅 `/stats/daily_scores.json`，给出基于评分的专业建议
- 用户：“把今天饮食分改成85分” → 读取或直接编辑 `/stats/scores/YYYY-MM-DD.json` 更新分值
- 用户：“根据完成率调整下周计划” → 读 `summary.json` 与待办列表，给出调整建议，用户认可后再写入新待办

## 6. 个性化分析联动
- 健康类分析建议结合 `/settings/profile.json`（身高、生活目标等画像）与 `/settings/weight.json`（体重趋势、BMI）交叉解读，给出贴合用户个人情况的建议。
''';

  static const String frontendDesignDoc = '''---
name: frontend-design
description: 网页设计技能：精美单文件 HTML 网页/落地页/H5/待办打卡工具/海报/邀请函/贺卡/简历页/数据可视化页面等展示与交互型内容的生成规范，涵盖美学方向、移动端适配、动效细节与 LocalStorage 交互状态持久化
---

# 网页设计技能 (Frontend Design)

用户让你「做个网页/页面/待办清单/打卡工具/记账页/海报/邀请函/贺卡/简历页/可视化大屏」时按本手册执行，产出**有设计感、适配手机屏幕、交互状态自留存**的单文件 HTML，避免千篇一律的「AI 生成感」。

## 1. 交付规范（QNote 环境）
- **输出方式**：一次 `write_file(path: "/notes/<标题>.html", content: ...)` 写入**完整单文件 HTML**（以 `<!DOCTYPE html>` 开头），App 会自动渲染网页预览；写完告知用户「已写入 /notes/xx.html，在笔记中点开即可预览」。
- **必备骨架**：`<head>` 中必须有 `<meta name="viewport" content="width=device-width, initial-scale=1.0">` 与 `<title>`；CSS 统一内联在 `<style>` 中。
- **外链资源**：预览支持 Tailwind CDN、Chart.js、Google Fonts 等外链；但字体必须写系统回退栈（如 `font-family: 'Noto Serif SC', 'Songti SC', serif`），关键内容不得依赖外链成功加载。图片优先用 CSS 图形或内联 SVG，外链图床仅作补充。
- **页内导航**：跳转一律用锚点（`href="#section"`）或 JS；**严禁依赖 `<a href="http://...">` 在预览内跳转**——外链点击会被交给系统浏览器打开、脱离笔记预览。
- **局部修改**：用户要求调整时用 `edit_file` 精准替换对应片段，不要整篇推倒重写。

## 2. 设计思考（动笔前先定三件事）
- **用途与受众**：这个页面解决什么问题？给谁看？在什么场合被打开？
- **基调方向**：选定一个极端且自洽的美学方向执行到底，例如：极简留白、极繁铺陈、复古未来、自然有机、奢华精致、玩趣玩具感、编辑杂志风、粗野主义、装饰艺术几何、柔和粉彩、工业实用等。极简与极繁都可以精彩，关键是**有意图**，而非强度堆砌。
- **记忆点**：用户看完能记住的一个东西——一个字体、一种构图、一处动效或一块色彩。先想清楚它，再动笔。

## 3. 美学准则
- **字体**：展示字体（标题）+ 正文字体成对配置形成对比；严禁 Inter/Roboto/Arial/system-ui 充当标识字体。中文可用 Noto Serif SC（宋体感）、LXGW WenKai（楷体手写感）、Noto Sans SC 多字重等，经 Google Fonts CDN 引入。
- **色彩**：用 CSS variables 定义色板；主色主导大面积，强调色只点在 5%-10% 的关键处（按钮、数字、下划线），忌平均分配；明确选 light 或 dark 其一执行到底。
- **动效**：CSS-only 优先。一次编排好的页面入场（`animation-delay` 逐级错峰的 staggered reveals）胜过零碎微交互；`transition` 只写具体属性（如 `transition: transform .3s, opacity .3s`），严禁 `transition: all`。
- **空间构图**：敢于不对称、重叠、斜向流动、破格元素；要么慷慨留白，要么受控的高密度排版，忌不痛不痒的中间态。
- **背景与氛围**：不要默认纯色平铺，用渐变网格、噪点纹理、几何图案、层叠半透明、细网格线等营造层次；装饰必须服务于既定基调。

## 4. 移动端硬性规范（预览容器是手机 WebView，375px 是第一画布）
- 布局先在 375px 宽下校准，再用 `media query` 向平板/宽屏扩展；
- 触控目标 ≥ 44×44px，元素间距防误触；
- `<input>`/`<textarea>` 字号 ≥ 16px（更小会触发 iOS 聚焦自动放大）；
- 交互元素加 `touch-action: manipulation` 消除双击缩放延迟；
- 用 `env(safe-area-inset-*)` 或 `viewport-fit=cover` 适配刘海屏与底部安全区；
- 触屏没有 hover：关键信息与操作入口不能只靠 hover 呈现；
- 只动画 `transform` 与 `opacity`（避免回流重绘），并提供 `@media (prefers-reduced-motion: reduce)` 降级；
- 图片与视频给显式宽高或 `aspect-ratio`，防止加载时布局跳动。

## 5. 工艺细节
- 阴影至少两层：一层大而淡模拟环境光，一层小而实模拟直射光；
- 半透明边框 + 阴影组合能让卡片边缘更锐利；
- 嵌套圆角同心：子元素圆角 ≤ 父元素，且视觉上同心（约等于父圆角减内边距）；
- 非中性色背景上，边框、阴影、文字色调向背景同色相微微偏移更协调；
- 数字对齐比较场景用 `font-variant-numeric: tabular-nums`；
- 语义化标签（header/main/section/footer）；可交互元素给 `:focus-visible` 焦点环；纯图标按钮加 `aria-label`；
- 文案用规范排版字符：弯引号（“ ”）、省略号（…）、间隔号（·）；
- 深色页面设 `color-scheme: dark` 并配 `<meta name="theme-color">`。

## 6. 反模式清单（出现即不合格）
- 紫色渐变 + 白底 + 等宽圆角卡片阵列 = 一眼 AI 生成，严禁；
- Inter/Roboto/system-ui 当标题字体；
- 所有模块同宽同高的均质卡片阵列；
- emoji 满天飞充当图标与装饰；
- 重阴影、大色块等过度装饰抢内容的风头；
- 每次产出长得一样：明暗、字体、构图、风格应随内容轮换，两次产出不应雷同；
- **交互型页面写成纯静态死页面（刷新即丢状态）**。

## 7. 典型工作流
- 用户「帮我做个 XX 网页/海报」→ 心里定下基调与记忆点（不必长篇复述给用户）→ 一次 `write_file` 产出完整单文件 HTML → 告知预览位置；
- 简单小卡片可省略完整流程，但第 6 章反模式清单始终生效；
- **数据可视化**：优先纯 CSS/内联 SVG（不依赖网络，最稳）；需要交互图表时用 Chart.js CDN，并确保断网时页面仍有可读的内容降级；
- 大段数据（表格、榜单）用低饱和底 + 高对比文字，密度可以高，但层级必须清楚。

## 8. 交互与状态持久化规范 (State Persistence)
QNote 预览环境原生开启了 DOM Storage 与独立 Origin 存储沙箱，**全面支持标准 `localStorage` 持久化**。当用户要求制作具有交互实用价值的工具（如待办清单 TodoList、打卡签到、计数器、记账、习惯追踪、问卷、设置、折叠备忘等）时，**必须实现状态本地持久留存**，确保用户退出重新打开后，之前的勾选、输入和操作依然完好保存：
- **数据驱动模式**：定义清晰的数据模型（Array/Object），界面渲染由数据驱动，而非单纯零散修改 DOM；
- **专属存储 Key**：在 `<script>` 开头声明业务唯一 Key，例如 `const STORAGE_KEY = 'qnote_app_todo_v1';`；
- **启动自动读取恢复**：
  ```javascript
  let state = [];
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) state = JSON.parse(raw);
  } catch (e) {
    console.warn('读取本地数据失败', e);
  }
  ```
  页面加载后调用 `render()` 将 `state` 渲染到 DOM 中；
- **交互实时持久化**：用户勾选 Checkbox、编辑文本、新增或删除列表项时，先更新 `state`，再执行：
  ```javascript
  function saveState() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch (e) {
      console.warn('保存数据失败', e);
    }
    render();
  }
  ```
- **贴心配套清空/重置能力**：在页面次要位置（如标题右侧或底部小字）提供小巧的「清空 / 重置数据」操作（带简单确认），执行 `localStorage.removeItem(STORAGE_KEY)` 并重置为默认初始数据；
- **异常保护**：涉及 `localStorage` 的读写必须使用 `try...catch` 包裹，保障极端情况或受限环境下页面基础展示不崩溃。
''';

  /// 获取所有可用 Skill 清单（内置 + 用户技能，含 `origin` 来源标记）
  ///
  /// 默认排除已归档的用户技能（技能索引、skill 工具与小Q视角均不可见）；
  /// [includeArchived] 为 true 时全量返回并附带 `archived` 标记，供管理页展示。
  List<Map<String, String>> listSkills({bool includeArchived = false}) {
    return [
      {
        'name': 'todo-manager',
        'path': '/skills/todo-manager.md',
        'description': '待办事项管理：待办分类（今日/长期/工作/学习等）、GTD任务规划、优先级标记与状态切换',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'note-manager',
        'path': '/skills/note-manager.md',
        'description': '笔记与知识库管理：多层笔记本分类、Markdown 深度排版、标签管理与置顶',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'timeline-manager',
        'path': '/skills/timeline-manager.md',
        'description': '时间线流水记录：每日流水记事、时间戳打卡、情绪与身体状态追踪',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'journal-manager',
        'path': '/skills/journal-manager.md',
        'description': '每日深度日记：长篇日记、反思复盘、情绪体察与九宫格总结',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'folder-manager',
        'path': '/skills/folder-manager.md',
        'description': '分类与笔记本目录管理：查看待办/笔记分类树、重命名分类、调整排序与级联删除',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'settings-manager',
        'path': '/skills/settings-manager.md',
        'description': '系统偏好与配置：外观主题模式与强调色、AI模型分配与参数、快捷打卡按键、固定作息、个人画像与云同步',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'stats-analyst',
        'path': '/skills/stats-analyst.md',
        'description': '数据洞察与生活评分分析：待办完成率汇总、近7天分类统计、每日生活健康总分与维度改进建议',
        'origin': AgentSkillOrigin.builtin,
      },
      {
        'name': 'frontend-design',
        'path': '/skills/frontend-design.md',
        'description': '网页设计：精美单文件 HTML 网页/待办打卡工具/海报/邀请函/简历/数据可视化，美学方向、移动端适配、动效细节与状态本地持久化规范',
        'origin': AgentSkillOrigin.builtin,
      },
      // 用户技能追加在内置之后，由 Agent/UI 按需加载；归档技能默认不可见
      for (final skill in _userSkills)
        if (includeArchived || !skill.archived)
          {
            'name': skill.name,
            'path': AgentSkill.pathOf(skill.name),
            'description': skill.description,
            'origin': AgentSkillOrigin.user,
            if (includeArchived && skill.archived) 'archived': 'true',
          },
    ];
  }

  /// 将技能名或别名解析为技能主名（斜杠命令 / 使用统计共用）
  ///
  /// 返回 null 表示未命中任何内置技能（含别名）与用户技能
  String? resolveSkillName(String nameOrAlias) {
    var key = nameOrAlias.trim();
    if (key.isEmpty) return null;
    if (key.startsWith('/skills/')) {
      key = key.substring('/skills/'.length);
    }
    if (key.startsWith('/.skills/')) {
      key = key.substring('/.skills/'.length);
    }
    if (key.endsWith('.md')) {
      key = key.substring(0, key.length - 3);
    }

    switch (key) {
      case 'todo-manager':
      case 'todo':
      case 'todos':
        return 'todo-manager';
      case 'note-manager':
      case 'note':
      case 'notes':
        return 'note-manager';
      case 'timeline-manager':
      case 'timeline':
        return 'timeline-manager';
      case 'journal-manager':
      case 'journal':
        return 'journal-manager';
      case 'folder-manager':
      case 'folder':
      case 'folders':
        return 'folder-manager';
      case 'settings-manager':
      case 'settings':
      case 'config':
        return 'settings-manager';
      case 'stats-analyst':
      case 'stats':
      case 'statistics':
        return 'stats-analyst';
      case 'frontend-design':
      case 'frontend':
      case 'web-design':
      case 'web':
      case 'design':
      case 'ui':
        return 'frontend-design';
    }
    if (builtinSkillNames.contains(key)) return key;
    for (final skill in _userSkills) {
      if (skill.name == key && !skill.archived) return skill.name;
    }
    return null;
  }

  /// 获取指定技能的手册内容（已归档的用户技能视为不存在）
  String? getSkillContent(String nameOrPath) {
    final key = resolveSkillName(nameOrPath);
    if (key == null) return null;

    switch (key) {
      case 'todo-manager':
        return todoManagerDoc;
      case 'note-manager':
        return noteManagerDoc;
      case 'timeline-manager':
        return timelineManagerDoc;
      case 'journal-manager':
        return journalManagerDoc;
      case 'folder-manager':
        return folderManagerDoc;
      case 'settings-manager':
        return settingsManagerDoc;
      case 'stats-analyst':
        return statsAnalystDoc;
      case 'frontend-design':
        return frontendDesignDoc;
      default:
        // 内置未命中时回退查用户技能（同步读内存缓存；归档技能已排除）
        for (final skill in _userSkills) {
          if (skill.name == key && !skill.archived) return skill.toMarkdown();
        }
        return null;
    }
  }

  // ==========================================
  // 用户技能层：加载 / 查询 / 增删改
  // ==========================================

  /// 确保用户技能缓存已从数据库加载（幂等；并发调用共享同一次加载）
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadingFuture ??= _loadFromDb().whenComplete(() {
      _loaded = true;
      _loadingFuture = null;
    });
  }

  /// 强制从数据库重载用户技能缓存（对话开始、云同步导入后刷新用）
  Future<void> reload() async {
    _loaded = false;
    _loadingFuture = null;
    await ensureLoaded();
  }

  Future<void> _loadFromDb() async {
    final skills = await ConfigRepository.instance.getUserSkills();
    _userSkills
      ..clear()
      ..addAll(skills);
  }

  /// 内置技能主名（用于 UI 来源标记与重名校验）
  static const Set<String> builtinSkillNames = {
    'todo-manager',
    'note-manager',
    'timeline-manager',
    'journal-manager',
    'folder-manager',
    'settings-manager',
    'stats-analyst',
    'frontend-design',
  };

  /// 内置技能别名（getSkillContent 的模糊匹配名，同样禁止用户技能占用）
  static const Set<String> _builtinAliasNames = {
    'todo', 'todos', 'note', 'notes', 'timeline', 'journal',
    'folder', 'folders', 'settings', 'config', 'stats', 'statistics',
    'frontend', 'web-design', 'web', 'design', 'ui',
  };

  /// 名称是否被内置技能（含别名）保留
  bool isReservedName(String name) =>
      builtinSkillNames.contains(name) || _builtinAliasNames.contains(name);

  /// 是否为内置技能主名
  bool isBuiltinSkill(String name) => builtinSkillNames.contains(name);

  /// 获取单个用户技能（未加载时返回 null；UI/Provider 层应先 ensureLoaded）
  AgentSkill? getUserSkill(String name) {
    for (final skill in _userSkills) {
      if (skill.name == name) return skill;
    }
    return null;
  }

  /// 新建或更新一个用户技能（内置名/别名/非法名直接抛异常）
  ///
  /// 仅更新缓存与数据库，不广播事件——Agent 侧写入的广播由 VFS 层负责，
  /// UI 侧写入由 Provider 自行刷新（与 /memory/ 的写入模式一致）。
  Future<void> saveUserSkill(AgentSkill skill) async {
    final name = skill.name.trim();
    if (!AgentSkill.isValidName(name)) {
      throw Exception('技能名称不合法：不能为空、含空白或路径分隔符，且不超过 40 字');
    }
    if (isReservedName(name)) {
      throw Exception('「$name」是内置技能占用的名称，请换一个名字');
    }
    await ensureLoaded();
    final updated = skill.copyWith(name: name, updatedAt: DateTime.now());
    await ConfigRepository.instance.saveUserSkill(updated);
    _userSkills.removeWhere((s) => s.name == name);
    _userSkills.add(updated);
    _userSkills.sort((a, b) => a.name.compareTo(b.name));
  }

  /// 删除一个用户技能（内置技能名直接抛异常）
  Future<void> deleteUserSkill(String name) async {
    if (isBuiltinSkill(name)) {
      throw Exception('内置技能不可删除');
    }
    await ensureLoaded();
    await ConfigRepository.instance.deleteUserSkill(name);
    _userSkills.removeWhere((s) => s.name == name);
    // 同步清理使用统计，避免残留无效记录
    unawaited(SkillUsageTracker.instance.remove(name));
  }

  /// 归档或恢复一个用户技能
  ///
  /// 归档不是删除：技能手册保留在 app_configs，但不再进入技能索引、
  /// 斜杠命令候选与小Q可查阅范围；恢复后即恢复全部可见性。
  Future<void> archiveUserSkill(String name, bool archived) async {
    await ensureLoaded();
    final skill = getUserSkill(name);
    if (skill == null) {
      throw Exception('未找到用户技能「$name」');
    }
    final updated = skill.copyWith(archived: archived, updatedAt: DateTime.now());
    await ConfigRepository.instance.saveUserSkill(updated);
    _userSkills.removeWhere((s) => s.name == name);
    _userSkills.add(updated);
    _userSkills.sort((a, b) => a.name.compareTo(b.name));
  }
}

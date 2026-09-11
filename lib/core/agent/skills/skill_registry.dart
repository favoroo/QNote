/// QNote 内置 Agent 专业技能注册表与手册加载中心
class SkillRegistry {
  static final SkillRegistry instance = SkillRegistry._();
  SkillRegistry._();

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
priority: normal         # normal(普通) | important(重要加急星标)
repeat_rule: none        # none | daily(每天) | workday(工作日) | weekly(每周) | monthly(每月) | yearly(每年)
tags: "学习,技术"        # 待办标签(选填，逗号分隔或字符串数组)
reminder_time: "09-11 19:00" # 提醒时间(选填，格式 MM-DD HH:mm，到点推送通知)
due_date: "2026-09-11 19:00" # 截止时间(选填，仅作记录，不触发通知)
is_long_term: false      # 是否为长期待办(选填)
---
这里是待办事项的详细说明、执行步骤或备注信息。
```

## 3. 核心操作规范
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
- **修改分类**：通过创建新路径并删除旧路径，或使用 `edit_file`。
- **查看待办**：使用 `list_dir(path: "/todos")` 查看分类；使用 `list_dir(path: "/todos/今日")` 查看分类下的所有待办。
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
- **检索笔记**：使用 `grep(query: "关键词", path: "/notes")` 进行跨笔记检索。
- **局部修改**：使用 `edit_file(path: ..., old_text: ..., new_text: ...)` 进行高精度修改。
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
- **追加流水**：通过 `read_file` 查阅当天文件后，使用 `write_file` 在文件末尾追加新的时序块（新块无需 id 注释），或使用 `edit_file` 更新指定事件。
- **id 注释必须原样保留（最高优先级）**：重写或整理当天文件时，已有块的 `<!-- id: xxx -->` 必须一字不差地带回。若 id 丢失，对应记录会被判定为新事件而重复创建，造成时间线出现重复条目！
- **修改与删除单条事件**：
  - 修改：优先使用 `edit_file` 精准替换对应行。
  - 删除：可以使用 `edit_file` 将该事件整块替换为空字符串（或用 `write_file` 写回剔除该事件后的文本），底层系统会自动差量软删除对应数据库记录；亦可直接调用 `delete_file(path: "/timeline/<id>.md")` 精确删除。
- **删除整天流水**：调用 `delete_file(path: "/timeline/YYYY-MM-DD.md")`。
- **打卡分类**：推荐使用标准分类如：`饮食`, `工作`, `运动`, `休息`, `心情`, `日常`。
''';

  static const String journalManagerDoc = '''---
name: journal-manager
description: 每日深度日记技能：长篇日记、反思复盘、情绪体察与九宫格总结
---

# 每日深度日记技能 (Journal Manager)

在 QNote 中，每天的长篇深度日记保存在 `/journal/YYYY-MM-DD.md` 中。

## 1. 路径规则
- 路径格式：`/journal/YYYY-MM-DD.md`

## 2. 内容建议结构
- **今日亮点**：1~3 件最值得称赞或有成就感的事
- **反思与觉察**：遇到的阻碍、情绪波动与应对策略
- **明日期待**：明天最重要的一件事

## 3. 核心操作
- **查看日记**：`read_file(path: "/journal/YYYY-MM-DD.md")`
- **编写/覆写**：`write_file(path: "/journal/YYYY-MM-DD.md", content: ...)`
- **追加感悟**：`read_file` 取得内容后在文末追加新的段落并 `write_file`。
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
      "freeModelId": "gemini-3.5-flash-lite",
      "customModelId": null
    },
    "timelineOptimization": {
      "useFreeModel": true,
      "freeModelId": "gemini-3.5-flash-lite",
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

### 1.3 `/settings/shortcuts.json`（首页快捷记录按钮）
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

### 1.4 `/settings/fixed_events.json`（每日固定作息与习惯模板）
管理每天的固定时间段模板（如睡眠、就餐、工作）：
```json
[
  {
    "id": "fixed_sleep",
    "name": "夜间睡眠",
    "startTime": "23:30",
    "endTime": "07:30",
    "isTimePoint": false,
    "isEnabled": true
  }
]
```

### 1.5 `/settings/profile.json`（个人画像资料）
管理个人昵称、生日、身高、体重、生活目标：
```json
{
  "nickname": "阿强",
  "birthday": "1998-06-18",
  "height": 178.0,
  "otherInfo": "保持健康规律的生活"
}
```

### 1.6 `/settings/webdav.json`（WebDAV 云端同步）
配置 WebDAV 服务器地址、用户名、密码与自动同步。

### 1.7 `/settings/weight.json`（体重与身体健康）
读取当前体重测量历史、BMI 与趋势，写入时可快捷追加一条打卡：`{"weight": 68.5}`。

### 1.8 `/settings/color_marks.json`（日历日期高光打点）
读取或设置特定日期的日历标记圆点。支持 `{"date": "2026-09-11", "color": "红色"}`（支持红色、绿色、蓝色、橙色、紫色或十六进制，传入 "none" 可清除标记）。

## 2. 核心操作
- **读取**：调用 `read_file(path: "/settings/xxx.json")` 获悉当前设置；
- **增量或全量保存**：调用 `write_file(path: "/settings/xxx.json", content: "...")` 或 `edit_file` 精准替换。底层 VFS 会自动做增量合并（Partial Merge），无需担心丢失未修改的字段。
''';

  static const String folderManagerDoc = '''---
name: folder-manager
description: 分类与笔记本目录管理技能：查看待办/笔记分类树、重命名分类、调整排序、级联软删除与整理
---

# 分类与笔记本目录管理技能 (Folder Manager)

在 QNote 中，分类与笔记本组织在 `/folders/` 虚拟目录下：

## 1. 虚拟文件清单
- `/folders/todos.json`: 待办分类列表（`id`, `name`, `sortOrder`, `isExpanded`）
- `/folders/notes.json`: 笔记本目录列表（支持 `parentId` 树形嵌套层级）

## 2. 核心操作规范
- **查看分类**：使用 `read_file(path: "/folders/todos.json")` 或 `/folders/notes.json`；
- **重命名分类**：使用 `write_file` 传入包含原 ID 和新名称的 JSON：
  `[{"id": "xxx", "name": "新名称"}]`，系统会自动保存并保持下属已有待办/笔记关联；
- **新增分类**：传入不带 ID 或新 ID 的对象：
  `[{"name": "投资理财", "sortOrder": 3}]`；
- **删除分类目录**：直接调用 `delete_file(path: "/todos/<分类名>/")` 或 `/notes/<笔记本名>/`，底层会自动级联软删除该分类及其下属的所有条目（系统默认分类除外）。
''';

  static const String statsAnalystDoc = '''---
name: stats-analyst
description: 数据洞察与生活评分分析技能：调阅待办完成率、近期作息生活统计、每日AI生活健康评分与改进建议
---

# 数据洞察与生活评分分析技能 (Stats Analyst)

在 QNote 中，统计数据组织在 `/stats/` 虚拟目录下：

## 1. 数据端点
- `/stats/summary.json`: 宏观完成度概览（待办总数、完成率、近 7 天时间线打卡总数、分类分布、平均情绪分等）
- `/stats/daily_scores.json`: 每日健康与生活评分（AI 综合总分 0-100、各维度细分评分、日常总结与个性化建议）

## 2. 典型使用场景
- 用户：“总结下我这周的工作和生活” → 查阅 `/stats/summary.json`，根据客观数据总结
- 用户：“我最近作息健康吗？有什么建议？” → 查阅 `/stats/daily_scores.json`，给出基于评分的专业建议
''';

  /// 获取所有可用 Skill 清单
  List<Map<String, String>> listSkills() {
    return [
      {
        'name': 'todo-manager',
        'path': '/skills/todo-manager.md',
        'description': '待办事项管理：待办分类（今日/长期/工作/学习等）、GTD任务规划、优先级标记与状态切换',
      },
      {
        'name': 'note-manager',
        'path': '/skills/note-manager.md',
        'description': '笔记与知识库管理：多层笔记本分类、Markdown 深度排版、标签管理与置顶',
      },
      {
        'name': 'timeline-manager',
        'path': '/skills/timeline-manager.md',
        'description': '时间线流水记录：每日流水记事、时间戳打卡、情绪与身体状态追踪',
      },
      {
        'name': 'journal-manager',
        'path': '/skills/journal-manager.md',
        'description': '每日深度日记：长篇日记、反思复盘、情绪体察与九宫格总结',
      },
      {
        'name': 'folder-manager',
        'path': '/skills/folder-manager.md',
        'description': '分类与笔记本目录管理：查看待办/笔记分类树、重命名分类、调整排序与级联删除',
      },
      {
        'name': 'settings-manager',
        'path': '/skills/settings-manager.md',
        'description': '系统偏好与配置：外观主题模式与强调色、AI模型分配与参数、快捷打卡按键、固定作息、个人画像与云同步',
      },
      {
        'name': 'stats-analyst',
        'path': '/skills/stats-analyst.md',
        'description': '数据洞察与生活评分分析：待办完成率汇总、近7天分类统计、每日生活健康总分与维度改进建议',
      },
    ];
  }

  /// 获取指定技能的手册内容
  String? getSkillContent(String nameOrPath) {
    var key = nameOrPath.trim();
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
        return todoManagerDoc;
      case 'note-manager':
      case 'note':
      case 'notes':
        return noteManagerDoc;
      case 'timeline-manager':
      case 'timeline':
        return timelineManagerDoc;
      case 'journal-manager':
      case 'journal':
        return journalManagerDoc;
      case 'folder-manager':
      case 'folder':
      case 'folders':
        return folderManagerDoc;
      case 'settings-manager':
      case 'settings':
      case 'config':
        return settingsManagerDoc;
      case 'stats-analyst':
      case 'stats':
      case 'statistics':
        return statsAnalystDoc;
      default:
        return null;
    }
  }
}

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
due_date: "2026-09-11 12:00" # 截止时间(选填)
is_long_term: false      # 是否为长期待办(选填)
---
这里是待办事项的详细说明、执行步骤或备注信息。
```

## 3. 核心操作规范
- **新建待办**：使用 `write_file(path: "/todos/分类/标题.md", content: "...")`。
  - 用户说“帮我加个中午拿快递的待办”，未指定分类时，默认写入 `/todos/今日/拿快递.md`。
  - 用户说“在工作待办里添加准备周报”，写入 `/todos/工作/准备周报.md`。
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
- 内容: 喝了一杯拿铁，吃全麦面包，精神饱满。

## [14:00] 技术评审会议 <!-- id: 9a8b7c6d-5e4f-3a2b-1c0d-9e8f7a6b5c4d -->
- 分类: 工作
- 心情: 5
- 内容: 完成了虚拟工作区 VFS 架构方案的确认。
```

## 2. 核心操作规范
- **追加流水**：通过 `read_file` 查阅当天文件后，使用 `write_file` 在文件末尾追加新的时序块（新块无需 id 注释），或使用 `edit_file` 更新指定事件。
- **id 注释必须原样保留（最高优先级）**：重写或整理当天文件时，已有块的 `<!-- id: xxx -->` 必须一字不差地带回。若 id 丢失，对应记录会被判定为新事件而重复创建，造成时间线出现重复条目！
- **避免整篇重写**：修改单条事件优先使用 `edit_file` 精准替换对应行，不要用 `write_file` 重写全天内容。
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
description: 系统偏好与配置技能：个人信息画像、WebDAV云同步与快捷记录配置
---

# 系统配置与偏好管理技能 (Settings Manager)

在 QNote 中，核心配置文件组织在 `/settings/` 目录下：

## 1. 文件清单
- `/settings/profile.json`: 个人资料（昵称、性别、生日、身高、体重、生活目标）
- `/settings/webdav.json`: WebDAV 远端同步配置（服务器地址、用户名、密码、同步目录）
- `/settings/shortcuts.json`: 首页快捷记录配置

## 2. 核心操作
- 使用 `read_file` 查看 JSON，使用 `edit_file` 或 `write_file` 更新指定字段。
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
        'name': 'settings-manager',
        'path': '/skills/settings-manager.md',
        'description': '系统偏好与配置：个人信息画像、WebDAV云同步与快捷记录配置',
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
      case 'settings-manager':
      case 'settings':
      case 'config':
        return settingsManagerDoc;
      default:
        return null;
    }
  }
}

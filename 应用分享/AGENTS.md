# Agent 工作指南

## 项目简介

QNote 是一个 **Flutter 多平台应用**（Web / iOS / Android），核心功能为日记/快捷记录、笔记、待办、AI 智能分析、数据统计。

### 项目结构

```
项目根目录/
├── lib/
│   ├── main.dart / app.dart              # 应用入口与配置
│   ├── database_init.dart / _io.dart     # 数据库初始化
│   ├── config/                           # 默认提示词、AI 服务商模型
│   ├── core/
│   │   ├── ai/                           # AI 服务与角色
│   │   ├── export/                       # 数据导出
│   │   ├── logger/                       # 日志
│   │   ├── network/                      # WebDAV 同步
│   │   ├── notification/                 # 本地通知
│   │   ├── router/                       # 路由
│   │   ├── storage/                      # 数据存储层（各 repository）
│   │   ├── theme/                        # 主题定义（app_theme.dart）
│   │   ├── utils/                        # 工具函数
│   │   └── back_handler.dart             # 返回键处理
│   ├── models/                           # 数据模型
│   ├── pages/                            # 页面（含 settings/ 子目录）
│   ├── providers/                        # 状态管理 (Provider)
│   └── widgets/                          # UI 组件
│       ├── diary/                        # 日记组件
│       ├── notes/                        # 笔记组件
│       └── statistics/                   # 统计组件
├── assets/                               # 静态资源
├── web/                                  # Web 平台配置
└── AGENTS.md
```

---

## 功能模块与文件定位

### 1. 日记/快捷记录 (Diary)

通过自然语言或图片快速记录生活数据（睡眠、饮食、活动、记账等）

| 模块 | 文件 |
|------|------|
| 页面 | `lib/pages/diary_page.dart` |
| 编辑器 | `lib/widgets/diary/diary_editor_view.dart` |
| 输入栏 | `lib/widgets/diary/diary_input_bar.dart` |
| 列表项 | `lib/widgets/diary/diary_item.dart` |
| 批量管理 | `lib/widgets/diary/diary_batch_manage_view.dart` |
| AI 提取辅助 | `lib/widgets/diary/ai_extract_helper.dart` |
| 日期选择器 | `lib/widgets/diary/custom_date_picker.dart` |
| 状态管理 | `lib/providers/diary_provider.dart` |
| 数据存储 | `lib/core/storage/diary_repository.dart` |

### 2. 笔记 (Notes)

| 模块 | 文件 |
|------|------|
| 页面 | `lib/pages/notes_page.dart` |
| 编辑器 | `lib/widgets/notes/note_editor_view.dart` |
| 状态管理 | `lib/providers/note_provider.dart` |
| 数据存储 | `lib/core/storage/note_repository.dart` |

### 3. 待办事项 (Todo)

| 模块 | 文件 |
|------|------|
| 页面 | `lib/pages/todo_page.dart` |
| 状态管理 | `lib/providers/todo_provider.dart` |
| 数据存储 | `lib/core/storage/todo_repository.dart` |

### 4. AI 助手

智能分析日记数据、自然语言解析、图片识别

| 模块 | 文件 |
|------|------|
| 页面 | `lib/pages/ai_page.dart` |
| AI 服务 | `lib/core/ai/ai_service.dart` |
| 角色配置 | `lib/core/ai/ai_role_service.dart` |
| 状态管理 | `lib/providers/ai_provider.dart` |
| AI 配置模型 | `lib/models/ai_config.dart`, `lib/models/ai_roles.dart` |
| AI 服务商模型 | `lib/config/models.dart` |
| 默认提示词 | `lib/config/defaults.dart` |

### 5. 数据统计 (Statistics)

睡眠、饮食、活动、财务、心情等数据可视化分析

| 模块 | 文件 |
|------|------|
| 页面 | `lib/pages/statistics_page.dart` |
| 睡眠统计 | `lib/widgets/statistics/sleep_stats.dart` |
| 饮食统计 | `lib/widgets/statistics/diet_stats.dart` |
| 活动统计 | `lib/widgets/statistics/activity_stats.dart` |
| 财务统计 | `lib/widgets/statistics/finance_stats.dart` |
| 心情统计 | `lib/widgets/statistics/mood_stats.dart` |
| 工具函数 | `lib/core/utils/stats_utils.dart` |

### 6. 设置页面 (Settings)

`lib/pages/settings/` 目录下：`ai_config_page` / `user_profile_page` / `shortcuts_page` / `sync_settings_page` / `data_management_page` / `personalization_page` / `about_page`

### 7. 数据存储层 (Storage)

`lib/core/storage/` 目录下，包含 `database_helper` 及各模块 repository：`diary` / `note` / `todo` / `folder` / `image` / `config` / `color_mark`

### 8. 辅助模块

| 模块 | 关键文件 | 说明 |
|------|---------|------|
| 同步 | `webdav_service.dart`, `sync_scheduler.dart`, `sync_provider.dart` | WebDAV 同步 |
| 主题 | `app_theme.dart`, `theme_provider.dart` | 主题定义与切换 |
| 快捷记录 | `shortcut_config.dart`, `shortcut_field.dart`, `shortcut_category.dart`, `shortcut_provider.dart` | 快捷记录类型与字段 |
| 用户资料 | `user_profile.dart`, `user_profile_provider.dart` | 身高体重等 |
| 文件夹 | `folder.dart`, `folder_provider.dart`, `folder_repository.dart` | 分类管理 |
| 导航 | `navigation_provider.dart`, `bottom_nav_bar.dart`, `side_drawer.dart`, `top_tab_switcher.dart` | 导航状态与组件 |
| 通知 | `notification_service.dart` | 本地通知 |
| 导出 | `export_service.dart` | 数据导出 |
| 路由 | `app_router.dart` | 页面导航 |
| 日志 | `logger_service.dart` | 调试日志 |
| 返回处理 | `back_handler.dart` | 物理返回键 |
| 图片选择 | `gallery_helper.dart` | 相机/相册 |
| Delta 转换 | `delta_markdown.dart` | Delta JSON 转 Markdown |
| Toast | `toast_utils.dart` | 轻提示 |

### 9. 通用 UI 组件 (Widgets)

`lib/widgets/` 目录下，跨模块复用组件：`action_menu` / `animated_gradient_border` / `birthday_picker` / `date_picker_input` / `date_range_picker` / `debug_console` / `search_view` / `select` / `stats_card` / `tag_picker` / `time_picker` / `time_range_selector` / `time_scroll_picker` / `unified_image`

### 10. 数据模型 (Models)

`lib/models/` 目录下：`diary_record` / `note` / `todo` / `folder` / `ai_config` / `ai_roles` / `user_profile` / `webdav_config` / `weight_record` / `body_state` / `chat_session` / `date_color_mark` / `shortcut_config` / `shortcut_field` / `shortcut_category` / `tag_entry`

---

## UI 设计风格指南

设计或修改 UI 时遵循本规范。主题默认值以 `lib/core/theme/app_theme.dart` 为准；页面级强化样式以本节令牌表为准。

### 1. 设计原则

- **信息密度优先**：内容完整可读，不为极简牺牲关键信息
- **Material 3 + 主题令牌**：颜色/圆角/字重优先 `Theme.of(context).colorScheme` 与 `textTheme`，禁止随意写死 hex（图表等特殊色除外）
- **扁平柔和**：`elevation: 0` 为主，用细边框 + 低透明度阴影区分层级
- **深浅色一致**：同一组件在 light/dark 下语义相同（边框、填充、文字层级一一对应）

### 2. 设计令牌速查

**圆角层级**

| 层级 | 圆角 | 典型场景 |
|------|------|----------|
| XL | 24 | 页面主卡片、BottomSheet/SnackBar、大面板 |
| L | 16–20 | 内容块、设置项容器、对话框（主题默认 20） |
| M | 12–16 | 列表内卡片、统计卡片（如 `stats_card`） |
| S | 10 | 按钮、Chip、ListTile（与 AppTheme 默认一致） |
| XS | 8–10 | 图标背景容器 |

**颜色语义**（统一用 `colorScheme`，勿硬编码）

| 用途 | 写法 |
|------|------|
| 卡片底 | `surface` |
| 浅色衬底/分组 | `surfaceContainerLowest.withValues(alpha: 0.5)` |
| 输入/次级块填充 | `surfaceContainerHighest.withValues(alpha: 0.3)` |
| 分隔线 | `outlineVariant.withValues(alpha: 0.3)` |
| 卡片边框 | `outlineVariant.withValues(alpha: 0.5)` |
| 正文/次要文字 | `onSurface` / `onSurfaceVariant` |
| 强调/选中 | `primary` / `primaryContainer` |

**间距**：以 8 为网格——`8 / 12 / 16 / 24`；卡片内边距默认 `16`，区块间距 `12–16`

**阴影**（统一使用，避免多层强阴影）：

```dart
BoxShadow(
  color: Colors.black.withValues(alpha: 0.02),
  blurRadius: 10,
  offset: Offset(0, 4),
)
```

### 3. 组件规范

**卡片容器**——内容区块封装在卡片中：

```dart
decoration: BoxDecoration(
  color: theme.colorScheme.surface,
  borderRadius: BorderRadius.circular(16), // 整页级面板用 24
  border: Border.all(
    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
  ),
  boxShadow: [/* 见上方阴影 */],
)
```

**输入与表单**

- 无边框线风格：filled + 圆角 16 + `surfaceContainerHighest.withValues(alpha: 0.3)` 填充
- Focus：`primary` 1–1.5px 描边；hint/label 用 `onSurfaceVariant`
- 优先 `InputDecorationTheme`；同一页面内不混用 10px 与 16px 圆角输入风格

**按钮与图标操作**

- `elevation: 0`；主按钮用 `ElevatedButton` 主题样式
- 图标底：`Container(decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)))`
- 最小点击区域 ≥ 44×44

**导航**

- 顶栏：`elevation: 0`、`scrolledUnderElevation: 0`；标题 `fontWeight: FontWeight.w600` 或 `bold`
- 内容页沉浸：仅在有背景图/渐变时用 `backgroundColor: Colors.transparent`，否则跟 `AppBarTheme`
- 底栏：顶部分割线 `outlineVariant.withValues(alpha: 0.3)`，背景 `surface`

**列表与弹层**

- 列表项圆角 10–12，分隔 `Divider(color: outlineVariant.withValues(alpha: 0.3))`
- Dialog 20 / BottomSheet 顶圆角 16 / SnackBar 24（与 AppTheme 一致）

### 4. 交互与反馈

- **操作反馈**：成功/失败用 `lib/core/utils/toast_utils.dart`；耗时操作用 loading 或按钮 disabled，避免无响应
- **状态可见**：选中态用 `primary` 背景或 `fontWeight: bold`；禁用态降低透明度，不单靠变灰
- **动效**：状态切换用 `AnimatedContainer` / `AnimatedSwitcher`，时长 200–300ms，曲线 `Curves.easeInOut`
- **手势**：破坏性操作二次确认；侧滑/长按与 diary、notes 现有行为保持一致

### 5. 实施检查清单

改 UI 前逐项确认：

1. 能否复用 `lib/widgets/` 已有组件（`stats_card`、`select`、`date_picker_input` 等）？
2. 颜色是否全部来自 `colorScheme`？
3. 圆角是否落在令牌表某一档（同页不随意混用）？
4. 深浅色下对比度是否可读？

### 6. 禁止项

- 禁止为「好看」新建随机圆角/阴影/配色
- 禁止页面级 `elevation > 0`（FAB 除外）
- 禁止复制粘贴大段 Decoration；重复样式应提取为 widget

---

## Flutter 开发流程

### 重要：代码修改后的预览方式

**禁止**每次修改代码后运行新的 `flutter run` 命令！

项目通常已有一个正在运行的 `flutter run` 进程（通常为 `flutter run -d chrome --web-port=8080`）。

#### 正确做法：
1. 修改代码后，通知用户在已运行的 Flutter 终端中按 `r` 热重载（Hot Reload）
2. 如需完全重启，通知用户按 `R` 热重启（Hot Restart）

#### 错误做法（请避免）：
- ❌ 运行 `flutter run -d chrome` 启动新的预览
- ❌ 运行 `flutter run --web-port=xxxxx` 启动新的预览

### 原因：
- 多个 `flutter run` 进程占用大量系统资源
- 热重载（按 `r`）是 Flutter 核心特性，速度更快（通常 < 1秒）

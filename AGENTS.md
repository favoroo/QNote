# Agent 工作指南

## 项目简介

QNote 是一个 **Flutter 多平台应用**（Web / iOS / Android），核心功能为日记/快捷记录、笔记、待办、AI 智能分析、数据统计。

### 项目结构

```
qnote_flutter/
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
│   │   ├── theme/                        # 主题定义
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
├── android/ / windows/                   # 原生平台配置
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

设计或修改 UI 时，严格遵循以下规范：

### 1. 整体美学
- **信息密度优先**：优先保证内容可读和信息展示完整，避免为"极简"牺牲信息密度
- **背景颜色**：浅色/柔和色调，如 `colorScheme.surfaceContainerLowest.withValues(alpha: 0.5)`
- **阴影与质感**：柔和弥散微阴影，避免强烈投影

### 2. 卡片化布局
- 内容区块封装在卡片中
- 圆角较大：`BorderRadius.circular(24)` 或 `16`
- 边框极细半透明：`Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5))`
- 阴影参考：`BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: Offset(0, 4))`

### 3. 输入框与表单
- 无边框底色，用带浅色填充的圆角框
- `fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)`，`BorderRadius.circular(16)`
- Focused 时带主题色细边框

### 4. 按钮与操作区
- 大圆角：`BorderRadius.circular(16)` 或 `20`
- 零浮现：`elevation: 0`
- 图标包裹在轻微透明背景色 Container 中：`iconColor.withValues(alpha: 0.1)` + `BorderRadius.circular(10)`

### 5. 导航栏
- 透明沉浸：`backgroundColor: Colors.transparent`，`elevation: 0`，`scrolledUnderElevation: 0`
- 标题加粗：`fontWeight: FontWeight.bold`

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

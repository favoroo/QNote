# Agent 工作指南

## 项目简介

这是一个 **Flutter 项目**，从原有的 React Web 应用转化而来。

- **原始项目位置**: `c:\01Code\qnote_flutter\01旧架构数据\`
- **技术栈**: Flutter (支持 Web、iOS、Android 多平台)
- **主要功能**: 笔记/日记记录、AI 分析、数据统计

### 项目结构

```
qnote_flutter/
├── lib/                    # Flutter Dart 源代码
│   ├── main.dart           # 应用入口
│   ├── app.dart            # App 配置
│   ├── config/             # 配置文件
│   ├── core/               # 核心功能模块
│   ├── models/             # 数据模型
│   ├── pages/              # 页面
│   ├── providers/          # 状态管理 (Provider)
│   └── widgets/            # UI 组件
├── 01旧架构数据/            # 原始 React 项目（参考用）
├── web/                    # Web 平台配置
└── AGENTS.md               # 本文件 - Agent 工作指南
```

---

## 功能模块与文件定位

### 1. 日记/快捷记录 (Diary)

核心功能：通过自然语言或图片快速记录生活数据（睡眠、饮食、活动、记账等）

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 页面 | `lib/pages/diary_page.dart` | `src/pages/DiaryPage.tsx` |
| 编辑器 | `lib/widgets/diary/diary_editor_view.dart` | `src/components/DiaryEditorView.tsx` |
| 列表项 | `lib/widgets/diary/diary_item.dart` | `src/components/DiaryItem.tsx` |
| 批量管理 | `lib/widgets/diary/diary_batch_manage_view.dart` | `src/components/DiaryBatchManageView.tsx` |
| 状态管理 | `lib/providers/diary_provider.dart` | `src/hooks/useDiary.ts` |
| 数据存储 | `lib/core/storage/diary_repository.dart` | - |

### 2. 笔记 (Notes)

核心功能：自由格式的笔记记录和管理

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 页面 | `lib/pages/notes_page.dart` | `src/pages/NotesPage.tsx` |
| 编辑器 | `lib/widgets/notes/note_editor_view.dart` | `src/components/NoteEditorView.tsx` |
| 状态管理 | `lib/providers/note_provider.dart` | `src/hooks/useNotes.ts` |
| 数据存储 | `lib/core/storage/note_repository.dart` | - |

### 3. 待办事项 (Todo)

核心功能：任务管理和提醒

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 页面 | `lib/pages/todo_page.dart` | `src/pages/TodoPage.tsx` |
| 状态管理 | `lib/providers/todo_provider.dart` | `src/hooks/useTodo.ts` |
| 数据存储 | `lib/core/storage/todo_repository.dart` | - |

### 4. AI 助手

核心功能：智能分析日记数据、自然语言解析、图片识别

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 页面 | `lib/pages/ai_page.dart` | `src/pages/AIPage.tsx` |
| AI 服务 | `lib/core/ai/ai_service.dart` | `src/lib/gemini.ts` |
| 角色配置 | `lib/core/ai/ai_role_service.dart` | - |
| 状态管理 | `lib/providers/ai_provider.dart` | `src/context/AIContext.tsx` |
| AI 配置模型 | `lib/models/ai_config.dart`, `lib/models/ai_roles.dart` | - |
| 默认提示词 | `lib/config/defaults.dart` | `src/config/defaults.ts` |

### 5. 数据统计 (Statistics)

核心功能：睡眠、饮食、活动、财务、心情等数据可视化分析

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 页面 | `lib/pages/statistics_page.dart` | `src/pages/StatisticsPage.tsx` |
| 睡眠统计 | `lib/widgets/statistics/sleep_stats.dart` | `src/components/statistics/SleepStats.tsx` |
| 饮食统计 | `lib/widgets/statistics/diet_stats.dart` | `src/components/statistics/DietStats.tsx` |
| 活动统计 | `lib/widgets/statistics/activity_stats.dart` | `src/components/statistics/ActivityStats.tsx` |
| 财务统计 | `lib/widgets/statistics/finance_stats.dart` | `src/components/statistics/FinanceStats.tsx` |
| 心情统计 | `lib/widgets/statistics/mood_stats.dart` | `src/components/statistics/MoodStats.tsx` |
| 工具函数 | `lib/core/utils/stats_utils.dart` | `src/lib/statsUtils.ts` |

### 6. 设置页面 (Settings)

| 模块 | Flutter 文件 |
|------|-------------|
| AI 配置 | `lib/pages/settings/ai_config_page.dart` |
| 用户资料 | `lib/pages/settings/user_profile_page.dart` |
| 快捷记录配置 | `lib/pages/settings/shortcuts_page.dart` |
| 同步设置 | `lib/pages/settings/sync_settings_page.dart` |
| 数据管理 | `lib/pages/settings/data_management_page.dart` |
| 个性化 | `lib/pages/settings/personalization_page.dart` |
| 关于 | `lib/pages/settings/about_page.dart` |

### 7. 数据存储层 (Storage)

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 数据库初始化 | `lib/database_init.dart`, `lib/database_init_io.dart` | - |
| 数据库助手 | `lib/core/storage/database_helper.dart` | - |
| 日记存储 | `lib/core/storage/diary_repository.dart` | `src/lib/storage.ts` |
| 笔记存储 | `lib/core/storage/note_repository.dart` | - |
| 待办存储 | `lib/core/storage/todo_repository.dart` | - |
| 文件夹存储 | `lib/core/storage/folder_repository.dart` | - |
| 图片存储 | `lib/core/storage/image_repository.dart` | - |
| 配置存储 | `lib/core/storage/config_repository.dart` | - |

### 8. 同步与网络 (Sync)

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| WebDAV 服务 | `lib/core/network/webdav_service.dart` | - |
| 同步调度 | `lib/core/network/sync_scheduler.dart` | `src/services/syncService.ts` |
| 状态管理 | `lib/providers/sync_provider.dart` | - |

### 9. 主题与样式 (Theme)

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 主题定义 | `lib/core/theme/app_theme.dart` | - |
| 状态管理 | `lib/providers/theme_provider.dart` | `src/context/ThemeContext.tsx` |

### 10. 快捷记录配置 (Shortcuts)

核心功能：定义快捷记录的类型和字段（睡眠、饮食、活动、记账等）

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 模型 | `lib/models/shortcut_config.dart`, `lib/models/shortcut_field.dart`, `lib/models/shortcut_category.dart` | `src/config/defaults.ts` |
| 状态管理 | `lib/providers/shortcut_provider.dart` | - |

### 11. 用户数据 (User Profile)

| 模块 | Flutter 文件 | 原项目参考 |
|------|-------------|-----------|
| 模型 | `lib/models/user_profile.dart` | - |
| 状态管理 | `lib/providers/user_profile_provider.dart` | `src/hooks/useUser.ts` |

### 12. 其他核心模块

| 模块 | Flutter 文件 | 说明 |
|------|-------------|------|
| 路由 | `lib/core/router/app_router.dart` | 页面导航 |
| 通知 | `lib/core/notification/notification_service.dart` | 本地通知 |
| 导出 | `lib/core/export/export_service.dart` | 数据导出 |
| 日志 | `lib/core/logger/logger_service.dart` | 调试日志 |
| 返回处理 | `lib/core/back_handler.dart` | 物理返回键 |

---

## 数据模型 (Models)

| 模型 | 文件 | 说明 |
|------|------|------|
| 日记记录 | `lib/models/diary_record.dart` | 日记数据结构 |
| 笔记 | `lib/models/note.dart` | 笔记数据结构 |
| 待办 | `lib/models/todo.dart` | 待办事项数据结构 |
| 文件夹 | `lib/models/folder.dart` | 分类文件夹 |
| AI 配置 | `lib/models/ai_config.dart` | AI 服务配置 |
| AI 角色 | `lib/models/ai_roles.dart` | AI 角色定义 |
| 用户资料 | `lib/models/user_profile.dart` | 用户身高体重等 |
| WebDAV 配置 | `lib/models/webdav_config.dart` | 同步服务配置 |
| 体重记录 | `lib/models/weight_record.dart` | 体重追踪 |
| 身体状态 | `lib/models/body_state.dart` | 身体状态记录 |
| 聊天会话 | `lib/models/chat_session.dart` | AI 聊天记录 |
| 日期标记 | `lib/models/date_color_mark.dart` | 日历日期标记 |

---

## 参考资源

- 原始 React 项目的组件、逻辑可作为转化参考
- 原项目使用 React + TypeScript + Vite，现已迁移至 Flutter
- 原项目配置文件 `src/config/defaults.ts` 包含默认的 AI 提示词和快捷记录配置

---

## UI 设计风格指南 (UI Design Guidelines)

为了保持 QNote 应用的整体风格统一且具有现代高级感，后续 Agent 在设计或修改 UI 时，必须严格遵循以下设计规范（继承自旧架构 React Web 应用）：

### 1. 整体美学 (Overall Aesthetic)
- **极简与纯净**：避免复杂的背景和生硬的线条，多使用留白（Padding / Margin）来区分视觉层级。
- **背景颜色**：页面的底层背景通常使用浅色/柔和色调，如 `colorScheme.surfaceContainerLowest.withValues(alpha: 0.5)`。
- **阴影与质感**：广泛使用柔和、弥散的微阴影来突出卡片层级，避免使用强烈的投影。

### 2. 卡片化布局 (Card-based Layout)
- **结构设计**：页面内的内容区块、设置项、信息展示等都应封装在卡片中。
- **边框与圆角**：
  - 圆角通常较大，如 `BorderRadius.circular(24)` 或 `16`。
  - 边框应极细且半透明，如 `Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5))`。
  - 背景色一般使用纯白 `Colors.white` 或当前主题的卡片底色。
- **阴影参数参考**：`BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4))`。

### 3. 输入框与表单 (Inputs & Forms)
- **无边框底色**：避免使用默认的 Material 强边框，改用带底色的圆角框。
- **圆角背景**：使用带有浅色填充的圆角背景，如 `fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)`，并配合 `BorderRadius.circular(16)`。
- **状态变化**：选中时（Focused）可带有主题色的细边框进行反馈。

### 4. 按钮与操作区 (Buttons & Actions)
- **圆角按钮**：主按钮（`FilledButton` / `ElevatedButton` 等）应具备较大圆角，如 `BorderRadius.circular(16)` 或 `20`。
- **零浮现**：移除默认的阴影高度（`elevation: 0`），主要依赖颜色对比来突出按钮。
- **精致图标**：图标控件常包裹在带有轻微透明背景色的 `Container` 中，如 `color: iconColor.withValues(alpha: 0.1)` 结合 `borderRadius: BorderRadius.circular(10)`。

### 5. 导航栏 (AppBar)
- **透明沉浸**：`AppBar` 尽量设置为透明 `backgroundColor: Colors.transparent`，并且去掉滚动阴影 `elevation: 0` 和 `scrolledUnderElevation: 0`。
- **标题加粗**：导航栏标题文字通常加粗（`fontWeight: FontWeight.bold`），保持简洁大方。

---

## Flutter 开发流程

### 重要：代码修改后的预览方式

**禁止**每次修改代码后运行新的 `flutter run` 命令！

项目通常已经有一个正在运行的 `flutter run` 进程（通常为flutter run -d chrome --web-port=8080）。

#### 正确的做法：

1. **修改代码后**，通知用户在已运行的 Flutter 终端中按 `r` 进行热重载（Hot Reload）
2. 热重载会立即应用代码更改，无需重启应用
3. 如果需要完全重启，通知用户按 `R` 进行热重启（Hot Restart）

#### 错误的做法（请避免）：

- ❌ 运行 `flutter run -d chrome` 启动新的预览
- ❌ 运行 `flutter run --web-port=xxxxx` 启动新的预览

### 原因：

- 多个 `flutter run` 进程会占用大量系统资源
- 每个进程会开启不同的预览端口，造成混乱
- 热重载（按 `r`）是 Flutter 的核心特性，速度更快（通常 < 1秒）

### 当前运行状态：

如果终端显示 `flutter run` 正在运行，说明预览服务已就绪，直接热重载即可。

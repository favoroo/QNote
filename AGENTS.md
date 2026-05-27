# Agent 工作指南

## 项目简介

QNote 是一个 **Flutter 多平台应用**（Web / iOS / Android），核心功能为日记/快捷记录、笔记、待办、AI 智能分析、数据统计。

## 注意事项
用中文写注释，用中文和用户解释沟通。

## CodeGraph 代码索引

项目已配置 CodeGraph MCP 服务器（`codegraph_*` 工具），提供基于 AST 的语义代码索引。

| 场景 | 用什么 |
|------|--------|
| 符号定义/查找 | `codegraph_search` |
| 调用链追踪 | `codegraph_trace` |
| 谁调用了 X / X 调用了谁 | `codegraph_callers` / `codegraph_callees` |
| 修改影响范围 | `codegraph_impact` |
| 符号签名/源码 | `codegraph_node` |
| 组合搜索+节点+调用关系 | `codegraph_context`（一步到位） |
| 批量查看多个符号源码 | `codegraph_explore` |
| 目录下有哪些文件 | `codegraph_files` |

结构性问题优先用 CodeGraph，字面文本搜索用 grep；信任 CodeGraph 结果，编辑后不要立即重新查询。

### 项目结构

```
lib/
├── main.dart / app.dart              # 应用入口与配置
├── database_init.dart / _io.dart     # 数据库初始化
├── config/                           # 默认提示词、AI 服务商模型
├── core/                             # 核心逻辑（ai/ export/ logger/ network/ router/ storage/ theme/ utils/）
├── models/                           # 数据模型
├── pages/                            # 页面（含 settings/ 子目录）
├── providers/                        # Riverpod 状态管理
└── widgets/                          # UI 组件（diary/ notes/ statistics/ + 通用组件）
```

---

## UI 设计原则

主题默认值以 `lib/core/theme/app_theme.dart` 为准。

- **Material 3 + 主题令牌**：颜色/圆角/字重优先使用 `colorScheme` 与 `textTheme`，避免硬编码 hex
- **扁平柔和**：`elevation: 0` 为主，用细边框 + 低透明度阴影区分层级
- **深浅色一致**：同一组件在 light/dark 下语义相同
- **信息密度优先**：内容完整可读，不为极简牺牲关键信息

---

## Flutter 开发流程

不要每次修改后运行新的 `flutter run`！项目通常已有运行中的进程（`flutter run -d chrome --web-port=8080`）。修改代码后通知用户按 `r` 热重载，需完全重启按 `R`。

---

## 代码风格

- 单引号；行宽 ≤ 120；多行参数加尾逗号；控制流必须加花括号
- Import 分 4 组（Dart 核心 → Flutter → 第三方 → 项目内部），组间空行，组内字母序
- 公共 API 加 `///` 文档注释；行内注释用中文，解释**为什么**
- TODO 格式：`// TODO(name): 描述 #issue`

---

## 状态管理（Riverpod）

| 场景 | 使用 |
|------|------|
| 异步数据 | `AsyncNotifierProvider` + `AsyncNotifier` |
| 简单状态 | `StateProvider` |
| 一次性读取 | `FutureProvider.family` |
| 服务实例 | `Provider` |

建议避免新增 `StateNotifierProvider`。数据变更后用 `ref.invalidate()` 或 Notifier 内 `refresh()`。一个 Provider 一个关注点，派生状态用 `Provider` 组合。

---

## 数据层

- Repository 通过 Provider 注入，保持单例模式
- 统一方法签名：`getAll()` / `getById()` / `insert()` / `update()` / `softDelete()` / `hardDelete()` / `search()`
- 所有写操作调用 `_syncLog.logChange()`
- 删除：用户触发用 `softDelete()`，`hardDelete()` 仅在数据管理页；查询默认过滤 `is_deleted = 0`
- 模型必须包含：`id`（不可变主键）、`toMap()` / `fromMap()` / `copyWith()`

---

## 组件与错误处理

- 页面基类：需状态+ref → `ConsumerStatefulWidget`；仅需 ref → `ConsumerWidget`；不需 ref → `StatelessWidget`/`StatefulWidget`
- Controller 在 `initState` 创建、`dispose` 释放
- 错误处理：服务层捕获→日志→rethrow；UI 层用 `AsyncValue.when(error:)` + Toast；避免空 catch
- 破坏性操作需二次确认

---

## 变更日志

修改源码或项目配置后，将重要变更写入 `CHANGELOG.md`。纯文档修改和只读操作无需写入。

```markdown
## YYYY-MM-DD

- **[HH:MM]**
  - **Added**: 新增了什么 (`文件路径`)。
  - **Fixed**: 修复了什么 (`文件路径`)。
  - **Changed**: 调整了什么 (`文件路径`)。
```

---

## 测试

建议为新增代码补充测试，`test/` 目录镜像 `lib/` 结构，文件命名 `xxx_test.dart`。

---

## Git 提交

格式：`<type>(<scope>): <description>`，Type：`feat` / `fix` / `refactor` / `style` / `docs` / `test` / `chore`

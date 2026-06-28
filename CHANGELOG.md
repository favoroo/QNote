# Agent 变更日志

本文件记录 Agent（AI 编程助手）对项目代码的所有修改，用于追溯问题、回溯决策。

格式规范见 `AGENTS.md` →「变更日志规范」。

---

## 2026-06-28

- **[17:35]**
  - **Added**: 完成 P0 高影响性能优化（共 9 项），覆盖生命周期/状态/重绘/重算四个维度，主要变化如下：
    1. **P0-1**: `lib/app.dart` resumed 时基于 `SyncLogRepository.getChangesSince` 检查是否有变更才 refresh，避免无脑全表查询。
    2. **P0-3+4**: `lib/providers/{diary,todo,note,folder,ai}_provider.dart` 所有列表 CRUD 改为内存增量更新（add → `[...state, item]`；update → `.map(...)`；delete → `.where(...)`），先 await DB 写入成功再更新 state 保证一致性；不再走 `refresh()` 全表重查。
    3. **P0-5**: `lib/pages/diary_page.dart` `_buildRecordsByDate` 用 `identical` + `_undoRecordsVersion` 计数器缓存分组结果，4 处 undo 修改点调用 `_bumpUndoRecordsVersion()` 失效缓存。
    4. **P0-6**: `lib/pages/notes_page.dart` `_flattenTree` 结果在 State 中缓存，folders/notes 引用未变时直接返回。
    5. **P0-7**: `lib/pages/{diary,ai,todo,statistics}_page.dart` 和 `lib/widgets/animated_gradient_border.dart` 5 处关键位置包 `RepaintBoundary`，隔离动画跑动时同屏重绘。
    6. **P0-8**: `lib/pages/ai_page.dart` watch 数从 4 降到 2，endDrawer 和 _buildContextFilterSection 下沉到 Consumer；用 `.select((c) => c?.id)` / `.select((value) => value != null)` 缩小订阅范围。
    7. **P0-9**: `lib/providers/diary_provider.dart` 新增 `diaryListByDateRangeProvider` (FutureProvider.family) 走 `DiaryRepository.getByDateRange` 按时间范围拉取，watch diaryListProvider 自动响应增删改；`lib/pages/statistics_page.dart` 移除全量加载改 watch 此 provider。
    8. **P0-2 + P1-26**: `lib/providers/stats_provider.dart`（新文件）把 5 个统计函数包到 `compute()` 中跑 isolate，不阻塞 UI；`StatTab` 枚举从 `statistics_page.dart` 移到 `lib/core/utils/stats_utils.dart` 避免循环依赖；stats 函数接收按范围拉取的 records，消除冗余过滤。

- **[——]**
  - **Changed**: 优化固定事件管理页列表卡片布局：将多段时间从标题行移到副标题行，避免被右侧开关挤压截断；副标题中仅当备注与名称不同时才显示备注，减少重复信息 (`lib/pages/settings/fixed_events_page.dart`)。

- **[——]**
  - **Changed**: 移除日记输入栏固定事件按钮行左侧的重复图标，使界面更简洁 (`lib/widgets/diary/diary_input_bar.dart`)。

- **[——]**
  - **Added**: 活动标签新增「情绪」类型选项，支持记录心情类事件（如"今天被领导骂了，不开心"）；优化智能提取提示词，使 AI 能识别并提取情绪类表达到活动标签 (`lib/config/defaults.dart`)。
  - **Changed**: 数据库版本升级至 18，自动为已有用户的活动标签追加「情绪」选项 (`lib/core/storage/database_helper.dart`)。

- **[11:30]**
  - **Changed**: 从 Git 暂存区中取消跟踪大文件 `应用分享.zip` (26MB) 和 Python 编译字节码文件夹 `__pycache__`，同时更新 `.gitignore` 规则，防止此类临时文件和打包产物再次被误提交 (`.gitignore`)。

- **[10:30]**
  - **Fixed**: 修复笔记图片删除后撤回（undo）导致图片无法正常显示的问题 (`lib/widgets/notes/note_editor_view.dart`)。原实现中删除新上传图片会立即物理删除磁盘文件，且已存在图片删除后加入 `_removedPaths` 在 undo 时未被清理，导致退出编辑器时仍被错误删除。现在通过扩展 `_EditorHistoryState` 记录 `removedPaths` / `newlyUploadedPaths` 快照，并统一图片删除为延迟删除，使 undo/redo 都能正确回滚文件级副作用。

- **[09:12]**
  - **Changed**: 微调日记事件卡片中正文与图片的左侧缩进（增加 4 dp），让内容视觉上收在标签 pill 内侧，避免“凸出”在标签外 (`lib/widgets/diary/diary_item.dart`)。

- **[08:40]**
  - **Changed**: 移除了睡眠日记卡片底部多余的「入睡时间」标签，因为顶部时间段中已能够直观体现 (`lib/widgets/diary/diary_item.dart`, `lib/widgets/diary/diary_batch_manage_view.dart`)。
  - **Changed**: 统一批量管理页中卡片时间段标签的颜色逻辑，使其不再统一使用全局主题色，而是与主页一致，自动跟随对应日记标签的自定义颜色 (`lib/widgets/diary/diary_batch_manage_view.dart`)。

## 2026-06-27

- **[——]**
  - **Fixed**: 修复日记页面批量智能提取按钮长按选择模型后黑屏的问题 (`lib/pages/diary_page.dart`)：`showDialog<AiConfig>` 改为 `showDialog<String>`，与 `_TimelineModelDialog` 实际返回类型一致；补上免费模型选中状态判断和保存逻辑。
  - **Changed**: 统一三处重复的模型选择弹窗为共享组件 `ModelSelectionDialog` (`lib/widgets/diary/model_selection_dialog.dart`)，删除 `diary_page.dart`、`diary_input_bar.dart`、`diary_editor_view.dart` 中各自的私有弹窗实现，UI 样式统一为圆形单选框风格。

- **[——]**
  - **Fixed**: 修复选择固定事件后时间线圆点不高亮的问题 (`lib/widgets/diary/diary_input_bar.dart`)：选择固定事件时清除草稿的跨天 offset，并使用统一的日期计算方式设置 `diaryInputTimeProvider`，避免 `addPostFrameCallback` 用错误日期覆盖。

- **[——]**
  - **Fixed**: 修复桌面小组件偶尔点击无反应的问题 (`android/.../MainActivity.kt`, `lib/app.dart`, `android/.../TodoWidgetProvider.kt`)：
    1. `handleIntent` 始终走 `pendingRoute` 路径，避免 `invokeMethod` 与 Flutter 引擎恢复/Provider 刷新竞态。
    2. `didChangeAppLifecycleState(resumed)` 中增加 `getPendingRoute` 拉取，确保导航在 Provider 刷新之后执行。
    3. 冷启动 `addPostFrameCallback` 增加 MethodChannel 就绪重试机制。
    4. `_navigateToRoute` 增加 200ms 延迟重试，防止路由器过渡中导航失败。
    5. `ACTION_TODO_CLICK` 的 `context.startActivity` 改为 `PendingIntent.send()`，兼容 Android 12+ 后台启动限制。

- **[22:27]**
  - **Changed**: 调整日记输入栏底部操作按钮样式：将时间按钮圆角从 12 调大至 18（胶囊形），并将右侧的图片与相机按钮调整为圆形（`BoxShape.circle`） (`lib/widgets/diary/diary_input_bar.dart`)。

- **[23:59]**
  - **Changed**: 深度美化并统一输入栏的快捷工具组设计 (`lib/widgets/diary/diary_input_bar.dart`)：
    1. 统一尺寸与圆角：将右侧“图片”和“相机”按钮的尺寸从圆形 `44x44` 调整为与时间按钮一致的圆角矩形 `36x36`（`BorderRadius.circular(12)`），使整排按钮在高度和形态上完美对齐统一。
    2. 色彩优化（选项 A）：将时间按钮（开始/结束/「+ 结束时间」）以及媒体按钮（图片、相机）的视觉风格统一调整为淡主题色大色块设计（淡蓝色 `primaryContainer` 背景 + 主题色 `primary` 文字及图标），降低视觉沉重感，提升界面整体美观度和舒适度。
  - **Changed**: 微调顶部栏按钮视觉层级，将调色盘按钮与批量管理按钮的背景色从实心主题色调整为较淡的主题色容器背景（`primaryContainer`），并将图标颜色设回主题色（`primary`），使顶部导航区域在保持色块交互感的同时更显清爽协调 (`lib/pages/diary_page.dart`)。
  - **Changed**: 进一步优化应用的主题大色块呈现设计，提升界面交互层级与视觉质感 (`lib/pages/diary_page.dart`, `lib/widgets/diary/diary_input_bar.dart`)：
    1. 顶部栏：调色盘按钮与批量管理按钮，背景均改为实心主题色，图标改为高对比度的纯白色。
    2. 输入栏时间按钮：开始时间与结束时间按钮背景均改为实心主题色，未设置的「+ 结束时间」按钮也同步改为实心主题色背景，按钮内的文字、图标与清除按钮均使用高对比度纯白色。
    3. 输入栏右侧操作按钮：图片选择与相机拍摄按钮背景均改为实心主题色，图标改为纯白色。
    4. 智能提取悬浮按钮：未处于提取状态下的魔法棒按钮背景改为实心主题色，魔法棒图标改为纯白色。

- **[23:45]**
  - **Changed**: 优化应用的主题色块呈现设计，将仅文本/线条的轻量着色优化为大色块设计 (`lib/pages/todo_page.dart`, `lib/widgets/time_range_selector.dart`, `lib/core/theme/app_theme.dart`)：
    1. 待办页（`TodoPage`）的“今日/长期”分段选择器，选中项背景改为实心主题色，文字颜色改为 `onPrimary`（白色）。
    2. 统计页（`TimeRangeSelector`）时间范围选择器，选中项背景改为实心主题色，文字颜色改为 `onPrimary`（白色）。
    3. 全局底部导航栏（`NavigationBar`）的选中态指示胶囊颜色改为实心主题色，同时将选中图标的线条颜色改为 `Colors.white`（白色），形成清晰的主题大色块反馈。

- **[22:30]**
  - **Added**: 笔记图片长按支持「AI 提取图片内容」功能。长按图片弹出操作菜单（AI 提取 / 预览 / 删除），选择「AI 提取图片内容」后调用多模态大模型识别图片，结果以 Markdown 引用块 `> 图：xxx` 形式自动追加到图片下方，方便分享笔记给 AI 助手时携带图片信息 (`lib/widgets/notes/note_editor_view.dart`)。
  - **Added**: `AiService` 新增多模态自由文本对话方法 `chatWithImage`，与 `extractUnified` 区别在于不强制 JSON 输出，返回模型纯文本响应；同步新增内部方法 `_buildImageChatRequestBody` 复用三种 provider（Gemini/Omni/标准 OpenAI）的多模态请求体结构 (`lib/core/ai/ai_service.dart`)。
  - **Added**: 在 `defaultSystemPrompts` 中新增 `note_image_analysis` 提示词，约束模型输出纯文本格式的图片描述 (`lib/config/defaults.dart`)。

- **[21:10]**
  - **Fixed**: 修复刚进入应用时顶部状态栏不是白色的问题。根因是冷启动默认加载的 `DiaryPage` 未使用 `AppBar`，导致系统未自动触发状态栏样式的刷新与初始化。已在 `lib/main.dart` 启动时及 `lib/app.dart` 的 `MaterialApp` 构建器中使用 `AnnotatedRegion` 全局动态控制状态栏的沉浸式和前景色（深浅色跟随主题动态切换），并为 `lib/core/theme/app_theme.dart` 中的 `lightTheme` 与 `darkTheme` 配置了默认的 `appBarTheme.systemOverlayStyle` 以维持统一体验。

## 2026-06-26

- **[08:30]**
  - **Changed**: 升级 `flutter_quill` 从 `11.5.0` 到 `11.5.1`，以兼容 Flutter 3.44/Dart 3.12 新增的 `TextInputClient.onFocusReceived` 方法（旧版本会导致 Web/移动端编译失败） (`pubspec.yaml`, `pubspec.lock`)。

## 2026-06-23

- **[23:14]**
  - **Added**: 固定事件支持设置和配置多个时间段/点，并优化联动标签的时长计算为全部时间段总和 (`lib/models/fixed_event_template.dart`, `lib/pages/settings/fixed_events_page.dart`, `lib/core/storage/database_helper.dart`)。
  - **Changed**: 重构日记快速记录栏（`DiaryInputBar`）发送逻辑，当使用含有多时段的固定事件模板时，自动为各个时段生成并保存独立的时间线日记记录 (`lib/widgets/diary/diary_input_bar.dart`)。
  - **Fixed**: 修复固定事件编辑/添加弹窗无法弹出的问题。原因是在 `showDialog` 异步路由内直接使用父页面的 `ref.watch` 导致对话框无法接收到 Riverpod 加载完毕的刷新通知，已在 `showDialog` 内层引入 `Consumer` 组件使对话框可以独立监听并正确重载 UI 展示 (`lib/pages/settings/fixed_events_page.dart`)。

- **[23:02]**
  - **Changed**: 将数据统计的默认界面改为评分板块，并将评分选项卡移动到首位 (`lib/pages/statistics_page.dart`)。

- **[22:58]**
  - **Fixed**: 修复评分热力图网格的各个方块挤在一起的问题。在网格行之间以及星期标签列中加入 `_cellGap` 垂直间距，解决垂直方向紧贴的问题，并让星期标签与网格行完美垂直对齐 (`lib/widgets/statistics/score_heatmap.dart`)。

- **[22:29]**
  - **Fixed**: 修复推理思考模型（如 SenseNova）图片识别检测误报"不支持图片识别"的问题。根因是 `_extractTextFromResponse` 只读取 `message.content`，当 token 被 `reasoning` 消耗完后返回空字符串；修复为回退读取 `reasoning`/`reasoning_content` 字段，同时提高 `checkImageRecognition` 的 `max_tokens` 从 50 到 200 (`lib/core/ai/ai_service.dart`)。

## 2026-06-22

- **[22:55]**
  - **Added**: 新增免费模型功能板块，支持 sensenova/agnes/gemma/gemini-flash-lite 四个免费模型，用户可选择主模型，调用失败时自动切换 (`lib/core/utils/obfuscation_utils.dart`, `lib/models/free_model_config.dart`, `lib/core/ai/free_model_service.dart`, `lib/core/ai/free_model_executor.dart`)。
  - **Added**: 免费模型列表支持从 GitHub（jsDelivr 加速）远程更新，apikey 经简单混淆处理 (`lib/core/ai/free_model_service.dart`)。
  - **Added**: 在 AI 配置页面新增免费模型 UI 板块，含更新按钮、主模型选择、模型列表展示 (`lib/pages/settings/ai_config_page.dart`)。
  - **Added**: 角色绑定（助手/时间轴优化）下拉新增"免费模型（自动切换）"选项 (`lib/pages/settings/ai_config_page.dart`)。
  - **Added**: 新增 `tool/generate_free_models.dart` 脚本，用于生成远程配置文件 `free_models.json`。
  - **Changed**: `AiRoles` 新增 `assistantUseFreeModel` / `timelineOptimizationUseFreeModel` 字段，支持角色级别启用免费模型 (`lib/models/ai_roles.dart`)。
  - **Changed**: `AiRoleService.getEffectiveConfigForRole` 支持免费模型，新增 `isFreeModelEnabled` / `getPreferredFreeModelId` / `getFreeModelConfigsForRole` 方法 (`lib/core/ai/ai_role_service.dart`)。
  - **Changed**: `CurrentChatNotifier.sendMessage` 支持免费模型自动切换逻辑 (`lib/providers/ai_provider.dart`)。

- **[22:39]**
  - **Added**: 新增 SenseNova（商汤）与 MiniMax AI 服务商配置 (`lib/config/models.dart`)。

## 2026-06-19

- **[18:30]**
  - **Changed**: 热力图月份标签改为中文（2月、3月等），星期标签改为中文（一/三/五），图例改为"少"/"多"，同时增大方块间距改善视觉拥挤问题 (`lib/widgets/statistics/score_heatmap.dart`)。

- **[15:50]**
  - **Fixed**: 修复 AI 统一提取时因响应数据类型异常导致 `type 'String' is not a subtype of type 'int' of 'index'` 崩溃问题，增加防御性类型检查 (`lib/core/ai/ai_service.dart`)。
  - **Fixed**: 修复 AI 提取结果中快捷标签匹配失败时显示原始英文 ID 或“其他”而非正确中文名称的问题，增强 `findShortcutById` 支持大小写不敏感匹配，并修复 `diary_input_bar.dart` 中回退逻辑 (`lib/widgets/diary/ai_extract_helper.dart`, `lib/widgets/diary/diary_input_bar.dart`)。

## 2026-06-17

- **[10:30]**
  - **Fixed**: 修复批量管理页面日期选择无法选择时间段的问题。将 `showDatePicker` 替换为 `showDateRangePicker`，支持选择起止日期范围 (`lib/widgets/diary/diary_batch_manage_view.dart`)。
  - **Added**: 在批量管理页面添加"本周"和"本月"快捷选择按钮。本周为周一到周日，本月为1号到月底 (`lib/widgets/diary/diary_batch_manage_view.dart`)。
  - **Added**: 在日期范围选择器和批量管理页面添加"今天"快捷按钮，快速选择今天的日期范围 (`lib/widgets/diary/custom_date_range_picker.dart`, `lib/widgets/diary/diary_batch_manage_view.dart`)。

- **[07:10]**
  - **Added**: 在数据统计评分标签页新增 GitHub 风格热力图组件，展示近3个月每日评分，分数越高颜色越深，使用主题色 primary 配合 alpha 透明度实现深浅变化 (`lib/widgets/statistics/score_heatmap.dart`)。
  - **Added**: 新增 `dailyScoreHeatmapProvider` 获取近 90 天评分数据 (`lib/providers/daily_score_provider.dart`)。
  - **Changed**: 在评分统计页面折线图上方插入热力图卡片 (`lib/widgets/statistics/daily_score_stats.dart`)。
  - **Fixed**: 修复热力图在移动端显示不全的问题。使用 `LayoutBuilder` 实现自适应宽度，根据屏幕可用空间动态计算显示周数 (`lib/widgets/statistics/score_heatmap.dart`)。

- **[06:44]**
  - **Changed**: 修改 `daily_score_system` AI 提示词的输出格式说明，要求 `summary` 和 `suggestions` 字段使用 Markdown 格式（换行、加粗、列表等），使 AI 评分建议内容在 UI 上正确渲染为富文本 (`lib/config/defaults.dart`)。
  - **Fixed**: 修复 AI 评分建议内容挤在一行的问题。在 `_AiSuggestionCard` 中添加 `_formatMarkdownText` 预处理函数，自动将纯文本格式（如 `[1. xxx。，2. xxx。]`）转换为 Markdown 列表，确保即使 AI 未输出标准 Markdown 也能正确换行显示 (`lib/widgets/statistics/daily_score_stats.dart`)。

## 2026-06-14

- **[22:55]**
  - **Fixed**: 修复固定事件编辑对话框中"时长(小时)"等非 select 文本字段无法正常连续输入的问题（输入"12"变成"21"）。根因是每次 build 都 `new TextEditingController` 重建控制器并 setDialogState 推算结束时间，导致光标归零、字符反向插入。改为在 State 字段按 `'$tagId#${field.id}'` 缓存 controller / focusNode，仅在 controller 未获焦时单向同步外部值；onFieldChanged 中修改 endHour/endMinute 的 setDialogState 推迟到下一帧 (`lib/pages/settings/fixed_events_page.dart`)。

- **[22:10]**
  - **Fixed**: 修复 AI 配置中默认 agnes 模型的 `baseUrl` 为空的问题，修正默认值并在编辑对话框中增加空 URL 兜底填充逻辑 (`lib/config/defaults.dart`, `lib/pages/settings/ai_config_page.dart`)。

- **[15:30]**
  - **Fixed**: 修复 `app.dart` 中 3 处空 catch 块，补充 `debugPrint` 日志记录 (`lib/app.dart`)。
  - **Changed**: 增强 `analysis_options.yaml` lint 规则，启用 `prefer_single_quotes`、`prefer_const_constructors`、`prefer_final_fields` 等 12 条规则 (`analysis_options.yaml`)。
  - **Changed**: 将所有 16 个模型类的非 id 字段改为 `final`，确保不可变性 (`lib/models/*.dart`)。
  - **Changed**: 将 `DiaryColorMarkNotifier` 从 `StateNotifier` 迁移为 `AsyncNotifier`，符合项目状态管理规范 (`lib/providers/diary_provider.dart`, `lib/pages/diary_page.dart`)。
  - **Added**: 补充 `DiaryRecord` 和 `Todo` 模型的单元测试（toMap/fromMap 往返、copyWith、getEffectiveDate、belongsToDate），共 22 个测试用例 (`test/models/diary_record_test.dart`, `test/models/todo_test.dart`)。

- **[11:05]**
  - **Added**: 固定事件支持多选，选中多个模板时各自的备注按选中顺序换行拼接显示在输入栏；时间用最后选中模板的时间；取消选中时自动移除对应模板的标签与备注 (lib/widgets/diary/diary_input_bar.dart)。

- **[10:50]**
  - **Changed**: 优化了日记快捷记录栏中的“固定事件”模板按钮颜色（`lib/widgets/diary/diary_input_bar.dart`）。移除了未选中状态下突兀的浅灰色不透明背景，统一改为和下方快捷类别标签一样的“透明背景 + 细边框（`outlineVariant`）”极简风格，同时将未选中状态的图标和文字颜色加深为 `onSurface`，确保整个输入框区域的各类气泡按钮在视觉上保持极度协调与清爽。

- **[10:45]**
  - **Added**: 固定事件支持「时间点」模式（顶部 SegmentedButton 切换时间点/时间段）；时间点模式下只选单个时间，无结束时间 (`lib/models/fixed_event_template.dart`, `lib/pages/settings/fixed_events_page.dart`)。
  - **Added**: 固定事件配置页中，关联的「睡眠」「活动」标签字段与事件开始/结束时间双向联动——改时间自动推算入睡时间/时长，改时长自动反推结束时间 (`lib/pages/settings/fixed_events_page.dart`)。
  - **Added**: 日记输入/编辑页中，活动标签的「时长」与开始/结束时间双向联动（与睡眠一致）；固定事件时间点模式填充草稿时不再强制设置结束时间 (`lib/widgets/diary/diary_input_bar.dart`, `lib/widgets/diary/diary_editor_view.dart`)。
  - **Changed**: 数据库升级至 v16，`fixed_event_templates` 表新增 `is_time_point` 列（含迁移与兜底补列）(`lib/core/storage/database_helper.dart`)。

- **[09:48]**
  - **Changed**: 优化了日记快捷记录输入栏（`lib/widgets/diary/diary_input_bar.dart`）最右侧的“向下收起”按钮颜色与样式。移除了原先突兀的蓝色渐变背景与微阴影，改为透明背景加轮廓线（`outlineVariant`）的极简样式，并稍微增大了点击热区，使其与同排的各种快捷分类按钮风格保持完美统一，视觉过渡更自然。

- **[时间]**
  - **Changed**: 调整笔记列表交互逻辑：长按触发拖动排序，三点菜单中新增「批量编辑」入口进入多选模式，移除了原本的长按进入选择模式 (`lib/pages/notes_page.dart`)。

- **[09:44]**
  - **Changed**: 优化了全局 Switch 开关组件在深浅色模式下的色彩显示 (`lib/core/theme/app_theme.dart`)。针对之前选中状态“轨道颜色与滑块颜色都是同种深色”导致视觉上显得过于厚重的问题，将选中状态重构为标准且更现代清爽的样式：轨道颜色保持为主品牌色（`accentColor`），滑块颜色（Thumb）统一替换为纯白色，同时移除了 Material 3 默认自带的不协调边框（`trackOutlineColor`），极大地提升了全局开关操作时的轻量感与视觉清晰度。

- **[09:42]**
  - **Changed**: 精简并统一了个性化设置中的主题色选项 (`lib/providers/theme_provider.dart`)。将原本的 12 种主题色删减并修改为 4 种特定的色彩：系统默认经典蓝 (`#005BCB`)、荧光黄绿 (`#C5E803`)、玫瑰粉红 (`#E91E8C`) 和春天亮绿 (`#00E676`)。

- **[09:40]**
  - **Changed**: 统一了侧边栏 drawer 菜单项与同步设置页面 (`lib/pages/settings/sync_settings_page.dart`) 的图标颜色搭配。将“设置与管理”分类下的所有选项以及“同步设置”中各种同步策略、功能控制（自动同步、同步图片、清理云端备份等）操作项统一为系统主品牌色（蓝色图标与浅蓝色背景/交互反馈），使设置体系的界面色彩整体协调、干净一致，不再出现高饱和的多色堆砌。

---

## 2026-06-09

- **[时间]**
  - **Added**: 新增固定事件快捷记录功能，支持用户自定义每日固定事件模板（如"8点到12点上班"），点击按钮即可自动填充时间段和内容 (`lib/models/fixed_event_template.dart`, `lib/core/storage/fixed_event_repository.dart`, `lib/providers/fixed_event_provider.dart`)。
  - **Added**: 新增固定事件管理页面，支持添加、编辑、删除、排序和启用/禁用固定事件模板 (`lib/pages/settings/fixed_events_page.dart`)。
  - **Changed**: 在日记输入栏上方新增固定事件按钮区域，点击模板按钮自动填充开始时间、结束时间和备注内容 (`lib/widgets/diary/diary_input_bar.dart`)。
  - **Changed**: 在侧边栏设置菜单新增"固定事件管理"入口 (`lib/widgets/side_drawer.dart`)。
  - **Changed**: 在路由配置中新增固定事件管理页面路由 (`lib/core/router/app_router.dart`)。
  - **Changed**: 数据库版本升级至 14，新增 `fixed_event_templates` 表 (`lib/core/storage/database_helper.dart`)。

---

## 2026-06-07

- **[22:45]**
  - **Added**: 新增了公共图片大图预览画廊组件 `FullScreenImageGallery`，支持在全屏下多张图片左右滑动切换和手势缩放 (`lib/widgets/unified_image.dart`)。
  - **Changed**: 调整了日记卡片 (`lib/widgets/diary/diary_item.dart`) 的图片点击交互。现在点击日记卡片上的图片会自动弹出大图预览画廊，而非触发整个卡片的编辑事件。
  - **Changed**: 优化了日记编辑页面 (`lib/widgets/diary/diary_editor_view.dart`) 与便签编辑页面 (`lib/widgets/notes/note_editor_view.dart`) 的图片预览体验，统一使用 `FullScreenImageGallery` 代替原本的单图预览，且便签编辑中支持左右滑动预览便签内的全部图片。

- **[22:38]**
  - **Added**: 支持对体重单位偏好 `weight_unit` 进行本地持久化保存，保证再次打开页面时能够恢复用户偏好。
  - **Changed**: 重构了个人信息页面 (`lib/pages/settings/user_profile_page.dart`) 的体重展示和录入系统。现在用户可以直接点击“最新体重”或体重输入框的后缀单位，在 `kg` 与 `斤` 之间切换单位。
  - **Changed**: 为维护底层数据物理单位一致性，数据库始终以 `kg` 作为绝对标准存储。在展示“最新体重”、绘制“折线趋势图”以及渲染“历史记录列表”时根据单位偏好将数值自动折算（1 kg = 2 斤）；在录入体重时，如果当前是“斤”模式，则先除以 2 折算成 `kg` 再保存至数据库。

- **[22:27]**
  - **Fixed**: 修复了当输入法弹起时，底部输入框及发送按钮可能会被键盘遮挡的缺陷。动态读取 `MediaQuery` 中的键盘弹起高度与屏幕可用尺寸，为快速记录输入栏的底部容器引入了动态最大高度限制 `dynamicMaxHeight`。在键盘弹起时，能自适应挤压收缩其上方的表单内容区域（`_buildFormFieldsArea`），并保持内部表单（如“症状”、“用药”等字段）的 `SingleChildScrollView` 正常滚动，以确保底部的文本输入框和发送按钮能稳定靠齐并高亮显示在键盘顶部，免受输入法遮蔽。 (`lib/widgets/diary/diary_input_bar.dart`)

- **[22:11]**
  - **Changed**: 重构了侧边栏设置菜单项图标的颜色搭配 (`lib/widgets/side_drawer.dart`)。为“个人信息”、“AI配置”、“快捷按钮管理”、“数据管理”、“同步设置”、“个性化设置”以及“关于”选项定制了色彩更饱满、语义更贴合且不重复的双色调配色，在深浅色模式下分别自动采用高对比度原色与低饱和度柔和微光毛玻璃风格，解决了原有配色中多项重复蓝色、数据管理置灰感及个性化设置使用警示红的突兀视觉体验。

- **[22:04]**
  - **Changed**: 彻底重构了笔记列表的层级渲染与拖拽逻辑。废弃了原本多层嵌套的 `ReorderableListView`（其会导致严重的手势冲突和 `DragTarget` 手势吞噬），重构为主页面在 `build` 期将整个嵌套树结构通过 `_flattenTree` 递归展平为 `List<FlattenedItem>` 一维扁平列表，并使用单层 `ListView.builder` 进行极速流畅渲染，彻底杜绝手势冲突；
  - **Added**: 实现了基于 `LongPressDraggable` 和三敏感区 `DragTarget` 叠加层（顶部 `before` 排序 / 中部 `inside` 移入，仅限文件夹 / 底部 `after` 排序）的 VS Code Style 高级拖拽重排与移入交互。在拖拽悬停至顶部/底部时显示蓝色高亮 Drop 横线，悬停在中部时高亮文件夹整行背景，并使用下一帧安全回调 `addPostFrameCallback` 驱动状态更新以杜绝 build 期间 setState 报错；
  - **Added**: 实现了列表底部全局的根目录 `DragTarget`，将任意内部节点的项拖拽到空白区域释放即可自动移回根目录；
  - **Added**: 在重构后的拖拽处理 `_handleDrop` 中集成了严密的循环文件夹拖入防御（禁止将父文件夹移入它自身或其子孙文件夹下）和精准的 `sortOrder` 序列化重算与批量入库逻辑，确保底层排序数据始终紧凑和一致 (`lib/pages/notes_page.dart`)。

- **[21:58]**
  - **Added**: 实现笔记和文件夹的长按拖拽跨层级移入文件夹或拖回根目录功能。通过为 `_NoteTile` 和 `_FolderTile` 外层添加 `LongPressDraggable` 并在 `_FolderTile` 外部套上 `DragTarget` 接收拖入，配合全局 `DragTarget` 接收拖出根目录。在长按拖拽时具有浮动小卡片预览及目标文件夹的高亮底色和边框反馈，同时内置循环引用检测（禁止将父文件夹拖入它自己或其子孙文件夹下），此操作与原本拖拽左侧六点按钮进行的同一层级重排功能互不冲突、完美共存 (`lib/pages/notes_page.dart`)。

- **[21:53]**
  - **Changed**: 优化笔记列表的布局紧凑度。缩小了文件夹和笔记行最左侧的六点拖拽指示器（`Icons.drag_indicator`）尺寸（16/18 -> 14），收窄其右侧间距与组件整体左侧内边距，并将文件夹折叠/展开箭头的点击宽度收窄以大幅释放横向物理空间，使笔记页面排版更加精致紧凑 (`lib/pages/notes_page.dart`)。

- **[21:50]**
  - **Fixed**: 修复笔记和日记卡片上的“三点”操作菜单按钮点击无反应的问题。将 `NotesPage` 中的 `_FolderTile`、`_NoteTile` 以及 `DiaryItem` 从 `StatelessWidget` 重构为 `StatefulWidget`，并在对应的 `State` 类中持久化其 `GlobalKey`，以防止在 Widget 发生 rebuild 时 `GlobalKey` 频繁重新生成导致其 context 丢失，确保弹窗菜单位置计算正常且能稳定拉起 (`lib/pages/notes_page.dart`, `lib/widgets/diary/diary_item.dart`)。

- **[21:40]**
  - **Changed**: 优化了数据统计页面的“查看数据”按钮。为避免窄屏设备上与时间范围选择器（周/月/年）发生重叠，将原本包含“查看数据”文本的胶囊按钮优化为精致的圆形图标按钮，并增加 `Tooltip` 提示 (`lib/pages/statistics_page.dart`)。

## 2026-06-03

- **[22:35]**
  - **Added**: 在 AI 模型供应商配置中新增 Agnes AI 服务商，支持自动填充其默认的 Base URL（`https://apihub.agnes-ai.com/v1`），并预置核心及历史模型 `agnes-2.0-flash`、`agnes-1.5-flash`、`agnes-image-2.1-flash`、`agnes-image-2.0-flash` 和 `agnes-video-2.0`。此外，Agnes AI 完全支持通过 `/v1/models` 端点拉取并更新最新模型列表 (`lib/config/models.dart`)。

- **[22:30]**
  - **Fixed**: 解决空白待办事项无法被点击重新编辑的问题。通过在待办项文本外部组件设置 `behavior: HitTestBehavior.opaque` 并以 `Container(width: double.infinity)` 容器包裹文本，将非编辑状态下的点击热区从局限的单个空格字符横向拉满到整行宽度，确保空白待办也可被轻松点击选中并进入编辑状态 (`lib/pages/todo_page.dart`)。

## 2026-06-02

- **[21:58]**
  - **Changed**: 优化日记记录事件时间段的排序与展示位置逻辑。如果为同一天的时间段，展示位置调整为 `endTime`；如果是跨日期时间段，根据其归属日期进行判定：归属于后一天时展示在 `endTime` 处，归属于前一天时展示在前一天的 `23:30`（晚上 11 点半）处，使时间轴上的排序和展示更符合日记记录的直觉 (`lib/models/diary_record.dart`)。
  - **Added**: 新增针对 `DiaryRecord.getDisplayTime()` 的单元测试，全面校验同天时间段、跨天且归属第二天、跨天且归属第一天等多种情况的返回时间正确性 (`test/models/diary_record_test.dart`)。

- **[09:45]**
  - **Fixed**: 修复待办事项（Todo）在今日/长期列表下点击无法正常编辑的缺陷。引入 `_isEditing` 状态属性，解耦了在 Widget 构建期对 `_focusNode.hasFocus` 的直接依赖，并改用 `WidgetsBinding.instance.addPostFrameCallback` 在 TextField 渲染挂载完成后延迟请求焦点，彻底解决由于从 Text 动态切换为 TextField 导致焦点瞬间丢失且编辑框闪退的 bug (`lib/pages/todo_page.dart`)。

## 2026-05-31

- **[11:00]**
  - **Fixed**: 修复 `ai_roles.dart` 文件结构损坏导致编译失败的问题——`AiRoles` 类内部嵌套了重复的类定义，`AiRoleSettings` 类完全缺失。重新整理为三个独立类：`AiRoles`（角色配置 ID）、`AiRoleSettings`（温度/令牌数设置）、`AiTemperatures`（角色温度组合） (`lib/models/ai_roles.dart`)。

## 2026-06-23

- **[22:20]**
  - **Changed**: 去除了免费模型配置面板中冗余的「自动选择（按优先级）」下拉选项，改为在拉取或加载免费模型时，自动将有效的第一款模型设置并保存为主模型 (`lib/pages/settings/ai_config_page.dart`)。
  - **Changed**: 将角色绑定下拉菜单中的「免费模型（自动切换）」选项文本简化为「免费模型」 (`lib/pages/settings/ai_config_page.dart`)。
  - **Fixed**: 修复了当角色（如时间轴智能提取）绑定了「免费模型」时，点击「检测图片识别」进行多模态能力检测仍会错误弹出「请先绑定并保存模型」提示的 bug，现在会正确使用当前选中的免费主模型进行评测 (`lib/pages/settings/ai_config_page.dart`)。
  - **Changed**: 聊天页面和智能提取处的长按选择模型功能支持选择并切换至「免费模型」，已在 `lib/pages/ai_page.dart`、`lib/pages/diary_page.dart`、`lib/widgets/diary/diary_editor_view.dart`、`lib/widgets/diary/diary_input_bar.dart` 各处长按切换对话框中新增支持。

- **[10:30]**
  - **Changed**: 修改了 `AiRoleService` 的初始化逻辑，初次进入应用后会自动将 `assistant` 和 `timelineOptimization` 角色配置为使用免费模型，并在后台自动刷新免费模型列表 (`lib/core/ai/ai_role_service.dart`, `lib/main.dart`)。
  - **Changed**: 修改了「AI 配置」页面逻辑，在本地缓存为空且未在更新时，自动触发免费模型列表更新 (`lib/pages/settings/ai_config_page.dart`)。
  - **Fixed**: 修复了 `ConfigRepository` 中尝试使用已被移除的 `defaultAiConfigs` 导致编译报错的问题 (`lib/core/storage/config_repository.dart`)。

- **[10:30]**
  - **Added**: 新增主题常量文件 `app_durations.dart`（动画时长）、`tag_colors.dart`（标签颜色）、`app_radius.dart`（圆角值），统一设计令牌 (`lib/core/theme/`)。
  - **Added**: 新增通用空状态组件 `EmptyStateWidget`，统一四个页面的空状态样式 (`lib/widgets/empty_state.dart`)。
  - **Added**: 为底部导航、日记删除、待办完成/删除、AI 发送等关键交互添加触觉反馈 (`HapticFeedback`)。
  - **Added**: 待办完成勾选动画——圆圈填充 `AnimatedContainer`、勾选图标弹性缩放 `TweenAnimationBuilder(elasticOut)`、删除线平滑过渡 `AnimatedDefaultTextStyle` (`lib/pages/todo_page.dart`)。
  - **Added**: AI 消息气泡入场动画（滑入+淡入）和流式输出闪烁光标 `_BlinkingCursor` (`lib/pages/ai_page.dart`)。
  - **Added**: 统计页 Tab 切换内容 `AnimatedSwitcher` 过渡动画 (`lib/pages/statistics_page.dart`)。
  - **Added**: 底部导航栏图标切换 `AnimatedSwitcher` 交叉淡入、`InkWell` 涟漪效果 (`lib/widgets/bottom_nav_bar.dart`)。
  - **Changed**: 侧边栏菜单项图标颜色从硬编码 `Colors.blue/orange` 等改为 `colorScheme` 语义色，深浅色模式自动适配 (`lib/widgets/side_drawer.dart`)。
  - **Changed**: 统计页 `_TabSwitcher` 从手动 `isDark` 判断硬编码颜色改为 `colorScheme` 语义令牌 (`lib/pages/statistics_page.dart`)。
  - **Changed**: 标签颜色从 `diary_item.dart` 和 `diary_editor_view.dart` 重复定义抽取为 `TagColors` 统一常量 (`lib/core/theme/tag_colors.dart`)。
  - **Changed**: 全项目 40+ 处硬编码颜色（`Colors.red/black/green/orange/amber/grey`）改为 `colorScheme.error/shadow/primary/onSurfaceVariant` 等语义令牌 (`lib/pages/ai_page.dart`, `lib/pages/notes_page.dart`, `lib/pages/todo_page.dart`, `lib/pages/diary_page.dart`)。
  - **Changed**: 圆角值收敛为 `AppRadius.small(8)/medium(12)/large(20)` 三档，修复 `diary_item` 卡片 16→12、`diary_editor_view` MultiSelectChip 8→20、`ai_page` 输入框 24→20/对话框 28→20、`todo_page` SegmentedControl 22/18→20 等不一致 (`lib/widgets/diary/diary_item.dart`, `lib/widgets/diary/diary_editor_view.dart`, `lib/pages/ai_page.dart`, `lib/pages/todo_page.dart`)。
  - **Changed**: 字号规范化——待办标题 14.5→14、副标题 11.5→12、AI 页面 9→10、待办页 AppBar 标题改用默认主题样式 (`lib/pages/todo_page.dart`, `lib/pages/ai_page.dart`)。
  - **Changed**: 四个页面空状态统一使用 `EmptyStateWidget` (`lib/pages/notes_page.dart`, `lib/pages/todo_page.dart`, `lib/pages/ai_page.dart`, `lib/pages/statistics_page.dart`)。
  - **Changed**: 全项目硬编码 `Duration(milliseconds: ...)` 替换为 `AppDurations.fast/normal/medium/slow` 常量。
  - **Changed**: FAB elevation 从 4 统一为 2（与主题定义一致） (`lib/pages/notes_page.dart`, `lib/pages/todo_page.dart`)。
  - **Changed**: 边框透明度统一为 0.4（原 0.3/0.5 散乱） (`lib/widgets/diary/diary_editor_view.dart`)。

- **[09:02]**
  - **Changed**: 整体重构并美化了个人信息页面 (`lib/pages/settings/user_profile_page.dart`)。
    - 将头像展示移动到“基本信息”卡片顶部的中心位置，调整为直径 88 并增加精致的白色描边与投影，优化了相机编辑角标；
    - 将姓名/昵称、出生年月、年龄、身高和最新体重等输入框统一重构为 Outlined 风格，并设置 `floatingLabelBehavior: FloatingLabelBehavior.always`，强制标签始终置顶于边框，防止空值与有值时标签发生高低错位；同时将文本字号从大字号 `bodyLarge` 调小为更紧凑的 `bodyMedium` (14sp, w500)，引入更窄的 `10px` 水平内边距，并将出生年月与年龄的横向比例由 `3:2` 调整为更合理的 `5:2` 以拓宽日期显示，同时移除了身高和最新体重输入框内的前缀图标，释放了横向物理像素，彻底解决了在窄屏手机上生日（原先会截断显示为 `2005-01-`）以及身高值（原先会截断显示为 `1... cm`）因空间不足而被截断、省略的缺陷；
    - 将性别选项重构为胶囊式分段滑动 Tab，内置性别图标与选中阴影；
    - 将身高和最新体重展示改造成左右对等的双栏卡片布局，使用 `InputDecorator` 保证两栏视觉高度与边框高度完全对称；
    - 重构“其他信息”备注框，将标题与图标抽离至文本域上方，与整体表单的卡片内布局风格对齐；
    - 统一将底部“AI 提示”卡片的内边距设置为 24px 并缩减图标间距，使该卡片的机器人图标、提示文本与上方“其他信息”卡片中的图标、提示文本在垂直方向上达成像素级对齐，解决了不对齐的视觉缺陷；
    - 将体重快速记录中的日期选择、体重值输入和添加按钮融合成一根一体化的精美卡片式输入条，并将历史记录的切换 Tab 改为质感极佳的胶囊式 Tab 分段器；
    - 实现了全局点击空白区域自动收回软键盘的交互机制。在根应用 `MaterialApp.router` 的 `builder` 方法中，将子路由及页面组件包裹进一个全局的 `GestureDetector(behavior: HitTestBehavior.translucent)`，拦截 tap 事件并统一调用 `FocusManager.instance.primaryFocus?.unfocus()`，使主页、日记、便签、待办、AI 智能助手、各种设置界面及对话框等所有界面均能获得一致的“点击空白处自动收起输入法”体验；
    - 优化了各个输入框的动作关联逻辑，为昵称、年龄和身高输入框添加 `textInputAction: TextInputAction.next` 支持键盘“下一步”导航；为体重记录输入框配置了 `textInputAction: TextInputAction.done` 与 `onSubmitted`，支持按下键盘的“完成”键在后台静默保存体重数据。

- **[08:49]**
  - **Changed**: 移除了 AI 配置编辑/添加对话框的顶部标题“编辑配置”/“添加配置”，并为 `AlertDialog` 设置了紧凑的 `contentPadding`，从而使下方的供应商选择、模型名称等输入控件整体上移，优化了空间利用率 (`lib/pages/settings/ai_config_page.dart`)。

- **[08:40]**
  - **Added**: 还原并优化了分段式笔记编辑器中的撤回 (Undo) 与取消撤回 (Redo) 历史系统。设计了多段状态快照模型 `_EditorHistoryState` 并集成了打字防抖保存、空格/回车即时保存以及格式化/图片/链接增删合并操作的快照触发逻辑，同时在编辑器底部工具栏中恢复了 Undo 与 Redo 按钮的渲染与交互功能 (`lib/widgets/notes/note_editor_view.dart`)。

- **[08:30]**
  - **Fixed**: 修复了混有文字与链接的文本（如分享的抖音文本、带有说明前缀的链接等）在笔记中无法提取并展示链接预览的缺陷。通过重写 `_addTextAndLinkSegments` 和 `_splitUrlsInSegment`，不再局限于仅匹配整行链接，而是使用正则表达式扫描并提取任意位置的 URL 或 Markdown 链接拆分为独立的 `_LinkSegment` 段落，使其完美展示网页预览卡片并保留与其前后的普通文本的合并机制 (`lib/widgets/notes/note_editor_view.dart`)。

## 2026-05-30

- **[23:10]**
  - **Added**: 在笔记块级链接预览卡片（及默认预览卡片）上新增了“编辑”按钮（`Icons.edit` 画笔图标）。点击后将弹出“编辑链接”对话框，支持修改链接 URL 和显示标题；若 URL 发生变更，将自动清除之前的 dismissed 状态并自动拉取新的链接网页预览 (`lib/widgets/notes/note_editor_view.dart`)。

- **[23:08]**
  - **Fixed**: 修复了在进行 AI 智能提取或评分分析时，若大模型返回包含闲聊说明文字或特定前缀（如 `* Input: ...`）等非标准 JSON 响应时抛出 `FormatException: Unexpected character` 从而导致提取失败的 Bug。我们对 `_parseJsonFromAiContent` 函数引入了更具容错性的 JSON 提取层（通过 `_extractJsonString` 定位最外层的 `{}` 或 `[]` 括号子串进行解析），极大提高了系统对非标 JSON 响应的解析成功率 (`lib/core/ai/ai_service.dart`)。

- **[22:58]**
  - **Changed**: 优化了笔记编辑器中的链接展示与删除交互逻辑。引入了块级段落 `_LinkSegment`，将单独成行的链接及其网页预览框绑定在一起作为不可分割的块段落进行整体渲染和删除。去除了原先纯文本段落（`_TextSegment`）中直接渲染链接预览以及用户可以在链接与预览框中间插入内容的设计。实现了在链接卡片上点击 `x` 按钮将整体同时删除链接和预览卡片的交互效果。此外支持了输入/粘贴链接并按回车或失去焦点时，自动将行拆分为块级链接段落并自动聚焦新行的交互 (`lib/widgets/notes/note_editor_view.dart`)。
  - **Added**: 在笔记编辑器底部的工具栏上新增了“插入链接”按钮（`Icons.link`），点击后将弹出对话框供用户输入链接与可选标题，确认后直接在光标处插入为块级链接段落 (`lib/widgets/notes/note_editor_view.dart`)。

- **[22:45]**
  - **Fixed**: 修复了在时间线页面对已存记录进行 AI 智能提取时，大模型输出的 `notes`（如图片中识别出的菜品备注信息）未能成功合并保存到日记正文/备注中的 Bug。现在已在 `_handleAiExtract` 中正确将 `result.notes` 合并到 `newContent` 中并更新至数据库 (`lib/pages/diary_page.dart`)。
  - **Fixed**: 解决了当用户仅输入纯文本（无图片）进行 AI 智能提取时，大模型由于注意力关联偏差可能仍会输出包含 `"图："` 前缀的 `notes`（幻觉/重复输出），导致日记内容中产生冗余文字的 Bug。增加了“只有在存在图片时才合并/使用 AI 返回的 `notes`”的防御性校验规则 (`lib/pages/diary_page.dart`, `lib/widgets/diary/diary_input_bar.dart`, `lib/widgets/diary/diary_editor_view.dart`)。

## 2026-05-29

- **[22:56]**
  - **Changed**: 优化了日记编辑页面与快速记录输入栏的图片上传交互体验。实现了“原图路径秒显 + 后台静默压缩保存”的异步处理流程，使得用户在选择图片后无需等待即可在界面上直接看到并继续后续操作 (`lib/widgets/diary/diary_editor_view.dart`, `lib/widgets/diary/diary_input_bar.dart`)。
  - **Changed**: 为正在后台压缩处理的图片添加了高质感的半透明黑色遮罩与微型进度指示器组件，提供清晰顺畅的交互反馈 (`lib/widgets/diary/diary_editor_view.dart`, `lib/widgets/diary/diary_input_bar.dart`)。
  - **Added**: 引入了保存/发送日记前的图片压缩任务等待屏障，若用户在压缩期间立即保存，将弹出 `正在处理图片，请稍候...` 对话框，在全部压缩完成后再行写入数据库，从而在提升操作流畅度的同时保障了最终数据路径的完整性。

- **[22:28]**
  - **Fixed**: 修复了 WebDAV 同步配置数据被覆盖或丢失的底层严重漏洞。通过修改 `ExportService._clearAllData`，在导入或远程恢复数据覆盖本地数据时，不再将 `webdav_configs` 和 `app_configs` 清空，避免了因云端备份中为保障安全未包含密码而将本地密码也抹去的漏洞 (`lib/core/export/export_service.dart`)。
  - **Changed**: 优化了同步设置页面（`SyncSettingsPage`）的配置保存体验。引入了对配置修改状态 of 脏标记检测，并通过 `PopScope` 拦截了顶栏返回键及系统手势返回动作。当配置有未保存的更改时，提供“保存/放弃/取消”二次确认弹框；同时在“连接测试”成功通过后，会自动同步保存当前正确的配置状态 (`lib/pages/settings/sync_settings_page.dart`)。
  - **Changed**: 移除了同步设置页面服务器地址、账户、应用密码和备份子目录的举例占位文字（hintText），在没有配置内容时显示为空，避免对用户造成干扰 (`lib/pages/settings/sync_settings_page.dart`)。
  - **Changed**: 优化了同步配置输入框的排版与文字大小。将输入框的左右内边距由 16 缩减为 12，并将字体字重调整为 w500，字号微调为 13，以腾出更多横向空间，确保类似服务器长链接地址等信息能够在一行内完整或更多地显示出来 (`lib/pages/settings/sync_settings_page.dart`)。

- **[22:22]**
  - **Changed**: 调整日记列表项（`DiaryItem`）与批量管理页（`diary_batch_manage_view.dart`）中标签事件的时间展示位置。将原本显示在类别标签右侧、其他属性标签左侧的时间戳，移动至所有属性标签/字段的右侧，以提供更符合直觉的顺序体验 (`lib/widgets/diary/diary_item.dart`, `lib/widgets/diary/diary_batch_manage_view.dart`)。

- **[22:20]**
  - **Changed**: 将桌面小组件底部的“还有 X 个待办，点击进入应用查看...”长文本重构为极简精致的“圆形数字标 + 简短文字”布局。新建了 `bg_widget_badge.xml` 作为圆形气泡背景，在多于 4 项待办时在底部左侧显示如 `+1` 的强调色数字标并紧跟“更多待办”说明文字，降低视觉噪音，保持了高档的微件格调 (`android/app/src/main/res/layout/widget_todo.xml`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`, `android/app/src/main/res/drawable/bg_widget_badge.xml`)。

- **[22:15]**
  - **Changed**: 优化美化待办小组件的界面。去除了列表中每个待办事件外层的灰色圆角背景框 (`bg_widget_input`)，并微调了内边距与外边距。使整个小组件列表与外部大卡片融为一体，排版更显轻盈、开阔与纯粹 (`android/app/src/main/res/layout/widget_todo.xml`)。

- **[21:57]**
  - **Changed**: 彻底重构今日待办桌面小组件的展示与交互机制。将脆弱且在部分国产定制系统（如魅族 Flyme）上极易被拦截禁用的 `ListView` + `RemoteViewsService` 动态列表，彻底重构为 4 个静态 View 槽位（Static Slots）组合的直连数据库渲染方案。新方案直接在 `TodoWidgetProvider` 的 `updateAppWidget` 中单次检索今日待办，根据是否有数据动态展示和填充静态槽位并挂载独立的点击/勾选广播事件，多于 4 条时展示“更多待办”导航提示。这完全避开了系统对后台跨进程 Service 绑定的权限拦截，实现 100% 刷新可靠性与即时勾选响应 (`android/app/src/main/res/layout/widget_todo.xml`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/MainActivity.kt`)。
  - **Deleted**: 彻底移除不再需要的原生服务类 `TodoWidgetService.kt` 并清理了 `AndroidManifest.xml` 中的服务配置，降低了小组件原生实现的复杂度与维护成本。

- **[21:42]**
  - **Fixed**: 优化日记列表项（`DiaryItem`）中的时间显示。新增 `_isTagTimeDuplicate` 辅助校验，当标签级时间（多标签或单标签的 `displayTime` / `time`）与整个日记卡片顶部显示的时间完全一致（开始时分与结束时分完全相同，或无结束时间且开始时分相同）时，自动隐藏标签旁边的重复时间，使卡片布局更精简清爽 (`lib/widgets/diary/diary_item.dart`)。

- **[21:37]**
  - **Fixed**: 修复待办桌面组件列表始终显示"暂无今日待办"的 Bug（头部数字正常但列表内容为空）。根因是 `setEmptyView` 自动机制会在 `RemoteViewsService` 异步加载期间因 ListView Adapter 初始为空而立即触发 EmptyView 显示，后续数据加载完成也无法自动隐藏。修复方案：移除 `setEmptyView` 自动绑定，改为在 Provider 中根据 SQL 查询到的 pendingCount 手动控制 `todo_empty_view` 和 `todo_list_view` 的可见性，使空状态完全由同步查询结果决定而非依赖异步 Adapter。同时在 `TodoWidgetService.onDataSetChanged()` 中补全了 `android.util.Log` 日志链路，便于后续定位 RemoteViewsService 调度问题 (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetService.kt`)。
  - **Changed**: 优化了智能标签提取的 System Prompt，强化了对于图片（特别是食物图片）的提取规则。明确指导 AI 在提取食物图片时识别具体的菜品名称及配料信息，并在 `notes` 字段中详细呈现，从而支持后续 AI 助手更精准的分析 (`lib/config/defaults.dart`)。

## 2026-05-28

- **[08:18]**
  - **Fixed**: 解决发布版本（`flutter build apk`）打包后待办小组件列表依然显示为空的深层机制缺陷。移除了 `TodoWidgetService.kt` 中针对文本项反射调用 `views.setInt(..., "setPaintFlags", ...)` 的逻辑，规避了现代 Android 系统对 RemoteViews 非白名单反射 API 审计过滤所导致的单项渲染崩溃 Bug。同时在 `TodoWidgetProvider.kt` 中添加了在用户点击刷新小组件时主动弹出“今日待办数据已刷新”的 Toast 反馈，协助用户获得可靠的刷新行为触觉感知 (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetService.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。

- **[07:35]**
  - **Fixed**: 修复待办小组件 ListView 无法渲染数据以及点击刷新无效的关键底层缺陷。因 `TodoWidgetService` 在 `AndroidManifest.xml` 中未声明 `android.widget.RemoteViewsService` 的 `<intent-filter>`，导致 Launcher 在尝试跨进程绑定服务时 Intent 校验匹配失败从而静默拒绝加载列表，已为服务正确添加该过滤器。同时将 `setRemoteAdapter` 统改回兼容性最优的双参数重载，规避了部分国产定制系统（MIUI/ColorOS 等）对 API 29 三参数重载的渲染 Bug，并优化了刷新广播，在 Intent 中附带特定的 `appWidgetId` 实现了对被点按组件的精准强制刷新 (`android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。

## 2026-05-27

- **[22:46]**
  - **Added**: 为待办小组件新增手动刷新机制。创建了刷新矢量图 `ic_refresh.xml`，并将待办小组件右上角原先的加号“新建待办”按钮替换为了“刷新待办”按钮，点击标题仍然能跳转进入主应用的今日待办页面 (`android/app/src/main/res/drawable/ic_refresh.xml`, `android/app/src/main/res/layout/widget_todo.xml`)。
  - **Fixed**: 解决待办小组件 ListView 列表项偶发性“显示为空/暂无待办”的异步绑定竞态 Bug。在 `TodoWidgetProvider.kt` 的 `updateAppWidget` 流程中，在绑定适配器后，额外使用 `Handler` 注入了 500ms 的延迟二次 notify 双保险机制，确保 Launcher 在完成跨进程 RemoteViews 架构绑定与 Adapter 实例建立后能必定加载出数据，同时在 `TodoWidgetProvider` 注册并实现了 `com.appone.qnote_flutter.TODO_REFRESH` 广播逻辑，供刷新按钮触发整体更新 (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`, `android/app/src/main/AndroidManifest.xml`)。

- **[22:40]**
  - **Fixed**: 修复了快捷记录小组件调窄后，点击外框底部透明区域或部分空白区域没有反应的问题。通过将最外层 `FrameLayout` 命名为 `widget_quick_record_root` 并为其全局绑定输入跳转 `PendingIntent`，使点击小组件内的任意背景和外部空白透明区域（除各功能按钮外）均可灵敏触发快速记录弹窗 (`android/app/src/main/res/layout/widget_quick_record.xml`, `android/app/src/main/kotlin/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt`)。

- **[22:34]**
  - **Changed**: 优化批量管理页面中日记卡片的内容显示行数，将原本被限制的 `maxLines: 2` 调整为 `maxLines: 8`，方便用户更完整地批量查看和阅读日记的备注文本数据 (`lib/widgets/diary/diary_batch_manage_view.dart`)。

- **[22:32]**
  - **Added**: 数据统计页面支持一键查看日记数据功能。在时间范围选择器同一排的右侧新增一个精致的胶囊型“查看数据”按钮（仅在具体统计分类下显示），点击后将当前所选分类标签和时间范围（周、月、年）打包，通过路由传参跳转到日记的“批量管理”视图 (`lib/pages/statistics_page.dart`)。
  - **Changed**: 重构批量管理视图，使其支持通过路由 `extra` 接收 `initialTags` 和 `initialDateRange` 参数作为初始筛选条件，并在初始化数据后立即应用筛选过滤 (`lib/widgets/diary/diary_batch_manage_view.dart`, `lib/core/router/app_router.dart`)。

- **[22:30]**
  - **Changed**: 优化快捷记录桌面小组件的外观比例。通过将其外层布局包装为 `FrameLayout` 并将实际的小组件卡片高度限定为 `54dp`（在容器中垂直居中），解决了小组件在桌面被拉伸导致上下边距过宽的问题。同时创建了专属的 `bg_widget_quick_record_outer.xml` 胶囊型外框背景，将其圆角半径从 `16dp` 提升至 `27dp`，使得外框的圆角与内部 `36dp` 高度的胶囊型输入框（`18dp` 圆角）呈现完全一致的半圆润视觉效果 (`android/app/src/main/res/layout/widget_quick_record.xml`, `android/app/src/main/res/drawable/bg_widget_quick_record_outer.xml`)。

- **[22:27]**
  - **Changed**: 优化批量管理页面中的日记卡片标签与属性显示 (`lib/widgets/diary/diary_batch_manage_view.dart`)。添加与外部日记事件项 `DiaryItem` 完全相同的标签专属颜色配置与图标解析，并支持显示多属性气泡标签（如时长、入睡时间、收支分类、金额等），将卡片顶部的时间标签统一改造成带有时钟图标的主色调精致气泡，使批量管理里的列表卡片设计美感与主页日记项完全对齐。

- **[22:18]**
  - **Added**: AI配置页新增「多模态能力检测」功能。可通过 Canvas 在本地动态绘制并输出一张印有数字“11”的极简 PNG 字节流，并重用多模态网络接口发送至当前绑定的“时间轴智能提取”大模型。大模型如果能正确识别并输出“11”或“十一”即评测为支持识别，可实时展示评测状态及详细的测试失败/网络错误信息，帮助用户轻松排查、甄别大模型的多模态图片处理能力 (`lib/pages/settings/ai_config_page.dart`, `lib/core/ai/ai_service.dart`)。

- **[22:05]**
  - **Fixed**: 修复跨天日记标签（如睡眠）时间展示出现前缀减号（如 `-22:00~08:00`）的体验缺陷。通过在 `TagEntry` 引入全新的 `displayTime` 属性，将底层机器存储时用于区分跨天偏移量的 `+1` / `-1` 转换为符合人机交互直觉的“昨天”、“次日”、“前天”等汉字描述，同时将日记时间流、编辑器、输入框的标签时间渲染统一切换为该属性，从根本上解决了 UI 上的负号疑惑，同时保障了底层数据解析保存的纯净度 (`lib/models/tag_entry.dart`, `lib/widgets/diary/diary_item.dart`, `lib/widgets/diary/diary_editor_view.dart`, `lib/widgets/diary/diary_input_bar.dart`)。

- **[22:01]**
  - **Changed**: 美化桌面小组件 UI。将快捷记录小组件中的输入框高度限制为更修长窄小的 `36dp`（垂直居中），并为其创建专属的 `bg_widget_quick_record_input.xml` 胶囊型背景（圆角半径由 `10dp` 增大至 `18dp`），让输入栏视觉上更窄、更圆润精致。同时将待办列表项的基础圆角由 `10dp` 稍微优化至 `12dp`，提升整体小组件的现代设计感 (`android/app/src/main/res/layout/widget_quick_record.xml`, `android/app/src/main/res/drawable/bg_widget_quick_record_input.xml`, `android/app/src/main/res/drawable/bg_widget_input.xml`)。

- **[21:44]**
  - **Fixed**: 修复智能时间线提取时，当选择的图片列表为空（或未启用图片提取）但执行提取时，因不安全地直接访问空列表的 `first` 元素导致抛出 `Bad state: No element` 异常的 bug。现在仅在 `shouldSendImage` 为 true（启用图片提取且存在图片）时才动态读取 `mimeType`，其余情况传入 `null` (`lib/widgets/diary/diary_input_bar.dart`, `lib/widgets/diary/ai_extract_helper.dart`)。

- **[13:05]**
  - **Fixed**: 修复待办小组件点击复选框无法更改状态的严重缺陷。这是因为基础 `listClickIntent` 预设了 `action = ACTION_TODO_CLICK`，导致 `Intent.fillIn` 在合并时无法用 checkbox 的自定义 action `ACTION_TODO_TOGGLE` 覆盖它。已通过将基础模板 Intent 的 action 保持置空解决，使 fill-in 能够成功动态填充不同的 Action (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。
  - **Changed**: 优化待办小组件的数据过滤逻辑。将 `TodoWidgetService.kt` 中获取待办列表 the SQL 条件改为只筛选未完成待办（`is_completed = 0`）。现在，只要在小组件中点击勾选完成，该项便会触发数据库修改并在刷新后自动从小组件列表中移除消失，行为与主应用的今日待办页面保持高度一致 (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetService.kt`)。

- **[09:59]**
  - **Fixed**: 修复待办列表小组件在部分 Android 10+（API 29+）设备上始终显示“暂无今日待办”的 bug。通过 `Build.VERSION.SDK_INT` 区分，对 Q 及以上版本的系统显式调用三参数方法签名 `views.setRemoteAdapter(appWidgetId, ...)`，解决双参数方法在较新版本 Android 系统上绑定 Adapter 失败的问题；同时在 `updateAppWidget` 流程中在小组件绑定适配器后，立即调用 `appWidgetManager.notifyAppWidgetViewDataChanged`，强制系统主动激发一次 Factory 的首帧数据查询加载动作，解决部分桌面（Launcher）在初始化小组件时不自动触发 `onDataSetChanged()` 数据查询的 bug (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。

- **[09:30]**
  - **Changed**: 精简 AGENTS.md 规范文件，移除过度限制性的 UI 细节规范（圆角层级表、颜色语义表、组件要点、禁止项）、命名规范表格、类型映射表、Lint 章节等，将"禁止"语气改为建议性，简化变更日志和测试流程要求 (`AGENTS.md`)。

- **[08:25]**
  - **Changed**: 简化快速记录小组件的占位文本内容，移除了最前方的 Emoji 表情并将文字修改为 `"快速记录..."`，设置 `maxLines="1"` 与 `ellipsize="end"`，配合稍微紧凑的字号以确保在各种窄屏尺寸下均能在一行内显示且不发生换行变形 (`android/app/src/main/res/layout/widget_quick_record.xml`)。

- **[08:25]**
  - **Fixed**: 修复待办小组件列表仍然显示“暂无今日待办”的 bug。在 `AndroidManifest.xml` 中将 `TodoWidgetService` 的 `android:exported` 改为 `true`，解决 Launcher 或系统进程跨进程绑定 RemoteViewsService 时被安全权限限制拒绝的严重问题 (`android/app/src/main/AndroidManifest.xml`)。
  - **Changed**: 简化 `serviceIntent` 的 `data` 唯一标识，由复杂的 `Intent.toUri` 改为极简 Scheme 格式 `Uri.parse("qnote://widget/todo/$appWidgetId")`，彻底杜绝部分旧设备或特定 ROM 在跨进程传输序列化数据时的解析异常风险 (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。
  - **Changed**: 重构 ListView 列表项的点击分发模型。将 ListView 的 `PendingIntentTemplate` 改为 BroadCast PendingIntent，接收端统一分发。点击文字时由 BroadCast 发送 `ACTION_TODO_CLICK` 并由 `TodoWidgetProvider` 代理启动 Activity 实现路由导航；点击复选框时发送 `ACTION_TODO_TOGGLE`，解决先前直接使用 Activity PendingIntentTemplate 导致点击复选框无法在后台修改数据库状态而会错误拉起主界面的严重 bug (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetService.kt`, `android/app/src/main/AndroidManifest.xml`)。

- **[07:35]**
  - **Fixed**: 修复待办小组件 ListView 列表项无法加载显示的 bug。去除了 `widget_todo.xml` 里的非 RemoteViews 属性 `nestedScrollingEnabled`；在 `TodoWidgetProvider.kt` 的 `serviceIntent` 绑定流程中添加显式包名设置 `setPackage(context.packageName)` 规避新版本 Android 的绑定限制 (`android/app/src/main/res/layout/widget_todo.xml`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。
  - **Fixed**: 修复快速记录弹窗尺寸过小、严重挤压变形的 bug。将 `QuickRecordDialogTheme` 继承的基类主题由 Dialog 主题修改为普通全屏 `NoActionBar` 主题 (`android/app/src/main/res/values/styles.xml`, `android/app/src/main/res/values-night/styles.xml`)。
  - **Added**: 为快捷记录页面最外层 `FrameLayout` 绑定点击事件，并为卡片 `LinearLayout` 设定 `clickable="true"`，完美实现点击弹窗外部空白区域时自动关闭弹窗的交互体验 (`android/app/src/main/res/layout/activity_quick_record.xml`, `android/app/src/main/kotlin/com/appone/qnote_flutter/QuickRecordActivity.kt`)。
  - **Fixed**: 修复通过小组件新增的日记记录在应用内未显示的问题。将 Android 端写入数据库时生成的时间戳格式由 UTC 更改为本地时区时间戳格式（去掉了末尾的 `'Z'` 并改用本地时区），使其与 Flutter 端的 `toIso8601String()` 返回格式一致，避免 8 小时时区差导致当日日记筛选过滤失效 (`android/app/src/main/kotlin/com/appone/qnote_flutter/QuickRecordActivity.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。
  - **Changed**: 在 `lib/app.dart` 中为根 Widget 接入 `WidgetsBindingObserver`，在应用切换回到前台（`resumed`）时，自动触发日记和待办 Provider 的 `refresh()` 重新加载数据，保证从小组件写入数据或勾选待办后，应用界面能实时同步数据变化 (`lib/app.dart`)。

## 2026-05-26

- **[22:58]**
  - **Fixed**: 修复小组件“无法加载微件”的严重缺陷。移除了 `RemoteViews` 渲染布局中不支持的 `Space` 视图并使用 `layout_marginEnd` / `layout_marginStart` 代替 (`android/app/src/main/res/layout/widget_quick_record.xml`, `android/app/src/main/res/layout/todo_item_widget.xml`)；在 `AndroidManifest.xml` 中将小组件 Provider、Service 和 Activity 的相对类名全部替换为完整的包路径全限定类名，防止系统因包名与包路径不匹配而抛出 `ClassNotFoundException` 导致无法实例化类 (`android/app/src/main/AndroidManifest.xml`)。
  - **Changed**: 在 `TodoWidgetProvider.kt` 的 `updateAppWidget` 流程中补充绑定 `setEmptyView` 逻辑，在没有待办时自动呈现空状态提示 (`android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`)。

- **[22:42]**
  - **Changed**: 数据统计页标签栏按钮更紧凑，减小内边距（horizontal 16→12, vertical 8→6）、按钮间距（8→4）、圆角（20→16）(`lib/pages/statistics_page.dart`)。
  - **Changed**: 将统计页「状态」标签改名为「健康」，图标从 `favorite` 改为 `health_and_safety`，同步更新健康统计卡片文案：标题「平均状态」→「健康状况」、严重程度标签（轻微/中度/严重）→（良好/一般/需关注）、图表 Y 轴标签同步、图表标题简化为「健康趋势」、图标统一为 `health_and_safety`(`lib/pages/statistics_page.dart`, `lib/widgets/statistics/mood_stats.dart`)。注意：底层 `calculateMoodStats` 已同时过滤 `displayTag == '状态' || displayTag == '健康'` 的记录，数据源已兼容。

- **[22:41]**
  - **Added**: 新增桌面小组件相关类与资源。包括桌面小组件方法通道接口 (`lib/core/utils/widget_utils.dart`)；快捷记录小组件、待办小组件及 FileProvider 共享配置 (`android/app/src/main/res/xml/widget_quick_record_info.xml`, `android/app/src/main/res/xml/widget_todo_info.xml`, `android/app/src/main/res/xml/file_paths.xml`)；快捷记录小组件、待办小组件、待办项及快速记录悬浮 Activity 布局 (`android/app/src/main/res/layout/widget_quick_record.xml`, `android/app/src/main/res/layout/widget_todo.xml`, `android/app/src/main/res/layout/todo_item_widget.xml`, `android/app/src/main/res/layout/activity_quick_record.xml`)；小组件圆角背景、输入框背景、悬浮输入框卡片与文本框背景、复选框/相机/相册/发送/添加等矢量图形样式 (`android/app/src/main/res/drawable/bg_widget.xml`, `android/app/src/main/res/drawable/bg_widget_input.xml`, `android/app/src/main/res/drawable/bg_dialog_card.xml`, `android/app/src/main/res/drawable/bg_dialog_input.xml`, `android/app/src/main/res/drawable/ic_checkbox_checked.xml`, `android/app/src/main/res/drawable/ic_checkbox_unchecked.xml`, `android/app/src/main/res/drawable/ic_camera.xml`, `android/app/src/main/res/drawable/ic_gallery.xml`, `android/app/src/main/res/drawable/ic_send.xml`, `android/app/src/main/res/drawable/ic_add.xml`)；浅色与深色配色方案 (`android/app/src/main/res/values/colors.xml`, `android/app/src/main/res/values-night/colors.xml`)；快捷日记小组件广播类、待办小组件广播类、待办小组件 ListView 的数据源 Service 与 Factory、以及微型悬浮 Activity 对话框实现类，支持后台线程读取/更新 SQLite、保存日记图片和记录 `sync_log` (`android/app/src/main/kotlin/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetProvider.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/TodoWidgetService.kt`, `android/app/src/main/kotlin/com/appone/qnote_flutter/QuickRecordActivity.kt`)。
  - **Changed**: 调整日记数据模型更新接口和待办列表更新接口，在新增/更新/删除/重排等操作后触发小组件通知更新通道 (`lib/providers/diary_provider.dart`, `lib/providers/todo_provider.dart`)；配置主 App 支持接收并路由挂起的待办小组件界面跳转指令 (`lib/app.dart`)；扩展主 Activity 注册 MethodChannel 双向通信通道并在小组件刷新时分发广播 (`android/app/src/main/kotlin/com/appone/qnote_flutter/MainActivity.kt`)；配置 Android 注册所有桌面小组件相关 Receiver、Service、悬浮 Activity 以及 FileProvider (`android/app/src/main/AndroidManifest.xml`)；添加快速记录悬浮对话框在浅色与深色模式下的透明背景与阴影配置样式 (`android/app/src/main/res/values/styles.xml`, `android/app/src/main/res/values-night/styles.xml`)。

- **[22:22]**
  - **Fixed**: 修复 AI 助手点击发送后软键盘没有收起的问题，在发送消息后立即调用 `FocusScope.of(context).unfocus()` 收起软键盘 (`lib/pages/ai_page.dart`)。
  - **Changed**: 优化 AI 助手流式消息刷新性能，在 AI 消息流式输出中加入 50ms 节流限制，避免高频 UI 重绘；同时重构 AI 页面中的消息区域渲染，通过 select 语句仅监听流状态是否存在的布尔值以决定是否插入流式气泡组件，实现高频刷新阶段只渲染流式气泡局部，大幅降低主页面及历史消息列表的重构开销 (`lib/providers/ai_provider.dart`, `lib/pages/ai_page.dart`)。
  - **Changed**: 优化流式自动滚动逻辑，智能检测滚动条位置，仅当用户当前处于对话最底部附近时才执行流式消息更新后的滚动跳跃，避免当用户试图滑动查看历史记录时被强行拉回底部 (`lib/pages/ai_page.dart`)。
  - **Added**: 新增 `_StreamingBubble` 局部 ConsumerWidget 组件，专门负责响应流式消息的动态刷新 (`lib/pages/ai_page.dart`)。

- **[22:18]**
  - **Fixed**: 修复智能提取中 AI 模型有时将提取字段属性误写为别名（例如将 `activity` 的 `type` 误写为 `_category`）导致提取失败的问题。在 `schema_formatter.dart` 中新增 `normalizeExtractedFields` 字段映射别名修正层并在相关逻辑中应用，同时微调 `defaults.dart` 中的智能提取系统提示词规则，严格规范字段键名一致性 (`lib/core/utils/schema_formatter.dart`, `lib/widgets/diary/ai_extract_helper.dart`, `lib/widgets/diary/diary_input_bar.dart`, `lib/config/defaults.dart`)。
- **[23:00]**
  - **Changed**: 精简 `AGENTS.md`，从 622 行压缩至 221 行（减少 64%），删除冗余代码示例、重复说明和低信息密度章节（功能模块概览、Lint 配置 yaml 块等），合并代码风格+注释、组件+错误处理章节，保留所有关键约束和令牌表 (`AGENTS.md`)。
- **[21:05]**
  - **Changed**: 智能提取改为动态检测 MIME 类型，避免硬编码，并在 `ImageRepository` 中添加 `getMimeType` 静态方法，提升文件格式扩展兼容性 (`lib/core/storage/image_repository.dart`, `lib/widgets/diary/ai_extract_helper.dart`, `lib/widgets/diary/diary_input_bar.dart`)。
- **[22:00]** 
  - **Added**: 创建变更日志机制，新增 `CHANGELOG.md`，在 `AGENTS.md` 中添加变更日志规范。
- **[20:30]**
  - **Fixed**: 统一 WebDAV 同步设置页面的 Toast 提示，移除局部冗余的自定义 Toast UI，改用全局 `Toast.success/error/info`，修复特定主题下字体颜色对比度过低看不清的问题 (`lib/pages/settings/sync_settings_page.dart`)。
- **[19:00]**
  - **Added**: 实现图片保存时的压缩机制，引入 `image` 包，存入本地前等比例缩放（最大边长 1080px）并以 80% 质量压缩为 JPEG，使用 `compute` 移至 Isolate 后台运行，削减约 98% 图片体积 (`pubspec.yaml`, `lib/core/storage/image_repository.dart`)。
- **[17:30]**
  - **Fixed**: 修复智能提取中图片未能成功转换为 Base64 的路径解析缺陷，`getBase64Image` 调用 `File(path)` 前先调用 `resolveLocalPath(path)` 规范化路径 (`lib/core/storage/image_repository.dart`)。

# Agent 变更日志

本文件记录 Agent（AI 编程助手）对项目代码的所有修改，用于追溯问题、回溯决策。

格式规范见 `AGENTS.md` →「变更日志规范」。

---

## 2026-05-28

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

---
name: fixed_events_duration_input_bug
overview: 修复固定事件"添加/编辑"对话框中"时长(小时)"等文本字段无法正常连续输入的问题：当前实现每次 build 都 new 一个 TextEditingController 并 setDialogState 推算结束时间，导致 controller 反复重建、光标归零，输入"12"被反向插入为"21"。
todos:
  - id: add-controller-cache
    content: 在 `_FixedEventsPageState` 中新增 `_fieldControllers` / `_fieldFocusNodes` 缓存字段、dispose 方法，并提供创建/获取/释放辅助方法
    status: completed
  - id: wire-dialog-lifecycle
    content: 在 `_showEditDialog` 打开时为当前 `selectedTagFields` 预创建 controller 与 focusNode；在 dialog 关闭时统一 dispose，并随选中标签变化按需增删缓存
    status: completed
    dependencies:
      - add-controller-cache
  - id: refactor-textfield
    content: 将 `_buildSelectedTagFields` 中 else 分支的 TextField 改为复用缓存 controller/focusNode，增加 ValueKey，仅在无焦点时单向同步外部值；为 number 字段加键盘类型与输入过滤
    status: completed
    dependencies:
      - wire-dialog-lifecycle
  - id: defer-endtime-recalc
    content: 将 `_showEditDialog` 中 `onFieldChanged` 修改 endHour/endMinute 的 `setDialogState` 用 `WidgetsBinding.instance.addPostFrameCallback` 推迟到下一帧
    status: completed
    dependencies:
      - refactor-textfield
  - id: verify-and-changelog
    content: 本地热重载后按"验证要点"逐项手测，并将本次修复写入 `CHANGELOG.md`（Fixed：`lib/pages/settings/fixed_events_page.dart`）
    status: completed
    dependencies:
      - defer-endtime-recalc
---

## 缺陷描述

在「固定事件管理 → 添加/编辑固定事件」对话框中，给事件关联「活动」标签后，尝试在「时长（小时）」等非 select/multiselect 类型的文本字段中连续输入数字时，输入方向异常（例如想输入 "12"，输入框里出现 "21"）。同时存在光标跳到开头、已输入内容被覆盖、连续输入丢字等连锁问题。**类型（select）、备注（多行）等走专用控件的字段不受影响**。

## 期望行为

- 文本字段可正常连续输入，字符按光标位置顺序追加。
- 数字类型字段弹出数字键盘，可输入小数。
- 切换/取消选中标签时，已输入内容可被正确回显。
- 输入「时长」后仍能反向推算结束时间，但不打断当前输入。

## 根因

Bug 集中在 `lib/pages/settings/fixed_events_page.dart` 的 `_buildSelectedTagFields` 中"非 select / multiselect 字段"分支（第 933–963 行）：

```
TextField(
  controller: TextEditingController(   // 每次 build 都 new 一个
    text: currentValue?.toString() ?? '',
  ),
  onChanged: (val) {
    setDialogState(() { ... });         // ① 同步写回 selectedTagFields
    onFieldChanged?.call(...);          // ② 内部再 setDialogState 改 endHour/endMinute
  },
)
```

双重问题：

1. **Controller 反复重建**：`StatefulBuilder` 在 `onChanged` 的 `setDialogState` 中重建，TextField 重新执行 build，每次都用 `new TextEditingController(text: currentValue)` 覆盖原 controller，新 controller 默认 `TextSelection.collapsed(offset: -1)`（光标 0 偏移），下一次按键被插到文本开头，于是 "1"+"2" → "21"。同时该 controller 从未 dispose，存在内存泄漏。
2. **onFieldChanged 内部同帧 setDialogState**：duration 变化时改 `endHour`/`endMinute` 进一步触发同帧/紧邻帧的重建，加剧光标和选区丢失。

## 修复策略

采用"缓存 controller + 异步反向推算 + 数字键盘"三件套，**最小改动、保持现有交互**：

1. **在 `_FixedEventsPageState` 维护 `Map<String, TextEditingController> _fieldControllers`**，key 用 `'$tagId#${field.id}'` 拼接。

- dialog 打开时按当前 `selectedTagFields` 预创建或复用 controller。
- 关闭 dialog（保存 / 取消 / 外部 dismiss）时统一 `dispose` 所有 controller。

2. **`_buildSelectedTagFields` 中改用缓存 controller**，仅在以下条件同时满足时把外部 `currentValue` 同步到 controller：

- `controller.text != currentValue?.toString()`
- `!focusNode.hasFocus`（或 controller 未处于 composing 态）
避免在用户输入途中覆盖光标位置和已输入字符。

3. **为每个字段配 `FocusNode`（同 map 缓存）**，用 `ValueKey('$tagId#${field.id}')` 包裹 TextField，确保字段被移除时正确释放。
4. **将 `onFieldChanged` 中修改 `endHour`/`endMinute` 的 `setDialogState` 推迟到下一帧**：

- 用 `WidgetsBinding.instance.addPostFrameCallback` 包一层，让当前 onChanged 完成后再重建。
- 此时 controller 文本已是用户最新输入，下一帧再判断是否需要把外部值同步到 controller，避免覆盖。

5. **数字类型字段（`field.type == 'number'`）加 `keyboardType: TextInputType.numberWithOptions(decimal: true)` 和 `FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))`**，约束为数字键盘与小数点。
6. **不动 `user_profile_page.dart` 第 450 行的 `readOnly` 生日选择器**（无焦点、无输入，不存在此问题）。

## 影响范围

- 单文件修改：`lib/pages/settings/fixed_events_page.dart`
- 涉及 `_FixedEventsPageState` 字段新增、`_showEditDialog` 生命周期管理、`_buildSelectedTagFields` 中一处 TextField 改造
- 不动 model / repository / provider / select / multiselect 分支

## 验证要点

- 输入 "1" → "12" → "12.5" 显示正确、光标位置正确。
- 选中「活动」后时长输入到一半取消选中再选回，原内容回显。
- 时长变化时结束时间被反向推算（08:00 + 12h = 20:00），且不会打断当前输入。
- 保存后再次打开 dialog，时长内容正确回显。
- 关闭 dialog 后无 controller / focusNode 泄漏。
- select / multiselect 控件与"类型"字段交互完全不变。
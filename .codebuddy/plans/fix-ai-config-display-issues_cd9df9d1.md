---
name: fix-ai-config-display-issues
overview: 修复 AI 配置页面的延迟文本溢出和多处缺少 mounted 检查导致的 setState after dispose 问题。
todos:
  - id: fix-layout-overflow
    content: 修复 `_buildConfigCard` 中延迟文本布局溢出问题
    status: completed
  - id: fix-test-model-image
    content: 为 `_testModelImageRecognition` 方法添加 mounted 检查
    status: completed
  - id: fix-test-single-config
    content: 为 `_testSingleConfig` 方法添加 mounted 检查
    status: completed
  - id: fix-test-all-configs
    content: 为 `_testAllConfigs` 方法添加 mounted 检查
    status: completed
  - id: fix-fetch-models
    content: 为 `_fetchModelsForVendor` 方法添加 mounted 检查
    status: completed
  - id: fix-slider-delete
    content: 修复 Slider onChanged 和删除回调中的 setState 问题
    status: completed
---

## 问题描述

用户反馈AI配置页面的预览显示存在问题，截图显示：

1. 模型卡片列表中显示"RIGHT OVERFLOWED BY 129 PIXELS"溢出警告
2. 显示"setState() called after dispose"状态管理错误

## 修复需求

- 修复 `_buildConfigCard` 中 `_buildLatencyText` 的布局溢出问题
- 为所有异步回调中的 `setState` 调用添加 `mounted` 检查
- 修复对话框中的 `setDialogState` 可能在 dispose 后调用的问题

## 涉及文件

- `lib/pages/settings/ai_config_page.dart`（第612-735行的卡片构建、第86-180行的模型获取方法、第420-515行的测试方法）

## 技术栈

- Flutter + Dart
- Riverpod 状态管理

## 修复方案

### 问题1：布局溢出修复

**原因**：`_buildConfigCard` 中 `displayName` 用 `Expanded` 包裹，但 `_buildLatencyText` 没有宽度约束，当测试失败返回长错误文本时会溢出。

**解决方案**：将 `_buildLatencyText` 用 `Flexible` 包裹或添加约束宽度。

### 问题2：setState after dispose 修复

**原因**：多处异步操作（测试延迟、获取模型列表等）完成后直接调用 `setState`，此时组件可能已被 dispose。

**需要修复的位置**：

- `_testModelImageRecognition` (第439、449、458、462行)
- `_testSingleConfig` (第470行)
- `_testAllConfigs` (第489行)
- `_buildRoleAssignment` 中 Slider (第891行)
- `_fetchModelsForVendor` 中的多处 `setState` (第102-173行)
- 删除配置回调 (第639、726行)

### 问题3：对话框 setDialogState 保护

**原因**：`_fetchModelsForVendor` 等异步方法在对话框关闭后仍可能调用 `setDialogState`。

**解决方案**：在调用 `setDialogState` 前检查对话框是否仍打开（通过检查 `context.mounted` 或添加标志位）。
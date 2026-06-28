---
name: diary-card-content-indent
overview: 微调日记事件卡片中单标签与多标签内容的左侧缩进，让文字和图片与上方标签 pills 保持一致的视觉内收。
todos:
  - id: add-content-indent
    content: 在 diary_item.dart 中为文字与图片增加统一左侧缩进并修正图片宽度计算
    status: completed
  - id: update-changelog
    content: 在 CHANGELOG.md 记录 UI 间距调整
    status: completed
    dependencies:
      - add-content-indent
---

## 用户需求

调整日记事件卡片（`DiaryItem`）中文字与图片的左侧对齐：当前内容文字/图片与上方标签 pill 的左边缘对齐，视觉上显得“在标签外面”。需要给文字和图片整体增加少量左侧缩进，使其看起来收在标签下方。

## 涉及范围

- 单标签场景：`_buildSingleTagContent` 渲染的正文、卡片内图片 `Wrap`
- 多标签场景：`_buildMultiTagSections` 渲染的富文本内容
- 仅修改 `lib/widgets/diary/diary_item.dart`，不改动功能逻辑

## 预期效果

卡片正文与图片整体向右偏移约 4 dp，视觉上与标签 pill 的内侧左边缘对齐，避免“凸出”感。

## 技术方案

### 实现策略

在 `DiaryItem` 现有布局基础上，通过统一左侧内边距让正文与图片向右收缩，不改变卡片外层 padding 与标签行位置，保持改动最小。

### 关键修改点

1. **单标签正文缩进**：调用 `_buildRichContent` 时传入 `leftPadding: 4.0`。
2. **单标签图片缩进**：图片 `Wrap` 的 `Padding` 由 `left: 0` 改为 `left: 4.0`。
3. **多标签正文缩进**：`_buildMultiTagSections` 中 `leftPadding` 由 `0` 改为 `4.0`。
4. **常量复用**：在 `_DiaryItemState` 中定义 `static const _contentIndent = 4.0`，三处统一引用，避免魔术数字。

### 图片宽度适配

图片区域当前使用 `screenWidth - 132` 计算最大宽度。增加 4 dp 左侧缩进后，可用宽度减少 4 dp，因此将 `maxWidth` 计算改为 `screenWidth - 132 - _contentIndent`，防止最右侧图片被截断或换行异常。

### 设计原则

- 遵循项目 UI 设计原则：少量、克制的间距调整，不引入新颜色、阴影或重样式。
- 保持 light/dark 主题无差异。
- 不改动状态管理、数据模型或交互逻辑。
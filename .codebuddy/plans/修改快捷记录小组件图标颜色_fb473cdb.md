---
name: 修改快捷记录小组件图标颜色
overview: 将 Android 桌面快捷记录小组件中的相册和相机图标颜色从灰色改为黑色，并适配深色模式
todos:
  - id: change-icon-colors
    content: 修改 ic_gallery.xml 和 ic_camera.xml 的 fillColor 为 widget_text_primary
    status: completed
---

## Product Overview

修改 Android 桌面快捷记录小组件中相册和相机两个图标的颜色，将灰色改为更深、对比度更高的颜色，同时适配深色模式显示效果。

## Core Features

- 将相册图标（`ic_gallery.xml`）和相机图标（`ic_camera.xml`）的颜色从灰色（`#8E8E93`）改为更深的颜色
- 浅色模式下使用近黑色（`#1C1C1E`），提升与白色背景的对比度
- 深色模式下自动切换为浅色（`#F2F2F7`），保证在深色背景上的可读性

## Tech Stack

- Android 原生资源文件：Vector Drawable XML + Colors XML

## 实现方案

**策略**：将图标的 `fillColor` 引用从 `widget_text_secondary` 改为 `widget_text_primary`。这是最优方案：

1. 无需新增颜色定义，复用现有语义化颜色变量
2. 浅色模式：`widget_text_primary = #1C1C1E`（近黑色），满足用户"改成黑色"的需求
3. 深色模式：`widget_text_primary = #F2F2F7`（近白色），在深色背景上清晰可见
4. 影响范围精确可控，仅影响两个图标颜色

## 修改范围

| 文件 | 操作 | 说明 |
| --- | --- | --- |
| `android/.../drawable/ic_gallery.xml` | 修改 | `fillColor`: `@color/widget_text_secondary` → `@color/widget_text_primary` |
| `android/.../drawable/ic_camera.xml` | 修改 | `fillColor`: `@color/widget_text_secondary` → `@color/widget_text_primary` |


注意：`widget_text_secondary` 同时被"快速记录..."占位文字引用，因此不能直接改其值，必须通过修改图标的 fillColor 目标来实现。
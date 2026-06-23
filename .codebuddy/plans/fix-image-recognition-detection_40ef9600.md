---
name: fix-image-recognition-detection
overview: 修复推理思考模型（如 sensenova）图片识别检测失败的问题：`_extractTextFromResponse` 只检查 `content` 字段，当模型 token 被 `reasoning` 消耗完导致 `content` 为空时，检测误报"不支持图片识别"。
todos:
  - id: fix-max-tokens
    content: 修复 checkImageRecognition 中 max_tokens 不足问题 (50→200)
    status: completed
  - id: fix-extract-text
    content: 修复 _extractTextFromResponse 增加 reasoning 字段回退
    status: completed
    dependencies:
      - fix-max-tokens
---

## 问题描述

用户在使用 SenseNova Flash Lite 多模态模型时，图片识别检测功能显示"不支持图片识别"，但模型实际支持且日志显示识别成功。

## 核心问题

1. **token 不足**：`checkImageRecognition` 使用 `max_tokens: 50`，推理模型输出 reasoning 后 content 被截断
2. **字段提取遗漏**：`_extractTextFromResponse` 只读取 `message.content`，未处理 `message.reasoning` 字段

## 需求

修复图片识别检测功能，使其正确识别支持图片识别的模型。

## 问题根因分析

```
用户日志:
  finish_reason: "length"  ← 50 tokens 被 reasoning 用完
  message.reasoning: "好的...里面是两个数字"11""
  message.content: (空，因为被截断了)

checkImageRecognition 返回值: false
原因: _extractTextFromResponse 返回空字符串，cleanResult 不包含 "11"
```

## 修复方案

### 1. 增加 token 配额

在 `checkImageRecognition` 中将 `max_tokens` 从 50 提升到 200，确保推理模型有足够空间输出 reasoning + content。

### 2. 增加 reasoning 字段回退

在 `_extractTextFromResponse` 中，当 `content` 为空时，尝试从 `message['reasoning']` 提取文本。

### 涉及文件

- `lib/core/ai/ai_service.dart` (两处修改)

### 变更点

1. 第 1199 行: `'max_tokens': 50` → `'max_tokens': 200`
2. 第 1162 行: `'maxOutputTokens': 50` → `'maxOutputTokens': 200`
3. 第 819 行: 增加 `reasoning` 字段回退逻辑
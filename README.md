<div align="center">

<img src="docs/app_icon.svg" alt="QNote" width="96" />

# QNote

**AI 随身记录管家 —— 让记下来的东西，真正帮到你。**

Flutter 多平台个人记录应用 · Android / iOS / Web

[官网介绍页](https://favoroo.github.io/QNote/) · [下载 APK](https://github.com/favoroo/QNote/releases/latest) · [更新日志](https://favoroo.github.io/QNote/#changelog)

</div>

---

QNote 把**时间线速记、富文本笔记、GTD 待办、数据统计、健康量化**沉淀在同一座本地数据底座上，并内置智能体 **小Q**——记待办、写笔记、打卡时间线、看统计，说一句就行。

## ✨ 核心特性

- **小Q 智能体**：5 种人设（可自定义）、9 大内置技能、14 个工具统一读写 VFS 虚拟文件系统；长期记忆、Edge TTS 流式语音、悬浮球、划选提问
- **时间线 + 日记双形态**：碎片随手记自动归类（睡眠/饮食/活动/记账），长文日记内置 GRAI / KPT / 九宫格模板
- **双模笔记**：富文本 ⇄ Markdown 无损切换（记忆光标位置），多层目录树，HTML / SVG / 代码内置预览
- **GTD 待办**：四象限、重复规则、系统级提醒；Android 原生桌面小组件 ×3（待办卡片 / 问小Q / 快捷记录）
- **健康量化**：直连小米运动健康云端协议（步数/睡眠分期/心率/血氧/压力），屏幕使用时间 Top 应用榜，每晚自动沉淀「运动健康日结」
- **统计与评分**：六维图表 + 每日五维生活健康总分，评分热力图、批量调分与撤销
- **本地优先**：所有数据存于设备本地 SQLite，零遥测；WebDAV 同步（坚果云 / Nextcloud / 自建）与 JSON 全量备份恢复
- **开箱即用的 AI**：内置免费模型池（默认 GLM-5.2），另预置 DeepSeek / OpenAI / Kimi / 智谱 / Gemini 等 15 家服务商

## 📥 下载

| 平台 | 获取方式 |
|------|----------|
| Android | [GitHub Releases](https://github.com/favoroo/QNote/releases/latest) 下载 `QNote-v<版本>-arm64-v8a.apk`（约 30 MB，arm64）；国内可走 [Gitee 镜像](https://gitee.com/favo9/qnote/releases) |
| Web | `flutter run -d chrome` 本地构建，或从源码构建 Web 版 |
| iOS | 从源码 `flutter build ipa` 自行构建安装 |

App 内置「检查更新」，双端 Release 自动发现新版本。

## 🛠 开发

```bash
flutter pub get
flutter run -d chrome --web-port=8080   # Web 调试
flutter run -d <android-device-id>      # Android 调试
flutter test                            # 单元测试
flutter analyze                         # 静态检查

# 发布构建（仅 arm64，见 .agents/skills/qnote-release/SKILL.md）
flutter build apk --release --target-platform android-arm64 \
  --obfuscate --split-debug-info=build/debug-info --tree-shake-icons
```

- 状态管理：Riverpod；数据层：sqflite（含 Web WASM）；富文本：flutter_quill
- 架构与代码约定详见 [`AGENTS.md`](AGENTS.md)
- 站点源在 [`docs/`](docs/)，由 GitHub Actions（`.github/workflows/pages.yml`）自动发布到 GitHub Pages

## 🔗 双端仓库

本仓库在 GitHub 与 Gitee 双端同步，Tag 与 Release 保持一致：

| 平台 | 仓库 |
|------|------|
| GitHub | [favoroo/QNote](https://github.com/favoroo/QNote) |
| Gitee | [favo9/qnote](https://gitee.com/favo9/qnote) |

## 🔒 隐私

QNote 不会收集任何用户的个人数据。所有数据均存储在您的本地设备上；云同步仅连接您自己的 WebDAV 服务。

---

© 2026 QNote Team

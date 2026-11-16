import 'q_style_theme.dart';

/// 构建 frontend-design 技能提示词（QStyle 风格系统）。
///
/// 主题决策表、家族 token 块与主题色块均由 [qStyleThemes] 自动生成，
/// 新增风格只需改 `q_style_theme.dart`，本文件无需改动。
String buildFrontendDesignDoc() {
  final magazineThemes = qStyleThemes.where((theme) => theme.family == QStyleFamily.magazine).toList();
  final swissThemes = qStyleThemes.where((theme) => theme.family == QStyleFamily.swiss).toList();
  final decisionRows = qStyleThemes
      .map((theme) => '| ${theme.suitableFor} | ${theme.family.label} | ${theme.name}（`${theme.id}`） |')
      .join('\n');
  final magazineBlocks = magazineThemes.map((theme) => theme.cssBlock).join('\n');
  final swissBlocks = swissThemes.map((theme) => theme.cssBlock).join('\n');

  return '''---
name: frontend-design
description: 网页设计技能（QStyle 风格系统）：精美单文件 HTML 网页/落地页/H5/待办打卡工具/海报/邀请函/贺卡/简历页/数据可视化页面等展示与交互型内容的生成规范。内置杂志风与瑞士风两个风格家族共 11 套锁定主题、12 个移动端登记版式、字体字号阶梯、组件词汇与 LocalStorage 状态持久化规则
---

# 网页设计技能 (Frontend Design · QStyle)

用户让你「做个网页 / 页面 / 待办清单 / 打卡工具 / 记账页 / 海报 / 邀请函 / 贺卡 / 简历页 / 可视化大屏」时，按本手册执行，产出**有设计感、适配手机屏幕、交互状态自留存**的单文件 HTML，避免千篇一律的「AI 生成感」。

QStyle 只有三条底线，违反任何一条都不合格：
1. **主题锁定**：颜色只能从本手册 11 套预设里选，禁止临场写 hex；
2. **版式锁定**：区块只能从 12 个登记版式里组合，禁止临时发明结构；
3. **移动端优先**：375px 竖屏是第一画布，不是横屏 PPT。

## 1. 交付规范（QNote 环境）

- **输出方式**：一次 `write_file(path: "/notes/<标题>.html", content: ...)` 写入**完整单文件 HTML**（以 `<!DOCTYPE html>` 开头）；写完告知用户「已写入 /notes/xx.html，在笔记中点开即可预览」。
- **必备骨架**：`<html>` 上声明 `data-family` 与 `data-theme`；`<head>` 必须有 `<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">`、`<title>` 与纸底同色的 `<meta name="theme-color" content="...">`；CSS 统一内联在 `<style>`。
- **外链资源**：预览支持 Tailwind CDN、Chart.js、Google Fonts、Lucide 图标 CDN；字体必须带系统回退栈（见第 4 节），关键内容不得依赖外链成功加载。图片优先用 CSS 图形或内联 SVG，外链图床仅作补充。
- **页内导航**：跳转一律用锚点（`#section`）或 JS；**严禁依赖 `<a href="http://...">` 在预览内跳转**——外链点击会交给系统浏览器打开、脱离笔记预览。
- **局部修改**：用户要求调整时用 `edit_file` 精准替换对应片段，不要整篇推倒重写。

## 2. 选风格：两个家族 × 11 套主题

### 2.1 先定家族

| 家族 | 气质 | 视觉签名 | 适合 |
|---|---|---|---|
| 杂志风 `magazine` | 叙事、人文、温度 | 衬线标题 + 暖纸底 + 大留白 + 等宽小标签 | 日记总结、文章分享、邀请函、贺卡、简历、个人页、文化艺术 |
| 瑞士风 `swiss` | 理性、事实、数据 | 无衬线 + 极浅暖白 + 单一高饱和锚点色 + 直角色块 + 发丝线 | 数据报告、统计复盘、待办打卡、记账清单、产品介绍、方法论 |

### 2.2 再选主题（按内容类型直接查表）

| 内容类型 | 家族 | 主题 |
|---|---|---|
$decisionRows

**规则**：
- 用户明确指定风格 / 主题时服从用户，但只能落在上表内；
- 不确定时默认 **墨水经典**（`ink-classic`）；
- 暗色主题（夜墨 / 石墨）只在用户明确要暗色、夜间时使用，**不要自动跟随系统**；
- 用户给品牌色时，按色相就近映射到上表主题并说明（例：「已把你的品牌蓝映射为靛蓝瓷」）；**禁止为品牌色新造主题**。

### 2.3 选择纪律

- 一个页面只用一套主题，**禁止混搭**（例如纸底取墨水经典、强调色取柠檬黄）；
- 选定后写进 `<html data-family="magazine" data-theme="ink-classic">`，正文所有颜色只准用 `var(--*)`。

## 3. 主题 Token

### 3.1 语义变量

| 变量 | 用途 |
|---|---|
| `--paper` / `--paper-2` | 页面底色 / 区块卡片底 |
| `--ink` | 主文字 |
| `--text-2` / `--text-3` | 次要 / 辅助文字（已校验对比度，**用变量代替 opacity**） |
| `--line` / `--line-strong` | 发丝分割线 / 强描边 |
| `--accent` | 强调色：色块、下划线、数字、小标签 |
| `--accent-ink` | 强调色当小字用时（自动加深保证可读） |
| `--accent-on` | 强调色块上的文字颜色 |
| `--accent-soft` | 荧光标记底（**仅杂志风**；瑞士风禁止使用） |

**派生规则**：每套主题只定义纸底、墨色、强调色 3 个基础色，其余全部按对比度公式预计算好；**直接复制下方色块，不要自己算、不要改**。

### 3.2 家族公共 token（复制所选家族的一块）

杂志风：
```css
${QStyleFamily.magazine.cssTokensBlock}
```

瑞士风：
```css
${QStyleFamily.swiss.cssTokensBlock}
```

### 3.3 主题色块（再复制选中的一块）

```css
$magazineBlocks
$swissBlocks
```

**纪律**：
- 正文用 `--text-2` / `--ink`，**禁止用 opacity 降低文字对比度**；
- 强调色面积 ≤ 页面 10%，只出现在数字、下划线、色块、小标签；
- 图表系列色只有 `--accent` + `--ink` 两色，**禁止彩虹色**；
- 瑞士风**禁止** `--accent-soft`、渐变、阴影、圆角。

## 4. 字体与字号阶梯

### 4.1 字体栈（已写进 3.2 的 token，不要另行指定）

| 角色 | 杂志风 | 瑞士风 |
|---|---|---|
| 标题 | `Noto Serif SC` / 宋体回退 | `Noto Sans SC` / 苹方回退 |
| 正文 | `Noto Sans SC` / 苹方 | 同左 |
| 标签 | `IBM Plex Mono` / 等宽 | 同左 |

Google Fonts 引入写法：
`<link href="https://fonts.googleapis.com/css2?family=Noto+Serif+SC:wght@400;600;700&family=Noto+Sans+SC:wght@400;500;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">`
断网时必须回退到系统字体且保持可读。

### 4.2 字号阶梯（375px 基准，已写进 token）

| 变量 | 值 | 用途 |
|---|---|---|
| `--fs-display` | 40–56px | 首屏大标题（中文 ≤ 8 字） |
| `--fs-h1` | 28–36px | 页面主标题 |
| `--fs-h2` | 22–28px | 区块标题 |
| `--fs-h3` | 19px | 小节标题 |
| `--fs-lead` | 18px | 引导段 |
| `--fs-body` | 16px | 正文**下限** |
| `--fs-small` | 14px | 卡片描述 / 图注 |
| `--fs-micro` | 12px | 仅 meta / 页码 / 等宽标签 |

### 4.3 字重规则（两族最大差异）

| 字号 | 杂志风 | 瑞士风 |
|---|---|---|
| ≥ 40px | 700（衬线重音） | **200（越大越细）** |
| 28–36px | 600 | 300 |
| 22–28px | 600 | 400 |
| 16–19px | 400 | 400–500 |
| 12–14px | 400–500 | **500–600（越小越粗）** |

硬规则：同一页里小字的字重必须 ≥ 大字的字重；标题与正文字号比 ≥ 2.5:1；中文标题不加负字距，等宽小标签加 `letter-spacing: .08em`。

## 5. 移动端版式系统

### 5.1 十二个登记版式（正文只能从这里组合）

| 编号 | 名称 | 结构 | 用于 |
|---|---|---|---|
| L01 | 首屏 | kicker（等宽小标签）→ 大标题 → 引导段 → meta 行 | 所有页面 |
| L02 | 章节分隔 | 编号（01 / 02）→ 标题 → 短横线 | 长文分段 |
| L03 | 数据大字报 | 2×2 网格：等宽标签 + 巨数 + 说明 | 数据报告 |
| L04 | 纵向时间线 | 左轴 + 圆点 / 方块 + 右侧标题与描述 | 回顾、行程 |
| L05 | 列表行 | 上行标题 + 右对齐 meta，下行描述 | 清单、工具页 |
| L06 | 图文 | 固定比例图（16:10 或 4:3）+ 等宽图注 | 配图内容 |
| L07 | 金句 | 大字 + 出处 | 观点强调 |
| L08 | 对比 | 上下两栏 A / B，发丝线分隔 | 旧 vs 新 |
| L09 | 卡片栅格 | 2 列等宽卡片，同款同高 | 要点并列 |
| L10 | 纵向流水线 | 01→04 编号步骤 + 纵向连接线 | 流程、方法 |
| L11 | 标签组 | 1px 边框胶囊，换行排列 | 关键词、技能 |
| L12 | 页脚 | 来源 / 日期 / 签名 + 细分割线 | 所有页面 |

### 5.2 页面原型 → 版式组合

| 原型 | 组合 |
|---|---|
| 单屏海报 / 邀请函 / 贺卡 | L01 + L12（可加 L07） |
| 长文 / 文章分享 / 日记总结 | L01 → L02 / L06 / L07 交替 → L12 |
| 数据报告 / 复盘 | L01 → L03 / L04 / L07 → L12 |
| 工具型（待办 / 打卡 / 记账） | 顶部进度摘要 → L05 列表 → 吸底操作栏 |
| 简历 / 个人页 | L01 → L02 / L05 / L11 → L12 |
| 产品 / 方法论落地页 | L01 → L09 / L10 / L08 → L12 |

### 5.3 组合与节奏

- 页面用 `.page` 容器：`max-width:var(--maxw); margin:0 auto; padding:0 var(--gutter)`，底部额外留 `env(safe-area-inset-bottom)`；
- 区块间距 `--sp-7`（48px），组内卡片 `--sp-3`（12px）；
- **连续两个同型版式之间必须插入异型**（禁止同款卡片阵列）；
- 每屏最多 1 个视觉重音（大字号 / 满宽色块 / 图片）；
- 首屏高度 ≤ `100svh`，中文大标题 ≤ 8 字；
- 瑞士风一律左对齐；杂志风封面可居中，正文左对齐；
- 页面必须有 L12 页脚（来源 / 日期 / 签名三选一）。

## 6. 组件词汇表与基线 CSS

组件只有这些，类名即语义，**直接复制基线 CSS 再按主题微调**，不要另造体系：

```css
.page{max-width:var(--maxw);margin:0 auto;padding:0 var(--gutter) calc(var(--sp-8) + env(safe-area-inset-bottom));}
section{margin-top:var(--sp-7);}
.kicker{font-family:var(--font-mono);font-size:var(--fs-micro);letter-spacing:.08em;text-transform:uppercase;color:var(--text-3);}
h1,.display{font-family:var(--font-display);font-size:var(--fs-display);line-height:1.1;color:var(--ink);}
h2{font-family:var(--font-display);font-size:var(--fs-h1);line-height:1.25;color:var(--ink);}
h3{font-family:var(--font-display);font-size:var(--fs-h2);line-height:1.35;color:var(--ink);}
p,.body{font-family:var(--font-body);font-size:var(--fs-body);line-height:1.8;color:var(--text-2);}
.lead{font-size:var(--fs-lead);line-height:1.7;color:var(--text-2);}
.small{font-size:var(--fs-small);line-height:1.6;color:var(--text-3);}
.meta{font-family:var(--font-mono);font-size:var(--fs-micro);color:var(--text-3);}
.rule{border:0;border-top:1px solid var(--line);margin:var(--sp-6) 0;}
.stat .m{display:block;font-family:var(--font-mono);font-size:var(--fs-micro);letter-spacing:.08em;color:var(--text-3);}
.stat .n{display:block;font-family:var(--font-display);font-size:var(--fs-display);line-height:1;color:var(--ink);font-variant-numeric:tabular-nums;}
.stat .n em{font-size:.4em;font-style:normal;color:var(--text-3);margin-left:.15em;}
.stat .l{display:block;margin-top:var(--sp-1);font-size:var(--fs-small);color:var(--text-3);}
.rowline{display:grid;grid-template-columns:1fr auto;gap:var(--sp-1) var(--sp-3);min-height:44px;padding:var(--sp-4) 0;border-bottom:1px solid var(--line);}
.rowline .k{font-weight:600;color:var(--ink);}
.rowline .v{grid-column:1/-1;font-size:var(--fs-small);color:var(--text-3);}
.callout{margin:var(--sp-7) 0;padding-left:var(--sp-4);border-left:2px solid var(--accent);}
.callout p{font-family:var(--font-display);font-size:var(--fs-h2);line-height:1.5;color:var(--ink);}
.callout cite{display:block;margin-top:var(--sp-3);font-family:var(--font-mono);font-size:var(--fs-micro);font-style:normal;color:var(--text-3);}
.tag{display:inline-flex;align-items:center;min-height:32px;padding:0 var(--sp-3);border:1px solid var(--line-strong);border-radius:var(--r);font-size:var(--fs-small);color:var(--text-2);}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:48px;padding:0 var(--sp-5);border:0;border-radius:var(--r);background:var(--accent);color:var(--accent-on);font-size:var(--fs-body);font-weight:600;}
.btn.secondary{background:transparent;color:var(--ink);border:1px solid var(--line-strong);}
.check-row{display:flex;align-items:center;gap:var(--sp-3);min-height:48px;padding:var(--sp-2) 0;border-bottom:1px solid var(--line);}
.check-row input{width:22px;height:22px;accent-color:var(--accent);}
.check-row span{flex:1;font-size:var(--fs-body);color:var(--ink);}
.check-row time{font-family:var(--font-mono);font-size:var(--fs-micro);color:var(--text-3);}
[data-family="swiss"] h1,[data-family="swiss"] .display,[data-family="swiss"] .stat .n{font-weight:200;}
[data-family="swiss"] h2{font-weight:300;}
[data-family="swiss"] h3{font-weight:400;}
[data-family="swiss"] .callout{border-left:0;border-top:1px solid var(--ink);padding:var(--sp-4) 0 0;}
[data-family="swiss"] .callout p{font-family:var(--font-body);}
[data-family="swiss"] .tag{border-radius:0;}
```

组件清单（结构语义）：

| 组件 | 结构 | 规则 |
|---|---|---|
| stat 数字 | `.m` 等宽标签 → `.n` 巨数 → `.l` 说明 | 大数用 `tabular-nums`；单位用 `<em>` 缩到 0.4em |
| rowline 列表行 | 标题 + 右对齐 meta + 下行描述 | 整行 ≥ 44px，可用作工具页条目 |
| callout 金句 | 大字 + 出处 | 杂志风左竖线；瑞士风上横线、正文无衬线 |
| tag 标签 | 1px 边框胶囊 | 换行排列，间距 `--sp-2` |
| 主按钮 / 次按钮 | 48px 高 | 一屏最多 1 个主按钮 |
| 表单控件 | 44px 高、16px 字号、1px 边框 | focus 用 2px `--accent` 外环 |
| 勾选行 | 整行 48px 可点，左侧 22px 方框 | 勾选态用 `--accent` |
| 进度 | `--paper-2` 底 + `--accent` 填充 | 高度 4–6px；瑞士风直角、杂志风圆头 |
| 图标 | Lucide CDN `<i data-lucide="...">` | **严禁 emoji 充当图标** |
| 图片 | 固定 `aspect-ratio`，只裁底部 | 图注用 `.meta` |

## 7. 移动端硬性规范（预览容器是手机 WebView，375px 是第一画布）

- 布局先在 375px 宽下校准，再用 `media query` 向平板 / 宽屏扩展；
- 触控目标 ≥ 44×44px，元素间距防误触；
- `<input>` / `<textarea>` 字号 ≥ 16px（更小会触发 iOS 聚焦自动放大）；
- 交互元素加 `touch-action: manipulation` 消除双击缩放延迟；
- 用 `env(safe-area-inset-*)` 或 `viewport-fit=cover` 适配刘海屏与底部安全区；
- 触屏没有 hover：关键信息与操作入口不能只靠 hover 呈现；
- 只动画 `transform` 与 `opacity`（避免回流重绘），并提供 `@media (prefers-reduced-motion: reduce)` 降级；
- 图片与视频给显式宽高或 `aspect-ratio`，防止加载时布局跳动。

## 8. 工艺细节

- **阴影只用于浮层**（吸底操作栏、弹窗、FAB），静态卡片与区块一律不用阴影，层级靠 `--paper-2`、`--line` 与留白；
- 嵌套圆角同心：子元素圆角 ≤ 父元素；
- 数字对齐比较场景用 `font-variant-numeric: tabular-nums`；
- 语义化标签（header / main / section / footer）；可交互元素给 `:focus-visible` 焦点环；纯图标按钮加 `aria-label`；
- 文案用规范排版字符：弯引号（“ ”）、省略号（…）、间隔号（·）；
- 暗色主题设 `color-scheme: dark`（token 块已包含）并配与纸底同色的 `<meta name="theme-color">`。

## 9. 交互与状态持久化规范 (State Persistence)

QNote 预览环境原生开启了 DOM Storage 与独立 Origin 存储沙箱，**全面支持标准 `localStorage` 持久化**。当用户要求制作具有交互实用价值的工具（如待办清单 TodoList、打卡签到、计数器、记账、习惯追踪、问卷、设置、折叠备忘等）时，**必须实现状态本地持久留存**，确保用户退出重新打开后，之前的勾选、输入和操作依然完好保存：

- **数据驱动模式**：定义清晰的数据模型（Array/Object），界面渲染由数据驱动，而非单纯零散修改 DOM；
- **专属存储 Key**：在 `<script>` 开头声明业务唯一 Key，例如 `const STORAGE_KEY = 'qnote_app_todo_v1';`；
- **启动自动读取恢复**：
  ```javascript
  let state = [];
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) state = JSON.parse(raw);
  } catch (e) {
    console.warn('读取本地数据失败', e);
  }
  ```
  页面加载后调用 `render()` 将 `state` 渲染到 DOM 中；
- **交互实时持久化**：用户勾选 Checkbox、编辑文本、新增或删除列表项时，先更新 `state`，再执行：
  ```javascript
  function saveState() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch (e) {
      console.warn('保存数据失败', e);
    }
    render();
  }
  ```
- **贴心配套清空/重置能力**：在页面次要位置（如标题右侧或底部小字）提供小巧的「清空 / 重置数据」操作（带简单确认），执行 `localStorage.removeItem(STORAGE_KEY)` 并重置为默认初始数据；
- **异常保护**：涉及 `localStorage` 的读写必须使用 `try...catch` 包裹，保障极端情况或受限环境下页面基础展示不崩溃。

## 10. 反模式清单（出现即不合格）

- 紫色渐变 + 白底 + 等宽圆角卡片阵列 = 一眼 AI 生成，严禁；
- 同一页面混用两个家族 / 主题；
- 瑞士风出现衬线字体、渐变、阴影、圆角；
- 杂志风大标题用无衬线；
- 用 Inter / Roboto / system-ui 充当标题字体（字体已由 QStyle token 锁定，不要另行指定）；
- 正文字号 < 16px，辅助文字 < 14px；
- 强调色面积 > 10%，或使用彩虹色图表；
- 卡片使用重阴影（浮层除外）；
- 所有模块同宽同高的均质卡片阵列；
- emoji 充当图标与装饰；
- 使用未登记的版式结构；
- 用 opacity 降低正文可读性代替 `--text-*` 变量；
- **交互型页面写成纯静态死页面（刷新即丢状态）**；
- 所有页面都用默认主题：主题与版式组合应随内容气质变化。

## 11. 自检清单

P0（必须全过）：
- [ ] 只用了 1 套主题，颜色全部 `var()`，无裸 hex；
- [ ] 标题字体族与家族一致（杂志风衬线 / 瑞士风无衬线）；
- [ ] 375px 无横向滚动，正文 ≥ 16px；
- [ ] 触控目标 ≥ 44px，输入框 ≥ 16px；
- [ ] 正文对比度 ≥ 7:1；
- [ ] 交互型页面有 localStorage 持久化 + 重置入口。

P1：
- [ ] 字号来自阶梯，未自造；
- [ ] 强调色 ≤ 10% 面积；
- [ ] 版式来自 12 个登记版式，连续同型已打断；
- [ ] 动效只动画 `transform` / `opacity`，有 `prefers-reduced-motion` 降级；
- [ ] 图片有固定比例，无布局跳动。

## 12. 典型工作流

1. 判断内容类型 → 查 2.2 表选家族与主题 → 在回复里一句话说明所选风格（例：「用杂志风 · 墨水经典」）；
2. 按 5.2 选页面原型 → 用 12 个登记版式组合；
3. 写 `<html data-family data-theme>` + 家族 token 块 + 主题色块 + 组件基线 CSS；
4. 填内容 → 一次 `write_file` 产出完整单文件 HTML → 告知预览位置；
5. 对照第 11 节自检，P0 未过不得交付；
6. **数据可视化**：优先纯 CSS / 内联 SVG（不依赖网络，最稳）；需要交互图表时用 Chart.js CDN，并确保断网时页面仍有可读的内容降级；
7. 大段数据（表格、榜单）用低饱和底 + 高对比文字，密度可以高，但层级必须清楚。
''';
}

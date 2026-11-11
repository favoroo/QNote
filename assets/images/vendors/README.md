# 厂商图标

`*.svg` 为各 AI 厂商的品牌标识，取自 [lobehub/icons](https://github.com/lobehub/icons)（MIT），
经 [magpie](https://github.com/) 的 `internal/gui/assets/icons/` 转存，文件名即
`lib/config/ai_vendors.dart` 中 `AiProviderConfig.icon` 的取值（不含扩展名）。

渲染规则见 `lib/widgets/ai/vendor_logo.dart`：

- 文件名以 `-color` 结尾 → 彩色原图直接渲染；
- 其余为单色图（SVG 根节点是 `fill="currentColor"`）→ 按主题 `onSurfaceVariant` 着色，
  否则在深色模式下会变成不可见的黑色；这份名单由
  `test/widgets/ai/vendor_logo_test.dart` 对照文件内容校验，新增图标时不会漏配。
- 没有官方图标的厂商（`icon` 为空）不做占位图，界面回落到名称首字母色块。

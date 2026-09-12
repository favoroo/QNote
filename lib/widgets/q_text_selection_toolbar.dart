import 'package:flutter/material.dart';

/// 平铺式文本选择工具栏：全部菜单项直接可见，宽度不足时自动换行。
///
/// Material 默认的 [TextSelectionToolbar] 在宽度放不下时会把后面的菜单项折叠
/// 进 ⋮ 溢出菜单，导致追加在末尾的自定义项（如「给小Q」）被隐藏。本组件复刻
/// 其外观（胶囊容器 + [TextSelectionToolbarTextButton]），但用 [Wrap] 平铺，
/// 任何菜单项都始终直接可见，也不再出现 ⋮。
///
/// 定位复用 SDK 公开的 [TextSelectionToolbarLayoutDelegate]：不传 `fitsAbove`，
/// delegate 会按工具栏实际高度（单行/换行后）自动判断放在选区上方还是下方。
class QTextSelectionToolbar extends StatelessWidget {
  const QTextSelectionToolbar({
    super.key,
    required this.anchors,
    required this.buttonItems,
  });

  /// 选区锚点，通常取 `editableTextState.contextMenuAnchors`
  final TextSelectionToolbarAnchors anchors;

  /// 菜单项（默认项 + 「给小Q」等自定义项）
  final List<ContextMenuButtonItem> buttonItems;

  // 与 SDK TextSelectionToolbar 一致的间距常量（工具栏与选区/屏幕边缘的距离）
  static const double _kToolbarContentDistance = 8.0;
  static const double _kToolbarScreenPadding = 8.0;

  /// 系统默认菜单项（剪切/复制/粘贴/分享/全选等）。
  ///
  /// Android 会把其他应用注册的"文本处理"（PROCESS_TEXT）动作以
  /// [ContextMenuButtonType.custom] 类型并入
  /// [EditableTextState.contextMenuButtonItems]（如欧路词典、Edge、Kimi 等），
  /// 平铺后菜单极为拥挤；调用方追加的自定义项（如「给小Q」）不经过这里，
  /// 不受影响
  static List<ContextMenuButtonItem> defaultButtonItems(
    EditableTextState editableTextState,
  ) {
    return editableTextState.contextMenuButtonItems
        .where((item) => item.type != ContextMenuButtonType.custom)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    // 与 SDK TextSelectionToolbar 相同的锚点换算：上下各留出与选区的间距
    final Offset anchorAbove =
        anchors.primaryAnchor - const Offset(0.0, _kToolbarContentDistance);
    final Offset anchorBelow = anchors.primaryAnchor +
        const Offset(0.0, TextSelectionToolbar.kToolbarContentDistanceBelow);
    final double paddingAbove =
        MediaQuery.paddingOf(context).top + _kToolbarScreenPadding;
    // 抵消外层 Padding 的偏移，把锚点换算到布局坐标系内
    final Offset localAdjustment =
        Offset(_kToolbarScreenPadding, paddingAbove);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _kToolbarScreenPadding,
        paddingAbove,
        _kToolbarScreenPadding,
        _kToolbarScreenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: anchorAbove - localAdjustment,
          anchorBelow: anchorBelow - localAdjustment,
        ),
        child: Material(
          type: MaterialType.card,
          color: Theme.of(context).colorScheme.surface,
          elevation: 1.0,
          // 复刻 SDK 胶囊圆角（44/2）；换行后为圆角矩形，观感一致
          borderRadius: const BorderRadius.all(
            Radius.circular(TextSelectionToolbar.kHandleSize),
          ),
          clipBehavior: Clip.antiAlias,
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (int i = 0; i < buttonItems.length; i++)
                _buildButton(context, i),
            ],
          ),
        ),
      ),
    );
  }

  /// 按位置生成同款内边距的菜单按钮；自定义项（如「给小Q」）用主题色高亮
  Widget _buildButton(BuildContext context, int index) {
    final item = buttonItems[index];
    final isCustom = item.type == ContextMenuButtonType.custom;
    return TextSelectionToolbarTextButton(
      padding: TextSelectionToolbarTextButton.getPadding(
        index,
        buttonItems.length,
      ),
      onPressed: item.onPressed,
      child: Text(
        item.label ?? AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
        style: isCustom
            ? TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
    );
  }
}

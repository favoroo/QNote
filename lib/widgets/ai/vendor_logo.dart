import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:qnote_flutter/config/ai_vendors.dart';

/// 厂商图标文件名中「单色图」的名单（取自各 SVG 根节点的 `fill="currentColor"`）
///
/// 单色图必须按主题色着色：它们的路径是 `currentColor`，原样渲染在深色模式下
/// 会变成看不见的黑色。名单与 `assets/images/vendors/` 里的文件内容强绑定，
/// 由 `test/widgets/ai/vendor_logo_test.dart` 对照校验，漏配会直接让测试失败。
const Set<String> monochromeVendorIcons = {
  'cerebras',
  'chutes',
  'cline',
  'commandcode',
  'groq',
  'kilo',
  'kimi',
  'longcat',
  'mimocode',
  'ollama',
  'openai',
  'opencode',
  'openrouter',
  'xai',
  'zai',
};

/// 厂商图标资源路径；无图标声明时返回 null
String? vendorIconAsset(String? vendorId) {
  if (vendorId == null || vendorId.isEmpty) return null;
  final icon = getProviderById(vendorId)?.icon ?? '';
  if (icon.isEmpty) return null;
  return 'assets/images/vendors/$icon.svg';
}

/// 厂商图标：统一渲染圆角方块里的品牌标识
///
/// 之所以统一自带背景块：各家 logo 的留白与描边差异很大，直接贴在卡片上会显得
/// 歪斜，套一层同尺寸浅色方块后，列表卡片与选择器网格里的图标才能对齐。
/// 没有官方图标的厂商（蚂蚁百灵、小浣熊等）不造假图标，回落到名称首字母。
class VendorLogo extends StatelessWidget {
  /// 厂商模板 id（`AiProvider.custom` 或未知 id 会走首字母兜底）
  final String? vendorId;

  /// 兜底首字母的来源；不传时用厂商模板名
  final String? fallbackLabel;

  final double size;

  /// 条目被停用时置灰，传递「不参与选路」的状态
  final bool disabled;

  const VendorLogo({super.key, required this.vendorId, this.fallbackLabel, this.size = 38, this.disabled = false});

  /// 停用态降低饱和度的灰度矩阵
  static const ColorFilter _grayscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final asset = vendorIconAsset(vendorId);
    final icon = asset == null ? '' : asset.split('/').last.replaceAll('.svg', '');
    final monochrome = monochromeVendorIcons.contains(icon);

    final Widget content;
    if (asset == null) {
      content = _letterFallback(colorScheme);
    } else {
      content = Center(
        child: SvgPicture.asset(
          asset,
          width: size * 0.62,
          height: size * 0.62,
          fit: BoxFit.contain,
          // 单色图按主题着色；彩色图保留原色，不加滤镜
          colorFilter: monochrome ? ColorFilter.mode(colorScheme.onSurfaceVariant, BlendMode.srcIn) : null,
          // 资源缺失时不留空白方块：兜底成首字母，界面仍然可读
          placeholderBuilder: (_) => _letterFallback(colorScheme),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // 首字母兜底自带主色底，图标态用中性底，两种情况下方块都不空
        color: asset == null
            ? colorScheme.primary.withValues(alpha: 0.1)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: disabled
          ? Opacity(
              opacity: 0.5,
              child: ColorFiltered(colorFilter: _grayscale, child: content),
            )
          : content,
    );
  }

  Widget _letterFallback(ColorScheme colorScheme) {
    final label = (fallbackLabel ?? getProviderById(vendorId ?? '')?.name ?? '').trim();
    final letter = label.isEmpty ? '?' : label.substring(0, 1).toUpperCase();
    return Center(
      child: Text(
        letter,
        style: TextStyle(fontSize: size * 0.44, fontWeight: FontWeight.w600, color: colorScheme.primary, height: 1),
      ),
    );
  }
}

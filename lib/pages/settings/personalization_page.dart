import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:qnote_flutter/core/theme/app_color_schemes.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

class PersonalizationPage extends ConsumerWidget {
  const PersonalizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accentColor = ref.watch(accentColorProvider);
    final background = ref.watch(backgroundSettingProvider);
    final savedScheme = ref.watch(savedColorSchemeProvider);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('个性化设置'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('推荐搭配', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  // 背景与主题色成对推荐，点一下同时应用；下方保留细调入口，
                  // 应用后整页即时换色，用户不需要先「预览」再确认。
                  // 最后多留一格「我的搭配」，把当前组合存成可复用预设
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 110,
                      mainAxisExtent: 90,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 6,
                    ),
                    itemCount: recommendedColorSchemes.length + 1,
                    itemBuilder: (context, index) {
                      if (index == recommendedColorSchemes.length) {
                        return _SavedSchemeSwatch(
                          savedScheme: savedScheme,
                          background: background,
                          accentColor: accentColor,
                          platformBrightness: platformBrightness,
                          onSaveCurrent: () => _onSaveCurrentScheme(context, ref),
                          onApply: savedScheme == null ? () {} : () => _onSchemeTap(ref, savedScheme),
                          onManage: () => _onSavedSchemeManage(context, ref),
                        );
                      }
                      final scheme = recommendedColorSchemes[index];
                      return _ColorSchemeSwatch(
                        scheme: scheme,
                        platformBrightness: platformBrightness,
                        isSelected: scheme.matches(background: background, accentColor: accentColor),
                        onTap: () => _onSchemeTap(ref, scheme),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '点一下同时应用；第 9 个可保存当前搭配，保存后点击套用、点角标可覆盖或删除。',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  Text('背景', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  // 背景取代了原来的浅色/深色开关：选中哪个预设，整页明暗就由它推导
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.35,
                    children: AppBackgroundPreset.values.map((preset) {
                      return _BackgroundPresetTile(
                        preset: preset,
                        accentColor: accentColor,
                        customColor: background.customColor,
                        platformBrightness: platformBrightness,
                        isSelected: background.preset == preset,
                        onTap: () => _onPresetTap(context, ref, preset),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '文字与图标会按背景自动选深浅色；主题色背景会自动微调，避免和按钮融在一起。',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  Text('主题色', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  // 4 列固定网格：8 个预设色呈规整两行，任何屏宽下都对齐
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    children: presetAccentColors.map((color) {
                      final isSelected = color.toARGB32() == accentColor.toARGB32();
                      return Center(
                        child: GestureDetector(
                          onTap: () => ref.read(accentColorProvider.notifier).setAccentColor(color),
                          // 外环用色块自身颜色，选荧光色时也能与圆点明确区分
                          child: AnimatedContainer(
                            duration: AppMotion.duration(context, AppDurations.fast),
                            curve: AppCurves.standard,
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: isSelected
                                  ? Border.all(color: color, width: 2)
                                  : Border.all(color: Colors.transparent, width: 2),
                            ),
                            padding: EdgeInsets.all(isSelected ? 4 : 2),
                            child: AnimatedContainer(
                              duration: AppMotion.duration(context, AppDurations.fast),
                              curve: AppCurves.standard,
                              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                              // 选中时对勾缩放淡入，选中态更直观；对勾颜色按色块亮度自适应，
                              // 否则荧光黄绿等浅色块上的白勾几乎看不见
                              child: AnimatedScale(
                                scale: isSelected ? 1.0 : 0.0,
                                duration: AppMotion.duration(context, AppDurations.fast),
                                curve: AppCurves.standard,
                                child: Icon(Icons.check_rounded, size: 20, color: AppContrast.onColor(color)),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  // 预设之外另开一整行「自定义」入口：交互是打开拾色器（非直接选中），
                  // 单独一行才能展示当前自选色与十六进制值，比塞成第 9 个色块更清楚
                  _CustomAccentTile(
                    customColor: accentColor,
                    isSelected: !presetAccentColors.any((c) => c.toARGB32() == accentColor.toARGB32()),
                    onTap: () => _onCustomAccentTap(context, ref),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 120),
            Container(
              width: double.infinity,
              height: 54,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    ref.read(backgroundSettingProvider.notifier).reset();
                    ref.read(accentColorProvider.notifier).setAccentColor(const Color(0xFF005BCB));
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.refresh, size: 20, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Text(
                        '恢复默认设置',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onPresetTap(BuildContext context, WidgetRef ref, AppBackgroundPreset preset) async {
    if (preset != AppBackgroundPreset.custom) {
      await ref.read(backgroundSettingProvider.notifier).setPreset(preset);
      return;
    }
    final current = ref.read(backgroundSettingProvider);
    final picked = await showDialog<Color>(
      context: context,
      builder: (context) =>
          _BackgroundColorPickerDialog(initialColor: current.customColor, accentColor: ref.read(accentColorProvider)),
    );
    if (picked != null) {
      await ref.read(backgroundSettingProvider.notifier).setCustomColor(picked);
    }
  }

  Future<void> _onSchemeTap(WidgetRef ref, AppColorSchemePreset scheme) async {
    final current = ref.read(backgroundSettingProvider);
    await ref
        .read(backgroundSettingProvider.notifier)
        .applyScheme(scheme.resolveBackground(current), scheme.accentColor);
  }

  /// 把当前背景与主题色存进第 9 个槽位。
  Future<void> _onSaveCurrentScheme(BuildContext context, WidgetRef ref) async {
    await ref
        .read(savedColorSchemeProvider.notifier)
        .save(ref.read(backgroundSettingProvider), ref.read(accentColorProvider));
    if (context.mounted) {
      Toast.success(context, '已保存当前搭配');
    }
  }

  /// 「我的搭配」角标菜单：覆盖或删除已保存的搭配。
  Future<void> _onSavedSchemeManage(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<_SavedSchemeAction>(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bookmark_add_rounded),
              title: const Text('用当前搭配覆盖'),
              onTap: () => Navigator.pop(sheetContext, _SavedSchemeAction.overwrite),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除我的搭配'),
              onTap: () => Navigator.pop(sheetContext, _SavedSchemeAction.delete),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) {
      return;
    }
    if (action == _SavedSchemeAction.overwrite) {
      await _onSaveCurrentScheme(context, ref);
      return;
    }
    await ref.read(savedColorSchemeProvider.notifier).clear();
    if (context.mounted) {
      Toast.info(context, '已删除「我的搭配」');
    }
  }

  Future<void> _onCustomAccentTap(BuildContext context, WidgetRef ref) async {
    final current = ref.read(accentColorProvider);
    final picked = await showDialog<Color>(
      context: context,
      builder: (context) => _AccentColorPickerDialog(initialColor: current),
    );
    if (picked != null) {
      await ref.read(accentColorProvider.notifier).setAccentColor(picked);
    }
  }
}

/// 「我的搭配」角标菜单的两种操作。
enum _SavedSchemeAction { overwrite, delete }

/// 把颜色格式化成 `#RRGGBB`（丢弃 alpha），用于自定义色值文案。
String _hexLabel(Color color) => '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// 搭配预览：画布 + 表面卡片 + 主题色圆点。
///
/// 把背景与主题色的组合画在同一块里，选之前就能看出搭配效果；
/// 选中用画布反色描边和主题色对勾角标表达，任何底色下都清晰。
class _SchemePreview extends StatelessWidget {
  const _SchemePreview({required this.scheme, required this.platformBrightness, required this.isSelected});

  final AppColorSchemePreset scheme;
  final Brightness platformBrightness;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = scheme.background.resolvePalette(
      accentColor: scheme.accentColor,
      platformBrightness: platformBrightness,
    );
    // 选中描边取画布反色：纯黑画布上是白圈、纸色画布上是深色圈，
    // 不受主题色影响，也不会和色块自身融在一起
    final ringColor = AppContrast.onColor(palette.canvas);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: AppMotion.duration(context, AppDurations.fast),
          curve: AppCurves.standard,
          width: 58,
          height: 58,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: palette.canvas,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: isSelected ? ringColor : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: palette.outlineVariant, width: 0.6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 18,
                        height: 2.5,
                        decoration: BoxDecoration(color: palette.onSurface, borderRadius: BorderRadius.circular(2)),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        width: 11,
                        height: 2,
                        decoration: BoxDecoration(
                          color: palette.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: scheme.accentColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Container(
                      height: 2.5,
                      decoration: BoxDecoration(color: palette.outlineVariant, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (isSelected)
          Positioned(
            right: -3,
            top: -3,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: scheme.accentColor,
                shape: BoxShape.circle,
                // 角标外圈用画布色，深色方案下也能和背景分开
                border: Border.all(color: palette.canvas, width: 1.5),
              ),
              child: Icon(Icons.check_rounded, size: 11, color: AppContrast.onColor(scheme.accentColor)),
            ),
          ),
      ],
    );
  }
}

/// 搭配名称：选中时加深加粗，窄格子里超长省略。
class _SchemeLabel extends StatelessWidget {
  const _SchemeLabel({required this.text, required this.isSelected});

  final String text;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }
}

/// 内置推荐组合的格子：预览 + 名称，点一下同时套用背景与主题色。
class _ColorSchemeSwatch extends StatelessWidget {
  const _ColorSchemeSwatch({
    required this.scheme,
    required this.platformBrightness,
    required this.isSelected,
    required this.onTap,
  });

  final AppColorSchemePreset scheme;
  final Brightness platformBrightness;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SchemePreview(scheme: scheme, platformBrightness: platformBrightness, isSelected: isSelected),
            const SizedBox(height: 6),
            _SchemeLabel(text: scheme.name, isSelected: isSelected),
          ],
        ),
      ),
    );
  }
}

/// 第 9 个槽位：把当前背景 + 主题色存成「我的搭配」。
///
/// 空槽位点一下直接保存当前搭配；保存后点击套用，右下角「⋯」可覆盖或删除。
class _SavedSchemeSwatch extends StatelessWidget {
  const _SavedSchemeSwatch({
    required this.savedScheme,
    required this.background,
    required this.accentColor,
    required this.platformBrightness,
    required this.onSaveCurrent,
    required this.onApply,
    required this.onManage,
  });

  final AppColorSchemePreset? savedScheme;
  final AppBackgroundSetting background;
  final Color accentColor;
  final Brightness platformBrightness;
  final VoidCallback onSaveCurrent;
  final VoidCallback onApply;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = savedScheme;

    if (scheme == null) {
      return Semantics(
        button: true,
        child: InkWell(
          onTap: onSaveCurrent,
          borderRadius: BorderRadius.circular(17),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Icon(Icons.bookmark_add_rounded, size: 22, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              const _SchemeLabel(text: '保存当前', isSelected: false),
            ],
          ),
        ),
      );
    }

    final isSelected = scheme.matches(background: background, accentColor: accentColor);
    final palette = scheme.background.resolvePalette(
      accentColor: scheme.accentColor,
      platformBrightness: platformBrightness,
    );

    return Semantics(
      button: true,
      selected: isSelected,
      child: InkWell(
        onTap: onApply,
        borderRadius: BorderRadius.circular(17),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _SchemePreview(scheme: scheme, platformBrightness: platformBrightness, isSelected: isSelected),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: _SavedSchemeMenuButton(palette: palette, onTap: onManage),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _SchemeLabel(text: savedColorSchemeName, isSelected: isSelected),
          ],
        ),
      ),
    );
  }
}

/// 「我的搭配」右下角的角标按钮：打开覆盖 / 删除菜单。
class _SavedSchemeMenuButton extends StatelessWidget {
  const _SavedSchemeMenuButton({required this.palette, required this.onTap});

  final AppSurfacePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '覆盖或删除我的搭配',
      child: Material(
        color: palette.surface,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: palette.outlineVariant),
            ),
            child: Icon(Icons.more_horiz_rounded, size: 14, color: palette.onSurface),
          ),
        ),
      ),
    );
  }
}

/// 「自定义主题色」入口行。
///
/// 未选中时用彩虹圆环 + 调色图标提示「可任选颜色」，与预设纯色块区分；
/// 选中时展示当前自选色与其十六进制值，让用户随时知道生效的具体颜色。
class _CustomAccentTile extends StatelessWidget {
  const _CustomAccentTile({required this.customColor, required this.isSelected, required this.onTap});

  /// 当前生效的主题色，仅在 [isSelected] 为真时作为自选色展示。
  final Color customColor;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 背景画在外层、Material/InkWell 放里面（与底部「恢复默认设置」同构），
    // 否则不透明底色会盖住点击水波纹
    return AnimatedContainer(
      duration: AppMotion.duration(context, AppDurations.fast),
      curve: AppCurves.standard,
      height: 60,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected ? customColor : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                _leading(theme),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '自定义颜色',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isSelected ? _hexLabel(customColor) : '选择任意颜色',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isSelected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
                  size: isSelected ? 20 : 22,
                  color: isSelected ? customColor : theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading(ThemeData theme) {
    if (isSelected) {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: customColor, shape: BoxShape.circle),
        child: Icon(Icons.check_rounded, size: 18, color: AppContrast.onColor(customColor)),
      );
    }
    // 未选中：彩虹环包一层表面色内圈，既暗示「任选颜色」又保证调色图标清晰可读
    return Container(
      width: 34,
      height: 34,
      padding: const EdgeInsets.all(2.5),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(
          colors: [
            Color(0xFFFF3B30),
            Color(0xFFFF9500),
            Color(0xFFFFCC00),
            Color(0xFF00E676),
            Color(0xFF00BCD4),
            Color(0xFF005BCB),
            Color(0xFF7C4DFF),
            Color(0xFFE91E8C),
            Color(0xFFFF3B30),
          ],
        ),
      ),
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.surface),
        child: Icon(Icons.colorize_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 自定义主题色拾色对话框。
///
/// 主题色会应用到按钮、开关、选中项等大量控件，即使选到极亮或极暗色也要可读；
/// 顶部预览用与真实主题一致的 [AppContrast.onColor] 给示例文字选深浅，先看效果再应用。
class _AccentColorPickerDialog extends StatefulWidget {
  const _AccentColorPickerDialog({required this.initialColor});

  final Color initialColor;

  @override
  State<_AccentColorPickerDialog> createState() => _AccentColorPickerDialogState();
}

class _AccentColorPickerDialogState extends State<_AccentColorPickerDialog> {
  late Color _color;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('自定义主题色'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '主题色预览',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(color: _color, borderRadius: BorderRadius.circular(8)),
                                child: Text(
                                  '按钮',
                                  style: TextStyle(
                                    color: AppContrast.onColor(_color),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _hexLabel(_color),
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ColorPicker(
                pickerColor: _color,
                onColorChanged: (color) => setState(() => _color = color),
                enableAlpha: false,
                labelTypes: const [],
                hexInputBar: true,
                paletteType: PaletteType.hsvWithHue,
                pickerAreaHeightPercent: 0.7,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _color), child: const Text('应用')),
      ],
    );
  }
}

/// 单张背景预设卡：用真实的画布/表面/文字色画一个迷你界面，选之前就能看到效果。
class _BackgroundPresetTile extends StatelessWidget {
  const _BackgroundPresetTile({
    required this.preset,
    required this.accentColor,
    required this.customColor,
    required this.platformBrightness,
    required this.isSelected,
    required this.onTap,
  });

  final AppBackgroundPreset preset;
  final Color accentColor;
  final Color customColor;
  final Brightness platformBrightness;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final setting = AppBackgroundSetting(preset: preset, customColor: customColor);
    final palette = setting.resolvePalette(accentColor: accentColor, platformBrightness: platformBrightness);
    // 预览圆点直接展示用户所选的主题色，与主题里按钮/FAB 使用的 primary 保持一致
    final primary = accentColor;
    final borderColor = isSelected ? AppContrast.onColor(palette.canvas) : palette.outlineVariant;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppDurations.fast),
        curve: AppCurves.standard,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.canvas,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.outlineVariant, width: 0.8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 34,
                      height: 4,
                      decoration: BoxDecoration(color: palette.onSurface, borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 24,
                      height: 3,
                      decoration: BoxDecoration(
                        color: palette.onSurfaceVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Container(
                            height: 3,
                            decoration: BoxDecoration(
                              color: palette.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _labelOf(preset),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.onSurface,
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (preset == AppBackgroundPreset.system)
                  Icon(Icons.brightness_auto_rounded, size: 14, color: palette.onSurfaceVariant),
                if (preset == AppBackgroundPreset.custom)
                  Icon(Icons.tune_rounded, size: 14, color: palette.onSurfaceVariant),
                if (isSelected) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.check_circle_rounded, size: 15, color: palette.onSurface),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _labelOf(AppBackgroundPreset preset) {
    switch (preset) {
      case AppBackgroundPreset.system:
        return '跟随系统';
      case AppBackgroundPreset.light:
        return '浅色';
      case AppBackgroundPreset.dark:
        return '深色';
      case AppBackgroundPreset.oled:
        return 'OLED 纯黑';
      case AppBackgroundPreset.accent:
        return '主题色';
      case AppBackgroundPreset.custom:
        return '自定义';
    }
  }
}

/// 自定义背景拾色对话框。
///
/// 顶部先展示「实际生效」的迷你界面，并在颜色被微调时明确提示，
/// 避免用户觉得自己选的颜色被悄悄改掉。
class _BackgroundColorPickerDialog extends StatefulWidget {
  const _BackgroundColorPickerDialog({required this.initialColor, required this.accentColor});

  final Color initialColor;
  final Color accentColor;

  @override
  State<_BackgroundColorPickerDialog> createState() => _BackgroundColorPickerDialogState();
}

class _BackgroundColorPickerDialogState extends State<_BackgroundColorPickerDialog> {
  late Color _color;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appliedColor = ensureAccentGap(_color, widget.accentColor);
    final palette = AppSurfacePalette.derived(appliedColor);
    final adjusted = appliedColor.toARGB32() != _color.toARGB32();

    return AlertDialog(
      title: const Text('自定义背景色'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 104,
                decoration: BoxDecoration(
                  color: palette.canvas,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.outlineVariant),
                ),
                padding: const EdgeInsets.all(12),
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.outlineVariant, width: 0.8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '实际背景预览',
                        style: TextStyle(color: palette.onSurface, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text('次级文字会自动选深浅色', style: TextStyle(color: palette.onSurfaceVariant, fontSize: 11)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: widget.accentColor, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Container(
                              height: 4,
                              decoration: BoxDecoration(
                                color: palette.outlineVariant,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (adjusted) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.auto_fix_high_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '所选颜色与主题色过近，已自动微调以保持区分。',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('快捷选择', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: presetAccentColors.map((color) {
                  final selected = color.toARGB32() == _color.toARGB32();
                  return GestureDetector(
                    onTap: () => setState(() => _color = color),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? AppContrast.onColor(color) : Colors.transparent,
                          width: selected ? 2 : 0,
                        ),
                      ),
                      child: selected ? Icon(Icons.check_rounded, size: 16, color: AppContrast.onColor(color)) : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              ColorPicker(
                pickerColor: _color,
                onColorChanged: (color) => setState(() => _color = color),
                enableAlpha: false,
                labelTypes: const [],
                hexInputBar: true,
                paletteType: PaletteType.hsvWithHue,
                pickerAreaHeightPercent: 0.7,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _color), child: const Text('应用')),
      ],
    );
  }
}

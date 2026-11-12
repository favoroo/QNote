import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

class PersonalizationPage extends ConsumerWidget {
  const PersonalizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accentColor = ref.watch(accentColorProvider);
    final background = ref.watch(backgroundSettingProvider);
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
                  // 4 列固定网格：8 色呈规整两行，任何屏宽下都对齐
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

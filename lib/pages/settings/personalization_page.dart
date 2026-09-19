import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

class PersonalizationPage extends ConsumerWidget {
  const PersonalizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final accentColor = ref.watch(accentColorProvider);

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
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('显示模式', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _ThemeModeButton(
                          title: '浅色',
                          icon: Icons.light_mode_outlined,
                          isSelected: themeMode == ThemeMode.light || (themeMode == ThemeMode.system && theme.brightness == Brightness.light),
                          onTap: () => ref.read(themeModeProvider.notifier).setThemeMode(ThemeMode.light),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _ThemeModeButton(
                          title: '深色',
                          icon: Icons.dark_mode_outlined,
                          isSelected: themeMode == ThemeMode.dark || (themeMode == ThemeMode.system && theme.brightness == Brightness.dark),
                          onTap: () => ref.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark),
                        ),
                      ),
                    ],
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
                            duration: AppDurations.fast,
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
                              duration: AppDurations.fast,
                              curve: AppCurves.standard,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                              // 选中时白色对勾缩放淡入，选中态更直观
                              child: AnimatedScale(
                                scale: isSelected ? 1.0 : 0.0,
                                duration: AppDurations.fast,
                                curve: AppCurves.standard,
                                child: const Icon(
                                  Icons.check_rounded,
                                  size: 20,
                                  color: Colors.white,
                                ),
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
                    ref.read(themeModeProvider.notifier).setThemeMode(ThemeMode.system);
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
}

class _ThemeModeButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeModeButton({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 100,
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

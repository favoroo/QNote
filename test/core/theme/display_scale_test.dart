import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/appearance_bootstrap.dart';
import 'package:qnote_flutter/core/theme/display_scale.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DisplayScale 档位令牌', () {
    test('三档倍率与名称固定，索引用于持久化', () {
      expect(DisplayScale.values, [DisplayScale.small, DisplayScale.medium, DisplayScale.large]);
      expect(DisplayScale.small.factor, 0.9);
      expect(DisplayScale.medium.factor, 1.0);
      expect(DisplayScale.large.factor, 1.15);
      expect(DisplayScale.small.label, '小');
      expect(DisplayScale.medium.label, '中');
      expect(DisplayScale.large.label, '大');
    });

    test('fromIndex 缺失或越界都回退到中档', () {
      expect(DisplayScale.fromIndex(null), DisplayScale.medium);
      expect(DisplayScale.fromIndex(-1), DisplayScale.medium);
      expect(DisplayScale.fromIndex(99), DisplayScale.medium);
      expect(DisplayScale.fromIndex(DisplayScale.small.index), DisplayScale.small);
      expect(DisplayScale.fromIndex(DisplayScale.large.index), DisplayScale.large);
    });
  });

  group('AppTextScale.resolve', () {
    const ref = 13.0;

    test('无系统缩放时即为用户档位', () {
      expect(AppTextScale.resolve(base: TextScaler.noScaling, factor: 1.15).scale(ref), closeTo(ref * 1.15, 1e-9));
      expect(AppTextScale.resolve(base: TextScaler.noScaling, factor: 0.9).scale(ref), closeTo(ref * 0.9, 1e-9));
    });

    test('叠加系统倍率后按乘积缩放（未触上限）', () {
      final scaler = AppTextScale.resolve(base: const TextScaler.linear(1.2), factor: 1.15);
      // 1.2 × 1.15 = 1.38，未超上限时按乘积缩放
      expect(scaler.scale(ref), closeTo(ref * 1.38, 1e-9));
    });

    test('总倍率超过上限时钳到 1.4，避免固定高度控件溢出', () {
      // 系统 1.5 × 大档 1.15 = 1.725 → 钳到 1.4
      expect(
        AppTextScale.resolve(base: const TextScaler.linear(1.5), factor: 1.15).scale(ref),
        closeTo(ref * 1.4, 1e-9),
      );
    });

    test('总倍率低于下限时钳到 0.8', () {
      // 系统 0.5 × 小档 0.9 = 0.45 → 钳到 0.8
      expect(
        AppTextScale.resolve(base: const TextScaler.linear(0.5), factor: 0.9).scale(ref),
        closeTo(ref * 0.8, 1e-9),
      );
    });
  });

  group('AppTextScale.wrap', () {
    testWidgets('中档原样返回，非中档包一层 MediaQuery', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const Text('x');
            },
          ),
        ),
      );

      const child = SizedBox.shrink();
      expect(identical(AppTextScale.wrap(context: ctx, factor: 1.0, child: child), child), isTrue);
      expect(AppTextScale.wrap(context: ctx, factor: 1.15, child: child), isA<MediaQuery>());
    });

    testWidgets('包一层后子树读到缩放后的 textScaler', (tester) async {
      double? scaled;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (outerCtx) {
              return AppTextScale.wrap(
                context: outerCtx,
                factor: 1.15,
                child: Builder(
                  builder: (innerCtx) {
                    scaled = MediaQuery.textScalerOf(innerCtx).scale(13);
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(scaled, closeTo(13 * 1.15, 1e-9));
    });
  });

  group('displayScaleProvider', () {
    tearDown(AppearanceBootstrap.resetForTest);

    test('预热后首帧即为用户保存的档位', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.displayScale: DisplayScale.small.index});
      await AppearanceBootstrap.warmUp();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(displayScaleProvider), DisplayScale.small);
    });

    test('未预热时先用中档，异步加载后切到持久化值', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.displayScale: DisplayScale.large.index});

      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(displayScaleProvider), DisplayScale.medium);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(displayScaleProvider), DisplayScale.large);
    });

    test('setScale 落库并即时更新状态，reset 回到中档', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.displayScale: DisplayScale.medium.index});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 等首次异步 _load 完成，避免与后续 setScale 竞争
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await container.read(displayScaleProvider.notifier).setScale(DisplayScale.large);
      expect(container.read(displayScaleProvider), DisplayScale.large);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(AppearanceKeys.displayScale), DisplayScale.large.index);

      await container.read(displayScaleProvider.notifier).reset();
      expect(container.read(displayScaleProvider), DisplayScale.medium);
      expect(prefs.getInt(AppearanceKeys.displayScale), DisplayScale.medium.index);
    });
  });
}

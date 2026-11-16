import 'package:flutter/material.dart';

import 'app_typography.dart';

/// 全局显示大小档位。
///
/// 项目的字号散落在 `textTheme`、[AppTypography] 令牌与大量硬编码 `fontSize`
/// 三处，逐点放大不现实；这里用 `MediaQuery.textScaler` 统一在渲染层缩放文字，
/// 一次覆盖全部 `Text` / `EditableText`，与 Android「字体大小」行为一致。
///
/// 枚举索引用于 SharedPreferences 持久化，只能追加，不能调整既有顺序。
enum DisplayScale {
  /// 小：在系统倍率基础上再 −10%，界面更紧凑。
  small(0.9, '小'),

  /// 中（默认）：不额外缩放，保持当前视觉。
  medium(1.0, '中'),

  /// 大：在系统倍率基础上再 +15%，正文更易读。
  large(1.15, '大');

  const DisplayScale(this.factor, this.label);

  /// 相对系统倍率的用户倍率。
  final double factor;

  /// 设置页展示的名称。
  final String label;

  /// 从持久化索引解析档位。
  ///
  /// 缺失或越界（历史数据 / 降级安装）时回退到 [medium]，不让界面崩在取值上。
  static DisplayScale fromIndex(int? index) {
    if (index == null || index < 0 || index >= DisplayScale.values.length) {
      return DisplayScale.medium;
    }
    return DisplayScale.values[index];
  }
}

/// 显示大小的动态入口。
///
/// 与 [AppMotion] 之于动效令牌的关系相同：[DisplayScale] 是静态令牌，
/// 这里是读取上下文、把令牌换算成 `TextScaler` 并注入控件树的地方。
abstract final class AppTextScale {
  /// 总倍率下限：防止叠加后文字过小。
  static const double _minFactor = 0.8;

  /// 总倍率上限：大档(1.15)叠加大号系统字体(1.3+)时若不钳制，
  /// 大量固定高度控件（分段胶囊、图表格）会溢出，故封顶。
  static const double _maxFactor = 1.4;

  /// 估算系统倍率的基准字号：取正文令牌，落在常见字号区间中部最稳。
  static const double _referenceFontSize = AppTypography.body;

  /// 把「系统倍率 × 用户档位」合成一个线性 [TextScaler] 并对总倍率钳制。
  ///
  /// 系统 `MediaQuery.textScaler` 在 iOS 上是非线性的，这里取正文基准字号处的
  /// 等效倍率再乘用户档位，换算为线性缩放——用户档位是中档时调用方根本不进入
  /// 本方法（见 [wrap]），因此不会改变系统无障碍缩放的默认行为。
  static TextScaler resolve({required TextScaler base, required double factor}) {
    final systemFactor = base.scale(_referenceFontSize) / _referenceFontSize;
    final total = (systemFactor * factor).clamp(_minFactor, _maxFactor);
    return TextScaler.linear(total);
  }

  /// 用显示大小包裹 [child]；中档（倍率 1.0）时原样返回，零开销、不动系统缩放。
  static Widget wrap({required BuildContext context, required double factor, required Widget child}) {
    if (factor == 1.0) {
      return child;
    }
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: resolve(base: media.textScaler, factor: factor),
      ),
      child: child,
    );
  }
}

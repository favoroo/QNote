import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:qnote_flutter/core/utils/diary_progress.dart';

/// 达标庆祝的强度分级与粒子弹道。
///
/// 「该不该弹、弹多重、某颗粒子此刻在哪」这三件事只依赖进度前后值与几个
/// 数值参数，耦合在 UI 里就只能靠起 App 点一点来验证；抽到此处后，冷启动
/// 误弹、分级走错档位、粒子算出 NaN 这类问题都能在没有渲染环境时锁住。

/// 庆祝强度：满额达标 > 破单日纪录 > 普通记录。
enum CheerLevel { plain, record, full }

/// 由进度前后值推导庆祝强度；返回 `null` 表示这一次不该弹任何东西。
///
/// [prev] 为 null 覆盖两种情形，两者都不能弹：本轮首次回调，以及列表刚加载完
/// 产出的第一个真实值（加载期间 provider 恒为 null）。后者是 0→已有条数的整段
/// 跳变，不是「用户刚记了一条」，冷启动进 App 不该弹横幅。
CheerLevel? resolveCheerLevel(DiaryProgress? prev, DiaryProgress? next) {
  if (prev == null || next == null || next.todayCount <= prev.todayCount) {
    return null;
  }
  if (!prev.isFull && next.isFull) {
    return CheerLevel.full;
  }
  if (prev.maxPerDay > 0 && next.todayCount > prev.maxPerDay) {
    return CheerLevel.record;
  }
  return CheerLevel.plain;
}

/// 各档的动画规格。数值集中在此，调手感不用翻组件代码。
extension CheerLevelSpec on CheerLevel {
  /// 是否值得放彩带与流光；普通记录只留极轻胶囊，庆祝才有稀缺感。
  bool get isCheer => this != CheerLevel.plain;

  /// 粒子颗数。普通记录为 0，粒子层因此整层不挂。
  int get particleCount => switch (this) {
        CheerLevel.full => 26,
        CheerLevel.record => 14,
        CheerLevel.plain => 0,
      };

  /// 胶囊停留时长（ms），到点后退场而非硬切消失。
  int get dwellMs => switch (this) {
        CheerLevel.full => 2500,
        CheerLevel.record => 1800,
        CheerLevel.plain => 1500,
      };

  /// 粒子起爆相对事件时刻的延迟（ms）：让圆环先鼓起，动线才有因果。
  int get burstDelayMs => switch (this) {
        CheerLevel.full => 90,
        CheerLevel.record => 150,
        CheerLevel.plain => 0,
      };

  /// 粒子层整段时长（ms），含起爆延迟。
  Duration get burstDuration => Duration(
        milliseconds: burstDelayMs + switch (this) {
          CheerLevel.full => 1150,
          CheerLevel.record => 900,
          CheerLevel.plain => 0,
        },
      );
}

/// 粒子形状：彩带为主、圆点填充、四角星做高光。
enum CheerShape { ribbon, dot, star }

/// 一颗粒子的静态参数；位置与透明度由 [particleOffset] / [particleAlpha] 算出。
class CheerParticle {
  const CheerParticle({
    required this.shape,
    required this.angle,
    required this.speed,
    required this.lifeMs,
    required this.delayMs,
    required this.spin,
    required this.curl,
    required this.colorIndex,
  });

  final CheerShape shape;

  /// 发射方向（弧度，0 指向右、负值朝上）。
  final double angle;

  /// 初速度 px/s。
  final double speed;

  /// 自身寿命 ms，比整段动画短，让先发射的先谢幕。
  final double lifeMs;

  /// 发射延迟 ms，错开才不炸成一坨。
  final double delayMs;

  /// 彩带翻滚的总圈数符号，圆点忽略。
  final double spin;

  /// 侧向摆幅 px，给弹道加一点飘感。
  final double curl;

  /// 色谱下标，由粒子层按主题解析成具体颜色。
  final int colorIndex;
}

/// 重力加速度 px/s²，让粒子尾段下坠而不是匀速直线飞走。
const double kCheerGravity = 560;

/// 扇形起爆的起始角与张角（弧度）。
///
/// 爆点是屏幕左下角附近的进度圆环，可用空间只在上方与右方：往左下半径内
/// 的粒子会立刻飞出屏幕，白撒一半。因此扇形从「略偏左上」扫到「略偏右下」。
const double _fanStart = -math.pi * 0.95;
const double _fanSpan = math.pi * 1.12;

/// 按 [count] 生成一组确定性粒子。
///
/// [seed] 决定随机序列：庆祝每次都是新事件，用自增序号当 seed 即可让连续的
/// 两次爆发长得不一样，同时测试里能逐项复现。
List<CheerParticle> seedBurst({required int count, required int seed}) {
  if (count <= 0) {
    return const [];
  }
  final random = math.Random(seed);

  return [
    for (var i = 0; i < count; i++)
      CheerParticle(
        shape: _shapeFor(i, count),
        angle: _fanStart + _fanSpan * random.nextDouble(),
        speed: 180 + 250 * random.nextDouble(),
        lifeMs: 620 + 360 * random.nextDouble(),
        delayMs: 90 * random.nextDouble(),
        spin: (random.nextDouble() - 0.5) * 6,
        curl: 6 + 18 * random.nextDouble(),
        colorIndex: i % 4,
      ),
  ];
}

/// 形状按索引分区而非随机分配：保证同 seed 同结果，且各档数量缩小时
/// 彩带/圆点/四角星的比例仍然稳定。
CheerShape _shapeFor(int index, int total) {
  final ratio = index / total;
  if (ratio < 0.62) {
    return CheerShape.ribbon;
  }
  if (ratio < 0.89) {
    return CheerShape.dot;
  }
  return CheerShape.star;
}

/// 粒子相对爆点在自身进度 [t]（0~1）处的位移，单位 px、屏幕坐标系（y 向下为正）。
///
/// 抛物线用「粒子寿命」换算成秒，因此 [t] 相同的两颗粒子飞得一样远 —— 视觉上
/// 整场爆发同时收尾，不会出现拖尾散场。
Offset particleOffset(CheerParticle p, double t) {
  final seconds = t * p.lifeMs / 1000;
  final lift = math.sin(p.angle) * p.speed * seconds;
  return Offset(
    math.cos(p.angle) * p.speed * seconds + p.curl * math.sin(3 * t * math.pi),
    lift + 0.5 * kCheerGravity * seconds * seconds,
  );
}

/// 粒子在自身进度 [t] 处的不透明度：前段满、后段加速收掉。
///
/// 四角星额外先升后降闪一下，高光才有「爆」的瞬时感。
double particleAlpha(CheerParticle p, double t) {
  if (t <= 0 || t >= 1) {
    return 0;
  }
  final fadeOut = 1 - _easeInSine(_clampDouble((t - 0.55) / 0.45));
  if (p.shape != CheerShape.star) {
    return fadeOut;
  }
  return fadeOut * math.sin(t * math.pi);
}

/// 正弦加速淡出：t=0 不动、t=1 全入，收尾比线性更利落。
double _easeInSine(double t) => math.pow(math.sin(t * math.pi / 2), 2).toDouble();

/// 彩带翻滚时的宽度调制系数（0.15~1），圆点与四角星忽略。
double ribbonTumble(CheerParticle p, double t) =>
    _clampDouble(math.cos(p.spin * t * math.pi * 2).abs() * 0.85, min: 0.15);

/// 收敛到 [min]~1 区间。
double _clampDouble(double value, {double min = 0}) {
  if (value <= min) {
    return min;
  }
  return value >= 1 ? 1 : value;
}

/// 粒子层应使用的爆点坐标。
///
/// 锚点由圆环上报，取不到时退回到屏幕左下角的圆环常规位置 —— 圆环是常驻
/// 控件，取不到只会发生在首帧之前，此时按常规位置画也比不画好。
Offset resolveBurstOrigin({required Offset? anchor, required Size size}) {
  return anchor ?? Offset(_fallbackInset, size.height - _fallbackInset);
}

/// 回退爆点距左/下边缘的距离：圆环左边 12 padding + 半径 22。
const double _fallbackInset = 34;

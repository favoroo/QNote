import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/cheer_burst.dart';
import 'package:qnote_flutter/core/utils/diary_progress.dart';

/// 造一份进度：只关心分级用到的几个字段，其余给安全默认值。
DiaryProgress _progress({
  required int todayCount,
  int target = 3,
  int maxPerDay = 0,
  int streakDays = 0,
}) {
  return DiaryProgress(
    todayCount: todayCount,
    target: target,
    streakDays: streakDays,
    maxPerDay: maxPerDay,
    todayPending: todayCount == 0,
  );
}

Iterable<Object?> _fingerprint(Iterable<CheerParticle> particles) {
  return [
    for (final p in particles) ...[
      p.shape,
      p.angle,
      p.speed,
      p.lifeMs,
      p.delayMs,
      p.spin,
      p.curl,
      p.colorIndex,
    ],
  ];
}

void main() {
  group('resolveCheerLevel', () {
    test('前后值任一为 null 不弹（冷启动首帧与列表刚加载完都走这条）', () {
      final p = _progress(todayCount: 3);

      expect(resolveCheerLevel(null, p), isNull);
      expect(resolveCheerLevel(p, null), isNull);
      expect(resolveCheerLevel(null, null), isNull);
    });

    test('列表加载完一次性从 0 跳到满档，也不该被当成刚记了一条', () {
      // 加载期间 provider 恒为 null，第一个真实值就是 3/3：prev 为 null 挡住误弹。
      expect(resolveCheerLevel(null, _progress(todayCount: 3, maxPerDay: 3)), isNull);
    });

    test('条数没变或变少不弹（补记旧日期、删除记录都不触发）', () {
      final before = _progress(todayCount: 3, maxPerDay: 3);

      expect(resolveCheerLevel(before, _progress(todayCount: 3, maxPerDay: 3)), isNull);
      expect(resolveCheerLevel(before, _progress(todayCount: 2, maxPerDay: 3)), isNull);
    });

    test('首次够到目标算满档，已经在目标之上再加只算破纪录', () {
      expect(
        resolveCheerLevel(_progress(todayCount: 2), _progress(todayCount: 3)),
        CheerLevel.full,
      );
      // 已经 3/3 再加一条：不是「首次达标」。
      expect(
        resolveCheerLevel(
          _progress(todayCount: 3, maxPerDay: 3),
          _progress(todayCount: 4, maxPerDay: 3),
        ),
        CheerLevel.record,
      );
    });

    test('目标改大后仍未达标，只是普通记录', () {
      expect(
        resolveCheerLevel(
          _progress(todayCount: 3, target: 5),
          _progress(todayCount: 4, target: 5, maxPerDay: 3),
        ),
        CheerLevel.plain,
      );
    });

    test('满档优先于破纪录：一次跨达标线又刷新单日最高，只按满档庆祝', () {
      expect(
        resolveCheerLevel(
          _progress(todayCount: 2, maxPerDay: 2),
          _progress(todayCount: 3, maxPerDay: 2),
        ),
        CheerLevel.full,
      );
    });
  });

  group('分级规格', () {
    test('粒子数与停留时长按档位递减，普通记录不放粒子', () {
      expect(CheerLevel.full.particleCount, 26);
      expect(CheerLevel.record.particleCount, 14);
      expect(CheerLevel.plain.particleCount, 0);

      expect(CheerLevel.full.dwellMs, greaterThan(CheerLevel.record.dwellMs));
      expect(CheerLevel.record.dwellMs, greaterThan(CheerLevel.plain.dwellMs));
    });

    test('只有普通记录不算庆祝，彩带与流光都挂在 isCheer 上', () {
      expect(CheerLevel.full.isCheer, isTrue);
      expect(CheerLevel.record.isCheer, isTrue);
      expect(CheerLevel.plain.isCheer, isFalse);
    });

    test('停留时长必须容得下退场，否则胶囊会被半路摘掉', () {
      // 退场 150ms（AppDurations.fast），最轻的一档也要留足。
      expect(CheerLevel.record.dwellMs, greaterThan(CheerLevel.record.burstDuration.inMilliseconds));
    });
  });

  group('seedBurst', () {
    test('同 seed 同结果，换 seed 换结果', () {
      final a = seedBurst(count: 26, seed: 7);
      final b = seedBurst(count: 26, seed: 7);
      final c = seedBurst(count: 26, seed: 8);

      expect(_fingerprint(a), _fingerprint(b));
      expect(_fingerprint(a), isNot(_fingerprint(c)));
    });

    test('数量按档位收口，普通记录返回空列表', () {
      expect(seedBurst(count: CheerLevel.full.particleCount, seed: 1), hasLength(26));
      expect(seedBurst(count: CheerLevel.record.particleCount, seed: 1), hasLength(14));
      expect(seedBurst(count: CheerLevel.plain.particleCount, seed: 1), isEmpty);
      expect(seedBurst(count: -3, seed: 1), isEmpty);
    });

    test('彩带占多数、四角星只做点缀', () {
      final shapes = seedBurst(count: 26, seed: 3).map((p) => p.shape);

      expect(shapes.where((s) => s == CheerShape.ribbon).length, greaterThan(12));
      expect(shapes.where((s) => s == CheerShape.star).length, lessThanOrEqualTo(3));
    });

    test('发射角全落在上半扇形，不会朝屏幕外白撒', () {
      for (final p in seedBurst(count: 26, seed: 5)) {
        // angle 为负即朝上：整段扇形不应出现明显向下的初速度。
        expect(p.angle, lessThanOrEqualTo(0.55));
      }
    });
  });

  group('粒子弹道', () {
    test('life=0 全部还在爆点上', () {
      for (final p in seedBurst(count: 26, seed: 11)) {
        expect(particleOffset(p, 0), Offset.zero);
      }
    });

    test('life 两端与越界处不透明度为 0，中段为正', () {
      for (final p in seedBurst(count: 26, seed: 11)) {
        expect(particleAlpha(p, 0), 0);
        expect(particleAlpha(p, 1), 0);
        expect(particleAlpha(p, -0.2), 0);
        expect(particleAlpha(p, 1.4), 0);
        expect(particleAlpha(p, 0.2), greaterThan(0));
      }
    });

    test('整段轨迹无 NaN 与溢出，越往后飞得越远', () {
      for (final p in seedBurst(count: 26, seed: 13)) {
        double previous = 0;
        for (var t = 0.0; t <= 1.0001; t += 0.05) {
          final offset = particleOffset(p, t.clamp(0.0, 1.0));
          final distance = offset.distance;

          expect(distance.isNaN, isFalse, reason: '${p.shape} 在 t=$t 算出 NaN');
          expect(distance.isFinite, isTrue);
          expect(particleAlpha(p, t), inInclusiveRange(0, 1));
          expect(ribbonTumble(p, t), inInclusiveRange(0.15, 1));
          if (t > 0.9) {
            expect(distance, greaterThan(previous * 0.5));
          }
          previous = distance;
        }
      }
    });

    test('尾段受重力下坠：水平发射的粒子只有向下的位移，且单调增大', () {
      // 直接构造而非从随机池里挑：angle=-π/2 的粒子全程在上升段，断言会随种子翻车。
      const p = CheerParticle(
        shape: CheerShape.dot,
        angle: 0,
        speed: 300,
        lifeMs: 900,
        delayMs: 0,
        spin: 0,
        curl: 0,
        colorIndex: 0,
      );
      final early = particleOffset(p, 0.3);
      final mid = particleOffset(p, 0.6);
      final tail = particleOffset(p, 0.95);

      expect(early.dy, greaterThan(0));
      expect(mid.dy, greaterThan(early.dy));
      expect(tail.dy, greaterThan(mid.dy));
      // 水平方向应当是匀速（curl 为 0），说明垂直增量确实只来自重力项。
      expect(tail.dx / mid.dx, closeTo(0.95 / 0.6, 0.001));
    });
  });

  group('resolveBurstOrigin', () {
    test('圆环还没上报时回退到左下角常规位置', () {
      final origin = resolveBurstOrigin(
        anchor: null,
        size: const Size(400, 800),
      );

      expect(origin.dx, 34);
      expect(origin.dy, 800 - 34);
    });

    test('有锚点时如实采用，不做二次加工', () {
      expect(
        resolveBurstOrigin(anchor: const Offset(123, 456), size: const Size(400, 800)),
        const Offset(123, 456),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/api_key_pool.dart';

/// 密钥池轮询/冷却/错误分类的纯单测（不联网、不碰数据库）
void main() {
  final pool = ApiKeyPool.instance;

  setUp(() {
    pool.resetForTest();
  });

  group('轮询', () {
    test('多把 Key 按 round-robin 依次返回', () {
      const keys = ['k1', 'k2', 'k3'];
      expect(pool.acquireNext('p1', keys), 'k1');
      expect(pool.acquireNext('p1', keys), 'k2');
      expect(pool.acquireNext('p1', keys), 'k3');
      expect(pool.acquireNext('p1', keys), 'k1');
    });

    test('单把 Key 永远返回同一把（不产生轮换开销）', () {
      expect(pool.acquireNext('p1', const ['only']), 'only');
      expect(pool.acquireNext('p1', const ['only']), 'only');
    });

    test('空池返回 null', () {
      expect(pool.acquireNext('p1', const []), isNull);
    });

    test('不同厂商的游标互不影响', () {
      expect(pool.acquireNext('p1', const ['a', 'b']), 'a');
      expect(pool.acquireNext('p2', const ['x', 'y']), 'x');
      expect(pool.acquireNext('p1', const ['a', 'b']), 'b');
      expect(pool.acquireNext('p2', const ['x', 'y']), 'y');
    });
  });

  group('冷却', () {
    test('标记冷却后轮换跳过该 Key', () {
      const keys = ['k1', 'k2'];
      expect(pool.acquireNext('p1', keys), 'k1');
      pool.markLimited('p1', 'k1');
      expect(pool.acquireNext('p1', keys), 'k2');
      expect(pool.hasAvailable('p1', keys), isTrue);
      expect(
        pool.cooldownRemaining('p1', 'k1'),
        greaterThan(Duration.zero),
      );
    });

    test('整池冷却后可读出最早解锁时刻', () {
      const keys = ['k1', 'k2'];
      pool.markLimited('p1', 'k1', cooldown: const Duration(seconds: 5));
      pool.markLimited('p1', 'k2', cooldown: const Duration(seconds: 9));
      expect(pool.hasAvailable('p1', keys), isFalse);
      final earliest = pool.earliestCooldownEnd('p1');
      expect(earliest, isNotNull);
      final remaining = earliest!.difference(DateTime.now());
      expect(remaining.inSeconds, inInclusiveRange(3, 5));
    });

    test('冷却时长有上限，防止把 Key 关到天荒地老', () {
      pool.markLimited('p1', 'k1', cooldown: const Duration(hours: 3));
      final remaining = pool.cooldownRemaining('p1', 'k1');
      expect(
        remaining.inSeconds,
        lessThanOrEqualTo(ApiKeyPool.maxCooldown.inSeconds),
      );
    });

    test('syncKeys 会清掉已删除 Key 的冷却记录', () {
      pool.markLimited('p1', 'gone');
      pool.syncKeys('p1', const ['k1']);
      expect(pool.cooldownRemaining('p1', 'gone'), Duration.zero);
    });

    test('reset 清空指定厂商的游标与冷却', () {
      pool.acquireNext('p1', const ['k1', 'k2']);
      pool.markLimited('p1', 'k1');
      pool.reset('p1');
      expect(pool.cooldownRemaining('p1', 'k1'), Duration.zero);
      expect(pool.acquireNext('p1', const ['k1', 'k2']), 'k1');
    });
  });

  group('错误分类', () {
    test('密钥脱敏保留首尾 4 位', () {
      expect(ApiKeyPool.maskKey('sk-1234567890abcd'), 'sk-1...abcd');
      expect(ApiKeyPool.maskKey('short'), '***');
    });

    test('退避延迟随重试次数增长且有抖动', () {
      final first = ApiKeyPool.getBackoffDelay(1).inMilliseconds;
      final third = ApiKeyPool.getBackoffDelay(3).inMilliseconds;
      expect(first, inInclusiveRange(300, 450));
      expect(third, greaterThan(first));
    });
  });
}
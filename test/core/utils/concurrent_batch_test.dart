import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/concurrent_batch.dart';

void main() {
  group('runWithConcurrency', () {
    test('空列表直接返回，不执行任何任务', () async {
      var calls = 0;
      await runWithConcurrency<int>(items: const [], concurrency: 3, task: (item, index, worker) async => calls++);
      expect(calls, 0);
    });

    test('每条任务恰好执行一次，下标连续且不重复', () async {
      final seen = <int>[];
      await runWithConcurrency<int>(
        items: List.generate(10, (i) => i),
        concurrency: 3,
        task: (item, index, worker) async {
          seen.add(index);
        },
      );
      expect(seen..sort(), List.generate(10, (i) => i));
    });

    test('同时运行的任务数不超过并发度', () async {
      var running = 0;
      var maxRunning = 0;
      await runWithConcurrency<int>(
        items: List.generate(12, (i) => i),
        concurrency: 3,
        task: (item, index, worker) async {
          running++;
          maxRunning = running > maxRunning ? running : maxRunning;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          running--;
        },
      );
      expect(maxRunning, 3);
    });

    test('任务数少于并发度时不会多开 worker', () async {
      final workers = <int>{};
      await runWithConcurrency<int>(
        items: [1, 2],
        concurrency: 8,
        task: (item, index, worker) async {
          workers.add(worker);
        },
      );
      expect(workers.length, 2);
    });

    test('同一 worker 槽位串行复用，槽位下标稳定在 0..concurrency-1', () async {
      final byWorker = <int, List<int>>{};
      await runWithConcurrency<int>(
        items: List.generate(9, (i) => i),
        concurrency: 3,
        task: (item, index, worker) async {
          byWorker.putIfAbsent(worker, () => []).add(index);
        },
      );
      expect(byWorker.keys.toSet(), {0, 1, 2});
      // 每个槽位都分到了 3 条，说明确实在轮流领取而不是只有一个 worker 在跑
      expect(byWorker.values.map((e) => e.length), everyElement(3));
    });

    test('单个任务抛异常不会中断整批', () async {
      final done = <int>[];
      final errors = <int>[];
      await runWithConcurrency<int>(
        items: List.generate(6, (i) => i),
        concurrency: 2,
        onError: (error, stackTrace, index) => errors.add(index),
        task: (item, index, worker) async {
          if (index == 2) throw StateError('boom');
          done.add(index);
        },
      );
      expect(errors, [2]);
      expect(done..sort(), [0, 1, 3, 4, 5]);
    });

    test('未提供 onError 时异常被吞掉，其余任务照常完成', () async {
      final done = <int>[];
      await runWithConcurrency<int>(
        items: List.generate(4, (i) => i),
        concurrency: 2,
        task: (item, index, worker) async {
          if (index == 0) throw StateError('boom');
          done.add(index);
        },
      );
      expect(done..sort(), [1, 2, 3]);
    });

    test('shouldStop 为 true 后不再领取新任务', () async {
      var started = 0;
      await runWithConcurrency<int>(
        items: List.generate(20, (i) => i),
        concurrency: 2,
        shouldStop: () => started >= 4,
        task: (item, index, worker) async {
          started++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        },
      );
      // 2 个 worker 各多领一条后才发现该停，最多比阈值多 2 条
      expect(started, lessThanOrEqualTo(6));
      expect(started, greaterThanOrEqualTo(4));
    });

    test('并发度小于 1 时按 1 处理，不会卡住', () async {
      final done = <int>[];
      await runWithConcurrency<int>(
        items: [1, 2, 3],
        concurrency: 0,
        task: (item, index, worker) async => done.add(index),
      );
      expect(done..sort(), [0, 1, 2]);
    });
  });

  group('SerialExecutor', () {
    test('并发提交按提交顺序串行执行，不会重叠', () async {
      final executor = SerialExecutor();
      var running = 0;
      var maxRunning = 0;
      final order = <int>[];

      await Future.wait([
        for (var i = 0; i < 5; i++)
          executor.run(() async {
            running++;
            maxRunning = running > maxRunning ? running : maxRunning;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            order.add(i);
            running--;
          }),
      ]);

      expect(maxRunning, 1);
      expect(order, [0, 1, 2, 3, 4]);
    });

    test('单个任务失败不影响后续任务，且错误仍抛给调用方', () async {
      final executor = SerialExecutor();
      final done = <int>[];

      final failing = executor.run<int>(() async => throw StateError('boom'));
      final after = executor.run<int>(() async {
        done.add(1);
        return 1;
      });

      await expectLater(failing, throwsStateError);
      expect(await after, 1);
      expect(done, [1]);
    });

    test('返回值透传给调用方', () async {
      final executor = SerialExecutor();
      expect(await executor.run(() async => 'ok'), 'ok');
    });
  });
}

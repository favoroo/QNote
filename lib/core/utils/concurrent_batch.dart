/// 固定并发度的批量任务调度。
///
/// 时间线批量提取是典型的「N 条互不依赖的 IO 任务」：串行总耗时 = N × 单条耗时，
/// 并发后约等于 ceil(N / 并发度) × 单条耗时。这里只负责调度，不关心任务内容，
/// 因此可以脱离 BuildContext / Riverpod 单独测试。
library;

/// 时间线批量提取的默认并发度。
///
/// 3 是「够快」与「别把端点打限流」之间的折中：多数厂商的低档套餐按 RPM / 并发
/// 限流，同时开 3 条通常还在配额内；再往上会频繁撞 429 触发 Key 冷却，
/// 冷却期内的等待反而比串行更慢。
const int kBatchExtractConcurrency = 3;

/// 以固定并发度执行 [items] 上的 [task]。
///
/// - 同一时刻最多 [concurrency] 个 [task] 在跑（含正在等待的）；
/// - [shouldStop] 返回 true 后不再领取新任务，**已发出的任务会跑完**
///   （它们各自持有取消令牌，由调用方决定是否中断）；
/// - 单个任务抛出的异常不会中断整批：交给 [onError] 处理，未提供时吞掉，
///   避免一条失败把剩下几十条全带走；
/// - [task] 的 `worker` 参数是执行它的工作槽下标（0..concurrency-1）。
///   并发调用同一个有状态服务（如 `AiService`，配置与 baseUrl 都是实例字段）
///   时，必须按槽位各持一个实例，否则会互相覆写配置串台。
Future<void> runWithConcurrency<T>({
  required List<T> items,
  required int concurrency,
  required Future<void> Function(T item, int index, int worker) task,
  bool Function()? shouldStop,
  void Function(Object error, StackTrace stackTrace, int index)? onError,
}) async {
  if (items.isEmpty) return;

  // 槽位不用比任务多：3 条记录开 3 个 worker 与开 8 个等价，后者只是空转
  final workerCount = concurrency < 1 ? 1 : (concurrency > items.length ? items.length : concurrency);

  // 领取下标与判断都不含 await，单线程事件循环里天然是原子的
  var cursor = 0;

  Future<void> worker(int slot) async {
    while (true) {
      if (shouldStop?.call() ?? false) return;
      final index = cursor++;
      if (index >= items.length) return;
      try {
        await task(items[index], index, slot);
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace, index);
      }
    }
  }

  await Future.wait(List.generate(workerCount, worker));
}

/// 串行执行器：把并发调用方的任务排队，保证同一时刻只有一个在跑。
///
/// 并发提取 AI 时，结果落库必须串行 —— SQLite 并发写会撞 `database is locked`，
/// 而列表状态是「读全表 → 替换一项 → 写回」，并发提交会互相覆盖丢更新。
/// 单个任务失败不影响后续任务（队列吞错保链，原始错误仍抛给调用方）。
class SerialExecutor {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_progress_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';

/// 列表加载未完成的 provider：日记页进 App 的首帧就是这个状态
class _PendingDiaryListNotifier extends DiaryListNotifier {
  final Completer<List<DiaryRecord>> completer = Completer();

  @override
  Future<List<DiaryRecord>> build() => completer.future;
}

/// 列表已就绪的 provider
class _ReadyDiaryListNotifier extends DiaryListNotifier {
  _ReadyDiaryListNotifier(this._records);

  final List<DiaryRecord> _records;

  @override
  Future<List<DiaryRecord>> build() async => _records;
}

DiaryRecord _todayRecord(int minute) {
  final now = DateTime.now();
  final time = DateTime(now.year, now.month, now.day, 9, minute);
  return DiaryRecord(
    id: 'r-$minute',
    title: '记录',
    time: time,
    createdAt: time,
    updatedAt: time,
  );
}

void main() {
  group('diaryProgressProvider 的就绪语义', () {
    test('列表还在加载时返回 null，而不是按空列表算出的 0 条', () async {
      final notifier = _PendingDiaryListNotifier();
      final container = ProviderContainer(
        overrides: [diaryListProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(diaryProgressProvider),
        isNull,
        reason: '把「还不知道」写成 0 条，会让首帧的 0→真实值跳变被误判成新记了一条',
      );

      notifier.completer.complete([
        _todayRecord(1),
        _todayRecord(2),
        _todayRecord(3),
      ]);
      await container.read(diaryListProvider.future);

      final progress = container.read(diaryProgressProvider);
      expect(progress, isNotNull);
      expect(progress!.todayCount, 3);
      expect(progress.isFull, isTrue);
    });

    test('目标条数可被 dailyTargetProvider 覆盖', () async {
      final container = ProviderContainer(
        overrides: [
          diaryListProvider.overrideWith(
            () => _ReadyDiaryListNotifier([_todayRecord(1), _todayRecord(2)]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(diaryListProvider.future);

      expect(container.read(diaryProgressProvider)!.remaining, 1);
      container.read(dailyTargetProvider.notifier).state = 5;
      expect(container.read(diaryProgressProvider)!.remaining, 3);
    });
  });
}

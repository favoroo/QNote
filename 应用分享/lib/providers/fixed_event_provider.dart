import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/core/storage/fixed_event_repository.dart';

/// 固定事件模板列表（只获取启用的）
final fixedEventListProvider = FutureProvider<List<FixedEventTemplate>>((ref) async {
  final repo = FixedEventRepository.instance;
  return repo.getEnabled();
});

/// 固定事件模板管理 Notifier
class FixedEventNotifier extends StateNotifier<List<FixedEventTemplate>> {
  final FixedEventRepository _repo = FixedEventRepository.instance;
  final Ref _ref;

  FixedEventNotifier(this._ref) : super([]);

  /// 加载所有模板（包括禁用的）
  Future<void> loadAll() async {
    state = await _repo.getAll();
    _ref.invalidate(fixedEventListProvider);
  }

  /// 新增模板
  Future<void> add(FixedEventTemplate template) async {
    await _repo.insert(template);
    await loadAll();
  }

  /// 更新模板
  Future<void> update(FixedEventTemplate template) async {
    await _repo.update(template);
    await loadAll();
  }

  /// 删除模板
  Future<void> delete(String id) async {
    await _repo.delete(id);
    await loadAll();
  }

  /// 重新排序
  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = [...state];
    if (oldIndex < newIndex) newIndex -= 1;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    for (int i = 0; i < list.length; i++) {
      final updated = list[i].copyWith(sortOrder: i);
      await _repo.update(updated);
      list[i] = updated;
    }
    state = list;
    _ref.invalidate(fixedEventListProvider);
  }
}

/// 固定事件模板管理 Provider
final fixedEventNotifierProvider =
    StateNotifierProvider<FixedEventNotifier, List<FixedEventTemplate>>((ref) {
  return FixedEventNotifier(ref);
});
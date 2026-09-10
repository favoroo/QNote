import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';

final shortcutListProvider = FutureProvider<List<ShortcutConfig>>((ref) async {
  final repo = ConfigRepository.instance;
  return repo.getShortcutConfigs();
});

class ShortcutListNotifier extends StateNotifier<List<ShortcutConfig>> {
  final ConfigRepository _repo = ConfigRepository.instance;
  final Ref _ref;

  ShortcutListNotifier(this._ref) : super([]);

  Future<void> load() async {
    state = await _repo.getShortcutConfigs();
    _ref.invalidate(shortcutListProvider);
  }

  Future<void> add(ShortcutConfig config) async {
    await _repo.insertShortcutConfig(config);
    await load();
  }

  Future<void> update(ShortcutConfig config) async {
    await _repo.updateShortcutConfig(config);
    await load();
  }

  Future<void> delete(String id) async {
    await _repo.deleteShortcutConfig(id);
    await load();
  }

  Future<void> restoreDefaults() async {
    await _repo.restoreDefaultShortcutConfigs();
    await load();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = [...state];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    for (int i = 0; i < list.length; i++) {
      final updated = list[i].copyWith(sortOrder: i);
      await _repo.updateShortcutConfig(updated);
      list[i] = updated;
    }
    state = list;
    _ref.invalidate(shortcutListProvider);
  }
}

final shortcutListNotifierProvider =
    StateNotifierProvider<ShortcutListNotifier, List<ShortcutConfig>>((ref) {
  return ShortcutListNotifier(ref);
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/weight_record.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:uuid/uuid.dart';

final userProfileProvider = FutureProvider<UserProfile?>((ref) async {
  final repo = ConfigRepository.instance;
  return repo.getUserProfile();
});

class UserProfileNotifier extends StateNotifier<UserProfile?> {
  final ConfigRepository _repo = ConfigRepository.instance;
  final Ref? _ref;

  UserProfileNotifier([this._ref]) : super(null) {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path == '/settings/profile.json') {
        load();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    _ref?.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });
  }

  Future<void> load() async {
    state = await _repo.getUserProfile();
    _ref?.invalidate(userProfileProvider);
  }

  Future<void> save(UserProfile profile) async {
    await _repo.saveUserProfile(profile);
    state = profile;
  }

  Future<void> addWeightRecord(double weight, {DateTime? time}) async {
    final profile = state ?? UserProfile(
      id: '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final record = WeightRecord(
      id: const Uuid().v4(),
      weight: weight,
      time: time ?? DateTime.now(),
    );
    final updated = profile.copyWith(
      weightHistory: [...profile.weightHistory, record],
    );
    await save(updated);
  }

  Future<void> deleteWeightRecord(String recordId) async {
    final profile = state;
    if (profile == null) return;
    final updated = profile.copyWith(
      weightHistory: profile.weightHistory.where((r) => r.id != recordId).toList(),
    );
    await save(updated);
  }
}

final userProfileNotifierProvider =
    StateNotifierProvider<UserProfileNotifier, UserProfile?>((ref) {
  return UserProfileNotifier(ref);
});

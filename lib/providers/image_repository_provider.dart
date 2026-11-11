import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/storage/image_repository.dart';

/// 图片仓库单例。
///
/// UI 层统一从这里取，避免组件内直接 `ImageRepository()`：
/// 单测可以 override 成假实现，也不需要每个组件自己维护实例。
final imageRepositoryProvider = Provider<ImageRepository>((ref) {
  return ImageRepository();
});

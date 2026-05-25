import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final canGoBackProvider = StateProvider<bool>((ref) => true);
final isDrawerOpenProvider = StateProvider<bool>((ref) => false);
final isAnyOverlayOpenProvider = StateProvider<bool>((ref) => false);

class BackHandler {
  static void setup(WidgetRef ref) {
    SystemChannels.navigation.setMethodCallHandler((call) async {
      if (call.method == 'popRoute') {
        final isDrawerOpen = ref.read(isDrawerOpenProvider);
        final isOverlayOpen = ref.read(isAnyOverlayOpenProvider);

        if (isDrawerOpen) {
          ref.read(isDrawerOpenProvider.notifier).state = false;
          return true;
        }
        if (isOverlayOpen) {
          ref.read(isAnyOverlayOpenProvider.notifier).state = false;
          return true;
        }
        return false;
      }
      return false;
    });
  }
}

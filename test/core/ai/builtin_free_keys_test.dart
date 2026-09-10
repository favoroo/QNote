import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';

void main() {
  group('BuiltinFreeKeys & FreeModelKeyManager Tests', () {
    test('4个内置密钥解密后与预期一致且不为空', () {
      final keys = BuiltinFreeKeys.getDecryptedKeys();
      expect(keys.length, equals(4));

      expect(keys[0], equals('sk-6yNu82SrnSc8nA5c3j1oFScGII7SxtNi'));
      expect(keys[1], equals('sk-IWpKaapIDrNvFpzkuXV16s4TWw4xCN28'));
      expect(keys[2], equals('sk-uo37IQgAueHyylHrrY57eouDYrsrBvg3'));
      expect(keys[3], equals('sk-Z76tPV1WnunUP7I1ZWbtRouHrlqKSpsW'));

      for (final k in keys) {
        expect(k.startsWith('sk-'), isTrue);
        expect(k.length, equals(35));
      }
    });

    test('FreeModelKeyManager 顺位轮询 Round-Robin 正常工作', () {
      final manager = FreeModelKeyManager.instance;
      final k1 = manager.acquireNextKey();
      final k2 = manager.acquireNextKey();
      final k3 = manager.acquireNextKey();
      final k4 = manager.acquireNextKey();
      final k5 = manager.acquireNextKey();

      expect({k1, k2, k3, k4}.length, equals(4));
      expect(k5, equals(k1)); // 循环回第 1 个
    });

    test('FreeModelKeyManager 限速自动切 Key 故障转移', () {
      final manager = FreeModelKeyManager.instance;
      final current = manager.acquireNextKey();
      final nextKey = manager.rotateKeyOnFailure(current);

      expect(nextKey, isNot(equals(current)));
      expect(nextKey.startsWith('sk-'), isTrue);
    });
  });
}

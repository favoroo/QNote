import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/recent_model_store.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const a = AiModelRef(providerId: 'p1', modelName: 'gpt-5.4');
  const b = AiModelRef(providerId: 'p2', modelName: 'glm-4.6');
  const c = AiModelRef(providerId: 'g3', modelName: AiModelRef.groupMarker);

  test('记录后最新在前，并能往返解析', () async {
    final store = RecentModelStore.instance;
    await store.record(a);
    await store.record(b);

    final loaded = await store.load();
    expect(loaded, [b, a]);
  });

  test('重复记录提到最前而不是重复占位', () async {
    final store = RecentModelStore.instance;
    await store.record(a);
    await store.record(b);
    await store.record(a);

    expect(await store.load(), [a, b]);
  });

  test('超过上限时丢弃最旧的', () async {
    final store = RecentModelStore.instance;
    for (var i = 0; i < RecentModelStore.maxEntries + 2; i++) {
      await store.record(AiModelRef(providerId: 'p$i', modelName: 'm$i'));
    }

    final loaded = await store.load();
    expect(loaded, hasLength(RecentModelStore.maxEntries));
    // 最新的在最前，最旧的两条已被挤出
    expect(loaded.first.modelName, 'm${RecentModelStore.maxEntries + 1}');
    expect(loaded.map((r) => r.modelName), isNot(contains('m0')));
  });

  test('路由组引用同样可存取', () async {
    final store = RecentModelStore.instance;
    await store.record(c);

    final loaded = await store.load();
    expect(loaded.single.isRouteGroup, isTrue);
    expect(loaded.single.providerId, 'g3');
  });

  test('损坏的存储内容被跳过，不影响其余条目', () async {
    SharedPreferences.setMockInitialValues({
      RecentModelStore.prefsKey: <String>['坏数据', a.encode()],
    });

    expect(await RecentModelStore.instance.load(), [a]);
  });

  test('清空后读出空列表', () async {
    final store = RecentModelStore.instance;
    await store.record(a);
    await store.clear();

    expect(await store.load(), isEmpty);
  });
}

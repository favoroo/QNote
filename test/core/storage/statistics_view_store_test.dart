import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/storage/statistics_view_store.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('没有历史记录时返回 null', () async {
    expect(await StatisticsViewStore.loadLastTab(), isNull);
  });

  test('保存后能读回同一分类', () async {
    await StatisticsViewStore.saveLastTab(StatTab.finance);
    expect(await StatisticsViewStore.loadLastTab(), StatTab.finance);
  });

  test('再次保存会覆盖上一次的分类', () async {
    await StatisticsViewStore.saveLastTab(StatTab.diet);
    await StatisticsViewStore.saveLastTab(StatTab.screenTime);
    expect(await StatisticsViewStore.loadLastTab(), StatTab.screenTime);
  });

  test('非法值回退为 null，由页面回落到默认分类', () async {
    SharedPreferences.setMockInitialValues({StatisticsViewStore.lastTabKey: 'unknown_tab'});
    expect(await StatisticsViewStore.loadLastTab(), isNull);
  });
}

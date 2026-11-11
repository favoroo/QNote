import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/config/ai_vendors.dart';
import 'package:qnote_flutter/core/utils/vendor_filter.dart';

void main() {
  group('关键词匹配', () {
    test('空关键词命中全部', () {
      expect(filterVendors(aiProviders).length, aiProviders.length);
      expect(filterVendors(aiProviders, query: '   ').length, aiProviders.length);
    });

    test('按名称、分组说明与地址都能搜到', () {
      expect(filterVendors(aiProviders, query: 'deepseek').map((v) => v.id), contains('deepseek'));
      // 中文名与一行说明也参与匹配，用户搜「通义」不该落空
      expect(filterVendors(aiProviders, query: '通义').map((v) => v.id), contains('qwen'));
      expect(filterVendors(aiProviders, query: 'dashscope').map((v) => v.id), contains('qwen'));
    });

    test('按种子模型名能搜到厂商', () {
      final hits = filterVendors(aiProviders, query: 'gemini-3.5-flash').map((v) => v.id);
      expect(hits, contains('gemini'));
    });

    test('多个片段要求全部命中', () {
      expect(filterVendors(aiProviders, query: 'qwen 通义').map((v) => v.id), contains('qwen'));
      // 只要有一个片段没人命中就返回空，避免「多打一个词反而更宽」
      expect(filterVendors(aiProviders, query: 'qwen 不存在的词'), isEmpty);
    });

    test('大小写不敏感', () {
      expect(filterVendors(aiProviders, query: 'OPENAI').map((v) => v.id), contains('openai'));
    });

    test('无匹配返回空列表', () {
      expect(filterVendors(aiProviders, query: '不存在的厂商xyz'), isEmpty);
    });
  });

  group('分组过滤', () {
    test('只返回该分组的厂商', () {
      final locals = filterVendors(aiProviders, category: VendorCategory.local);
      expect(locals, isNotEmpty);
      expect(locals.every((v) => v.category == VendorCategory.local), isTrue);
    });

    test('分组与关键词可叠加', () {
      final result = filterVendors(aiProviders, category: VendorCategory.cn, query: 'deepseek');
      expect(result.map((v) => v.id), contains('deepseek'));
      expect(result.every((v) => v.category == VendorCategory.cn), isTrue);
    });
  });

  group('分组归类', () {
    test('分组顺序固定为枚举顺序，空分组不出现', () {
      final grouped = groupVendors(filterVendors(aiProviders, category: VendorCategory.local));
      expect(grouped.keys.toList(), [VendorCategory.local]);
    });

    test('全部厂商都能归入某个分组，数量不丢', () {
      final grouped = groupVendors(aiProviders);
      final total = grouped.values.fold<int>(0, (sum, items) => sum + items.length);
      expect(total, aiProviders.length);
      expect(grouped.containsKey(VendorCategory.custom), isTrue);
    });
  });

  group('端点声明', () {
    test('regionFor 忽略末尾斜杠，老条目的 GLM 地址也能认出来', () {
      final zhipu = getProviderById('zhipu')!;
      // 目录里默认地址带尾斜杠，而 region 声明不带，两者必须被视为同一套端点
      expect(zhipu.regionFor('https://open.bigmodel.cn/api/paas/v4/')?.id, 'api');
      expect(zhipu.regionFor('https://open.bigmodel.cn/api/coding/paas/v4')?.id, 'coding');
      expect(zhipu.regionFor('https://example.com/v1'), isNull);
    });

    test('默认地址一定等于某个已声明的端点，否则选择器会显示成「都没选」', () {
      for (final spec in aiProviders.where((s) => s.regions.isNotEmpty)) {
        expect(spec.regionFor(spec.defaultBaseUrl), isNotNull, reason: '${spec.id} 的 defaultBaseUrl 不在 regions 里');
      }
    });
  });
}

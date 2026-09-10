import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/version_utils.dart';

void main() {
  group('parseVersion', () {
    test('解析标准三段版本号', () {
      expect(parseVersion('1.2.0'), <int>[1, 2, 0]);
    });

    test('忽略 v 前缀', () {
      expect(parseVersion('v1.2.0'), <int>[1, 2, 0]);
    });

    test('忽略 build 号', () {
      expect(parseVersion('1.2.0+5'), <int>[1, 2, 0]);
    });

    test('忽略预发布后缀', () {
      expect(parseVersion('1.2.0-beta.1'), <int>[1, 2, 0]);
    });

    test('非数字分段按 0 处理', () {
      expect(parseVersion('1.x.0'), <int>[1, 0, 0]);
    });

    test('空字符串退化为单个 0', () {
      expect(parseVersion(''), <int>[0]);
    });
  });

  group('isVersionNewer', () {
    test('主版本号更新', () {
      expect(isVersionNewer(candidate: 'v2.0.0', current: '1.9.9'), isTrue);
    });

    test('次版本号更新', () {
      expect(isVersionNewer(candidate: '1.1.0', current: '1.0.9'), isTrue);
    });

    test('修订号更新', () {
      expect(isVersionNewer(candidate: '1.0.1', current: '1.0.0'), isTrue);
    });

    test('版本号相同不算更新', () {
      expect(isVersionNewer(candidate: 'v1.0.0', current: '1.0.0'), isFalse);
    });

    test('版本更旧不算更新', () {
      expect(isVersionNewer(candidate: '1.0.0', current: '1.0.1'), isFalse);
    });

    test('位数不同时缺失位补 0 比较', () {
      expect(isVersionNewer(candidate: '1.2', current: '1.2.0'), isFalse);
      expect(isVersionNewer(candidate: '1.2.1', current: '1.2'), isTrue);
    });

    test('带 build 号时只比较版本主干', () {
      expect(isVersionNewer(candidate: '1.0.0+2', current: '1.0.0+1'), isFalse);
    });
  });

  group('normalizeVersion', () {
    test('去掉前缀与 build 号', () {
      expect(normalizeVersion('v1.2.0+5'), '1.2.0');
    });

    test('保留全部版本分段', () {
      expect(normalizeVersion('2.0.1'), '2.0.1');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/user_profile.dart';

void main() {
  group('UserProfile custom fields tests', () {
    test('should survive roundtrip with custom fields', () {
      final now = DateTime(2026, 6, 28, 12, 0);
      final profile = UserProfile(
        id: 'user-1',
        nickname: '小明',
        otherInfo: '备注信息',
        customFields: {
          '工作': '程序员',
          '身体状况': '良好',
        },
        createdAt: now,
        updatedAt: now,
      );

      final map = profile.toMap();
      final restored = UserProfile.fromMap(map);

      expect(restored.id, profile.id);
      expect(restored.nickname, profile.nickname);
      expect(restored.otherInfo, profile.otherInfo);
      expect(restored.customFields, isNotNull);
      expect(restored.customFields['工作'], '程序员');
      expect(restored.customFields['身体状况'], '良好');
      expect(restored.customFields.length, 2);
    });

    test('should handle empty custom fields roundtrip', () {
      final now = DateTime(2026, 6, 28, 12, 0);
      final profile = UserProfile(
        id: 'user-2',
        nickname: '小红',
        createdAt: now,
        updatedAt: now,
      );

      final map = profile.toMap();
      final restored = UserProfile.fromMap(map);

      expect(restored.customFields, isEmpty);
    });

    test('copyWith should update custom fields', () {
      final now = DateTime(2026, 6, 28, 12, 0);
      final profile = UserProfile(
        id: 'user-3',
        nickname: '小刚',
        customFields: {
          '工作': '设计师',
        },
        createdAt: now,
        updatedAt: now,
      );

      final updated = profile.copyWith(
        customFields: {
          '工作': '产品经理',
          '兴趣': '跑步',
        },
      );

      expect(updated.customFields['工作'], '产品经理');
      expect(updated.customFields['兴趣'], '跑步');
      expect(updated.customFields.length, 2);
      expect(profile.customFields['工作'], '设计师'); // Original untouched
    });
  });
}

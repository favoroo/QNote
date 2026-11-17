import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';

DiaryRecord _recordFor(String tag) {
  final time = DateTime(2026, 11, 15, 12, 0);
  return DiaryRecord(
    id: 'tag_$tag',
    title: tag,
    time: time,
    tags: [tag],
    displayTag: tag,
    content: '内容',
    tagEntries: [TagEntry(id: tag, name: tag, fields: const {})],
    createdAt: time,
    updatedAt: time,
  );
}

Widget _wrap(DiaryRecord record, Brightness brightness) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness, useMaterial3: true),
    home: Scaffold(
      body: ListView(children: [DiaryItem(record: record)]),
    ),
  );
}

/// 取标签名胶囊的底色：从文字往上找到第一层带淡彩底 + 圆角的 Container。
Color? _pillColor(WidgetTester tester, String tag) {
  final textFinder = find.text(tag);
  if (textFinder.evaluate().isEmpty) {
    return null;
  }
  Color? found;
  tester.widgetList<Container>(find.byType(Container)).forEach((container) {
    if (found != null) {
      return;
    }
    final decoration = container.decoration;
    if (decoration is! BoxDecoration || decoration.borderRadius == null) {
      return;
    }
    final child = container.child;
    if (child is! Row) {
      return;
    }
    final hasTagText = child.children.any((w) => w is Text && w.data == tag);
    if (hasTagText) {
      found = decoration.color;
    }
  });
  return found;
}

void main() {
  group('时间线标签胶囊配色', () {
    for (final brightness in Brightness.values) {
      testWidgets('$brightness 下每个内置标签的胶囊底色都取自对应色板', (tester) async {
        for (final tag in TagColors.knownTags) {
          await tester.pumpWidget(_wrap(_recordFor(tag), brightness));
          await tester.pump();

          expect(tester.takeException(), isNull);
          final pill = _pillColor(tester, tag);
          expect(pill, isNotNull, reason: '「$tag」胶囊未渲染');

          // 胶囊底色 = 标签色 14% 透明度，反解出实际用的标签色
          final expected = TagColors.of(tag, brightness).withValues(alpha: 0.14);
          expect(pill!.toARGB32(), expected.toARGB32(), reason: '「$tag」胶囊底色与色板不一致');
        }
      });
    }

    testWidgets('浅色主题下活动 / 健康 / 运动健康三支胶囊颜色互不相同', (tester) async {
      final seen = <int>{};
      for (final tag in ['活动', '健康', '运动健康']) {
        await tester.pumpWidget(_wrap(_recordFor(tag), Brightness.light));
        await tester.pump();
        final pill = _pillColor(tester, tag);
        expect(pill, isNotNull);
        seen.add(pill!.toARGB32());
      }
      expect(seen.length, 3, reason: '三类标签仍在共用同一个色值');
    });

    testWidgets('自定义标签回落到中性灰胶囊', (tester) async {
      const custom = '我的自定义标签';
      await tester.pumpWidget(_wrap(_recordFor(custom), Brightness.light));
      await tester.pump();

      final pill = _pillColor(tester, custom);
      expect(pill, isNotNull);
      expect(pill!.toARGB32(), TagColors.defaultTag(Brightness.light).withValues(alpha: 0.14).toARGB32());
    });

    testWidgets('标签原色作为图标（AI 提取按钮）时达到图形级对比度', (tester) async {
      // 卡片右下角的提取按钮直接用标签原色画图标，没有淡底压深兜底
      for (final brightness in Brightness.values) {
        for (final tag in TagColors.knownTags) {
          final color = TagColors.of(tag, brightness);
          final surface = brightness == Brightness.dark ? const Color(0xFF1A1D24) : Colors.white;
          expect(
            AppContrast.contrastRatio(color, surface),
            greaterThanOrEqualTo(AppContrast.minimumGraphicRatio),
            reason: '$brightness 下「$tag」原色作图标不可读',
          );
        }
      }
    });
  });
}

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

/// 打开统计页/明细列表用的只读记录详情弹层，可左右滑动查看相邻记录。
Future<void> showStatRecordSheet(
  BuildContext context, {
  required List<DiaryRecord> records,
  required int initialIndex,
}) {
  if (records.isEmpty) return Future.value();
  final index = initialIndex.clamp(0, records.length - 1);
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: AppTheme.sheetAnimationStyle,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => StatRecordDetailSheet(records: records, initialIndex: index),
  );
}

/// 只读记录详情弹层：PageView 左右滑动切换，右上「编辑」跳编辑页。
class StatRecordDetailSheet extends StatefulWidget {
  final List<DiaryRecord> records;
  final int initialIndex;

  const StatRecordDetailSheet({super.key, required this.records, required this.initialIndex});

  @override
  State<StatRecordDetailSheet> createState() => _StatRecordDetailSheetState();
}

class _StatRecordDetailSheetState extends State<StatRecordDetailSheet> {
  late final PageController _pageController;
  late int _currentIndex;
  late final List<DiaryRecord> _records;
  final Map<String, List<Object>> _heroTagsByRecord = {};

  List<Object> _heroTagsFor(DiaryRecord record) {
    final tags = _heroTagsByRecord.putIfAbsent(record.id, () => <Object>[]);
    while (tags.length < record.photos.length) {
      tags.add(Object());
    }
    if (tags.length > record.photos.length) {
      tags.removeRange(record.photos.length, tags.length);
    }
    return tags;
  }

  @override
  void initState() {
    super.initState();
    _records = List.of(widget.records);
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _edit(DiaryRecord record) async {
    await context.push('/diary/editor', extra: record);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                  Expanded(
                    child: Text(
                      '记录详情 (${_currentIndex + 1} / ${_records.length})',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(_records[_currentIndex])),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _records.length,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemBuilder: (context, index) => _buildRecord(context, _records[index], theme, colorScheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecord(BuildContext context, DiaryRecord record, ThemeData theme, ColorScheme colorScheme) {
    final tagColor = TagColors.of(record.displayTag);
    final tagInk = AppContrast.inkOnTint(tagColor, colorScheme.surface, 0.12);
    final fields = _recordFields(record);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _pill(context, Icons.access_time, _formatTimeRange(record), tagColor, tagInk),
              if (record.displayTag.isNotEmpty) ...[
                const SizedBox(width: 8),
                _pill(context, Icons.sell_outlined, record.displayTag, tagColor, tagInk),
              ],
            ],
          ),
          if (fields.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(theme, colorScheme, '记录数据'),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppRadius.medium),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in fields) ...[
                    if (f != fields.first) const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(
                            f.$1,
                            style: TextStyle(fontSize: AppTypography.bodySmall, color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            f.$2,
                            style: TextStyle(
                              fontSize: AppTypography.body,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (record.content.trim().isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(theme, colorScheme, '正文'),
            const SizedBox(height: 8),
            Text(
              record.content.trim(),
              style: TextStyle(fontSize: AppTypography.body, height: 1.5, color: colorScheme.onSurface),
            ),
          ],
          if (record.photos.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle(theme, colorScheme, '图片'),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final heroTags = _heroTagsFor(record);
                final reduce = AppMotion.reduce(context);
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < record.photos.length; i++)
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          AppMotion.galleryRoute(
                            FullScreenImageGallery(
                              images: record.photos,
                              initialIndex: i,
                              heroTags: List<Object?>.from(heroTags),
                            ),
                          ),
                        ),
                        child: HeroMode(
                          enabled: !reduce,
                          child: Hero(
                            tag: heroTags[i],
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.small),
                              child: UnifiedImage(
                                imagePath: record.photos[i],
                                width: 84,
                                height: 84,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, ColorScheme colorScheme, String text) {
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.onSurfaceVariant),
    );
  }

  Widget _pill(BuildContext context, IconData icon, String text, Color color, Color ink) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: ink),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(fontSize: AppTypography.label, fontWeight: FontWeight.bold, color: ink),
          ),
        ],
      ),
    );
  }

  String _formatTimeRange(DiaryRecord record) {
    final start = record.startTime ?? record.time;
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(start);
    if (record.endTime != null) {
      return '$dateStr - ${DateFormat('HH:mm').format(record.endTime!)}';
    }
    return dateStr;
  }

  /// 取出该记录饮食/记账标签的结构化字段，转成「中文标签 → 值」列表。
  ///
  /// 逐条标签处理（而非合并成一个 Map），以便按标签语义给出不同文案：
  /// 饮食的 calories 是「热量(kcal)」、消费的 amount 才是「金额(¥)」。
  List<(String, String)> _recordFields(DiaryRecord record) {
    final entries = record.tagEntries
        .where((e) => e.id == 'diet' || e.id == 'consumption' || e.name == '饮食' || e.name == '记账')
        .toList();

    final result = <(String, String)>[];
    void addFields(Map<String, dynamic> fields, {required bool isDiet}) {
      for (final entry in fields.entries) {
        final key = entry.key;
        if (key.startsWith('_') && key != '_category') continue;
        // 饮食的份量只作为估算依据，不面向用户展示
        if (isDiet && key == 'amount') continue;
        final value = _formatFieldValue(key, entry.value, isDiet: isDiet);
        if (value.isEmpty) continue;
        result.add((_fieldLabel(key, isDiet: isDiet), value));
      }
    }

    if (entries.isEmpty) {
      final bs = record.bodyState;
      if (bs != null) addFields(bs, isDiet: record.displayTag == '饮食' || record.tags.contains('饮食'));
    } else {
      for (final e in entries) {
        addFields(e.fields, isDiet: e.id == 'diet' || e.name == '饮食');
      }
    }
    return result;
  }

  String _fieldLabel(String key, {required bool isDiet}) {
    if (isDiet) {
      switch (key) {
        case 'item':
          return '食物';
        case 'calories':
        case 'cal':
          return '热量';
        case 'rating':
        case 'health':
        case '评价':
          return '评价';
        case 'type':
        case '种类':
          return '种类';
      }
    }
    const map = <String, String>{
      'type': '类型',
      '支出类型': '类型',
      'incomeType': '收入类型',
      '收入类型': '收入类型',
      'amount': '金额',
      '金额': '金额',
      'rating': '评价',
      'health': '评价',
      '评价': '评价',
      'item': '种类',
      '种类': '种类',
      '类别': '类别',
      '_category': '收支',
      'category': '收支',
    };
    return map[key] ?? key;
  }

  String _formatFieldValue(String key, dynamic raw, {required bool isDiet}) {
    if (raw == null) return '';
    final text = raw.toString().trim();
    if (text.isEmpty) return '';
    if (isDiet) {
      if (key == 'calories' || key == 'cal') {
        if (!text.toLowerCase().contains('kcal') && !text.contains('卡')) return '${text}kcal';
        return text;
      }
    }
    if (key == '_category' || key == 'category') {
      final lower = text.toLowerCase();
      if (lower == 'expense' || lower == '支出') return '支出';
      if (lower == 'income' || lower == '收入') return '收入';
    }
    if (key == 'amount' || key == '金额' || key == '钱数') {
      final num = double.tryParse(text);
      if (num != null) {
        final body = num == num.roundToDouble() ? num.toStringAsFixed(0) : num.toStringAsFixed(2);
        return '¥$body';
      }
    }
    return text;
  }
}

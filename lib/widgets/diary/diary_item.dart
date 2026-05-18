import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

class DiaryItem extends StatelessWidget {
  final DiaryRecord record;
  final VoidCallback? onTap;
  final void Function(DiaryRecord)? onEdit;
  final void Function(DiaryRecord)? onDelete;

  const DiaryItem({
    super.key,
    required this.record,
    this.onTap,
    this.onEdit,
    this.onDelete,
  });

  static const _tagIcons = <String, IconData>{
    '睡眠': Icons.nightlight_round,
    '饮食': Icons.restaurant,
    '活动': Icons.directions_run,
    '记账': Icons.account_balance_wallet,
  };

  static const _defaultIcon = Icons.description_outlined;

  static const _tagColors = <String, Color>{
    '睡眠': Color(0xFF6366F1),
    '饮食': Color(0xFFF59E0B),
    '活动': Color(0xFF10B981),
    '记账': Color(0xFFEF4444),
  };

  static const _defaultColor = Color(0xFF6B7280);

  IconData _tagIcon(String displayTag) => _tagIcons[displayTag] ?? _defaultIcon;

  Color _tagColor(String displayTag) => _tagColors[displayTag] ?? _defaultColor;

  String _formatTimeRange() {
    final start = record.startTime ?? record.time;
    final startStr = DateFormat.Hm().format(start);

    if (record.endTime != null) {
      final endStr = DateFormat.Hm().format(record.endTime!);
      return '$startStr - $endStr';
    }
    return startStr;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = _tagColor(record.displayTag);
    final actionMenuKey = GlobalKey();

    // Parse content fields if they are in JSON or if bodyState exists
    Map<String, dynamic> fields = {};
    if (record.bodyState != null) {
      fields = record.bodyState!;
    } else {
      // Fallback: try to parse content as "Key: Value, Key2: Value2"
      // But for now, just use content as is if no bodyState
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline Column
          SizedBox(
            width: 48,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                // Icon Circle
                Positioned(
                  top: 12,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: tagColor.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _tagIcon(record.displayTag),
                          size: 14,
                          color: tagColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Content Card
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 16, right: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: Time Range + Tag + More
                  Row(
                    children: [
                      // Time Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.access_time,
                              size: 12,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatTimeRangeWithDate(),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Tag
                      if (record.displayTag.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: tagColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            record.displayTag,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: tagColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      const Spacer(),
                      // More Button
                      IconButton(
                        key: actionMenuKey,
                        icon: Icon(
                          Icons.more_vert,
                          size: 18,
                          color: theme.colorScheme.outline,
                        ),
                        onPressed: () {
                          ActionMenu.show(
                            context: context,
                            key: actionMenuKey,
                            items: [
                              ActionMenuItem(
                                icon: Icons.edit,
                                label: '编辑',
                                onTap: () => onEdit?.call(record),
                              ),
                              ActionMenuItem(
                                icon: Icons.delete_outline,
                                label: '删除',
                                isDestructive: true,
                                onTap: () => onDelete?.call(record),
                              ),
                            ],
                          );
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Fields (from bodyState)
                  if (fields.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        children: fields.entries.map((entry) {
                          if (entry.value == null || entry.value.toString().isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${entry.key}：',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    entry.value.toString(),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  // Content (Remark)
                  if (record.content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '备注：',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              record.content,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Photos
                  if (record.photos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: record.photos.map((photo) {
                          return UnifiedImage(
                            imagePath: photo,
                            width: 60,
                            height: 60,
                            borderRadius: BorderRadius.circular(8),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimeRangeWithDate() {
    final start = record.startTime ?? record.time;
    final dateStr = DateFormat('MM-dd').format(start);
    final startStr = DateFormat.Hm().format(start);

    if (record.endTime != null) {
      final endStr = DateFormat.Hm().format(record.endTime!);
      return '$dateStr $startStr → $endStr';
    }
    return '$dateStr $startStr';
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';

class DiaryItem extends StatelessWidget {
  final DiaryRecord record;
  final VoidCallback? onTap;
  final void Function(DiaryRecord)? onEdit;
  final void Function(DiaryRecord)? onDelete;
  final VoidCallback? onAiExtract;
  final VoidCallback? onAiExtractLongPress;
  final bool isExtracting;
  final VoidCallback? onUndo;
  final bool isUndoable;
  final Animation<double>? undoAnimation;

  const DiaryItem({
    super.key,
    required this.record,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.onAiExtract,
    this.onAiExtractLongPress,
    this.isExtracting = false,
    this.onUndo,
    this.isUndoable = false,
    this.undoAnimation,
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


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = _tagColor(record.displayTag);
    final actionMenuKey = GlobalKey();

    String formatDouble(dynamic val) {
      if (val == null) return '';
      final d = double.tryParse(val.toString());
      if (d == null) return val.toString();
      if (d == d.toInt()) {
        return d.toInt().toString();
      }
      return d.toString();
    }

    final additionalTags = <String>[];
    if (record.bodyState != null) {
      final bs = record.bodyState!;
      
      dynamic getVal(List<String> keys) {
        for (final k in keys) {
          if (bs.containsKey(k)) return bs[k];
          final lowerK = k.toLowerCase();
          for (final entry in bs.entries) {
            if (entry.key.toLowerCase() == lowerK) {
              return entry.value;
            }
          }
        }
        return null;
      }

      if (record.displayTag == '睡眠') {
        final durationVal = getVal(['duration', '时长', '睡眠时长']);
        if (durationVal != null) {
          final formatted = formatDouble(durationVal);
          if (formatted.isNotEmpty) {
            additionalTags.add('$formatted小时');
          }
        }
      } else if (record.displayTag == '记账') {
        final categoryVal = getVal(['_category', 'category', '收支类型', '收支']);
        String? direction;
        if (categoryVal != null) {
          final catStr = categoryVal.toString().toLowerCase();
          if (catStr == 'expense' || catStr == '支出') {
            direction = '支出';
          } else if (catStr == 'income' || catStr == '收入') {
            direction = '收入';
          }
        }
        
        if (direction == null) {
          if (bs.containsKey('type') || bs.containsKey('支出类型')) {
            direction = '支出';
          } else if (bs.containsKey('incomeType') || bs.containsKey('收入类型')) {
            direction = '收入';
          }
        }
        
        if (direction != null) {
          additionalTags.add(direction);
        }

        final typeVal = getVal(['type', 'incomeType', '支出类型', '收入类型', '分类', '类型']);
        if (typeVal != null && typeVal.toString().isNotEmpty) {
          additionalTags.add(typeVal.toString());
        }

        final amountVal = getVal(['amount', '金额', '钱数']);
        if (amountVal != null) {
          final formatted = formatDouble(amountVal);
          if (formatted.isNotEmpty) {
            additionalTags.add('$formatted元');
          }
        }
      }
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
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16, right: 12),
              child: GestureDetector(
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: AnimatedGradientBorder(
                  isAnimating: isExtracting,
                  borderRadius: 16,
                  strokeWidth: 2,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isExtracting
                            ? Colors.transparent
                            : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                    // Main Content
                    Padding(
                      padding: const EdgeInsets.only(right: 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header: Time Range + Tag
                          Row(
                            children: [
                              // Expanded left side to wrap Time Pill and Tag to prevent overflow
                              Expanded(
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
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
                                    ...additionalTags.map((tagText) => Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: tagColor.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            tagText,
                                            style: theme.textTheme.labelSmall?.copyWith(
                                              color: tagColor,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        )),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Rich Content & Fields
                          _buildRichContent(context, record.content, record.bodyState, record.displayTag) ?? const SizedBox.shrink(),
                          // Photos
                          if (record.photos.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 24, top: 4),
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
                    // More Button (Top Right)
                    Positioned(
                      top: -6,
                      right: -14,
                      child: IconButton(
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
                    ),
                    // AI Extract Button (Bottom Right)
                    if (onAiExtract != null)
                      Positioned(
                        bottom: -4,
                        right: -6,
                        child: GestureDetector(
                          onTap: isUndoable ? onUndo : (isExtracting ? null : onAiExtract),
                          onLongPress: isUndoable ? null : (isExtracting ? null : onAiExtractLongPress),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: isUndoable
                                  ? theme.colorScheme.error.withValues(alpha: 0.08)
                                  : theme.colorScheme.primary.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: isUndoable
                                ? (undoAnimation != null
                                    ? AnimatedBuilder(
                                        animation: undoAnimation!,
                                        builder: (context, child) {
                                          return Stack(
                                            alignment: Alignment.center,
                                            children: [
                                              SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CustomPaint(
                                                  painter: _UndoCountdownPainter(
                                                    progress: undoAnimation!.value,
                                                    color: theme.colorScheme.error,
                                                  ),
                                                ),
                                              ),
                                              child!,
                                            ],
                                          );
                                        },
                                        child: Icon(
                                          Icons.undo,
                                          size: 12,
                                          color: theme.colorScheme.error,
                                        ),
                                      )
                                    : Icon(
                                        Icons.undo,
                                        size: 12,
                                        color: theme.colorScheme.error,
                                      ))
                                : isExtracting
                                    ? Center(
                                        child: SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.8,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      )
                                    : Icon(
                                        Icons.auto_awesome,
                                        size: 14,
                                        color: theme.colorScheme.primary.withValues(alpha: 0.8),
                                      ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
        ],
      ),
    );
  }

  Widget? _buildRichContent(BuildContext context, String? text, Map<String, dynamic>? bodyState, String? tag) {
    String cleanText = text ?? '';
    if (cleanText.isEmpty) return null;

    final theme = Theme.of(context);
    if (tag != null && tag.isNotEmpty && cleanText.startsWith('【$tag】')) {
      cleanText = cleanText.substring(tag.length + 2).trim();
    }

    if (cleanText.isEmpty) return null;

    final rawLines = cleanText.split('\n');
    final displayLines = <String>[];
    String remarkText = '';

    final isSpecialTag = tag == '睡眠' || tag == '记账';

    final keysToSkip = {
      'duration', 'quality', 'fallasleeptime', 'item', 'amount', 'type', 'incometype',
      'symptom', 'severity', 'notes', 'note', 'remark', 'remarks',
      '时长', '质量', '入睡时间', '项目', '金额', '类型', '支出类型', '收入类型', '症状', '严重程度', '备注', '种类', '睡眠质量'
    };

    String normalizeKey(String key) {
      return key.trim().toLowerCase().replaceAll(RegExp(r'[\s\(_\)（）\-:]+'), '');
    }

    for (final line in rawLines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      if (trimmedLine.startsWith('备注：')) {
        remarkText = trimmedLine.substring(3).trim();
        continue;
      } else if (trimmedLine.startsWith('备注:')) {
        remarkText = trimmedLine.substring(3).trim();
        continue;
      }

      if (isSpecialTag) {
        if (trimmedLine.contains(':') || trimmedLine.contains('：')) {
          continue;
        }
        displayLines.add(trimmedLine);
        continue;
      }

      if (!trimmedLine.contains(':') && !trimmedLine.contains('：')) {
        displayLines.add(trimmedLine);
        continue;
      }

      final regExp = RegExp(r'([^:：,，]+)([:：])\s*([^,，]+)([,，]?)');
      final matches = regExp.allMatches(trimmedLine);

      if (matches.isEmpty) {
        displayLines.add(trimmedLine);
        continue;
      }

      final remainingSegments = <String>[];
      int lastIndex = 0;

      for (final match in matches) {
        final key = match.group(1)?.trim() ?? '';
        final normKey = normalizeKey(key);
        final val = match.group(3)?.trim() ?? '';

        if (keysToSkip.contains(normKey)) {
          lastIndex = match.end;
          continue;
        }

        final colon = match.group(2) ?? '：';
        remainingSegments.add('$key$colon$val');
        lastIndex = match.end;
      }

      if (lastIndex < trimmedLine.length) {
        final suffix = trimmedLine.substring(lastIndex).trim().replaceAll(RegExp(r'^[，,]+|[，,]+$'), '');
        if (suffix.isNotEmpty && !keysToSkip.contains(normalizeKey(suffix))) {
          remainingSegments.add(suffix);
        }
      }

      if (remainingSegments.isNotEmpty) {
        displayLines.add(remainingSegments.join('，'));
      }
    }

    final elements = <Widget>[];

    for (final line in displayLines) {
      elements.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            line,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      );
    }

    if (remarkText.isNotEmpty) {
      elements.add(
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text.rich(
            TextSpan(
              children: [
                if (!isSpecialTag) ...[
                  TextSpan(
                    text: '备注',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                      fontSize: 13,
                      letterSpacing: -0.2,
                    ),
                  ),
                  TextSpan(
                    text: '：',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                TextSpan(
                  text: remarkText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            style: const TextStyle(height: 1.6),
          ),
        ),
      );
    }

    if (elements.isEmpty) return null;

    return Padding(
      padding: const EdgeInsets.only(left: 24, top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: elements,
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

class _UndoCountdownPainter extends CustomPainter {
  final double progress;
  final Color color;

  _UndoCountdownPainter({
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 4) / 2;

    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final sweepAngle = (1.0 - progress) * 2 * 3.141592653589793;
    if (sweepAngle > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -3.141592653589793 / 2,
        sweepAngle,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UndoCountdownPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

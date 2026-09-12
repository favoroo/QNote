import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';

class DiaryItem extends StatefulWidget {
  final DiaryRecord record;
  final VoidCallback? onTap;
  final void Function(DiaryRecord)? onEdit;
  final void Function(DiaryRecord)? onDelete;
  final VoidCallback? onAiExtract;
  final VoidCallback? onAiExtractLongPress;
  /// 「给小Q」引用该条记录（非 null 时操作菜单与卡片长按展示该入口）
  final void Function(DiaryRecord)? onQuoteToQ;
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
    this.onQuoteToQ,
    this.isExtracting = false,
    this.onUndo,
    this.isUndoable = false,
    this.undoAnimation,
  });

  @override
  State<DiaryItem> createState() => _DiaryItemState();
}

class _DiaryItemState extends State<DiaryItem> {
  final _actionMenuKey = GlobalKey();

  DiaryRecord get record => widget.record;
  VoidCallback? get onTap => widget.onTap;
  void Function(DiaryRecord)? get onEdit => widget.onEdit;
  void Function(DiaryRecord)? get onDelete => widget.onDelete;
  VoidCallback? get onAiExtract => widget.onAiExtract;
  VoidCallback? get onAiExtractLongPress => widget.onAiExtractLongPress;
  void Function(DiaryRecord)? get onQuoteToQ => widget.onQuoteToQ;
  bool get isExtracting => widget.isExtracting;
  VoidCallback? get onUndo => widget.onUndo;
  bool get isUndoable => widget.isUndoable;
  Animation<double>? get undoAnimation => widget.undoAnimation;

  /// 卡片操作菜单：more_vert 按钮与长按卡片共用；
  /// 配置了 onQuoteToQ 时追加「给小Q」引用入口
  void _showActionMenu() {
    ActionMenu.show(
      context: context,
      key: _actionMenuKey,
      items: [
        if (onQuoteToQ != null)
          ActionMenuItem(
            icon: Icons.smart_toy_rounded,
            label: '给小Q',
            onTap: () => onQuoteToQ?.call(record),
          ),
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
  }

  static const _tagIcons = <String, IconData>{
    '睡眠': Icons.nightlight_round,
    '饮食': Icons.restaurant,
    '活动': Icons.directions_run,
    '记账': Icons.account_balance_wallet,
  };

  static const _defaultIcon = Icons.description_outlined;

  static const _tagColors = TagColors.map;

  static const _defaultColor = TagColors.defaultTag;

  /// 正文与图片相对标签 pill 的左侧缩进，避免视觉上“凸出”在标签外
  static const _contentIndent = 4.0;

  IconData _tagIcon(String displayTag) => _tagIcons[displayTag] ?? _defaultIcon;

  Color _tagColor(String displayTag) => _tagColors[displayTag] ?? _defaultColor;

  String _formatDouble(dynamic val) {
    if (val == null) return '';
    final d = double.tryParse(val.toString());
    if (d == null) return val.toString();
    if (d == d.toInt()) return d.toInt().toString();
    return d.toString();
  }

  List<String> _buildAdditionalTags(TagEntry entry) {
    final tags = <String>[];
    final bs = entry.fields;
    final handledKeys = <String>{};

    if (entry.name == '睡眠') {
      final durationVal = _getVal(bs, ['duration', '时长', '睡眠时长']);
      if (durationVal != null) {
        final formatted = _formatDouble(durationVal);
        if (formatted.isNotEmpty) tags.add('$formatted小时');
      }
      handledKeys.addAll(['duration', '时长', '睡眠时长']);

      final qualityVal = _getVal(bs, ['quality', '质量', '睡眠质量']);
      if (qualityVal != null && qualityVal.toString().isNotEmpty) {
        tags.add(qualityVal.toString());
      }
      handledKeys.addAll(['quality', '质量', '睡眠质量']);

      // 不在卡片底部标签显示，已在顶部时间段中体现
      handledKeys.addAll(['fallAsleepTime', '入睡时间']);
    } else if (entry.name == '饮食') {
      final typeVal = _getVal(bs, ['type', 'item', '种类', '类别']);
      if (typeVal != null && typeVal.toString().isNotEmpty)
        tags.add(typeVal.toString());
      final ratingVal = _getVal(bs, ['rating', 'health', '评价']);
      if (ratingVal != null && ratingVal.toString().isNotEmpty)
        tags.add(ratingVal.toString());
      handledKeys.addAll([
        'type',
        'item',
        '种类',
        '类别',
        'rating',
        'health',
        '评价',
      ]);
    } else if (entry.name == '活动') {
      final typeVal = _getVal(bs, ['type', 'item', '项目', '类型']);
      if (typeVal != null && typeVal.toString().isNotEmpty)
        tags.add(typeVal.toString());
      final durationVal = _getVal(bs, ['duration', '时长']);
      if (durationVal != null) {
        final formatted = _formatDouble(durationVal);
        if (formatted.isNotEmpty) tags.add('$formatted小时');
      }
      handledKeys.addAll(['type', 'item', '项目', '类型', 'duration', '时长']);
    } else if (entry.name == '健康') {
      final symptomVal = _getVal(bs, ['symptom', '症状']);
      if (symptomVal != null) {
        if (symptomVal is List) {
          for (final s in symptomVal) {
            if (s.toString().isNotEmpty) tags.add(s.toString());
          }
        } else if (symptomVal.toString().isNotEmpty) {
          tags.add(symptomVal.toString());
        }
      }
      final severityVal = _getVal(bs, ['severity', '严重程度']);
      if (severityVal != null && severityVal.toString().isNotEmpty) {
        tags.add(severityVal.toString());
      }
      final medicationVal = _getVal(bs, ['medication', '用药']);
      if (medicationVal != null && medicationVal.toString().isNotEmpty) {
        tags.add('💊 ${medicationVal.toString()}');
      }
      handledKeys.addAll([
        'symptom',
        '症状',
        'severity',
        '严重程度',
        'medication',
        '用药',
      ]);
    } else if (entry.name == '记账') {
      final categoryVal = _getVal(bs, ['_category', 'category', '收支类型', '收支']);
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
      if (direction != null) tags.add(direction);
      final typeVal = _getVal(bs, [
        'type',
        'incomeType',
        '支出类型',
        '收入类型',
        '分类',
        '类型',
      ]);
      if (typeVal != null && typeVal.toString().isNotEmpty)
        tags.add(typeVal.toString());
      final amountVal = _getVal(bs, ['amount', '金额', '钱数']);
      if (amountVal != null) {
        final formatted = _formatDouble(amountVal);
        if (formatted.isNotEmpty) tags.add('$formatted元');
      }
      handledKeys.addAll([
        '_category',
        'category',
        '收支类型',
        '收支',
        'type',
        'incomeType',
        '支出类型',
        '收入类型',
        '分类',
        '类型',
        'amount',
        '金额',
        '钱数',
      ]);
    }

    for (final f in bs.entries) {
      if (f.key.startsWith('_')) continue;
      final normKey = f.key.trim().toLowerCase();
      if (handledKeys.contains(normKey)) continue;

      final label = _getFieldLabel(entry.name, f.key, bs);
      final normLabel = label.trim().toLowerCase();
      if (handledKeys.contains(normLabel)) continue;

      final val = _formatFieldValue(entry.name, f.key, f.value);
      if (val.isNotEmpty) {
        tags.add('$label: $val');
      }
    }

    return tags;
  }

  dynamic _getVal(Map<String, dynamic> bs, List<String> keys) {
    for (final k in keys) {
      if (bs.containsKey(k)) return bs[k];
      final lowerK = k.toLowerCase();
      for (final entry in bs.entries) {
        if (entry.key.toLowerCase() == lowerK) return entry.value;
      }
    }
    return null;
  }

  String _getFieldLabel(
    String tagName,
    String key,
    Map<String, dynamic> fields,
  ) {
    final lowerKey = key.trim().toLowerCase();
    switch (lowerKey) {
      case 'duration':
        return '时长';
      case 'quality':
        return '睡眠质量';
      case 'fallasleeptime':
        return '入睡时间';
      case 'item':
        if (tagName == '饮食') return '种类';
        if (tagName == '活动') return '类型';
        return '项目';
      case 'type':
        if (tagName == '饮食') return '种类';
        if (tagName == '活动') return '类型';
        if (tagName == '记账') {
          final isIncome =
              fields['_category'] == 'income' ||
              fields.containsKey('incomeType') ||
              fields.containsKey('收入类型');
          return isIncome ? '收入类型' : '支出类型';
        }
        return '类型';
      case 'rating':
        return '评价';
      case 'health':
        return '评价';
      case 'amount':
        if (tagName == '记账') return '金额';
        return '数量';
      case 'incometype':
        if (tagName == '记账') return '收入类型';
        return '类型';
      default:
        final translations = {
          'duration': '时长',
          'quality': '质量',
          'item': '项目',
          'type': '类型',
          'rating': '评价',
          'health': '评价',
          'amount': '数量',
          'price': '价格',
          'cost': '费用',
          'location': '地点',
          'note': '备注',
          'remark': '备注',
        };
        return translations[lowerKey] ?? key;
    }
  }

  String _formatFieldValue(String tagName, String key, dynamic value) {
    final valStr = _formatDouble(value);
    if (valStr.isEmpty) return '';
    final lowerKey = key.trim().toLowerCase();
    if (tagName == '睡眠' && lowerKey == 'duration') {
      if (!valStr.contains('小时') && !valStr.contains('h')) {
        return '$valStr小时';
      }
    }
    if (tagName == '记账' && lowerKey == 'amount') {
      if (!valStr.contains('元') &&
          !valStr.contains('￥') &&
          !valStr.contains(r'$')) {
        return '$valStr元';
      }
    }
    return valStr;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = _tagColor(record.displayTag);
    final hasMultipleTags = record.tagEntries.length > 1;

    return IntrinsicHeight(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 48,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
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
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16, right: 12),
            child: GestureDetector(
              onTap: onTap,
              // 长按卡片弹出操作菜单（与 more_vert 按钮共用，含「给小Q」引用入口）
              onLongPress: _showActionMenu,
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
                          : tagColor.withValues(alpha: 0.15),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: tagColor.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.01),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildHeader(theme, tagColor),
                              if (hasMultipleTags)
                                _buildMultiTagSections(theme)
                              else ...[
                                _buildTagAndFieldsRow(theme, tagColor),
                                _buildSingleTagContent(theme, tagColor),
                              ],
                              if (record.photos.isNotEmpty)
                                Builder(
                                  builder: (context) {
                                    final screenWidth = MediaQuery.of(
                                      context,
                                    ).size.width;
                                    final maxWidth =
                                        screenWidth - 132 - _contentIndent;
                                    final spacing = 6.0;
                                    final itemWidth =
                                        ((maxWidth - spacing * 2 - 2.0) / 3)
                                            .clamp(50.0, 70.0);
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        left: _contentIndent,
                                        top: 4,
                                      ),
                                      child: Wrap(
                                        spacing: spacing,
                                        runSpacing: spacing,
                                        children: record.photos.asMap().entries.map((entry) {
                                          final index = entry.key;
                                          final photo = entry.value;
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () {
                                              Navigator.of(context).push(
                                                MaterialPageRoute(
                                                  builder: (_) => FullScreenImageGallery(
                                                    images: record.photos,
                                                    initialIndex: index,
                                                  ),
                                                ),
                                              );
                                            },
                                            child: UnifiedImage(
                                              imagePath: photo,
                                              width: itemWidth,
                                              height: itemWidth,
                                              borderRadius: BorderRadius.circular(
                                                8,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: -14,
                        child: IconButton(
                          key: _actionMenuKey,
                          icon: Icon(
                            Icons.more_vert,
                            size: 18,
                            color: theme.colorScheme.outline,
                          ),
                          onPressed: _showActionMenu,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                      ),
                      if (onAiExtract != null)
                        Positioned(
                          bottom: -22,
                          right: -24,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: isUndoable ? onUndo : onAiExtract,
                            onLongPress: isUndoable
                                ? null
                                : (isExtracting
                                      ? null
                                      : onAiExtractLongPress),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: (isUndoable
                                              ? theme.colorScheme.error
                                              : tagColor)
                                          .withValues(alpha: 0.2),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
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
                                                      width: 28,
                                                      height: 28,
                                                      child: CustomPaint(
                                                        painter:
                                                            _UndoCountdownPainter(
                                                          progress:
                                                              undoAnimation!
                                                                  .value,
                                                          color: theme
                                                              .colorScheme
                                                              .error,
                                                        ),
                                                      ),
                                                    ),
                                                    child!,
                                                  ],
                                                );
                                              },
                                              child: Icon(
                                                Icons.undo,
                                                size: 14,
                                                color:
                                                    theme.colorScheme.error,
                                              ),
                                            )
                                          : Icon(
                                              Icons.undo,
                                              size: 14,
                                              color: theme.colorScheme.error,
                                            ))
                                    : isExtracting
                                    ? Center(
                                        child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.0,
                                            color: tagColor,
                                          ),
                                        ),
                                      )
                                    : Icon(
                                        Icons.auto_awesome,
                                        size: 16,
                                        color: tagColor,
                                      ),
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

  Widget _buildHeader(ThemeData theme, Color primaryTagColor) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: primaryTagColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.access_time_filled,
                  size: 14,
                  color: primaryTagColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _formatTimeRangeWithDate(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: primaryTagColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTagAndFieldsRow(ThemeData theme, Color primaryTagColor) {
    final rowItems = <Widget>[];

    if (record.tagEntries.isNotEmpty) {
      for (final entry in record.tagEntries) {
        final color = _tagColor(entry.name);

        // Add the primary tag pill (filled)
        rowItems.add(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              entry.name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );

        // Add the additional fields (outlined)
        final additionalTags = _buildAdditionalTags(entry);
        for (final tagText in additionalTags) {
          rowItems.add(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tagText,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }

        final showTime = entry.displayTime ?? entry.time;
        if (showTime != null &&
            showTime.isNotEmpty &&
            !_isTagTimeDuplicate(entry)) {
          rowItems.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                showTime,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.7,
                  ),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        }
      }
    } else if (record.displayTag.isNotEmpty) {
      // Just display tag if no tagEntries
      rowItems.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: primaryTagColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: primaryTagColor.withValues(alpha: 0.25),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            record.displayTag,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    if (rowItems.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: rowItems.map((item) {
            final isLast = rowItems.last == item;
            return Padding(
              padding: EdgeInsets.only(right: isLast ? 0 : 8),
              child: item,
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildTagEntryPills(
    ThemeData theme,
    TagEntry entry, {
    bool showIcon = false,
    String? showTime,
  }) {
    final color = _tagColor(entry.name);
    final icon = _tagIcon(entry.name);

    final rowItems = <Widget>[];

    // 1. Tag name pill (filled)
    rowItems.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIcon) ...[
              Icon(icon, size: 12, color: Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              entry.name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );

    // 2. Field pills (outlined)
    final additionalTags = _buildAdditionalTags(entry);
    for (final tagText in additionalTags) {
      rowItems.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            tagText,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    // 3. Optional time display
    if (showTime != null &&
        showTime.isNotEmpty &&
        !_isTagTimeDuplicate(entry)) {
      rowItems.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            showTime,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: rowItems,
    );
  }

  Widget _buildMultiTagSections(ThemeData theme) {
    final sections = <Widget>[];

    for (int i = 0; i < record.tagEntries.length; i++) {
      final entry = record.tagEntries[i];

      if (i > 0) {
        sections.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
        );
      }

      sections.add(
        _buildTagEntryPills(
          theme,
          entry,
          showIcon: true,
          showTime: entry.displayTime ?? entry.time,
        ),
      );
    }

    final richContent = _buildRichContent(
      context: theme,
      text: record.content,
      bodyState: record.bodyState,
      tag: record.displayTag,
      leftPadding: _contentIndent,
      isMultiTag: true,
    );
    if (richContent != null) {
      sections.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      );
      sections.add(richContent);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: sections,
      ),
    );
  }

  Widget _buildSingleTagContent(ThemeData theme, Color tagColor) {
    final richContent = _buildRichContent(
      context: theme,
      text: record.content,
      bodyState: record.bodyState,
      tag: record.displayTag,
      leftPadding: _contentIndent,
    );
    if (richContent == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        richContent,
      ],
    );
  }

  Widget? _buildRichContent({
    required ThemeData context,
    String? text,
    Map<String, dynamic>? bodyState,
    String? tag,
    double leftPadding = 0,
    bool isMultiTag = false,
  }) {
    String cleanText = text ?? '';
    if (cleanText.isEmpty) return null;

    final theme = context;
    if (tag != null && tag.isNotEmpty && cleanText.startsWith('【$tag】')) {
      cleanText = cleanText.substring(tag.length + 2).trim();
    }

    if (cleanText.isEmpty) return null;

    final rawLines = cleanText.split('\n');
    final displayLines = <String>[];
    String remarkText = '';

    final isSpecialTag = !isMultiTag && (tag == '睡眠' || tag == '记账');

    final keysToSkip = {
      'duration',
      'quality',
      'fallasleeptime',
      'type',
      'rating',
      'item',
      'amount',
      'incometype',
      'symptom',
      'severity',
      'notes',
      'note',
      'remark',
      'remarks',
      'health',
      'medication',
      '时长',
      '质量',
      '入睡时间',
      '类型',
      '评价',
      '项目',
      '金额',
      '收入类型',
      '症状',
      '严重程度',
      '备注',
      '种类',
      '睡眠质量',
      '类别',
      '用药',
    };

    String normalizeKey(String key) {
      return key.trim().toLowerCase().replaceAll(
        RegExp(r'[\s\(_\)（）\-:]+'),
        '',
      );
    }

    for (final entry in record.tagEntries) {
      for (final f in entry.fields.entries) {
        keysToSkip.add(normalizeKey(f.key));
        final label = _getFieldLabel(entry.name, f.key, entry.fields);
        keysToSkip.add(normalizeKey(label));
      }
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
        if (trimmedLine.contains(':') || trimmedLine.contains('：')) continue;
        displayLines.add(trimmedLine);
        continue;
      }

      if (!trimmedLine.contains(':') && !trimmedLine.contains('：')) {
        displayLines.add(trimmedLine);
        continue;
      }

      final regExp = RegExp(r'([^:：,，;；]+)([:：])\s*([^,，;；]+)([,，;；]?)');
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
        String lastPartNorm = '';
        if (key.contains('-')) {
          lastPartNorm = normalizeKey(key.split('-').last);
        }
        final val = match.group(3)?.trim() ?? '';

        bool shouldSkip = false;
        for (final skipKey in keysToSkip) {
          if (normKey == skipKey ||
              normKey.contains(skipKey) ||
              skipKey.contains(normKey)) {
            shouldSkip = true;
            break;
          }
          if (lastPartNorm.isNotEmpty &&
              (lastPartNorm == skipKey ||
                  lastPartNorm.contains(skipKey) ||
                  skipKey.contains(lastPartNorm))) {
            shouldSkip = true;
            break;
          }
        }

        if (shouldSkip) {
          lastIndex = match.end;
          continue;
        }

        final colon = match.group(2) ?? '：';
        remainingSegments.add('$key$colon$val');
        lastIndex = match.end;
      }

      if (lastIndex < trimmedLine.length) {
        final suffix = trimmedLine
            .substring(lastIndex)
            .trim()
            .replaceAll(RegExp(r'^[，,;；]+|[，,;；]+$'), '');
        if (suffix.isNotEmpty) {
          final normSuffix = normalizeKey(suffix);
          bool suffixShouldSkip = false;
          for (final skipKey in keysToSkip) {
            if (normSuffix == skipKey ||
                normSuffix.contains(skipKey) ||
                skipKey.contains(normSuffix)) {
              suffixShouldSkip = true;
              break;
            }
          }
          if (!suffixShouldSkip) {
            remainingSegments.add(suffix);
          }
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
          child: Text(
            remarkText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      );
    }

    if (elements.isEmpty) return null;

    return Padding(
      padding: EdgeInsets.only(left: leftPadding, top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: elements,
      ),
    );
  }

  String _formatTimeRangeWithDate() {
    final start = record.startTime ?? record.time;
    final startDateStr = DateFormat('MM-dd').format(start);
    final startStr = DateFormat.Hm().format(start);

    if (record.endTime != null) {
      final end = record.endTime!;
      final endStr = DateFormat.Hm().format(end);

      final isCrossDate =
          start.year != end.year ||
          start.month != end.month ||
          start.day != end.day;

      if (isCrossDate) {
        final endDateStr = DateFormat('MM-dd').format(end);
        return '$startDateStr $startStr → $endDateStr $endStr';
      }
      return '$startDateStr $startStr → $endStr';
    }
    return '$startDateStr $startStr';
  }

  bool _isTagTimeDuplicate(TagEntry entry) {
    if (entry.startHour == null || entry.startMinute == null) {
      return false;
    }

    final recordStart = record.startTime ?? record.time;
    final recordStartHour = recordStart.hour;
    final recordStartMinute = recordStart.minute;

    final isStartSame =
        entry.startHour == recordStartHour &&
        entry.startMinute == recordStartMinute;
    if (!isStartSame) return false;

    if (record.endTime == null) {
      return entry.endHour == null;
    } else {
      if (entry.endHour == null) return false;

      final recordEndHour = record.endTime!.hour;
      final recordEndMinute = record.endTime!.minute;
      return entry.endHour == recordEndHour &&
          entry.endMinute == recordEndMinute;
    }
  }
}

class _UndoCountdownPainter extends CustomPainter {
  final double progress;
  final Color color;

  _UndoCountdownPainter({required this.progress, required this.color});

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

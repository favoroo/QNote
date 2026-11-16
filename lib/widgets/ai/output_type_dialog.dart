import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/agent/output_types/output_type_registry.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/widgets/ai/output_type_icons.dart';

/// 「+」面板中的附件入口类型（回调由调用方映射到各自的选取流程）
enum AddAttachmentKind { camera, gallery, journal, note, todo }

/// 「+」面板结果：选择了一个附件入口，或选择/清除了一个输出类型
sealed class AddPanelResult {
  const AddPanelResult();
}

class AttachmentPickResult extends AddPanelResult {
  final AddAttachmentKind kind;

  const AttachmentPickResult(this.kind);
}

class OutputTypePickResult extends AddPanelResult {
  /// 目标输出类型 id；null 表示清除已选类型
  final String? outputTypeId;

  const OutputTypePickResult(this.outputTypeId);
}

/// 附件入口定义：图标 + 文案
///
/// 入口不再各配一支彩虹色：统一中性图标块，避免五个高饱和圆圈抢走
/// 「输出类型」选中态的注意力。
const List<({AddAttachmentKind kind, IconData icon, String label})> kAttachmentEntries = [
  (kind: AddAttachmentKind.camera, icon: Icons.camera_alt_rounded, label: '相机'),
  (kind: AddAttachmentKind.gallery, icon: Icons.photo_library_rounded, label: '相册'),
  (kind: AddAttachmentKind.journal, icon: Icons.auto_stories_rounded, label: '日记'),
  (kind: AddAttachmentKind.note, icon: Icons.description_rounded, label: '笔记'),
  (kind: AddAttachmentKind.todo, icon: Icons.check_circle_outline_rounded, label: '待办'),
];

/// 打开「+」面板：上半区「添加内容」（相机/相册/日记/笔记/待办），
/// 下半区「输出类型」（按类别分组的形态选择）。
Future<AddPanelResult?> showAddAndOutputDialog(BuildContext context, {String? selectedOutputTypeId}) {
  return AppMotion.showDialog<AddPanelResult>(
    context: context,
    builder: (_) => _AddAndOutputDialog(selectedOutputTypeId: selectedOutputTypeId),
  );
}

class _AddAndOutputDialog extends StatefulWidget {
  final String? selectedOutputTypeId;

  const _AddAndOutputDialog({this.selectedOutputTypeId});

  @override
  State<_AddAndOutputDialog> createState() => _AddAndOutputDialogState();
}

class _AddAndOutputDialogState extends State<_AddAndOutputDialog> {
  /// 弹窗内本地选择：卡片点击只改这里，底部主按钮才真正提交并关闭
  String? _selectedTypeId;

  @override
  void initState() {
    super.initState();
    // 传入的 id 可能来自旧版本（类型已删除），只保留当前注册表仍认识的
    _selectedTypeId = outputTypeById(widget.selectedOutputTypeId)?.id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.86;
    // 圆角与底色跟随全局 dialogTheme，避免弹窗自成一套样式
    final dialogShape = theme.dialogTheme.shape;
    final dialogRadius = dialogShape is RoundedRectangleBorder && dialogShape.borderRadius is BorderRadius
        ? dialogShape.borderRadius as BorderRadius
        : BorderRadius.circular(20);
    // 路由层已有 SafeArea，这里再兜一层：无论从悬浮窗还是页面打开，都避开刘海/手势条
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 480, maxHeight: maxHeight),
            child: Material(
              color: theme.dialogTheme.backgroundColor ?? colorScheme.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: dialogRadius),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(context, theme),
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 以弹窗宽度判断列数：390 宽手机得到两列，320 宽小屏回落单列
                        final singleColumn = constraints.maxWidth < 340;
                        final contentWidth = constraints.maxWidth - 32;
                        return SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildSectionTitle(theme, '添加内容'),
                                const SizedBox(height: 10),
                                _buildAttachmentRow(context, theme),
                                const SizedBox(height: 20),
                                // 两个区块之间只用一根发丝线分隔，不再加粗描边
                                Divider(height: 1, thickness: 1, color: colorScheme.outlineVariant),
                                const SizedBox(height: 20),
                                _buildOutputSection(context, theme, singleColumn, contentWidth),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  _buildFooter(context, theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 固定头部：仅保留右上角 36 关闭按钮（不随内容滚动），不再展示标题与说明
  Widget _buildHeader(BuildContext context, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: '关闭',
            child: InkResponse(
              onTap: () => Navigator.of(context).pop(),
              radius: 18,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.close_rounded, size: 20, color: colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 区块标题：比分组标题大一档，用字号与字重建立清晰的两层结构
  Widget _buildSectionTitle(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        fontSize: AppTypography.subtitle,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
        letterSpacing: 0.2,
        height: 1.2,
      ),
    );
  }

  Widget _buildAttachmentRow(BuildContext context, ThemeData theme) {
    return Row(
      children: [
        for (var i = 0; i < kAttachmentEntries.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _buildAttachmentEntry(context, theme, kAttachmentEntries[i])),
        ],
      ],
    );
  }

  /// 附件入口：中性 tile（浅容器底 + 发丝线），图标用可读强调色，
  /// 把高饱和实心色块全部留给「输出类型」的选中态与底部主按钮
  Widget _buildAttachmentEntry(
    BuildContext context,
    ThemeData theme,
    ({AddAttachmentKind kind, IconData icon, String label}) entry,
  ) {
    final colorScheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: '添加${entry.label}',
      child: Material(
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(AttachmentPickResult(entry.kind)),
          child: SizedBox(
            height: 64,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(entry.icon, size: 21, color: theme.accentInk),
                const SizedBox(height: 7),
                Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: AppTypography.label,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOutputSection(BuildContext context, ThemeData theme, bool singleColumn, double contentWidth) {
    final groups = groupedOutputTypes();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 当前选择已由底部实心胶囊常驻展示，这里不再重复一遍「已选：X」
        _buildSectionTitle(theme, '输出类型'),
        const SizedBox(height: 16),
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) const SizedBox(height: 18),
          _buildGroupHeader(theme, groups[i]),
          const SizedBox(height: 8),
          _buildGroupGrid(context, theme, groups[i].value, singleColumn, contentWidth),
        ],
      ],
    );
  }

  /// 分类标题：左侧 3px 实心主题色竖条 + w700 标题，做瑞士海报式的模块标记
  Widget _buildGroupHeader(ThemeData theme, MapEntry<String, List<OutputTypeOption>> group) {
    final colorScheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 3,
          height: 13,
          decoration: BoxDecoration(color: colorScheme.primary, borderRadius: BorderRadius.circular(1.5)),
        ),
        const SizedBox(width: 8),
        Text(
          group.key,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: AppTypography.body,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
            height: 1.2,
          ),
        ),
        // 数量保留原信息，但去掉独立胶囊底，避免和分类标题抢层级
        const SizedBox(width: 8),
        Text(
          '${group.value.length} 项',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: AppTypography.caption,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurfaceVariant,
            height: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildGroupGrid(
    BuildContext context,
    ThemeData theme,
    List<OutputTypeOption> options,
    bool singleColumn,
    double contentWidth,
  ) {
    const gap = 8.0;
    final itemWidth = singleColumn ? contentWidth : (contentWidth - gap) / 2;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final option in options)
          SizedBox(width: itemWidth, height: 68, child: _buildTypeCard(context, theme, option)),
      ],
    );
  }

  /// 输出类型卡片：选中即整卡铺实心主题色（深色主题同样成立），
  /// 未选中保持表面色 + 发丝线；用色块而非淡色 tint + 描边表达选中。
  Widget _buildTypeCard(BuildContext context, ThemeData theme, OutputTypeOption option) {
    final colorScheme = theme.colorScheme;
    final selected = option.id == _selectedTypeId;
    final radius = BorderRadius.circular(12);
    // 实心卡片上的所有前景统一取 onPrimary，保证深浅两套主题都可读
    final titleColor = selected ? colorScheme.onPrimary : colorScheme.onSurface;
    final descriptionColor = selected ? colorScheme.onPrimary.withValues(alpha: 0.85) : colorScheme.onSurfaceVariant;
    final borderSide = selected
        ? (theme.accentNeedsOutline ? BorderSide(color: colorScheme.outlineVariant) : BorderSide.none)
        : BorderSide(color: colorScheme.outlineVariant);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colorScheme.primary : colorScheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: radius, side: borderSide),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _selectedTypeId = selected ? null : option.id),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: selected
                            ? colorScheme.onPrimary.withValues(alpha: 0.14)
                            : colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        iconForOutputType(option.id),
                        size: 19,
                        color: selected ? colorScheme.onPrimary : theme.accentInk,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            // 右上角勾选角标会压住标题尾部，选中时给标题让出空间
                            padding: EdgeInsets.only(right: selected ? 16 : 0),
                            child: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: AppTypography.body,
                                fontWeight: FontWeight.w600,
                                color: titleColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            option.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: AppTypography.label,
                              letterSpacing: 0,
                              color: descriptionColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 勾选角标：onPrimary 实心圆 + primary 勾，选中状态一眼可辨
              if (selected)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(color: colorScheme.onPrimary, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded, size: 12, color: colorScheme.primary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 固定底部操作区：当前选择摘要（实心胶囊）+ 清除 + 实心主按钮
  Widget _buildFooter(BuildContext context, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final selected = outputTypeById(_selectedTypeId);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(child: _buildSelectionSummary(theme, selected)),
              if (selected != null) ...[
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => setState(() => _selectedTypeId = null),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: colorScheme.onSurfaceVariant,
                    textStyle: theme.textTheme.bodySmall?.copyWith(
                      fontSize: AppTypography.bodySmall,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: const Text('清除'),
                ),
              ],
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(OutputTypePickResult(_selectedTypeId)),
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  side: theme.accentNeedsOutline ? BorderSide(color: colorScheme.outlineVariant) : BorderSide.none,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: theme.textTheme.labelLarge?.copyWith(
                    fontSize: AppTypography.body,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: Text(
                  selected == null ? '完成' : '使用「${selected.label}」',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 已选摘要：小号实心主题色胶囊，图标 / 名称 / 后缀统一用 onPrimary
  Widget _buildSelectionSummary(ThemeData theme, OutputTypeOption? selected) {
    final colorScheme = theme.colorScheme;
    if (selected == null) {
      return Text(
        '未选择输出类型',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: AppTypography.bodySmall,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }
    final extension = selected.extension;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: colorScheme.primary,
          borderRadius: BorderRadius.circular(999),
          border: theme.accentNeedsOutline ? Border.all(color: colorScheme.outlineVariant) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconForOutputType(selected.id), size: 13, color: colorScheme.onPrimary),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                extension == null ? selected.label : '${selected.label} · .$extension',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: AppTypography.label,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onPrimary,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'package:qnote_flutter/config/ai_vendors.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/vendor_filter.dart';
import 'package:qnote_flutter/widgets/ai/vendor_logo.dart';

/// 厂商模板选择器（「添加模型服务」与编辑页「更换厂商模板」共用）
///
/// 厂商数量到 50+ 后，一条平铺长列表在手机上要滑很久才能找到目标，因此这里给两条
/// 路径：**分组 chips**（自定义 / 账号登录 / 国内 / 国际 / 聚合）用于浏览，
/// **搜索框**用于直达。网格在手机上排 2 列、宽屏 3 列，比 ListTile 一列一行多出
/// 近一倍的信息密度。
///
/// 卡片里**只放图标与名称**：手机 2 列时单个卡片只有约 175dp 宽，扣掉图标与内边距
/// 后名称只剩约 120dp，「Qwen（通义千问）」这类中英混排的名字一行必然被截成
/// 「Qwen（通…」。所以名称给到 2 行、字号压到 13；原先那行厂商简介（`note`）已
/// 从卡片移除——它占掉半张卡的高度却几乎读不全，仍然参与搜索匹配，需要时搜得到。
///
/// 账号登录型带「账号」徽标：它要点登录而不是粘 Key，这是两类厂商在流程上的
/// 唯一区别，必须在选择阶段就能看出来。徽标放在名称下方而不是同一行，避免再挤
/// 名称宽度。
class VendorPickerSheet extends StatefulWidget {
  /// 当前已选厂商模板（编辑页复用本弹层时用），null 表示新增场景
  final String? selectedId;

  const VendorPickerSheet({super.key, this.selectedId});

  /// 弹出并返回选中的厂商模板 id；用户取消时返回 null
  static Future<String?> show(BuildContext context, {String? selectedId}) {
    return showModalBottomSheet<String>(
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => VendorPickerSheet(selectedId: selectedId),
    );
  }

  @override
  State<VendorPickerSheet> createState() => _VendorPickerSheetState();
}

class _VendorPickerSheetState extends State<VendorPickerSheet> {
  final TextEditingController _searchCtl = TextEditingController();

  /// null = 全部分组
  VendorCategory? _category;
  String _query = '';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vendors = filterVendors(aiProviders, category: _category, query: _query);
    // 只在「不限分组且没搜索」时展示分区标题，搜索/筛选后混排分区标题反而更难扫
    final grouped = (_category == null && _query.trim().isEmpty) ? groupVendors(vendors) : null;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('选择厂商', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildSearchField(theme)),
          SliverToBoxAdapter(child: _buildCategoryChips(theme)),
          if (vendors.isEmpty)
            SliverToBoxAdapter(child: _buildEmptyState(theme))
          else if (grouped != null)
            for (final entry in grouped.entries) ...[
              SliverToBoxAdapter(child: _buildSectionHeader(theme, entry.key)),
              _buildGrid(entry.value),
            ]
          else
            _buildGrid(vendors),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchCtl,
        onChanged: (value) => setState(() => _query = value),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索厂商或模型名',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  tooltip: '清空',
                  onPressed: () {
                    _searchCtl.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  Widget _buildCategoryChips(ThemeData theme) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _categoryChip(theme, label: '全部', category: null),
          for (final category in VendorCategory.values) _categoryChip(theme, label: category.label, category: category),
        ],
      ),
    );
  }

  Widget _categoryChip(ThemeData theme, {required String label, required VendorCategory? category}) {
    final selected = _category == category;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => setState(() => _category = category),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, VendorCategory category) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category.label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(
            category.description,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<AiProviderConfig> vendors) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          // 手机 2 列、平板与 Web 3 列；高度按「名称最多两行 + 可选徽标」定，
          // 留出余量避免长名字被裁切
          maxCrossAxisExtent: 230,
          mainAxisExtent: 66,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _vendorTile(context, vendors[index]),
          childCount: vendors.length,
        ),
      ),
    );
  }

  Widget _vendorTile(BuildContext context, AiProviderConfig spec) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = spec.id == widget.selectedId;
    // 账号型与免密钥型带徽标；徽标独占一行，不抢名称的横向空间
    final badge = spec.authMode != 'api_key' ? '账号' : (spec.keyOptional ? '免密钥' : null);

    return Material(
      color: selected ? colorScheme.primary.withValues(alpha: 0.08) : theme.cardColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).pop(spec.id),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? theme.accentInk.withValues(alpha: 0.6)
                  : colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              VendorLogo(vendorId: spec.id, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      spec.name,
                      // 2 列窄卡放不下「Qwen（通义千问）」这类中英混排全名，
                      // 允许折行比截成省略号更有用
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: AppTypography.body,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: selected ? theme.accentInk : null,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(height: 2),
                      Align(alignment: Alignment.centerLeft, child: _miniBadge(theme, badge)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniBadge(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: AppTypography.caption,
          height: 1.1,
          color: theme.accentInk,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        children: [
          Icon(Icons.search_off_rounded, size: 32, color: theme.colorScheme.outline),
          const SizedBox(height: 8),
          Text('没有匹配的厂商', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            '换个关键词，或选「自定义」手动填写地址、协议与模型',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

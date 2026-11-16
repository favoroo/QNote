import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/csv_parser.dart';
import 'package:qnote_flutter/core/utils/csv_table_layout.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// CSV/TSV 笔记预览：真正可用的移动端数据表。
///
/// 支持搜索、按列排序（数值列按数值比较并右对齐）、拖拽调整列宽、双击
/// 恢复自动列宽、自动换行开关，以及更适合窄屏阅读的卡片视图。第一行视为
/// 表头；各行列数不一致时按表头列数裁剪/补齐。
///
/// 单元格可直接编辑：详情弹窗里改完保存后，通过 [onSourceChanged] 把整份
/// 重序列化的源码交回宿主（笔记编辑器负责写回笔记并触发自动保存）。
class CsvTableView extends StatefulWidget {
  final String source;
  final String delimiter;

  /// 单元格保存后回调；null 表示纯查看模式（弹窗只读）
  final void Function(String source)? onSourceChanged;

  const CsvTableView({super.key, required this.source, this.delimiter = ',', this.onSourceChanged});

  @override
  State<CsvTableView> createState() => _CsvTableViewState();
}

enum _CsvViewMode { table, cards }

class _IndexedRow {
  /// 原表数据行下标（不含表头），排序/过滤后仍用于展示「第 N 行」与选中标记
  final int index;
  final List<String> cells;

  const _IndexedRow(this.index, this.cells);
}

class _CsvTableViewState extends State<CsvTableView> {
  static const double _rowHeight = 44;
  static const double _minColumnWidth = 64;
  static const double _maxColumnWidth = 360;
  static const double _resizeHandleWidth = 16;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _horizontalController = ScrollController();

  String _query = '';
  int? _sortColumn;
  bool _sortAsc = true;
  // 默认紧凑单行，优先一屏扫更多行；长内容点单元格看全文，需要整列展开时再开「换行」
  bool _wrapCells = false;
  _CsvViewMode _viewMode = _CsvViewMode.table;

  /// 当前查看过的数据行（存原始行下标，排序/过滤后仍能正确高亮）
  int? _selectedRowIndex;

  // 解析与派生结果缓存：源码/分隔符不变时，搜索、排序、拖拽都不会重复解析
  String? _cacheKey;
  String? _parseError;
  List<String> _header = const [];
  List<List<String>> _dataRows = const [];
  List<String> _searchIndex = const [];
  Set<int> _numericColumns = const <int>{};
  List<double> _autoWidths = const [];

  /// 原始解析结果（未过滤空行）：编辑写回时按原位置改，避免重排源码
  List<List<String>> _rawRows = const [];

  /// 展示行（过滤空行后）对应的原始行下标；第 0 位是表头行
  List<int> _keptRawIndices = const [];

  /// 用户手动调整过的列宽；源码变化时清空，避免旧表宽度带到新表
  final Map<int, double> _manualWidths = <int, double>{};

  int? _resizingColumn;
  double _resizeStartWidth = 0;
  double _resizeStartX = 0;

  @override
  void dispose() {
    _searchController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  void _ensureParsed() {
    final key = '${widget.delimiter}\u0000${widget.source}';
    if (_cacheKey == key) {
      return;
    }
    _cacheKey = key;
    _parseError = null;
    _header = const [];
    _dataRows = const [];
    _searchIndex = const [];
    _numericColumns = const <int>{};
    _autoWidths = const [];
    _rawRows = const [];
    _keptRawIndices = const [];
    _manualWidths.clear();
    _sortColumn = null;
    _resizingColumn = null;
    _selectedRowIndex = null;

    try {
      final rawRows = parseDelimited(widget.source, delimiter: widget.delimiter);
      // 与 dropBlankRows 相同的过滤口径，同时记录「展示行 → 原始行」映射，编辑写回时定位
      final kept = <int>[
        for (var i = 0; i < rawRows.length; i++)
          if (rawRows[i].any((c) => c.trim().isNotEmpty)) i,
      ];
      final parsed = [for (final index in kept) rawRows[index]];
      _rawRows = rawRows;
      _keptRawIndices = kept;
      if (parsed.isEmpty || parsed.first.isEmpty) {
        return;
      }
      final columnCount = parsed.first.length;
      _header = [for (var i = 0; i < columnCount; i++) _headerLabel(parsed.first[i], i)];
      _dataRows = [for (final row in parsed.skip(1)) _normalizeRow(row, columnCount)];
      _searchIndex = [for (final row in _dataRows) row.join('\u0000').toLowerCase()];
      _numericColumns = {
        for (var i = 0; i < columnCount; i++)
          if (isNumericCsvColumn(_dataRows, i)) i,
      };
      _autoWidths = computeCsvColumnWidths(rows: parsed, columnCount: columnCount);
    } catch (error) {
      // 解析器本身很宽容，这里兜住异常内存/输入导致的意外，界面给出明确错误态
      debugPrint('CSV 预览解析失败: $error');
      _parseError = '表格内容读取失败，请检查源码后重试。';
      _header = const [];
      _dataRows = const [];
      _searchIndex = const [];
      _numericColumns = const <int>{};
      _autoWidths = const [];
      _rawRows = const [];
      _keptRawIndices = const [];
    }
  }

  static String _headerLabel(String raw, int index) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? '列 ${index + 1}' : trimmed;
  }

  static List<String> _normalizeRow(List<String> row, int columnCount) {
    if (row.length == columnCount) {
      return row;
    }
    if (row.length > columnCount) {
      return row.sublist(0, columnCount);
    }
    return [...row, for (var i = row.length; i < columnCount; i++) ''];
  }

  double _effectiveColumnWidth(int index) {
    final manual = _manualWidths[index];
    if (manual != null) {
      return manual.clamp(_minColumnWidth, _maxColumnWidth).toDouble();
    }
    final auto = index < _autoWidths.length ? _autoWidths[index] : 72.0;
    return auto.clamp(_minColumnWidth, _maxColumnWidth).toDouble();
  }

  void _toggleSort(int column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAsc = !_sortAsc;
      } else {
        _sortColumn = column;
        _sortAsc = true;
      }
    });
  }

  void _onResizeStart(int column, DragStartDetails details) {
    setState(() => _resizingColumn = column);
    _resizeStartWidth = _effectiveColumnWidth(column);
    _resizeStartX = details.globalPosition.dx;
  }

  void _onResizeUpdate(int column, DragUpdateDetails details) {
    if (_resizingColumn != column) {
      return;
    }
    final width = (_resizeStartWidth + details.globalPosition.dx - _resizeStartX)
        .clamp(_minColumnWidth, _maxColumnWidth)
        .toDouble();
    setState(() => _manualWidths[column] = width);
  }

  void _endResize() {
    if (_resizingColumn == null) {
      return;
    }
    setState(() => _resizingColumn = null);
  }

  void _resetColumnWidth(int column) {
    if (!_manualWidths.containsKey(column)) {
      return;
    }
    setState(() => _manualWidths.remove(column));
    Toast.info(context, '已恢复自动列宽');
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  /// 记录当前查看的行；表格里用左侧实心竖条标记，便于关闭详情后继续定位
  void _selectRow(_IndexedRow row) {
    if (_selectedRowIndex == row.index) {
      return;
    }
    setState(() => _selectedRowIndex = row.index);
  }

  /// 把编辑后的单元格写回原始行并交给宿主。
  ///
  /// 展示行经过空行过滤，先映射回原始行下标再改；重序列化整份源码时，
  /// 换行风格沿用原文件（CRLF/LF），未受影响字段保持原样。
  void _applyCellEdit(int dataRowIndex, int column, String newValue) {
    final rawSlot = dataRowIndex + 1; // 展示列表第 0 位是表头
    if (rawSlot < 0 || rawSlot >= _keptRawIndices.length || column < 0) {
      return;
    }
    final rawIndex = _keptRawIndices[rawSlot];
    final rawRow = [..._rawRows[rawIndex]];
    while (rawRow.length <= column) {
      rawRow.add('');
    }
    if (rawRow[column] == newValue) {
      return;
    }
    rawRow[column] = newValue;
    final rows = [..._rawRows]..[rawIndex] = rawRow;
    final lineEnding = widget.source.contains('\r\n') ? '\r\n' : '\n';
    widget.onSourceChanged?.call(serializeDelimited(rows, delimiter: widget.delimiter, lineEnding: lineEnding));
  }

  void _showCellDetail({required int column, required _IndexedRow row}) {
    _selectRow(row);
    final onSave = widget.onSourceChanged == null
        ? null
        : (String newValue) => _applyCellEdit(row.index, column, newValue);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      builder: (_) => _CsvCellDetailSheet(
        columnName: _header[column],
        value: row.cells[column],
        rowNumber: row.index + 1,
        onSave: onSave,
      ),
    );
  }

  void _showRowDetail(_IndexedRow row) {
    _selectRow(row);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      builder: (_) => _CsvRowDetailSheet(header: _header, cells: row.cells, rowNumber: row.index + 1),
    );
  }

  Future<void> _copyCell(String value) async {
    if (value.trim().isEmpty) {
      Toast.info(context, '单元格为空');
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      Toast.info(context, '已复制');
    }
  }

  Future<void> _copyRow(_IndexedRow row) async {
    await Clipboard.setData(ClipboardData(text: encodeTsvRow(row.cells)));
    if (mounted) {
      Toast.info(context, '已复制整行（TSV）');
    }
  }

  int _compareRows(_IndexedRow a, _IndexedRow b, int column, bool numeric) {
    final left = a.cells[column].trim();
    final right = b.cells[column].trim();
    if (numeric) {
      final leftNumber = double.tryParse(left);
      final rightNumber = double.tryParse(right);
      // 空值/非数值固定排在末尾，不随升序/降序翻转
      if (leftNumber == null && rightNumber == null) {
        return 0;
      }
      if (leftNumber == null) {
        return 1;
      }
      if (rightNumber == null) {
        return -1;
      }
      return _sortAsc ? leftNumber.compareTo(rightNumber) : rightNumber.compareTo(leftNumber);
    }
    final result = left.toLowerCase().compareTo(right.toLowerCase());
    return _sortAsc ? result : -result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _ensureParsed();

    if (_parseError != null) {
      return _CsvStatusState(icon: Icons.error_outline_rounded, title: '表格解析失败', description: _parseError!);
    }
    if (_header.isEmpty) {
      return const _CsvStatusState(
        icon: Icons.table_chart_outlined,
        title: '暂无表格数据',
        description: '点右上角「源码」补充表头与数据后再预览。',
      );
    }

    final List<_IndexedRow> indexed = [for (var i = 0; i < _dataRows.length; i++) _IndexedRow(i, _dataRows[i])];
    final query = _query.trim().toLowerCase();
    List<_IndexedRow> visible;
    if (query.isEmpty) {
      visible = indexed;
    } else {
      visible = [
        for (var i = 0; i < indexed.length; i++)
          if (_searchIndex[i].contains(query)) indexed[i],
      ];
    }
    if (_sortColumn != null) {
      final column = _sortColumn!;
      final numeric = _numericColumns.contains(column);
      visible = [...visible]..sort((a, b) => _compareRows(a, b, column, numeric));
    }

    return Column(
      children: [
        _buildToolbar(theme, searching: query.isNotEmpty, hitCount: visible.length),
        Expanded(
          child: _viewMode == _CsvViewMode.table
              ? _buildTableView(theme, visible, searching: query.isNotEmpty)
              : _buildCardView(theme, visible, searching: query.isNotEmpty),
        ),
      ],
    );
  }

  Widget _buildToolbar(ThemeData theme, {required bool searching, required int hitCount}) {
    final cardHint = _viewMode == _CsvViewMode.table && _header.length >= 5 ? ' · 可切卡片' : '';
    final hint = _viewMode == _CsvViewMode.table ? '拖表头调列宽 · 点单元格看全文$cardHint' : '点卡片看全文 · 长按复制整行';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: SizedBox(height: 38, child: _buildSearchField(theme)),
        ),
        SizedBox(
          height: 46,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildCountText(theme, searching: searching, hitCount: hitCount),
                      const SizedBox(height: 2),
                      Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: AppTypography.label,
                          height: 1.2,
                          letterSpacing: 0,
                          color: AppPalette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildViewModeSwitch(theme),
                // 换行只影响表格排布，卡片视图本身就会换行，避免出现无效开关
                if (_viewMode == _CsvViewMode.table) ...[const SizedBox(width: 8), _buildWrapSwitch(theme)],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 行列统计：主数字放大加粗，单位降到 12 号，靠字号与字重拉层级
  Widget _buildCountText(ThemeData theme, {required bool searching, required int hitCount}) {
    final colorScheme = theme.colorScheme;
    final numberStyle = theme.textTheme.titleSmall?.copyWith(
      fontSize: AppTypography.subtitle,
      fontWeight: FontWeight.w700,
      height: 1.1,
      color: colorScheme.onSurface,
    );
    final unitStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: AppTypography.bodySmall,
      height: 1.1,
      color: colorScheme.onSurfaceVariant,
    );
    return Text.rich(
      TextSpan(
        children: [
          if (searching) ...[
            TextSpan(text: '命中 ', style: unitStyle),
            TextSpan(text: '$hitCount', style: numberStyle),
            TextSpan(text: ' / 总 ', style: unitStyle),
            TextSpan(text: '${_dataRows.length}', style: numberStyle),
            TextSpan(text: ' 行', style: unitStyle),
          ] else ...[
            TextSpan(text: '${_dataRows.length}', style: numberStyle),
            TextSpan(text: ' 行 · ', style: unitStyle),
            TextSpan(text: '${_header.length}', style: numberStyle),
            TextSpan(text: ' 列', style: unitStyle),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final radius = BorderRadius.circular(10);
    final enabledBorder = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colorScheme.outlineVariant, width: 1),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: theme.accentInk, width: 1.4),
    );

    return TextField(
      controller: _searchController,
      onChanged: (value) => setState(() => _query = value),
      textInputAction: TextInputAction.search,
      style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurface),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索表格内容',
        hintStyle: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        prefixIcon: Icon(Icons.search_rounded, size: 18, color: colorScheme.onSurfaceVariant),
        prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                onPressed: _clearSearch,
                tooltip: '清空搜索',
                icon: Icon(Icons.close_rounded, size: 16, color: colorScheme.onSurfaceVariant),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              ),
        suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        filled: true,
        // 输入区用表面色 + 发丝线；聚焦只换线色，不叠加淡底以免和表头色块抢注意力
        fillColor: colorScheme.surface,
        border: enabledBorder,
        enabledBorder: enabledBorder,
        focusedBorder: focusedBorder,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildViewModeSwitch(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colorScheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(2),
        // 选中项是实心 primary 色块，未选中项只留文字，不做淡底 + 描边
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ViewModeButton(
              label: '表格',
              selected: _viewMode == _CsvViewMode.table,
              onTap: () {
                if (_viewMode != _CsvViewMode.table) {
                  setState(() => _viewMode = _CsvViewMode.table);
                }
              },
            ),
            _ViewModeButton(
              label: '卡片',
              selected: _viewMode == _CsvViewMode.cards,
              onTap: () {
                if (_viewMode != _CsvViewMode.cards) {
                  setState(() => _viewMode = _CsvViewMode.cards);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWrapSwitch(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final selected = _wrapCells;
    final foreground = selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;
    return Material(
      color: selected ? colorScheme.primary : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: selected
            // 同色系背景下实心块要补一圈发丝线才能交代边界
            ? (theme.accentNeedsOutline ? BorderSide(color: colorScheme.outlineVariant) : BorderSide.none)
            : BorderSide(color: colorScheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _wrapCells = !_wrapCells),
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wrap_text_rounded, size: 15, color: foreground),
                const SizedBox(width: 4),
                Text(
                  '换行',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: AppTypography.bodySmall,
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTableView(ThemeData theme, List<_IndexedRow> rows, {required bool searching}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = [for (var i = 0; i < _header.length; i++) _effectiveColumnWidth(i)];
        final totalWidth = widths.fold<double>(0, (sum, width) => sum + width);
        final availableWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : totalWidth;
        final tableWidth = math.max(totalWidth, availableWidth);
        final colorScheme = theme.colorScheme;

        return Stack(
          children: [
            Scrollbar(
              controller: _horizontalController,
              child: SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: tableWidth,
                  height: constraints.maxHeight,
                  child: Column(
                    children: [
                      _buildHeaderRow(theme, widths),
                      Container(height: 1, color: colorScheme.outlineVariant),
                      Expanded(
                        child: rows.isEmpty
                            ? const SizedBox.shrink()
                            : ListView.builder(
                                padding: EdgeInsets.zero,
                                itemCount: rows.length,
                                itemExtent: _wrapCells ? null : _rowHeight,
                                itemBuilder: (context, index) => _buildDataRow(theme, rows[index], widths),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (rows.isEmpty)
              Positioned(
                top: _rowHeight + 1,
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildEmptyBody(theme, searching: searching),
              ),
          ],
        );
      },
    );
  }

  Widget _buildHeaderRow(ThemeData theme, List<double> widths) {
    final colorScheme = theme.colorScheme;
    // 表头是整张表唯一的实心大色块，用主题色铺满整行
    return Container(
      height: _rowHeight,
      color: colorScheme.primary,
      child: Row(children: [for (var i = 0; i < _header.length; i++) _buildHeaderCell(theme, i, widths[i])]),
    );
  }

  Widget _buildHeaderCell(ThemeData theme, int column, double width) {
    final colorScheme = theme.colorScheme;
    final active = _sortColumn == column;
    return SizedBox(
      width: width,
      height: _rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // 实心底上用 onPrimary 低透明度发丝线分隔列，避免描边糊在主题色里
          border: Border(right: BorderSide(color: colorScheme.onPrimary.withValues(alpha: 0.25), width: 1)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              right: _resizeHandleWidth,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _toggleSort(column),
                  hoverColor: colorScheme.onPrimary.withValues(alpha: 0.08),
                  splashColor: colorScheme.onPrimary.withValues(alpha: 0.14),
                  highlightColor: colorScheme.onPrimary.withValues(alpha: 0.10),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _header[column],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontSize: AppTypography.bodyLarge,
                              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                              color: colorScheme.onPrimary,
                            ),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 3),
                          Icon(
                            _sortAsc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                            size: 14,
                            color: colorScheme.onPrimary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: _resizeHandleWidth,
              child: _ColumnResizeHandle(
                key: ValueKey('csv-column-resize-$column'),
                color: colorScheme.onPrimary,
                active: _resizingColumn == column,
                onDragStart: (details) => _onResizeStart(column, details),
                onDragUpdate: (details) => _onResizeUpdate(column, details),
                onDragEnd: _endResize,
                onDoubleTap: () => _resetColumnWidth(column),
              ),
            ),
            // 排序激活列用 onPrimary 实心短横条标记，不做淡色蒙层
            if (active)
              Positioned(left: 0, right: 0, bottom: 0, height: 3, child: ColoredBox(color: colorScheme.onPrimary)),
          ],
        ),
      ),
    );
  }

  Widget _buildDataRow(ThemeData theme, _IndexedRow row, List<double> widths) {
    final colorScheme = theme.colorScheme;
    final selected = _selectedRowIndex == row.index;
    final cells = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (var i = 0; i < _header.length; i++) _buildDataCell(theme, row, i, widths[i])],
    );

    return Container(
      // 选中竖条用前景装饰绘制：不占布局宽度，切换选中时行内容不会横向抖动
      foregroundDecoration: selected
          ? BoxDecoration(
              border: Border(left: BorderSide(color: colorScheme.primary, width: 3)),
            )
          : null,
      decoration: BoxDecoration(
        // 撤掉斑马纹，行分隔只留 1px 发丝线；选中行保留极淡主题色底
        color: selected ? colorScheme.primary.withValues(alpha: 0.05) : null,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant, width: 1)),
      ),
      // 换行模式下行高由内容决定；只对当前可见行做固有高度测量
      child: _wrapCells ? IntrinsicHeight(child: cells) : cells,
    );
  }

  Widget _buildDataCell(ThemeData theme, _IndexedRow row, int column, double width) {
    final colorScheme = theme.colorScheme;
    final numeric = _numericColumns.contains(column);
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showCellDetail(column: column, row: row),
          onLongPress: () => _copyCell(row.cells[column]),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: _wrapCells ? 10 : 0),
            child: Align(
              alignment: _wrapCells ? Alignment.topLeft : Alignment.centerLeft,
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  row.cells[column],
                  maxLines: _wrapCells ? 6 : 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: numeric ? TextAlign.right : TextAlign.left,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: AppTypography.body,
                    color: colorScheme.onSurface,
                    height: _wrapCells ? 1.35 : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardView(ThemeData theme, List<_IndexedRow> rows, {required bool searching}) {
    if (rows.isEmpty) {
      return _buildEmptyBody(theme, searching: searching);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      itemCount: rows.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildRowCard(theme, rows[index]),
    );
  }

  Widget _buildRowCard(ThemeData theme, _IndexedRow row) {
    final colorScheme = theme.colorScheme;
    final firstValue = row.cells.first;
    final firstLabel = _header.first;
    final firstEmpty = firstValue.trim().isEmpty;

    return Material(
      // 卡片用表面色 + 发丝线，无阴影无渐变；层级完全交给左缘实心色条
      color: colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showRowDetail(row),
        onLongPress: () => _copyRow(row),
        child: Container(
          foregroundDecoration: BoxDecoration(
            border: Border(left: BorderSide(color: colorScheme.primary, width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '第 ${row.index + 1} 行 · $firstLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: AppTypography.label,
                        letterSpacing: 0,
                        color: AppPalette.textMuted,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                firstEmpty ? '（空）' : firstValue,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  // 首列是卡片的阅读锚点：比字段正文大 3 号并加粗，靠字号拉层级
                  fontSize: AppTypography.title,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: firstEmpty ? AppPalette.textMuted : colorScheme.onSurface,
                ),
              ),
              if (_header.length > 1) ...[
                const SizedBox(height: 10),
                for (var i = 1; i < _header.length; i++) ...[
                  if (i > 1) Container(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.7)),
                  _buildCardField(theme, i, row.cells[i]),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardField(ThemeData theme, int column, String value) {
    final colorScheme = theme.colorScheme;
    final numeric = _numericColumns.contains(column);
    final empty = value.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              _header[column],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: AppTypography.label,
                letterSpacing: 0,
                color: AppPalette.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              empty ? '—' : value,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: numeric ? TextAlign.right : TextAlign.left,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: AppTypography.body,
                color: empty ? AppPalette.textMuted : colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyBody(ThemeData theme, {required bool searching}) {
    return _CsvStatusState(
      icon: searching ? Icons.search_off_rounded : Icons.table_rows_outlined,
      title: searching ? '没有匹配的行' : '只有表头，没有数据行',
      description: searching ? '换个关键词，或清空搜索查看全部内容。' : '在源码中补充数据后，表格会自动刷新。',
      action: searching
          ? FilledButton(
              onPressed: _clearSearch,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                textStyle: const TextStyle(fontSize: AppTypography.bodySmall, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                side: theme.accentNeedsOutline ? BorderSide(color: theme.colorScheme.outlineVariant, width: 0.9) : null,
              ),
              child: const Text('清空搜索'),
            )
          : null,
    );
  }
}

/// 工具条里的「表格 / 卡片」分段按钮
class _ViewModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ViewModeButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        // 选中 = 实心 primary + onPrimary；未选中保持透明，不再用淡底和描边
        color: selected ? colorScheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 50,
            height: 32,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: AppTypography.bodySmall,
                  color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 表头右缘的列宽拖拽握把
class _ColumnResizeHandle extends StatefulWidget {
  final bool active;

  /// 手柄颜色：表头是实心 primary 底，由调用方传入 onPrimary 保证可见
  final Color color;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDoubleTap;

  const _ColumnResizeHandle({
    super.key,
    required this.active,
    required this.color,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDoubleTap,
  });

  @override
  State<_ColumnResizeHandle> createState() => _ColumnResizeHandleState();
}

class _ColumnResizeHandleState extends State<_ColumnResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.active || _hovered;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        label: '调整列宽',
        hint: '左右拖动调整列宽，双击恢复自动宽度',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: widget.onDoubleTap,
          onHorizontalDragStart: widget.onDragStart,
          onHorizontalDragUpdate: widget.onDragUpdate,
          onHorizontalDragEnd: (_) => widget.onDragEnd(),
          onHorizontalDragCancel: widget.onDragEnd,
          child: Center(
            child: AnimatedContainer(
              duration: AppDurations.fast,
              width: highlighted ? 2.5 : 1.75,
              height: widget.active ? 28 : 20,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: highlighted ? 0.95 : 0.55),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单元格详情：列名 + 完整内容 + 复制
/// 单元格详情弹窗：内容大字展示；传入 [onSave] 时变为可直接编辑，保存写回笔记
class _CsvCellDetailSheet extends StatefulWidget {
  final String columnName;
  final String value;
  final int rowNumber;

  /// 保存回调；null 表示纯查看模式（只读展示）
  final void Function(String newValue)? onSave;

  const _CsvCellDetailSheet({required this.columnName, required this.value, required this.rowNumber, this.onSave});

  @override
  State<_CsvCellDetailSheet> createState() => _CsvCellDetailSheetState();
}

class _CsvCellDetailSheetState extends State<_CsvCellDetailSheet> {
  late final TextEditingController _controller = TextEditingController(text: widget.value)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 内容有实际改动时才允许保存，避免无意义写回
  bool get _changed => _controller.text != widget.value;

  void _save(BuildContext context) {
    final newValue = _controller.text;
    Navigator.of(context).pop();
    // 先关弹窗再回调：宿主收到新源码后会重建预览，避免弹窗挂在旧元素树上
    widget.onSave?.call(newValue);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final editable = widget.onSave != null;
    final empty = widget.value.trim().isEmpty;
    final fieldStyle = theme.textTheme.bodyLarge?.copyWith(
      // 详情页的主角是内容本身：比正文大 3 号并加中等字重
      fontSize: AppTypography.title,
      fontWeight: FontWeight.w500,
      height: 1.6,
      color: colorScheme.onSurface,
    );

    return Padding(
      // 键盘弹起时抬高内容，避免输入框被遮挡
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.68),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.columnName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: AppTypography.headline,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '第 ${widget.rowNumber} 行 · ${editable ? '点击可直接修改' : '单元格内容'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: AppTypography.label,
                          color: AppPalette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant, width: 1),
                ),
                child: editable
                    ? TextField(
                        key: const Key('csv-cell-edit-field'),
                        controller: _controller,
                        autofocus: true,
                        minLines: 2,
                        maxLines: null,
                        // 跟随弹窗容器尺寸滚动，长内容不受键盘挤压
                        style: fieldStyle,
                        decoration: const InputDecoration.collapsed(
                          hintText: '输入内容',
                          hintStyle: TextStyle(color: AppPalette.textMuted),
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectableText(
                          empty ? '（空）' : widget.value,
                          style: fieldStyle?.copyWith(color: empty ? AppPalette.textMuted : colorScheme.onSurface),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              editable ? '保存后内容写回笔记，逗号/引号/换行会自动转义' : (empty ? '此单元格没有内容' : '长按内容也可选择复制'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: AppTypography.label, color: AppPalette.textMuted),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: empty ? null : () => _copyToClipboard(context, widget.value, '已复制'),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('复制内容'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colorScheme.onSurface,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(fontSize: AppTypography.bodyLarge, fontWeight: FontWeight.w600),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      side: BorderSide(color: colorScheme.outlineVariant, width: 1),
                    ),
                  ),
                ),
                if (editable) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _changed ? () => _save(context) : null,
                      icon: const Icon(Icons.check_rounded, size: 16),
                      label: const Text('保存修改'),
                      style: FilledButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        disabledBackgroundColor: colorScheme.primary.withValues(alpha: 0.35),
                        disabledForegroundColor: colorScheme.onPrimary,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: AppTypography.bodyLarge, fontWeight: FontWeight.w600),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        side: theme.accentNeedsOutline
                            ? BorderSide(color: colorScheme.outlineVariant, width: 0.9)
                            : null,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片视图的行详情：所有列名 + 完整值
class _CsvRowDetailSheet extends StatefulWidget {
  final List<String> header;
  final List<String> cells;
  final int rowNumber;

  const _CsvRowDetailSheet({required this.header, required this.cells, required this.rowNumber});

  @override
  State<_CsvRowDetailSheet> createState() => _CsvRowDetailSheetState();
}

class _CsvRowDetailSheetState extends State<_CsvRowDetailSheet> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final header = widget.header;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.90),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '第 ${widget.rowNumber} 行',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: AppTypography.headline,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${header.length} 列 · 长按卡片可复制整行',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: AppTypography.label,
                          color: AppPalette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant, width: 1),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: header.length > 5,
                  thickness: 3,
                  radius: const Radius.circular(2),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      children: [
                        for (var i = 0; i < header.length; i++) ...[
                          if (i > 0) Container(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.7)),
                          _buildField(theme, i),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _copyToClipboard(context, encodeTsvRow(widget.cells), '已复制整行（TSV）'),
                icon: const Icon(Icons.content_copy_rounded, size: 16),
                label: const Text('复制整行（TSV）'),
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: AppTypography.bodyLarge, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  side: theme.accentNeedsOutline ? BorderSide(color: colorScheme.outlineVariant, width: 0.9) : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(ThemeData theme, int column) {
    final colorScheme = theme.colorScheme;
    final header = widget.header;
    final value = column < widget.cells.length ? widget.cells[column] : '';
    final empty = value.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            header[column],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: AppTypography.label,
              letterSpacing: 0,
              color: AppPalette.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            empty ? '（空）' : value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: AppTypography.body,
              height: 1.45,
              color: empty ? AppPalette.textMuted : colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态/错误态共用的居中提示
class _CsvStatusState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  const _CsvStatusState({required this.icon, required this.title, required this.description, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                // 空态图标也用实心 primary 色块，和表头保持同一套强调语言
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
                // 同色系背景下实心块补一圈发丝线交代边界
                border: theme.accentNeedsOutline ? Border.all(color: colorScheme.outlineVariant) : null,
              ),
              child: Icon(icon, size: 26, color: colorScheme.onPrimary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: AppTypography.title,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: AppTypography.bodySmall,
                height: 1.45,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    );
  }
}

Future<void> _copyToClipboard(BuildContext context, String text, String message) async {
  if (text.isEmpty) {
    Toast.info(context, '没有可复制的内容');
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    Toast.info(context, message);
  }
}

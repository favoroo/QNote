import 'package:flutter/material.dart';

class SelectItem<T> {
  final T value;
  final String label;

  const SelectItem({
    required this.value,
    required this.label,
  });
}

class QNoteSelect<T> extends StatefulWidget {
  final List<SelectItem<T>> items;
  final List<T> selectedValues;
  final ValueChanged<List<T>> onChanged;
  final bool isMultiSelect;
  final String? hint;
  final String? label;

  const QNoteSelect({
    super.key,
    required this.items,
    required this.selectedValues,
    required this.onChanged,
    this.isMultiSelect = false,
    this.hint,
    this.label,
  });

  @override
  State<QNoteSelect<T>> createState() => _QNoteSelectState<T>();
}

class _QNoteSelectState<T> extends State<QNoteSelect<T>> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  String _searchQuery = '';

  String _getDisplayText() {
    if (widget.selectedValues.isEmpty) return '';
    final selected = widget.items
        .where((item) => widget.selectedValues.contains(item.value))
        .map((item) => item.label)
        .join(', ');
    return selected;
  }

  void _openSelect() {
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    _searchQuery = '';

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => _SelectOverlay<T>(
        layerLink: _layerLink,
        fieldSize: size,
        screenSize: screenSize,
        items: widget.items,
        selectedValues: widget.selectedValues,
        isMultiSelect: widget.isMultiSelect,
        onSelected: _handleSelection,
        onDismiss: _closeSelect,
        onSearch: (query) {
          setState(() {
            _searchQuery = query;
          });
          _overlayEntry?.markNeedsBuild();
        },
        searchQuery: _searchQuery,
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _handleSelection(T value) {
    if (widget.isMultiSelect) {
      final newValues = List<T>.from(widget.selectedValues);
      if (newValues.contains(value)) {
        newValues.remove(value);
      } else {
        newValues.add(value);
      }
      widget.onChanged(newValues);
      setState(() {});
      _overlayEntry?.markNeedsBuild();
    } else {
      widget.onChanged([value]);
      _closeSelect();
    }
  }

  void _closeSelect() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _closeSelect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayText = _getDisplayText();
    final hasSelection = displayText.isNotEmpty;

    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _openSelect,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint ?? '请选择',
            suffixIcon: const Icon(Icons.arrow_drop_down),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          isEmpty: !hasSelection,
          child: hasSelection
              ? Text(
                  displayText,
                  style: theme.textTheme.bodyLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
        ),
      ),
    );
  }
}

class _SelectOverlay<T> extends StatefulWidget {
  final LayerLink layerLink;
  final Size fieldSize;
  final Size screenSize;
  final List<SelectItem<T>> items;
  final List<T> selectedValues;
  final bool isMultiSelect;
  final ValueChanged<T> onSelected;
  final VoidCallback onDismiss;
  final ValueChanged<String> onSearch;
  final String searchQuery;

  const _SelectOverlay({
    required this.layerLink,
    required this.fieldSize,
    required this.screenSize,
    required this.items,
    required this.selectedValues,
    required this.isMultiSelect,
    required this.onSelected,
    required this.onDismiss,
    required this.onSearch,
    required this.searchQuery,
  });

  @override
  State<_SelectOverlay<T>> createState() => _SelectOverlayState<T>();
}

class _SelectOverlayState<T> extends State<_SelectOverlay<T>>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<SelectItem<T>> get _filteredItems {
    if (widget.searchQuery.isEmpty) return widget.items;
    return widget.items
        .where((item) =>
            item.label.toLowerCase().contains(widget.searchQuery.toLowerCase()))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredItems = _filteredItems;
    final overlayHeight = widget.screenSize.height * 0.4;
    final maxMenuHeight = overlayHeight.clamp(200.0, 400.0);

    return Stack(
      children: [
        GestureDetector(
          onTap: widget.onDismiss,
          behavior: HitTestBehavior.opaque,
          child: SizedBox.expand(),
        ),
        CompositedTransformFollower(
          link: widget.layerLink,
          offset: Offset(0, widget.fieldSize.height + 4),
          showWhenUnlinked: false,
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              alignment: Alignment.topCenter,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                color: theme.colorScheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: widget.fieldSize.width,
                    maxHeight: maxMenuHeight,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          decoration: InputDecoration(
                            hintText: '搜索...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onChanged: widget.onSearch,
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child: filteredItems.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  '无匹配项',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                itemCount: filteredItems.length,
                                itemBuilder: (context, index) {
                                  final item = filteredItems[index];
                                  final isSelected = widget.selectedValues
                                      .contains(item.value);
                                  return ListTile(
                                    dense: true,
                                    leading: widget.isMultiSelect
                                        ? Checkbox(
                                            value: isSelected,
                                            onChanged: (_) =>
                                                widget.onSelected(item.value),
                                          )
                                        : isSelected
                                            ? Icon(
                                                Icons.check,
                                                size: 20,
                                                color:
                                                    theme.colorScheme.primary,
                                              )
                                            : const SizedBox(width: 20),
                                    title: Text(item.label),
                                    onTap: () =>
                                        widget.onSelected(item.value),
                                  );
                                },
                              ),
                      ),
                      if (widget.isMultiSelect) ...[
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: widget.onDismiss,
                              child: const Text('确定'),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

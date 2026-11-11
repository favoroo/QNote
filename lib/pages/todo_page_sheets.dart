part of 'todo_page.dart';
// 从 todo_page.dart 拆分：待办编辑底部弹层及其键盘避让外壳。

/// 仿小米待办：底部弹出小窗（用于添加或编辑待办事项）
class _TodoEditBottomSheet extends StatefulWidget {
  final Todo? todo;
  final String? folderId;
  final List<Folder> folders;
  final void Function({required String title, String? reminderTime, String repeatRule, String? folderId}) onSaveAdd;
  final void Function({required Todo updatedTodo}) onSaveEdit;
  final void Function(Todo todo)? onDelete;
  final void Function(Todo todo)? onQuoteToQ;

  const _TodoEditBottomSheet({
    this.todo,
    this.folderId,
    required this.folders,
    required this.onSaveAdd,
    required this.onSaveEdit,
    this.onDelete,
    this.onQuoteToQ,
  });

  @override
  State<_TodoEditBottomSheet> createState() => _TodoEditBottomSheetState();
}

class _TodoEditBottomSheetState extends State<_TodoEditBottomSheet> {
  late TextEditingController _textController;
  final FocusNode _textFocusNode = FocusNode();
  String? _reminderTime;
  String _repeatRule = 'none';
  String? _selectedFolderId;
  bool _isCompleted = false;
  bool _lastHasText = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.todo?.title ?? '');
    _reminderTime = widget.todo?.reminderTime;
    _repeatRule = widget.todo?.repeatRule ?? 'none';
    _selectedFolderId = widget.todo?.folderId ?? widget.folderId;
    _isCompleted = widget.todo?.isCompleted ?? false;
    _textController.addListener(_onTextChanged);
    _lastHasText = _textController.text.trim().isNotEmpty;
    // 弹层入场动画结束后再拉起键盘，避免入场与键盘弹出两段动画同帧叠加掉帧
    Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        _textFocusNode.requestFocus();
      }
    });
  }

  void _onTextChanged() {
    // 发送按钮显隐只依赖 hasText，仅在翻转时重建，避免每次按键整层 setState
    final hasText = _textController.text.trim().isNotEmpty;
    if (hasText != _lastHasText) {
      _lastHasText = hasText;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _textFocusNode.dispose();
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  void _handleSubmitted(String value) {
    final text = value.trim();
    if (widget.todo == null) {
      // 添加模式：回车即可连续添加待办
      if (text.isNotEmpty) {
        widget.onSaveAdd(
          title: text,
          reminderTime: _reminderTime,
          repeatRule: _repeatRule,
          folderId: _selectedFolderId,
        );
        HapticFeedback.lightImpact();
        _textController.clear();
        setState(() {
          _reminderTime = null;
          _repeatRule = 'none';
        });
      }
    } else {
      // 编辑模式：回车直接保存并关闭
      _handleComplete();
    }
  }

  void _handleComplete() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      // 若没有编辑内容，直接返回，程序不会把空的事项添加上去
      Navigator.pop(context);
      return;
    }

    if (widget.todo == null) {
      // 添加待办
      widget.onSaveAdd(title: text, reminderTime: _reminderTime, repeatRule: _repeatRule, folderId: _selectedFolderId);
    } else {
      // 编辑待办
      widget.onSaveEdit(
        updatedTodo: widget.todo!.copyWith(
          title: text,
          reminderTime: _reminderTime,
          repeatRule: _repeatRule,
          folderId: _selectedFolderId,
          isCompleted: _isCompleted,
        ),
      );
    }
    Navigator.pop(context);
  }

  Future<void> _pickReminderTime() async {
    final reminder = _reminderTime;
    final initialDate = reminder != null ? ReminderUtils.parse(reminder) : null;
    final result = await showTimePickerDialog(context: context, initialTime: initialDate, title: '提醒时间');
    if (result != null) {
      setState(() {
        _reminderTime = ReminderUtils.format(result);
      });
    }
  }

  Future<void> _pickRepeatRule() async {
    final rules = [
      {'key': 'none', 'label': '不重复', 'desc': '单次任务，不自动生成'},
      {'key': 'daily', 'label': '每天', 'desc': '完成后生成次日待办'},
      {'key': 'workday', 'label': '工作日', 'desc': '周一至周五，周末顺延至下周一'},
      {'key': 'weekly', 'label': '每周', 'desc': '每周同一时间重复'},
      {'key': 'monthly', 'label': '每月', 'desc': '每月同日重复'},
      {'key': 'yearly', 'label': '每年', 'desc': '每年同日重复'},
    ];

    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.repeat, color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '重复周期',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...rules.map((r) {
                  final isSelected = _repeatRule == r['key'];
                  return ListTile(
                    leading: Icon(
                      isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline,
                    ),
                    title: Text(
                      r['label']!,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      r['desc']!,
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onTap: () => Navigator.pop(ctx, r['key']),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null) {
      setState(() {
        _repeatRule = selected;
      });
    }
  }

  Future<void> _pickFolder() async {
    if (widget.folders.length <= 1) return;
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.folder_outlined, color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '选择分类',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...widget.folders.map((f) {
                  final isCurrent = _selectedFolderId == f.id;
                  return ListTile(
                    leading: Icon(
                      isCurrent ? Icons.folder : Icons.folder_outlined,
                      color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      f.name,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    trailing: isCurrent
                        ? Text('当前分类', style: TextStyle(fontSize: 12, color: theme.colorScheme.primary))
                        : null,
                    onTap: () => Navigator.pop(ctx, f.id),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null) {
      setState(() {
        _selectedFolderId = selected;
      });
    }
  }

  String _repeatRuleLabel(String rule) {
    switch (rule) {
      case 'daily':
        return '每天';
      case 'workday':
        return '工作日';
      case 'weekly':
        return '每周';
      case 'monthly':
        return '每月';
      case 'yearly':
        return '每年';
      default:
        return '重复';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasText = _textController.text.trim().isNotEmpty;

    // 当前选中的分类名称
    final selectedFolder =
        widget.folders.where((f) => f.id == _selectedFolderId).firstOrNull ?? widget.folders.firstOrNull;
    final selectedFolderName = selectedFolder?.name ?? '';

    // 键盘避让外壳单独精确订阅 viewInsets，内容子树经 child 复用，
    // 键盘动画期间只有外壳逐帧重建，弹层内容不再整层 rebuild
    return _TodoSheetInsetShell(
      decorationColor: isDark ? const Color(0xFF222222) : colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 待办输入区（左侧圆角方块，中间自动聚焦输入框，更舒展宽阔）
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: widget.todo == null
                    ? null
                    : () {
                        setState(() {
                          _isCompleted = !_isCompleted;
                        });
                      },
                child: Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(top: 3, right: 14),
                  decoration: BoxDecoration(
                    color: _isCompleted
                        ? (isDark ? Colors.white24 : colorScheme.primary.withValues(alpha: 0.15))
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _isCompleted
                          ? (isDark ? Colors.white38 : colorScheme.outline.withValues(alpha: 0.4))
                          : (isDark ? Colors.white54 : colorScheme.outline.withValues(alpha: 0.5)),
                      width: 2.0,
                    ),
                  ),
                  child: _isCompleted
                      ? Icon(Icons.check, size: 15, color: isDark ? Colors.white70 : colorScheme.primary)
                      : null,
                ),
              ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: TextField(
                    controller: _textController,
                    focusNode: _textFocusNode,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _handleSubmitted,
                    style: TextStyle(
                      fontSize: 17.5,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white : colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 2),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      hintText: widget.todo == null ? '回车连续添加' : '输入待办内容',
                      hintStyle: TextStyle(
                        fontSize: 17.5,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.35)
                            : colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          // 底部功能胶囊栏与完成按钮
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // 设置提醒胶囊
                      InkWell(
                        onTap: _pickReminderTime,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                          decoration: BoxDecoration(
                            color: _reminderTime != null
                                ? colorScheme.primary.withValues(alpha: 0.15)
                                : (isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.alarm,
                                size: 15,
                                color: _reminderTime != null
                                    ? colorScheme.primary
                                    : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _reminderTime ?? '提醒',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: _reminderTime != null ? FontWeight.w600 : FontWeight.normal,
                                  color: _reminderTime != null
                                      ? colorScheme.primary
                                      : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                ),
                              ),
                              if (_reminderTime != null) ...[
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () {
                                    setState(() => _reminderTime = null);
                                  },
                                  child: Icon(Icons.close, size: 13, color: colorScheme.primary),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 设置重复胶囊
                      InkWell(
                        onTap: _pickRepeatRule,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                          decoration: BoxDecoration(
                            color: _repeatRule != 'none'
                                ? colorScheme.primary.withValues(alpha: 0.15)
                                : (isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.repeat,
                                size: 15,
                                color: _repeatRule != 'none'
                                    ? colorScheme.primary
                                    : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _repeatRuleLabel(_repeatRule),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: _repeatRule != 'none' ? FontWeight.w600 : FontWeight.normal,
                                  color: _repeatRule != 'none'
                                      ? colorScheme.primary
                                      : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 切换分类胶囊（若分类数大于1）
                      if (widget.folders.length > 1 && selectedFolderName.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: _pickFolder,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.folder_outlined,
                                  size: 15,
                                  color: isDark ? Colors.white70 : colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  selectedFolderName,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isDark ? Colors.white70 : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      // 编辑模式：给小Q 与 删除操作
                      if (widget.todo != null) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          icon: QIcon(size: 20, color: colorScheme.primary),
                          tooltip: '给小Q',
                          onPressed: () {
                            Navigator.pop(context);
                            widget.onQuoteToQ?.call(widget.todo!);
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline, size: 20, color: colorScheme.error),
                          tooltip: '删除',
                          onPressed: () {
                            Navigator.pop(context);
                            widget.onDelete?.call(widget.todo!);
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 圆形上箭头完成/提交按钮（统一遵循应用全局主题色）
              Semantics(
                button: true,
                label: '完成',
                child: Tooltip(
                  message: '完成',
                  child: GestureDetector(
                    onTap: _handleComplete,
                    child: AnimatedContainer(
                      duration: AppDurations.normal,
                      curve: Curves.easeInOut,
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasText
                            ? colorScheme.primary
                            : (isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.8)),
                      ),
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        size: 20,
                        color: hasText
                            ? colorScheme.onPrimary
                            : (isDark
                                  ? Colors.white.withValues(alpha: 0.3)
                                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 待办编辑弹层的键盘避让外壳。
///
/// 单独精确订阅 viewInsets 计算底部留白与 SafeArea 开关，键盘动画期间只有
/// 此小节点逐帧重建；弹层内容经 child 传入保持 Element 复用，不再整层 rebuild。
class _TodoSheetInsetShell extends StatelessWidget {
  final Color decorationColor;
  final Widget child;

  const _TodoSheetInsetShell({required this.decorationColor, required this.child});

  @override
  Widget build(BuildContext context) {
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
    final bottomMargin = viewInsetsBottom > 0 ? (viewInsetsBottom + 12.0) : 16.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomMargin, left: 14, right: 14),
      child: Container(
        decoration: BoxDecoration(
          color: decorationColor,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 16, offset: const Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        child: SafeArea(top: false, bottom: viewInsetsBottom == 0, child: child),
      ),
    );
  }
}

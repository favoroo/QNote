part of 'ai_page.dart';
// 从 ai_page_widgets.dart 拆分：多选笔记 / 待办 / 日记的选择弹窗及其 State。

class _MultiNoteSelectorDialog extends StatefulWidget {
  final List<Note> notes;
  final List<String> initialSelected;
  const _MultiNoteSelectorDialog({required this.notes, required this.initialSelected});

  @override
  State<_MultiNoteSelectorDialog> createState() => _MultiNoteSelectorDialogState();
}

class _MultiNoteSelectorDialogState extends State<_MultiNoteSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected = _selected.length == widget.notes.length && widget.notes.isNotEmpty;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('选择笔记'),
          if (widget.notes.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selected.clear();
                  } else {
                    _selected = widget.notes.map((n) => n.id).toList();
                  }
                });
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(isAllSelected ? '取消全选' : '全选', style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.notes.isEmpty
            ? const Center(child: Text('暂无笔记'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.notes.length,
                itemBuilder: (ctx, i) {
                  final note = widget.notes[i];
                  final isSelected = _selected.contains(note.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      DateFormat('MM/dd HH:mm').format(note.updatedAt),
                      style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(note.id);
                        } else {
                          _selected.remove(note.id);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _selected), child: Text('确定（${_selected.length}）')),
      ],
    );
  }
}

class _MultiTodoSelectorDialog extends StatefulWidget {
  final List<Todo> todos;
  final List<String> initialSelected;
  const _MultiTodoSelectorDialog({required this.todos, required this.initialSelected});

  @override
  State<_MultiTodoSelectorDialog> createState() => _MultiTodoSelectorDialogState();
}

class _MultiTodoSelectorDialogState extends State<_MultiTodoSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected = _selected.length == widget.todos.length && widget.todos.isNotEmpty;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('选择待办'),
          if (widget.todos.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selected.clear();
                  } else {
                    _selected = widget.todos.map((t) => t.id).toList();
                  }
                });
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(isAllSelected ? '取消全选' : '全选', style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.todos.isEmpty
            ? const Center(child: Text('暂无待办'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.todos.length,
                itemBuilder: (ctx, i) {
                  final todo = widget.todos[i];
                  final isSelected = _selected.contains(todo.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Text(
                      todo.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(decoration: todo.isCompleted ? TextDecoration.lineThrough : null),
                    ),
                    subtitle: Text(
                      todo.isCompleted ? '已完成' : '未完成',
                      style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(todo.id);
                        } else {
                          _selected.remove(todo.id);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.of(context).pop(_selected), child: const Text('确定')),
      ],
    );
  }
}

class _MultiJournalSelectorDialog extends StatefulWidget {
  final List<Note> journals;
  final List<String> initialSelected;
  const _MultiJournalSelectorDialog({required this.journals, required this.initialSelected});

  @override
  State<_MultiJournalSelectorDialog> createState() => _MultiJournalSelectorDialogState();
}

class _MultiJournalSelectorDialogState extends State<_MultiJournalSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected = _selected.length == widget.journals.length && widget.journals.isNotEmpty;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('选择日记'),
          if (widget.journals.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selected.clear();
                  } else {
                    _selected = widget.journals.map((j) => j.id).toList();
                  }
                });
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(isAllSelected ? '取消全选' : '全选', style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.journals.isEmpty
            ? const Center(child: Text('暂无日记'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.journals.length,
                itemBuilder: (ctx, i) {
                  final journal = widget.journals[i];
                  final isSelected = _selected.contains(journal.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Row(
                      children: [
                        const Icon(Icons.auto_stories_outlined, size: 16, color: Color(0xFFE91E63)),
                        const SizedBox(width: 6),
                        Text('${journal.title} 日记', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        journal.content.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(journal.id);
                        } else {
                          _selected.remove(journal.id);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _selected), child: Text('确定（${_selected.length}）')),
      ],
    );
  }
}

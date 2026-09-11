import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

class AiPage extends ConsumerStatefulWidget {
  const AiPage({super.key});

  @override
  ConsumerState<AiPage> createState() => _AiPageState();
}

class _AiPageState extends ConsumerState<AiPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _isTyping = false;
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String? _selectedPeriodPreset; // '今日', '本周', '本月', '全部', '自定义'
  String get _periodPreset => _selectedPeriodPreset ?? '本周';
  bool _isBatchMode = false;
  List<String> _selectedSessionIds = [];
  String? _activeModelId;

  // 豆包式附件状态（图片、分享给AI的日记、笔记与待办）
  final List<String> _attachedImages = [];
  final List<String> _attachedJournalIds = [];
  final List<String> _attachedNoteIds = [];
  final List<String> _attachedTodoIds = [];
  final Map<String, String> _journalTitles = {};
  final Map<String, String> _noteTitles = {};
  final Map<String, String> _todoTitles = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 默认本周（周一至今天）
    _filterStartDate = today.subtract(Duration(days: today.weekday - 1));
    _filterEndDate = today;
    _selectedPeriodPreset = '本周';
    _initActiveModelId();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncContextFilter();
      _scrollToBottom();
    });
  }

  Future<void> _initActiveModelId() async {
    final roles = await ref.read(aiRolesProvider.future);
    if (roles != null && roles.assistantUseFreeModel) {
      if (mounted) setState(() => _activeModelId = '__free_model__');
      return;
    }
    try {
      final config = await AiRoleService.instance.getEffectiveConfigForRole('assistant');
      if (mounted) {
        setState(() => _activeModelId = config.id);
      }
    } catch (_) {
      if (roles?.assistant != null) {
        if (mounted) setState(() => _activeModelId = roles!.assistant);
      } else {
        final config = await ref.read(defaultAiConfigProvider.future);
        if (config != null && mounted) setState(() => _activeModelId = config.id);
      }
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        if (immediate) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        } else {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: AppDurations.medium,
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  void _scrollToBottomIfNeeded() {
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      final isNearBottom = pos.maxScrollExtent - pos.pixels < 150;
      if (isNearBottom || pos.pixels == 0) {
        _scrollToBottom(immediate: true);
      }
    }
  }

  void _syncContextFilter() {
    ref.read(contextFilterProvider.notifier).state = AiContextFilter(
      scope: 'all',
      startDate: _filterStartDate,
      endDate: _filterEndDate,
      selectedNoteIds: const [],
      selectedTodoIds: const [],
      selectedTags: const [],
    );
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    final hasImages = _attachedImages.isNotEmpty;
    final hasNotes = _attachedNoteIds.isNotEmpty;
    final hasTodos = _attachedTodoIds.isNotEmpty;
    final hasJournals = _attachedJournalIds.isNotEmpty;

    if ((text.isEmpty && !hasImages && !hasNotes && !hasTodos && !hasJournals) || _isTyping) {
      return;
    }

    final content = text.isNotEmpty
        ? text
        : (hasImages ? '请结合图片进行分析' : '请结合我分享的内容进行分析');

    final imagesToSend = hasImages ? List<String>.from(_attachedImages) : null;
    final notesToSend = hasNotes ? List<String>.from(_attachedNoteIds) : null;
    final todosToSend = hasTodos ? List<String>.from(_attachedTodoIds) : null;
    final journalsToSend = hasJournals ? List<String>.from(_attachedJournalIds) : null;

    HapticFeedback.lightImpact();
    _inputController.clear();
    setState(() {
      _attachedImages.clear();
      _attachedNoteIds.clear();
      _attachedTodoIds.clear();
      _attachedJournalIds.clear();
    });
    FocusScope.of(context).unfocus();
    setState(() => _isTyping = true);
    _syncContextFilter();
    _scrollToBottom();

    try {
      if (ref.read(currentChatProvider) == null) {
        final session = await ref
            .read(chatSessionListProvider.notifier)
            .createSession();
        ref.read(currentChatProvider.notifier).setSession(session);
      }

      await ref.read(currentChatProvider.notifier).sendMessage(
            content,
            images: imagesToSend,
            noteIds: notesToSend,
            todoIds: todosToSend,
            journalIds: journalsToSend,
          );
    } catch (e) {
      debugPrint('发送消息失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isTyping = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _openDatePicker() async {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final startOfMonth = DateTime(today.year, today.month, 1);

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_view_week, size: 20),
                  title: const Text('本周（默认）', style: TextStyle(fontSize: 14)),
                  trailing: _periodPreset == '本周'
                      ? Icon(Icons.check, color: theme.colorScheme.primary, size: 20)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _filterStartDate = startOfWeek;
                      _filterEndDate = today;
                      _selectedPeriodPreset = '本周';
                    });
                    _syncContextFilter();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.today, size: 20),
                  title: const Text('今日', style: TextStyle(fontSize: 14)),
                  trailing: _periodPreset == '今日'
                      ? Icon(Icons.check, color: theme.colorScheme.primary, size: 20)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _filterStartDate = today;
                      _filterEndDate = today;
                      _selectedPeriodPreset = '今日';
                    });
                    _syncContextFilter();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_month, size: 20),
                  title: const Text('本月', style: TextStyle(fontSize: 14)),
                  trailing: _periodPreset == '本月'
                      ? Icon(Icons.check, color: theme.colorScheme.primary, size: 20)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _filterStartDate = startOfMonth;
                      _filterEndDate = today;
                      _selectedPeriodPreset = '本月';
                    });
                    _syncContextFilter();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive, size: 20),
                  title: const Text('全部', style: TextStyle(fontSize: 14)),
                  trailing: _periodPreset == '全部'
                      ? Icon(Icons.check, color: theme.colorScheme.primary, size: 20)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _filterStartDate = null;
                      _filterEndDate = null;
                      _selectedPeriodPreset = '全部';
                    });
                    _syncContextFilter();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_today_outlined, size: 20),
                  title: const Text('选择特定单日...', style: TextStyle(fontSize: 14)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _filterStartDate ?? today,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      locale: const Locale('zh', 'CN'),
                    );
                    if (picked != null) {
                      setState(() {
                        _filterStartDate = picked;
                        _filterEndDate = picked;
                        _selectedPeriodPreset = '自定义';
                      });
                      _syncContextFilter();
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.date_range_outlined, size: 20),
                  title: const Text('选择自定义范围...', style: TextStyle(fontSize: 14)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final picked = await showDateRangePicker(
                      context: context,
                      initialDateRange: _filterStartDate != null && _filterEndDate != null
                          ? DateTimeRange(start: _filterStartDate!, end: _filterEndDate!)
                          : null,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      locale: const Locale('zh', 'CN'),
                    );
                    if (picked != null) {
                      setState(() {
                        _filterStartDate = picked.start;
                        _filterEndDate = picked.end;
                        _selectedPeriodPreset = '自定义';
                      });
                      _syncContextFilter();
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickFromCamera() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 80,
      );
      if (image != null && mounted) {
        setState(() {
          _attachedImages.add(image.path);
        });
      }
    } catch (e) {
      debugPrint('拍照失败: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final images = await GalleryHelper.pickMultiImages(
        context,
        maxAssets: 9,
      );
      if (images.isNotEmpty && mounted) {
        setState(() {
          for (final img in images) {
            if (!_attachedImages.contains(img.path)) {
              _attachedImages.add(img.path);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('相册选图失败: $e');
    }
  }

  Future<void> _pickJournals() async {
    final journals = await JournalService.instance.getAllJournals();
    if (!mounted) return;
    if (journals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无已写日记，可在时间线左下角撰写日记')),
      );
      return;
    }
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiJournalSelectorDialog(
        journals: journals,
        initialSelected: _attachedJournalIds,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedJournalIds.clear();
        _attachedJournalIds.addAll(result);
        for (final j in journals) {
          _journalTitles[j.id] = '${j.title} 日记';
        }
      });
    }
  }

  Future<void> _pickNotes() async {
    final notes = await NoteRepository().getAll();
    if (!mounted) return;
    // 排除日记笔记，保持普通笔记专属
    final validNotes = notes
        .where((n) => !n.isDeleted && !JournalService.isJournalNote(n.id))
        .toList();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiNoteSelectorDialog(
        notes: validNotes,
        initialSelected: _attachedNoteIds,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedNoteIds.clear();
        _attachedNoteIds.addAll(result);
        for (final n in validNotes) {
          _noteTitles[n.id] = n.title.isNotEmpty ? n.title : '无标题笔记';
        }
      });
    }
  }

  Future<void> _pickTodos() async {
    final todos = await TodoRepository().getAll();
    if (!mounted) return;
    final validTodos = todos.where((t) => !t.isDeleted).toList();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _MultiTodoSelectorDialog(
        todos: validTodos,
        initialSelected: _attachedTodoIds,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _attachedTodoIds.clear();
        _attachedTodoIds.addAll(result);
        for (final t in validTodos) {
          _todoTitles[t.id] = t.title.isNotEmpty ? t.title : '无标题待办';
        }
      });
    }
  }

  void _showAttachmentMenu(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildAttachmentOption(
                        icon: Icons.camera_alt_rounded,
                        label: '相机',
                        iconColor: const Color(0xFF3F51B5),
                        bgColor: const Color(0xFF3F51B5).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickFromCamera();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.photo_library_rounded,
                        label: '相册',
                        iconColor: const Color(0xFF009688),
                        bgColor: const Color(0xFF009688).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickFromGallery();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.auto_stories_rounded,
                        label: '日记',
                        iconColor: const Color(0xFFE91E63),
                        bgColor: const Color(0xFFE91E63).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickJournals();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.description_rounded,
                        label: '笔记',
                        iconColor: const Color(0xFFFF9800),
                        bgColor: const Color(0xFFFF9800).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickNotes();
                        },
                        theme: theme,
                      ),
                      const SizedBox(width: 18),
                      _buildAttachmentOption(
                        icon: Icons.check_circle_outline_rounded,
                        label: '待办',
                        iconColor: const Color(0xFF4CAF50),
                        bgColor: const Color(0xFF4CAF50).withValues(alpha: 0.12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickTodos();
                        },
                        theme: theme,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color iconColor,
    required Color bgColor,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openExportDialog() async {
    final contextText = await ref
        .read(currentChatProvider.notifier)
        .exportContext();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => _ExportDialog(
        contextText: contextText,
        initialQuestion: _inputController.text,
      ),
    );
  }

  Future<void> _openModelSelector() async {
    final configs = await ref.read(aiConfigListProvider.future);
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _ModelSelectorDialog(configs: configs, activeModelId: _activeModelId),
    );
    if (selected != null && selected != _activeModelId) {
      setState(() => _activeModelId = selected);
      final roles = await ref.read(aiRolesProvider.future);
      final isFree = selected == '__free_model__';
      final oldRoles = roles ?? const AiRoles();
      final newRoles = AiRoles(
        assistant: isFree ? null : selected,
        assistantUseFreeModel: isFree,
        timelineOptimization: oldRoles.timelineOptimization,
        timelineOptimizationUseFreeModel: oldRoles.timelineOptimizationUseFreeModel,
      );
      await saveAiRoles(newRoles);
      ref.invalidate(aiRolesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentChat = ref.watch(currentChatProvider);
    final aiConfigsAsync = ref.watch(aiConfigListProvider);
    final theme = Theme.of(context);

    // Listen to aiConfigsAsync to ensure _activeModelId is always valid
    ref.listen<AsyncValue<List<AiConfig>>>(aiConfigListProvider, (prev, next) {
      if (next is AsyncData<List<AiConfig>>) {
        final configs = next.value;
        if (configs.isNotEmpty) {
          // If current active ID is not in the list, or null, pick the first or default
          final currentValid = configs.any((c) => c.id == _activeModelId);
          if (!currentValid) {
            final defaultCfg = configs.where((c) => c.isDefault).firstOrNull ?? configs.first;
            setState(() => _activeModelId = defaultCfg.id);
          }
        } else {
          setState(() => _activeModelId = null);
        }
      }
    });

    ref.listen(currentChatProvider, (_, _) => _scrollToBottom());
    ref.listen(aiStreamingMessageProvider, (prev, next) {
      if (next != null) {
        _scrollToBottomIfNeeded();
      }
    });

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('小Q助手'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      ),
      // 历史抽屉的 sessionsAsync 与 currentChat.id 订阅下沉，避免顶层 rebuild 连带
      endDrawer: Consumer(
        builder: (context, ref, _) {
          final sessionsAsync = ref.watch(chatSessionListProvider);
          final activeId = ref.watch(
            currentChatProvider.select((c) => c?.id),
          );
          return _buildHistoryDrawer(sessionsAsync, activeId, theme);
        },
      ),
      body: Column(
        children: [
          _buildDateFilterBar(theme),
          Expanded(child: _buildChatArea(currentChat, theme)),
          _buildInputArea(aiConfigsAsync, theme),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildDateFilterBar(ThemeData theme) {
    String dateText;
    if (_periodPreset == '今日') {
      dateText = '今日';
    } else if (_periodPreset == '本周') {
      dateText = '本周';
    } else if (_periodPreset == '本月') {
      dateText = '本月';
    } else if (_periodPreset == '全部') {
      dateText = '全部';
    } else if (_filterStartDate != null) {
      if (_filterEndDate != null && !_isSameDay(_filterStartDate!, _filterEndDate!)) {
        dateText =
            '${DateFormat('MM/dd').format(_filterStartDate!)}-${DateFormat('MM/dd').format(_filterEndDate!)}';
      } else {
        dateText = DateFormat('yyyy/MM/dd').format(_filterStartDate!);
      }
    } else {
      dateText = '全部';
    }

    final isDefaultWeek = _periodPreset == '本周';
    final hasActiveFilter = _periodPreset != '全部';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
            width: 0.8,
          ),
        ),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: _openDatePicker,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: hasActiveFilter
                    ? theme.colorScheme.primary.withValues(alpha: 0.12)
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: hasActiveFilter
                      ? theme.colorScheme.primary.withValues(alpha: 0.3)
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _periodPreset == '今日'
                        ? Icons.today
                        : (_periodPreset == '本月'
                            ? Icons.calendar_month
                            : (_periodPreset == '全部'
                                ? Icons.all_inclusive
                                : Icons.calendar_view_week)),
                    size: 14,
                    color: hasActiveFilter
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    dateText,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: hasActiveFilter ? FontWeight.w600 : FontWeight.normal,
                      color: hasActiveFilter
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: hasActiveFilter
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (!isDefaultWeek) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: () {
                final now = DateTime.now();
                final today = DateTime(now.year, now.month, now.day);
                setState(() {
                  _filterStartDate = today.subtract(Duration(days: today.weekday - 1));
                  _filterEndDate = today;
                  _selectedPeriodPreset = '本周';
                });
                _syncContextFilter();
              },
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Tooltip(
                  message: '恢复为默认本周',
                  child: Icon(
                    Icons.refresh,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.ios_share,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: _openExportDialog,
            tooltip: '导出上下文与Prompt',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildChatArea(ChatSession? currentChat, ThemeData theme) {
    final messages = currentChat?.messages ?? [];
    
    // If messages are empty, virtualize the assistant's greeting bubble so it's shown.
    final displayMessages = messages.isEmpty
        ? [
            ChatMessage(
              role: 'assistant',
              content: defaultSystemPrompts['assistant_greeting'] ?? '你好！我是你的全能助手「小Q」。你可以直接向我提问，或者让我帮你添加待办、记录流水、修改笔记与设置等。',
              timestamp: DateTime.now(),
            )
          ]
        : messages;

    final hasStreaming = ref.watch(aiStreamingMessageProvider.select((value) => value != null));
    final showTyping =
        _isTyping && !hasStreaming && messages.isNotEmpty && messages.last.role == 'user';
    final showStreaming = hasStreaming;

    final totalCount = displayMessages.length + (showTyping ? 1 : 0) + (showStreaming ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        // 隔离每条消息的重绘，流式输出时只重绘最后一条
        if (index < displayMessages.length) {
          return RepaintBoundary(
            child: _ChatBubble(message: displayMessages[index]),
          );
        }
        if (showTyping && index == displayMessages.length) {
          return const _TypingBubble();
        }
        return const _StreamingBubble();
      },
    );
  }

  Widget _buildInputArea(
    AsyncValue<List<AiConfig>> aiConfigsAsync,
    ThemeData theme,
  ) {
    final configs = aiConfigsAsync.valueOrNull ?? [];
    final activeName = _getActiveConfigName(configs);
    final hasAttachments = _attachedImages.isNotEmpty ||
        _attachedJournalIds.isNotEmpty ||
        _attachedNoteIds.isNotEmpty ||
        _attachedTodoIds.isNotEmpty;

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. 多模型切换胶囊（仅配置了多个模型时精简展示在右侧）
              if (configs.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, right: 2),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: _openModelSelector,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              activeName,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

              // 2. 豆包式附件挂载条（图片缩略图、分享的笔记、分享的待办）
              if (hasAttachments) ...[
                _buildAttachmentBar(theme),
                const SizedBox(height: 6),
              ],

              // 3. 底部输入栏与操作按钮
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 附件/分享加号按钮（类似豆包）
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, right: 6),
                    child: InkWell(
                      onTap: () => _showAttachmentMenu(context, theme),
                      borderRadius: BorderRadius.circular(22),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.add_rounded,
                          size: 26,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _buildInputField(theme)),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _inputController,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      final canSend = (hasText || hasAttachments) && !_isTyping;
                      return GestureDetector(
                        onTap: canSend ? _sendMessage : null,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: canSend
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              Icons.send_rounded,
                              size: 22,
                              color: canSend
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentBar(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 64),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 已选图片缩略图
            ..._attachedImages.map((imgPath) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: UnifiedImage(
                          imagePath: imgPath,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedImages.remove(imgPath);
                          });
                        },
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),

            // 已选分享日记
            ..._attachedJournalIds.map((jId) {
              final title = _journalTitles[jId] ?? '日记';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.auto_stories_outlined,
                        size: 14,
                        color: Color(0xFFE91E63),
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedJournalIds.remove(jId);
                          });
                        },
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 已选分享笔记
            ..._attachedNoteIds.map((noteId) {
              final title = _noteTitles[noteId] ?? '笔记';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedNoteIds.remove(noteId);
                          });
                        },
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 已选分享待办
            ..._attachedTodoIds.map((todoId) {
              final title = _todoTitles[todoId] ?? '待办';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_box_outlined,
                        size: 14,
                        color: theme.colorScheme.secondary,
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedTodoIds.remove(todoId);
                          });
                        },
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 继续添加小卡片按钮
            InkWell(
              onTap: () => _showAttachmentMenu(context, theme),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '添加',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputField(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 120),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          TextField(
            controller: _inputController,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              filled: false,
              hintText: '输入问题或指令...',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: EdgeInsets.only(
                left: 16,
                top: 10,
                bottom: 10,
                right: 42,
              ),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendMessage(),
          ),
          Positioned(
            right: 6,
            bottom: 4,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _inputController,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _inputController.clear();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withValues(alpha: 0.85),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.error.withValues(alpha: 0.25),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _getActiveConfigName(List<AiConfig> configs) {
    if (_activeModelId == '__free_model__') return 'QNote内置模型';
    if (_activeModelId == null) return '默认';
    final config = configs.where((c) => c.id == _activeModelId).firstOrNull;
    return config?.name ?? '默认';
  }

  Widget _buildHistoryDrawer(
    AsyncValue<List<ChatSession>> sessionsAsync,
    String? activeId,
    ThemeData theme,
  ) {
    return Drawer(
      child: sessionsAsync.when(
        data: (sessions) {
          return Column(
          children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '对话历史',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (sessions.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.grid_view,
                              size: 18,
                              color: _isBatchMode
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            onPressed: () {
                              setState(() {
                                _isBatchMode = !_isBatchMode;
                                if (!_isBatchMode) _selectedSessionIds = [];
                              });
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: !_isBatchMode
                    ? SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新建对话'),
                          onPressed: () async {
                            final session = await ref
                                .read(chatSessionListProvider.notifier)
                                .createSession();
                            ref
                                .read(currentChatProvider.notifier)
                                .setSession(session);
                            if (!mounted) return;
                            Navigator.pop(context);
                          },
                        ),
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                setState(() {
                                  _selectedSessionIds =
                                      _selectedSessionIds.length ==
                                          sessions.length
                                      ? []
                                      : sessions.map((s) => s.id).toList();
                                });
                              },
                              child: Text(
                                _selectedSessionIds.length == sessions.length
                                    ? '取消全选'
                                    : '全选',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                              ),
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('确认'),
                                    content: const Text('确定要清空所有对话吗？'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('确定'),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok == true) {
                                  for (final s in sessions) {
                                    await ref
                                        .read(chatSessionListProvider.notifier)
                                        .deleteSession(s.id);
                                  }
                                  ref
                                      .read(currentChatProvider.notifier)
                                      .setSession(null);
                                  setState(() {
                                    _isBatchMode = false;
                                    _selectedSessionIds = [];
                                  });
                                }
                              },
                              child: const Text('清空全部'),
                            ),
                          ),
                        ],
                      ),
              ),
              const Divider(height: 1),
              Expanded(
                child: sessions.isEmpty
                    ? const EmptyStateWidget(icon: Icons.chat_bubble_outline, message: '暂无对话')
                    : ListView.builder(
                        itemCount: sessions.length,
                        itemBuilder: (ctx, i) => _buildSessionTile(
                          sessions[i],
                          sessions[i].id == activeId,
                          theme,
                        ),
                      ),
              ),
              if (_isBatchMode && _selectedSessionIds.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text('删除已选 (${_selectedSessionIds.length})'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                      ),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('确认'),
                            content: Text(
                              '确定要删除选中的 ${_selectedSessionIds.length} 个对话吗？',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('确定'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          for (final id in _selectedSessionIds) {
                            await ref
                                .read(chatSessionListProvider.notifier)
                                .deleteSession(id);
                          }
                          final currentId = ref.read(currentChatProvider)?.id;
                          if (currentId != null &&
                              _selectedSessionIds.contains(currentId)) {
                            ref
                                .read(currentChatProvider.notifier)
                                .setSession(null);
                          }
                          setState(() {
                            _selectedSessionIds = [];
                            _isBatchMode = false;
                          });
                        }
                      },
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Widget _buildSessionTile(
    ChatSession session,
    bool isActive,
    ThemeData theme,
  ) {
    final isSelected = _selectedSessionIds.contains(session.id);
    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: theme.colorScheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('确认'),
                content: const Text('确定要删除这个对话吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) {
        ref.read(chatSessionListProvider.notifier).deleteSession(session.id);
        if (ref.read(currentChatProvider)?.id == session.id) {
          ref.read(currentChatProvider.notifier).setSession(null);
        }
      },
      child: ListTile(
        leading: _isBatchMode
            ? Checkbox(
                value: isSelected,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedSessionIds = [
                        ..._selectedSessionIds,
                        session.id,
                      ];
                    } else {
                      _selectedSessionIds = _selectedSessionIds
                          .where((id) => id != session.id)
                          .toList();
                    }
                  });
                },
              )
            : Icon(
                Icons.chat_bubble_outline,
                size: 16,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: isActive ? theme.colorScheme.primary : null,
          ),
        ),
        subtitle: Text(
          DateFormat('MM/dd HH:mm').format(session.updatedAt),
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: !_isBatchMode
            ? IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: () async {
                  await ref
                      .read(chatSessionListProvider.notifier)
                      .deleteSession(session.id);
                  if (ref.read(currentChatProvider)?.id == session.id) {
                    ref.read(currentChatProvider.notifier).setSession(null);
                  }
                },
              )
            : null,
        selected: isActive && !_isBatchMode,
        onTap: () {
          if (_isBatchMode) {
            setState(() {
              if (isSelected) {
                _selectedSessionIds = _selectedSessionIds
                    .where((id) => id != session.id)
                    .toList();
              } else {
                _selectedSessionIds = [..._selectedSessionIds, session.id];
              }
            });
          } else {
            ref.read(currentChatProvider.notifier).setSession(session);
            Navigator.pop(context);
          }
        },
      ),
    );
  }
}

class _StreamingBubble extends ConsumerWidget {
  const _StreamingBubble();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamingMessageText = ref.watch(aiStreamingMessageProvider);
    return _ChatBubble(
      message: ChatMessage(
        role: 'assistant',
        content: streamingMessageText ?? '',
        timestamp: DateTime.now(),
      ),
      showCursor: true,
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool showCursor;
  const _ChatBubble({required this.message, this.showCursor = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AppDurations.medium,
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 20),
            child: child,
          ),
        );
      },
      child: Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // Avatar and sender name header
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isUser) ...[
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.smart_toy_rounded,
                      size: 13,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '小Q',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ] else ...[
                Text(
                  '您的提问',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Bubble container
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: isUser ? 10 : 12,
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primary
                  : theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: isUser ? const Radius.circular(16) : const Radius.circular(4),
                bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(16),
              ),
              border: isUser
                  ? null
                  : Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                      width: 1,
                    ),
              boxShadow: isUser
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: isUser
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.images != null && message.images!.isNotEmpty)
                        _buildImagesGrid(context, message.images!),
                      if (message.content.isNotEmpty)
                        Text(
                          message.content,
                          style: TextStyle(
                            color: theme.colorScheme.onPrimary,
                            fontSize: 14,
                          ),
                        ),
                    ],
                  )
                : message.content.isEmpty
                ? const _TypingDots()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 思考过程展示（若有）
                      if (message.thought != null && message.thought!.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.psychology_outlined,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  message.thought!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // 工具调用或执行反馈卡片
                      if (message.role == 'tool')
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: (message.isError == true)
                                ? theme.colorScheme.errorContainer.withValues(alpha: 0.4)
                                : theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                (message.isError == true) ? Icons.error_outline : Icons.check_circle_outline,
                                size: 14,
                                color: (message.isError == true) ? theme.colorScheme.error : theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '操作反馈 [${message.toolName ?? "tool"}]',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: (message.isError == true) ? theme.colorScheme.error : theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),

                      MarkdownBody(
                        data: message.content,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 14,
                            height: 1.5,
                          ),
                          h1: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            height: 1.6,
                          ),
                          h2: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            height: 1.5,
                          ),
                          h3: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            height: 1.4,
                          ),
                          code: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: theme.colorScheme.primary,
                            backgroundColor: Colors.transparent,
                          ),
                          codeblockDecoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                          blockquoteDecoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLow,
                            border: Border(
                              left: BorderSide(
                                color: theme.colorScheme.primary,
                                width: 4,
                              ),
                            ),
                            borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(6),
                            ),
                          ),
                          blockquotePadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          listBullet: TextStyle(color: theme.colorScheme.onSurface),
                        ),
                      ),
                      if (showCursor) const _BlinkingCursor(),
                    ],
                  ),
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildImagesGrid(BuildContext context, List<String> images) {
    if (images.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: () => _showFullImageDialog(context, images.first),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 200,
                maxHeight: 200,
              ),
              child: UnifiedImage(
                imagePath: images.first,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: images.map((imgPath) {
          return GestureDetector(
            onTap: () => _showFullImageDialog(context, imgPath),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 68,
                height: 68,
                child: UnifiedImage(
                  imagePath: imgPath,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showFullImageDialog(BuildContext context, String imagePath) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              child: Center(
                child: UnifiedImage(
                  imagePath: imagePath,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Icon(
                    Icons.smart_toy_rounded,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'QNote AI',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const _TypingDots(),
          ),
        ),
      ],
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _animations = List.generate(3, (i) {
      return CurvedAnimation(
        parent: _controller,
        curve: Interval(i * 0.2, i * 0.2 + 0.4, curve: Curves.easeInOut),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return ScaleTransition(
          scale: _animations[i],
          child: Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        );
      }),
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor();

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 2,
        height: 16,
        margin: const EdgeInsets.only(left: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _ExportDialog extends StatefulWidget {
  final String contextText;
  final String initialQuestion;
  const _ExportDialog({
    required this.contextText,
    required this.initialQuestion,
  });

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late TextEditingController _questionController;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _questionController = TextEditingController(text: widget.initialQuestion);
  }

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  String _getFullContent() {
    final question = _questionController.text.trim();
    final q = question.isEmpty ? '请基于以上数据，给我一些分析和改善建议。' : question;
    return '${widget.contextText}\n\n---\n\n**我的提问是：**\n$q';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.large)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Container(
          color: theme.colorScheme.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Header
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.file_upload_outlined,
                        color: theme.colorScheme.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '导出分析上下文',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '复制以下内容到其他 AI 软件中提问',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),

              // 2. Question Area
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '想问 AI 的问题',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _questionController,
                      maxLines: 2,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '想对 AI 说什么？（不输入则使用默认建议）',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.3), width: 1.5),
                        ),
                      ),
                      onChanged: (_) {
                        setState(() {}); // Trigger refresh to update preview text
                      },
                    ),
                  ],
                ),
              ),

              // 3. Preview Container
              Expanded(
                child: Container(
                  color: theme.colorScheme.surfaceContainerLowest.withValues(alpha: 0.5),
                  padding: const EdgeInsets.all(16.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.01),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16.0),
                          child: SelectionArea(
                            child: Text(
                              _getFullContent(),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.5,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 4. Bottom Copy Button
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _getFullContent()));
                      setState(() => _copied = true);
                      Future.delayed(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _copied = false);
                      });
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(_copied ? Icons.check : Icons.copy, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          _copied ? '内容已复制到剪贴板！' : '复制全部内容',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultiNoteSelectorDialog extends StatefulWidget {
  final List<Note> notes;
  final List<String> initialSelected;
  const _MultiNoteSelectorDialog({
    required this.notes,
    required this.initialSelected,
  });

  @override
  State<_MultiNoteSelectorDialog> createState() =>
      _MultiNoteSelectorDialogState();
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
              child: Text(
                isAllSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14),
              ),
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
                    title: Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      DateFormat('MM/dd HH:mm').format(note.updatedAt),
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: Text('确定 (${_selected.length})'),
        ),
      ],
    );
  }
}

class _ModelSelectorDialog extends StatelessWidget {
  final List<AiConfig> configs;
  final String? activeModelId;
  const _ModelSelectorDialog({
    required this.configs,
    required this.activeModelId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFreeActive = activeModelId == '__free_model__';

    return SimpleDialog(
      title: const Text('选择模型'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, '__free_model__'),
          child: Row(
            children: [
              Icon(
                isFreeActive
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: isFreeActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'QNote内置模型',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isFreeActive ? theme.colorScheme.primary : null,
                      ),
                    ),
                    Text(
                      '多节点轮询与自动容灾',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ...configs.map((config) {
          final isActive = config.id == activeModelId;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, config.id),
            child: Row(
              children: [
                Icon(
                  isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isActive ? theme.colorScheme.primary : null,
                        ),
                      ),
                      Text(
                        '${config.provider} / ${config.modelName}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _MultiTodoSelectorDialog extends StatefulWidget {
  final List<Todo> todos;
  final List<String> initialSelected;
  const _MultiTodoSelectorDialog({
    required this.todos,
    required this.initialSelected,
  });

  @override
  State<_MultiTodoSelectorDialog> createState() =>
      _MultiTodoSelectorDialogState();
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
              child: Text(
                isAllSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14),
              ),
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
                      style: TextStyle(
                        decoration: todo.isCompleted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: Text(
                      todo.isCompleted ? '已完成' : '未完成',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _MultiJournalSelectorDialog extends StatefulWidget {
  final List<Note> journals;
  final List<String> initialSelected;
  const _MultiJournalSelectorDialog({
    required this.journals,
    required this.initialSelected,
  });

  @override
  State<_MultiJournalSelectorDialog> createState() =>
      _MultiJournalSelectorDialogState();
}

class _MultiJournalSelectorDialogState
    extends State<_MultiJournalSelectorDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAllSelected =
        _selected.length == widget.journals.length && widget.journals.isNotEmpty;

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
              child: Text(
                isAllSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 14),
              ),
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
                        const Icon(
                          Icons.auto_stories_outlined,
                          size: 16,
                          color: Color(0xFFE91E63),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${journal.title} 日记',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        journal.content.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: Text('确定 (${_selected.length})'),
        ),
      ],
    );
  }
}



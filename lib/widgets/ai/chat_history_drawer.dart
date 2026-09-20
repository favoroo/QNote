import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/chat_storage_usage.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/chat_image_refs.dart';
import 'package:qnote_flutter/core/utils/chat_time_group.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/ai/chat_session_tile.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';

/// 小Q 的历史对话抽屉。
///
/// 形态对齐 DeepSeek：顶部搜索 + 按时间分组（7 天内 / 30 天内 / 更早按年月）+
/// 节头吸顶且右侧钉批量选择入口。
///
/// [sessionsAsync] 与 [activeId] 刻意做成构造入参而不是组件内部自己 `watch`：
/// 一是让抽屉的重建只由「列表变化 / 切会话」驱动，聊天流式刷新够不到这两条订阅；
/// 二是 widget 测试可以直接喂一个 `AsyncData` 起组件，不必 pump 整个 `AiPage`、
/// 也不必碰 sqflite。
class ChatHistoryDrawer extends ConsumerStatefulWidget {
  final AsyncValue<List<ChatSession>> sessionsAsync;
  final String? activeId;

  /// 分桶的时间基准，默认取当前时刻。
  ///
  /// 做成可注入是因为「7 天内 / 30 天内」的归属完全依赖它：不注入的话，同一份
  /// 测试数据会在不同日期跑出不同的分组结果（实测就因此把一条 09-12 的对话
  /// 算进了「30 天内」，看起来像折叠逻辑坏了）。与 `stats_utils.formatDayLabel`
  /// 的 `today` 参数同一惯例。
  final DateTime? now;

  const ChatHistoryDrawer({
    super.key,
    required this.sessionsAsync,
    this.activeId,
    this.now,
  });

  @override
  ConsumerState<ChatHistoryDrawer> createState() => _ChatHistoryDrawerState();
}

class _ChatHistoryDrawerState extends ConsumerState<ChatHistoryDrawer> {
  bool _isBatchMode = false;
  List<String> _selectedSessionIds = [];

  /// 用户手动点过节头的分组，记录其显式展开态；未记录的走 `isDefaultExpanded`。
  ///
  /// 用「值覆盖」而不是「一个只存反项的 Set」：后者在近组（默认展开）和月组
  /// （默认折叠）上要做两套反向判断，很容易把其中一边写反（实测就写反过一次，
  /// 症状是月组点了永远展不开）。
  final Map<String, bool> _groupExpandedOverride = {};

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    // ActionMenu 用的是类级静态 OverlayEntry，而抽屉是开关式的：不主动收就会留下
    // 「抽屉已经没了、菜单还挂在根 Overlay 上」，且菜单项闭包抓着的 context 已销毁。
    ActionMenu.dismiss(immediate: true);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    // 只切关键词：勾选的收敛在 build 里按「当前可见集」派生，
    // 不在这里改状态，避免在监听回调里对 provider 数据做二次依赖。
    setState(() {});
  }

  bool get _isSearching => _searchController.text.trim().isNotEmpty;

  // ---------------------------------------------------------------- 分组折叠

  bool _isExpanded(ChatHistoryGroup group) =>
      _groupExpandedOverride[group.id] ?? group.isDefaultExpanded;

  /// 折叠/展开**只改状态，绝不动滚动位置**：节头的 `minExtent == maxExtent`，
  /// 被点的节头自身位置恒定，加一次 jumpTo 反而会把视口弹到别处
  /// （`diary_page` 的分组折叠踩过同一个坑）。
  void _toggleGroup(ChatHistoryGroup group) {
    HapticFeedback.lightImpact();
    setState(() {
      _groupExpandedOverride[group.id] = !_isExpanded(group);
    });
  }

  // ---------------------------------------------------------------- 批量选择

  void _toggleBatchMode() {
    setState(() {
      _isBatchMode = !_isBatchMode;
      if (!_isBatchMode) _selectedSessionIds = [];
    });
  }

  void _toggleCheck(String id) {
    setState(() {
      if (_selectedSessionIds.contains(id)) {
        _selectedSessionIds = _selectedSessionIds
            .where((selected) => selected != id)
            .toList();
      } else {
        _selectedSessionIds = [..._selectedSessionIds, id];
      }
    });
  }

  void _enterBatchMode(String id) {
    HapticFeedback.lightImpact();
    setState(() {
      _isBatchMode = true;
      _selectedSessionIds = [id];
    });
  }

  void _selectAll(List<ChatSession> visible) {
    setState(() {
      // 判定与作用域都按「当前可见集」：搜索态下按全表长度判定会既选不全也取消不掉
      _selectedSessionIds =
          _selectedSessionIds.length == visible.length
          ? []
          : visible.map((s) => s.id).toList();
    });
  }

  // ---------------------------------------------------------------- 行级动作

  void _openSession(ChatSession session) {
    ref.read(currentChatProvider.notifier).setSession(session);
    Navigator.pop(context);
  }

  /// 新建对话：复用 Notifier 里的空白会话判定，连点不会堆出多个空会话。
  Future<void> _createSession() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final previous = ref.read(currentChatProvider);
    final session = await ref
        .read(chatSessionListProvider.notifier)
        .createSession();
    ref.read(currentChatProvider.notifier).setSession(session);
    if (!mounted) return;
    // 本来就停在空白新对话上时，界面点了不会有任何变化，用 Toast 明确回应
    if (previous == null || isBlankNewChatSession(previous)) {
      Toast.info(context, '已是新对话，直接说就行');
    }
    Navigator.pop(context);
  }

  Future<void> _togglePin(ChatSession session) async {
    await ref
        .read(chatSessionListProvider.notifier)
        .setPinned(session.id, !session.isPinned);
  }

  /// 重命名：只弹输入框，落库交给 Notifier（它会回填 currentChat 的副本）。
  Future<void> _renameSession(ChatSession session) async {
    final controller = TextEditingController(text: session.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: '输入对话名称'),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || !mounted) {
      return;
    }
    await ref
        .read(chatSessionListProvider.notifier)
        .renameSession(session.id, title);
  }

  // ---------------------------------------------------------------- 删除通路

  /// 统一的对话删除确认。
  ///
  /// 删除已改为物理删除（旧版软删只是打标记，数据一直占着库），所以四条删除入口
  /// （侧滑、行尾按钮、批量删除、清空全部）都必须先让用户看清三件事：删掉多少内容、
  /// 不可恢复、以及**不会**牵连小Q已经写成的笔记/日记/待办与工作区文件。
  Future<bool> _confirmDeleteSessions(List<ChatSession> targets) async {
    if (targets.isEmpty) {
      return false;
    }
    var messageCount = 0;
    var imageCount = 0;
    for (final session in targets) {
      messageCount += session.messages.length;
      imageCount += countSessionImageRefs(session);
    }

    final detail = StringBuffer();
    detail.writeln(
      targets.length == 1
          ? '将永久删除「${targets.first.title}」'
          : '将永久删除 ${targets.length} 个对话',
    );
    detail.write('（共 $messageCount 条消息');
    if (imageCount > 0) {
      detail.write(' · $imageCount 张图片');
    }
    detail.writeln('），包括小Q生成并保存在本机的图片。');
    detail.writeln();
    detail.writeln('小Q已为你创建的笔记、日记、待办和虚拟工作区文件不会被删除。');
    detail.write('此操作不可恢复，并会同步到其它设备。');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: SingleChildScrollView(
          child: Text(
            detail.toString(),
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return false;
    }
    return ok == true;
  }

  /// 执行删除并反馈：内部统一处理「当前会话被删时清空对话区」与 Toast，
  /// 四条入口共用，避免各处漏掉其中一步。
  Future<void> _performDelete(List<ChatSession> targets) async {
    final ids = targets.map((s) => s.id).toList();
    final report = await ref
        .read(chatSessionListProvider.notifier)
        .deleteSessions(ids);
    final currentId = ref.read(currentChatProvider)?.id;
    if (currentId != null && ids.contains(currentId)) {
      ref.read(currentChatProvider.notifier).setSession(null);
    }
    if (!mounted) {
      return;
    }
    Toast.success(context, _deleteToastText(targets, report));
  }

  /// 删除结果文案：只有真的删掉了磁盘上的图片文件才报「释放约」，
  /// 因为消息记录虽然从库里删了，SQLite 文件要等「整理数据库」才会收缩。
  String _deleteToastText(
    List<ChatSession> targets,
    ChatSessionDeleteReport report,
  ) {
    final head = targets.length == 1
        ? '已删除「${targets.first.title}」'
        : '已删除 ${targets.length} 个对话';
    if (report.deletedImageFiles > 0) {
      return '$head · 回收 ${report.deletedImageFiles} 张图片 · '
          '释放约 ${formatChatStorageBytes(report.imageFreedBytes)}';
    }
    return head;
  }

  /// 批量删除：一次事务删完，避免逐条删除时每次都重扫一遍全表图片引用。
  ///
  /// [failMessage] 与 [logAction] 分开传，让「清空全部」和「删除已选」两种场景
  /// 在 Toast 上说法不同、在日志里也各自可查，不必从文案反推来源。
  Future<void> _deleteBatch(
    List<ChatSession> targets, {
    required String failMessage,
    required String logAction,
  }) async {
    if (!await _confirmDeleteSessions(targets)) {
      return;
    }
    try {
      await _performDelete(targets);
    } catch (error) {
      if (mounted) {
        Toast.error(context, failMessage);
      }
      LoggerService.instance.logAI(
        logAction,
        details: 'count=${targets.length}, $error',
        level: LogLevel.warning,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isBatchMode = false;
      _selectedSessionIds = [];
    });
  }

  // ---------------------------------------------------------------- 渲染

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: widget.sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorState(
          error: e,
          action: '加载历史对话失败',
          // Drawer 宽度有限，用紧凑态避免长异常串挤掉重试按钮
          compact: true,
          onRetry: () => ref.invalidate(chatSessionListProvider),
        ),
        data: (sessions) => _buildContent(sessions, theme),
      ),
    );
  }

  Widget _buildContent(List<ChatSession> sessions, ThemeData theme) {
    final searching = _isSearching;
    final visible = searching
        ? filterChatSessions(sessions: sessions, keyword: _searchController.text)
        : sessions;
    // 勾选集按「当前可见」收敛：搜索态下改关键词后，看不见的勾选既不该计数也不该被删掉
    final visibleIds = visible.map((s) => s.id).toSet();
    final selected = _selectedSessionIds
        .where(visibleIds.contains)
        .toList();

    return Column(
      children: [
        _buildTopBar(theme),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: _buildSearchField(theme),
        ),
        // 只要进了批量态就给这条操作栏：早期版本额外要求「已勾选」，
        // 结果进批量后不先勾一条就找不到「全选」，等于把全选锁在了它自己的下游
        if (_isBatchMode && visible.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _selectAll(visible),
                    child: Text(
                      selected.length == visible.length ? '取消全选' : '全选',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () => _deleteBatch(
                      sessions,
                      failMessage: '清空失败',
                      logAction: '清空对话历史失败',
                    ),
                    child: const Text('清空全部'),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _buildList(
            sessions: sessions,
            visible: visible,
            selected: selected,
            searching: searching,
            theme: theme,
          ),
        ),
        if (_isBatchMode && selected.isNotEmpty)
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
                label: Text('删除已选 (${selected.length})'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                ),
                onPressed: () {
                  final targets = visible
                      .where((s) => selected.contains(s.id))
                      .toList();
                  _deleteBatch(
                    targets,
                    failMessage: '删除失败',
                    logAction: '批量删除对话失败',
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    return Padding(
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
              IconButton(
                // 与聊天页顶栏的新建按钮同图标，两处语义对齐
                icon: const Icon(Icons.maps_ugc_outlined, size: 18),
                tooltip: '新建对话',
                onPressed: _createSession,
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    final scheme = theme.colorScheme;
    return TextField(
      controller: _searchController,
      textInputAction: TextInputAction.search,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: '搜索对话标题或内容',
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        prefixIcon: Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: '清空',
                onPressed: _searchController.clear,
              ),
        // 圆角收一档：抽屉只有 300 出头宽，用 16 会把填充区撑成胶囊
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
          borderSide: BorderSide(
            color: scheme.primary.withValues(alpha: 0.5),
            width: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildList({
    required List<ChatSession> sessions,
    required List<ChatSession> visible,
    required List<String> selected,
    required bool searching,
    required ThemeData theme,
  }) {
    if (visible.isEmpty) {
      return searching
          ? const EmptyStateWidget(
              icon: Icons.search_off,
              message: '没有匹配的对话',
              description: '换个关键词试试',
            )
          : const EmptyStateWidget(
              icon: Icons.chat_bubble_outline,
              message: '暂无对话',
              description: '点上方图标开始新对话',
            );
    }

    Widget row(ChatSession session) => _buildTile(
      session,
      isChecked: selected.contains(session.id),
      query: searching ? _searchController.text.trim() : '',
    );

    // 搜索态绕过分桶与折叠：月组默认折叠，否则搜到的老对话根本渲染不出来。
    if (searching) {
      return CustomScrollView(
        slivers: [
          // 搜索态没有分组节头，批量入口若只挂在节头上就会在搜索时彻底消失，
          // 所以这里复用同一个节头 delegate（不吸顶，因为没有相邻节头要推进）。
          SliverToBoxAdapter(
            child: _ChatGroupHeaderDelegate(
              label: '${visible.length} 个结果',
              count: visible.length,
              expanded: true,
              highlight: false,
              isBatchMode: _isBatchMode,
              onToggleCollapse: () {},
              onToggleBatch: _toggleBatchMode,
              collapseEnabled: false,
            ).build(context, 0, false),
          ),
          SliverList(
            key: const ValueKey('rows-search'),
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => row(visible[i]),
              childCount: visible.length,
            ),
          ),
        ],
      );
    }

    final groups = buildChatHistoryGroups(sessions, now: widget.now);
    return CustomScrollView(
      slivers: [
        for (final group in groups) ...[
          SliverPersistentHeader(
            // 折叠一个组会让后面所有 sliver 的槽位前移。不给它们按 id 打 key 的话，
            // RenderObjectWidget 的子节点是按「位置 + 类型」匹配的，实测会出现
            // 被折叠组的行残留在邻组里渲染出来。
            key: ValueKey('header-${group.id}'),
            pinned: true,
            delegate: _ChatGroupHeaderDelegate(
              label: group.label,
              count: group.count,
              expanded: _isExpanded(group),
              highlight: group.kind == ChatHistoryGroupKind.pinned,
              isBatchMode: _isBatchMode,
              onToggleCollapse: () => _toggleGroup(group),
              onToggleBatch: _toggleBatchMode,
            ),
          ),
          if (_isExpanded(group))
            SliverList(
              key: ValueKey('rows-${group.id}'),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => row(group.sessions[i]),
                childCount: group.count,
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildTile(
    ChatSession session, {
    required bool isChecked,
    required String query,
  }) {
    return ChatSessionTile(
      // 稳定 key：置顶/取消置顶会把这一行从一个组挪到另一个组，
      // 靠位置匹配会让 State（含菜单锚点 GlobalKey）串到别的会话上。
      // 分桶保证同一 id 只出现在一个组，因此不会重复挂 key。
      key: ValueKey(session.id),
      session: session,
      isActive: session.id == widget.activeId,
      isBatchMode: _isBatchMode,
      isChecked: isChecked,
      searchQuery: query,
      onToggleCheck: () => _toggleCheck(session.id),
      onOpen: () => _openSession(session),
      onEnterBatchMode: () => _enterBatchMode(session.id),
      onTogglePin: () => _togglePin(session),
      onRename: () => _renameSession(session),
      confirmDelete: () => _confirmDeleteSessions([session]),
      performDelete: () => _performDelete([session]),
    );
  }
}

/// 时间组节头：吸顶，右侧钉批量选择入口。
///
/// `minExtent == maxExtent` 固定高度，因此 `shrinkOffset` 恒为 0，不需要任何
/// offset 补偿；多个 pinned 头天然产生「后一个把前一个顶出去」的推进效果。
class _ChatGroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  final int count;
  final bool expanded;

  /// 置顶组用 primary 着色，让「为什么这一组在最上面」一眼可辨。
  final bool highlight;
  final bool isBatchMode;
  final VoidCallback onToggleCollapse;
  final VoidCallback onToggleBatch;

  /// 搜索态的计数行复用本 delegate，但它没有可折叠的内容，
  /// 于是不画折叠箭头、也不响应点击。
  final bool collapseEnabled;

  static const double extent = 44;

  const _ChatGroupHeaderDelegate({
    required this.label,
    required this.count,
    required this.expanded,
    required this.highlight,
    required this.isBatchMode,
    required this.onToggleCollapse,
    required this.onToggleBatch,
    this.collapseEnabled = true,
  });

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 高度必须锁成 tight：SliverPinnedPersistentHeader 的几何是
    // `paintExtent = min(子组件实测高度, ...)` 而 `layoutExtent = maxExtent - scrollOffset`，
    // 一旦子组件的自然高度（这里 40 高的 compact IconButton）小于声明的 maxExtent，
    // 就会抛「layoutExtent exceeds paintExtent」的断言。
    return SizedBox(
      height: extent,
      child: ColoredBox(
        // 必须不透明：pinned 头压在滚上来的正文上时，深色底会让文字从字缝里透出来
        color: theme.drawerTheme.backgroundColor ?? scheme.surface,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onToggleCollapse,
                borderRadius: BorderRadius.circular(AppRadius.small),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: highlight
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      if (!expanded && count > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      if (collapseEnabled) ...[
                        const SizedBox(width: 2),
                        Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.grid_view,
                size: 18,
                color: isBatchMode ? scheme.primary : scheme.onSurfaceVariant,
              ),
              tooltip: isBatchMode ? '退出批量选择' : '批量选择',
              visualDensity: VisualDensity.compact,
              onPressed: onToggleBatch,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  /// 按值比较：delegate 每次父 build 都是新实例，写成恒 true 会在流式刷新时
  /// 白白重绘，写成恒 false 则折叠态与计数不再更新。
  @override
  bool shouldRebuild(covariant _ChatGroupHeaderDelegate oldDelegate) {
    return oldDelegate.label != label ||
        oldDelegate.count != count ||
        oldDelegate.expanded != expanded ||
        oldDelegate.highlight != highlight ||
        oldDelegate.isBatchMode != isBatchMode ||
        oldDelegate.collapseEnabled != collapseEnabled;
  }
}

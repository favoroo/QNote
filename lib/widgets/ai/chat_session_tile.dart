import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';
import 'package:qnote_flutter/widgets/search_highlight.dart';

/// 历史抽屉里的单条会话行。
///
/// 做成 `ConsumerStatefulWidget` 有两个必要：一是读 `agentRunningSessionsProvider`
/// （该会话有小Q任务在跑时行首转圈、副标题提示「生成中」，并且要挡住改名/置顶，
/// 因为任务收尾时会用发起那一刻捕获的标题整行落库）；二是自持菜单锚点 GlobalKey。
class ChatSessionTile extends ConsumerStatefulWidget {
  final ChatSession session;
  final bool isActive;
  final bool isBatchMode;
  final bool isChecked;

  /// 非空时标题里的命中段会被高亮；无命中时留空。
  final String searchQuery;

  final VoidCallback onToggleCheck;
  final VoidCallback onOpen;
  final VoidCallback onEnterBatchMode;
  final VoidCallback onTogglePin;
  final VoidCallback onRename;

  /// 删除前的统一二次确认（由抽屉持有，四条删除入口共用同一套文案）。
  final Future<bool> Function() confirmDelete;

  /// 执行删除并反馈（内部处理「当前会话被删时清空对话区」与 Toast）。
  final Future<void> Function() performDelete;

  const ChatSessionTile({
    super.key,
    required this.session,
    required this.isActive,
    required this.isBatchMode,
    required this.isChecked,
    required this.searchQuery,
    required this.onToggleCheck,
    required this.onOpen,
    required this.onEnterBatchMode,
    required this.onTogglePin,
    required this.onRename,
    required this.confirmDelete,
    required this.performDelete,
  });

  @override
  ConsumerState<ChatSessionTile> createState() => _ChatSessionTileState();
}

class _ChatSessionTileState extends ConsumerState<ChatSessionTile> {
  /// 菜单锚点。放在 State 里而不是外层 `Map<String, GlobalKey>`：State 的生命周期
  /// 跟着 `ValueKey(session.id)` 的元素走，滚出视口即销毁，不会攒出一张只增不减的表。
  final _tileKey = GlobalKey();

  /// 行级动作菜单。长按与行尾 `more_horiz` 走同一个入口——**Web 端没有长按**，
  /// 鼠标用户必须有一个可见的行级菜单入口。
  void _showRowMenu({required bool isRunning}) {
    HapticFeedback.lightImpact();
    final session = widget.session;
    ActionMenu.show(
      context: context,
      key: _tileKey,
      items: [
        ActionMenuItem(
          icon: session.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          label: session.isPinned ? '取消置顶' : '置顶',
          onTap: () => _guardBusy(isRunning, widget.onTogglePin),
        ),
        ActionMenuItem(
          icon: Icons.edit_outlined,
          label: '重命名',
          onTap: () => _guardBusy(isRunning, widget.onRename),
        ),
        ActionMenuItem(
          icon: Icons.select_all_outlined,
          label: '批量选择',
          onTap: widget.onEnterBatchMode,
        ),
        ActionMenuItem(
          icon: Icons.delete_outline,
          label: '删除',
          isDestructive: true,
          onTap: _deleteFromTrailingButton,
        ),
      ],
    );
  }

  /// 小Q 正在该会话上跑任务时，改名与置顶都会被任务收尾的整行落库覆盖掉，
  /// 所以这里不静默失败，而是明确告诉用户稍后再改。
  void _guardBusy(bool isRunning, VoidCallback action) {
    if (isRunning) {
      Toast.info(context, '小Q正在生成，稍后再改');
      return;
    }
    action();
  }

  /// 菜单/行尾按钮：确认后再删。侧滑路径的确认由 `Dismissible.confirmDismiss` 承担。
  Future<void> _deleteFromTrailingButton() async {
    if (!await widget.confirmDelete()) {
      return;
    }
    await _deleteAndReport('删除对话失败');
  }

  /// 删除失败只在本地留痕并提示，不向上抛：这一行删不掉不该打断抽屉的其余交互。
  Future<void> _deleteAndReport(String scene) async {
    try {
      await widget.performDelete();
    } catch (error) {
      if (mounted) {
        Toast.error(context, '删除失败');
      }
      LoggerService.instance.logAI(
        scene,
        details: 'session=${widget.session.id}, $error',
        level: LogLevel.warning,
      );
    }
  }

  /// 行首：批量勾选框 / 生成中转圈 / 对话图标；置顶时右上角叠一枚小图钉角标，
  /// 用来解释「为什么这条不在它的时间组里」。
  Widget _buildLeading(ThemeData theme, {required bool isRunning}) {
    final scheme = theme.colorScheme;
    if (widget.isBatchMode) {
      return Checkbox(
        value: widget.isChecked,
        onChanged: (_) => widget.onToggleCheck(),
      );
    }
    final Widget icon = isRunning
        ? LoadingRing(
            size: 16,
            strokeWidth: 1.8,
            color: widget.isActive ? scheme.primary : scheme.onSurfaceVariant,
          )
        : Icon(
            Icons.chat_bubble_outline,
            size: 16,
            color: widget.isActive ? scheme.primary : theme.disabledColor,
          );
    if (!widget.session.isPinned) {
      return icon;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -5,
          top: -4,
          child: Icon(Icons.push_pin, size: 9, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    // 该会话的小Q任务是否正在生成：列表项转圈 + 「生成中」副标题提示
    final isRunning = ref.watch(
      agentRunningSessionsProvider.select((s) => s.contains(session.id)),
    );
    final titleStyle = TextStyle(
      fontWeight: FontWeight.w500,
      color: widget.isActive ? theme.colorScheme.primary : null,
    );

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: theme.colorScheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => widget.confirmDelete(),
      onDismissed: (_) async {
        await _deleteAndReport('侧滑删除对话失败');
        // 划走动画已完成但删除失败时，必须重绘把这一行画回来，
        // 否则会出现「界面已移除、数据源还在」的 Dismissible 断言
        if (mounted) {
          setState(() {});
        }
      },
      child: ListTile(
        key: _tileKey,
        leading: _buildLeading(theme, isRunning: isRunning),
        title: highlightSearchMatch(
          session.title,
          widget.searchQuery,
          theme,
          baseStyle: titleStyle,
        ),
        subtitle: Text(
          isRunning && !widget.isBatchMode
              ? '小Q生成中…'
              : DateFormat('MM/dd HH:mm').format(session.updatedAt),
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: widget.isBatchMode
            ? null
            : IconButton(
                icon: Icon(
                  Icons.more_horiz,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: '置顶 / 重命名 / 批量选择 / 删除',
                onPressed: () => _showRowMenu(isRunning: isRunning),
              ),
        selected: widget.isActive && !widget.isBatchMode,
        onTap: () {
          if (widget.isBatchMode) {
            widget.onToggleCheck();
          } else {
            widget.onOpen();
          }
        },
        onLongPress: () {
          if (widget.isBatchMode) return;
          _showRowMenu(isRunning: isRunning);
        },
      ),
    );
  }
}

import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 全局悬浮小Q快捷入口的页面上下文。
///
/// 描述用户当前所处的界面与正在查看的目标内容（哪个界面、哪个文件），
/// 是会话隔离（[signature]）与动态上下文注入（[toPromptBlock]）的数据来源。
///
/// 上下文有两个来源，生效优先级为「覆盖栈顶 > 基础上下文」：
/// - 基础上下文：由当前路由 location 推导（[fromLocation]），覆盖 5 个 tab 页与设置类页面；
/// - 覆盖上下文：各编辑页（笔记/日记/手账）在 initState 压栈、dispose 出栈。
enum QContextType {
  /// 时间线列表页
  diaryList,

  /// 时间线单条记录编辑页
  diaryDetail,

  /// 每日长篇日记编辑页
  journal,

  /// 笔记库列表页
  notesList,

  /// 笔记编辑页
  noteDetail,

  /// 待办页
  todoList,

  /// 统计页
  statistics,

  /// 跨库搜索页
  search,

  /// 小Q 页面本身
  aiPage,

  /// 其他无内容目标的页面（设置等）
  other,
}

/// 页面上下文快照
class QPageContext {
  /// 页面类型
  final QContextType type;

  /// 目标内容 id（笔记 id / 时间线记录 id / 手账日期字符串），列表页为 null
  final String? targetId;

  /// 目标内容标题（如笔记标题、日期描述），用于面板徽章展示
  final String? targetTitle;

  /// 会话隔离签名：同一签名内的多次输入视为同一对话，签名变化即重置会话
  final String signature;

  /// 面板头部徽章展示文案（如「笔记《读书笔记》」）
  final String displayLabel;

  const QPageContext({
    required this.type,
    required this.signature,
    required this.displayLabel,
    this.targetId,
    this.targetTitle,
  });

  /// 生效上下文的兜底值：无法识别的页面
  static QPageContext get fallback => const QPageContext(
        type: QContextType.other,
        signature: 'page:other',
        displayLabel: '当前页面',
      );

  /// 由当前路由 location 推导基础页面上下文（tab 页与设置类页面）。
  /// 编辑页等需要精确目标的场景由页面自行压栈覆盖，不在此解析
  static QPageContext fromLocation(String location) {
    final path = location.split('?').first;
    return switch (path) {
      '/diary' || '/diary/batch' || '/diary/editor' => const QPageContext(
          type: QContextType.diaryList,
          signature: 'page:diary',
          displayLabel: '时间线',
        ),
      '/notes' || '/notes/editor' => const QPageContext(
          type: QContextType.notesList,
          signature: 'page:notes',
          displayLabel: '笔记库',
        ),
      '/todo' => const QPageContext(
          type: QContextType.todoList,
          signature: 'page:todo',
          displayLabel: '待办',
        ),
      '/statistics' => const QPageContext(
          type: QContextType.statistics,
          signature: 'page:statistics',
          displayLabel: '统计',
        ),
      '/ai' => const QPageContext(
          type: QContextType.aiPage,
          signature: 'page:ai',
          displayLabel: '小Q',
        ),
      _ => path.startsWith('/settings')
          ? const QPageContext(
              type: QContextType.other,
              signature: 'page:settings',
              displayLabel: '设置',
            )
          : QPageContext.fallback,
    };
  }

  /// 目标内容是否有明确的虚拟工作区文件可操作
  bool get hasFileTarget => switch (type) {
        QContextType.noteDetail ||
        QContextType.diaryDetail ||
        QContextType.journal =>
          targetId != null,
        _ => false,
      };

  /// 组装注入 system 尾部的页面上下文说明块，让小Q知道用户在哪个界面、
  /// 要操作哪个文件。返回 null 表示无需注入（无目标内容的通用页面）
  Future<String?> toPromptBlock() async {
    final workspace = VirtualWorkspaceService.instance;
    switch (type) {
      case QContextType.noteDetail:
        final path = await workspace.resolveNotePath(targetId!);
        if (path == null) return null;
        return _fileBlock('笔记编辑页', targetTitle ?? '无标题笔记', path,
            '笔记 id: $targetId');
      case QContextType.diaryDetail:
        final dayPath = await workspace.resolveTimelineDayPath(targetId!);
        if (dayPath == null) return null;
        return _fileBlock('时间线记录编辑页', targetTitle ?? '一条流水记录', dayPath,
            '记录 id: $targetId，修改单条记录时保留其 `<!-- id: ... -->` 标记');
      case QContextType.journal:
        final date = DateTime.tryParse(targetId!);
        if (date == null) return null;
        return _fileBlock('每日日记编辑页',
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
            workspace.journalPathForDate(date), '日期: $targetId');
      case QContextType.todoList:
        return _pageBlock('待办页', '用户在浏览与管理待办列表，无特定打开的目标文件');
      case QContextType.diaryList:
        return _pageBlock('时间线页', '用户在浏览时间线流水列表，无特定打开的目标文件');
      case QContextType.notesList:
        return _pageBlock('笔记库页', '用户在浏览笔记本与笔记列表，无特定打开的目标文件');
      case QContextType.statistics:
        return _pageBlock('统计页', '用户在查看数据统计与生活评分');
      case QContextType.search:
        return _pageBlock('搜索页', '用户在跨库搜索日记、笔记与待办');
      case QContextType.aiPage:
      case QContextType.other:
        return null;
    }
  }

  /// 有明确目标文件的说明块
  String _fileBlock(String pageName, String title, String path, String extra) {
    return ['当前页面上下文（用户通过全局悬浮快捷入口发起）', '用户当前正在【$pageName】：$title',
            '该内容对应的虚拟工作区文件：$path（$extra）',
            '用户的指令通常针对当前打开的内容，请先用 read_file 读取上述文件了解现状，再用 edit_file / write_file 完成修改；若指令与该内容无关，按通用指令处理']
        .join('\n');
  }

  /// 无目标文件的页面说明块
  String _pageBlock(String pageName, String scene) {
    return ['当前页面上下文（用户通过全局悬浮快捷入口发起）', '用户当前位于【$pageName】：$scene',
            '按用户指令处理即可，必要时先用 list_dir / read_file 自主探索相关数据']
        .join('\n');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QPageContext &&
          other.type == type &&
          other.targetId == targetId &&
          other.targetTitle == targetTitle &&
          other.signature == signature &&
          other.displayLabel == displayLabel;

  @override
  int get hashCode =>
      Object.hash(type, targetId, targetTitle, signature, displayLabel);
}

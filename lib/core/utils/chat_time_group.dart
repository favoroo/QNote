import 'package:qnote_flutter/models/chat_session.dart';

/// 历史抽屉的分组类别。
enum ChatHistoryGroupKind { pinned, recent7, within30, month }

/// 历史抽屉的一个时间分组：节头文案 + 组内会话。
///
/// [id] 是折叠状态的持久化键，必须在「同一批数据重算后」保持稳定，
/// 因此只由分组类别和年月推出，不含条数等会随增删变化的量。
class ChatHistoryGroup {
  final String id;
  final String label;
  final ChatHistoryGroupKind kind;
  final List<ChatSession> sessions;

  const ChatHistoryGroup({
    required this.id,
    required this.label,
    required this.kind,
    required this.sessions,
  });

  int get count => sessions.length;

  /// 近组默认展开、月组默认折叠：抽屉宽度有限，不该把用户八个月前的对话一次铺完。
  bool get isDefaultExpanded => kind != ChatHistoryGroupKind.month;
}

/// 「7 天内」覆盖最近 7 个自然日（含今天），即自然日差 0~6。
const int _recent7MaxDayOffset = 6;

/// 「30 天内」接在其后，覆盖自然日差 7~29。
const int _within30MaxDayOffset = 29;

/// 按 DeepSeek 口径把会话分桶：置顶 → 7 天内 → 30 天内 → 更早按「yyyy年M月」。
///
/// 两条必须守住的性质：
/// - **每个会话只进一个组**（置顶项从时间桶里摘走，不会同时出现在「置顶」和「7 天内」）。
///   抽屉的每行持有自己的 GlobalKey，一旦同一 id 出现在两组就会
///   `Duplicate GlobalKey detected` 白屏，所以这条不变式由单测锁死。
/// - 空组**根本不出现**（而不是渲染一个空节头）。
///
/// [now] 可注入以便单测固定时间口径，与 `stats_utils.formatDayLabel` 的 `today` 同惯例。
List<ChatHistoryGroup> buildChatHistoryGroups(
  List<ChatSession> sessions, {
  DateTime? now,
}) {
  final base = now ?? DateTime.now();
  final pinned = <ChatSession>[];
  final recent7 = <ChatSession>[];
  final within30 = <ChatSession>[];
  // key = 年月序号（year * 12 + month - 1），单调递增，便于整型比较排序
  final byMonth = <int, List<ChatSession>>{};

  for (final session in sessions) {
    if (session.isPinned) {
      pinned.add(session);
      continue;
    }
    final offset = _dayOffsetFrom(base, session.updatedAt);
    if (offset <= _recent7MaxDayOffset) {
      recent7.add(session);
    } else if (offset <= _within30MaxDayOffset) {
      within30.add(session);
    } else {
      final key = session.updatedAt.year * 12 + session.updatedAt.month - 1;
      byMonth.putIfAbsent(key, () => <ChatSession>[]).add(session);
    }
  }

  final groups = <ChatHistoryGroup>[];
  if (pinned.isNotEmpty) {
    groups.add(
      ChatHistoryGroup(
        id: 'pinned',
        // 叫「置顶对话」而不是「置顶」：后者与行级菜单里的「置顶」动作项同名，
        // 节头是分组名、菜单项是动词，两处撞成同一个词既难读也让测试无法区分。
        label: '置顶对话',
        kind: ChatHistoryGroupKind.pinned,
        sessions: _sortedByUpdatedAtDesc(pinned),
      ),
    );
  }
  if (recent7.isNotEmpty) {
    groups.add(
      ChatHistoryGroup(
        id: 'recent7',
        label: '7 天内',
        kind: ChatHistoryGroupKind.recent7,
        sessions: _sortedByUpdatedAtDesc(recent7),
      ),
    );
  }
  if (within30.isNotEmpty) {
    groups.add(
      ChatHistoryGroup(
        id: 'within30',
        label: '30 天内',
        kind: ChatHistoryGroupKind.within30,
        sessions: _sortedByUpdatedAtDesc(within30),
      ),
    );
  }

  final monthKeys = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
  for (final key in monthKeys) {
    final year = key ~/ 12;
    final month = key % 12 + 1;
    groups.add(
      ChatHistoryGroup(
        // 只含年月：条数会变，用它当折叠键会让用户折叠的组在新增对话后自己弹开
        id: 'y$year-$month',
        label: '$year年$month月',
        kind: ChatHistoryGroupKind.month,
        sessions: _sortedByUpdatedAtDesc(byMonth[key]!),
      ),
    );
  }

  return groups;
}

/// 关键词过滤：命中会话标题或任意一条消息正文。
///
/// 数据已由 `getAllChatSessions` 整表全量载入内存，所以这里是纯 Dart 扫描，
/// **不新增 repository 查询方法**。
///
/// 刻意**不扫** `thought` / `toolCalls` / `uiDetails`：那是模型内部的中转内容，
/// 扫中了对用户是噪音，会频繁造出「我明明没写过这个词」的假命中。
///
/// [keyword] 为空时原样返回入参本身（连拷贝都不做），方便上层用 `identical()`
/// 命中缓存短路。
List<ChatSession> filterChatSessions({
  required List<ChatSession> sessions,
  required String keyword,
}) {
  final query = keyword.trim().toLowerCase();
  if (query.isEmpty) {
    return sessions;
  }
  return sortChatSessionsForDisplay(
    sessions.where((session) => _matchesQuery(session, query)).toList(),
  );
}

/// 展示顺序：置顶优先，其次 updatedAt 倒序。
///
/// 置顶优先**只放在这里**而不是写进 SQL 的 `orderBy`：`ChatSessionListNotifier` 的
/// `upsertLocal` / `updateSession` 两处内存重排只按 updatedAt，一旦库序掺进
/// `is_pinned DESC`，「冷启动读出的顺序」和「增删改后的顺序」就会出现两套口径。
List<ChatSession> sortChatSessionsForDisplay(List<ChatSession> sessions) {
  final sorted = List<ChatSession>.of(sessions)
    ..sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
  return sorted;
}

/// [at] 距 [base] 多少个自然日；同一天为 0，未来的时间戳按今天算（不产生负偏移）。
int _dayOffsetFrom(DateTime base, DateTime at) {
  final baseDay = DateTime(base.year, base.month, base.day);
  final atDay = DateTime(at.year, at.month, at.day);
  final offset = baseDay.difference(atDay).inDays;
  return offset < 0 ? 0 : offset;
}

List<ChatSession> _sortedByUpdatedAtDesc(List<ChatSession> sessions) {
  return sessions..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
}

bool _matchesQuery(ChatSession session, String query) {
  if (session.title.toLowerCase().contains(query)) {
    return true;
  }
  for (final message in session.messages) {
    if (message.content.toLowerCase().contains(query)) {
      return true;
    }
  }
  return false;
}

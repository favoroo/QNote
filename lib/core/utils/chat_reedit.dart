import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';

/// 用户提问「再次编辑」的支撑件。
///
/// 这几段逻辑都直接耦合 `session.messages` 的落库形态（`uiDetails.attachments` 的
/// 键名与 `role` 序列），留在页面里只能靠起 App 点一点来验证；抽到此处后，
/// 「点哪条、回填哪些引用、chip 显示什么名字」都能在没有数据库和 UI 的环境下锁住。

/// 一条用户消息携带的引用附件 id 集合；字段为 null 表示该类型无引用。
///
/// null-when-absent 的返回口径与发送侧 `CurrentChatNotifier.sendMessage` 的入参
/// 形态一一对应，回填与重试两条链路因此可以直接复用同一份解析。
class ChatAttachmentRefs {
  const ChatAttachmentRefs({this.noteIds, this.todoIds, this.journalIds});

  final List<String>? noteIds;
  final List<String>? todoIds;
  final List<String>? journalIds;

  bool get isEmpty =>
      (noteIds?.isEmpty ?? true) &&
      (todoIds?.isEmpty ?? true) &&
      (journalIds?.isEmpty ?? true);

  /// 从消息的 `uiDetails['attachments']` 还原引用；无该字段的旧消息返回全空实例。
  factory ChatAttachmentRefs.fromMessage(ChatMessage message) {
    final attachments = message.uiDetails?['attachments'];
    final map = attachments is Map ? attachments : null;
    return ChatAttachmentRefs(
      noteIds: _readIds(map, 'notes'),
      todoIds: _readIds(map, 'todos'),
      journalIds: _readIds(map, 'journals'),
    );
  }
}

/// 取一类引用的 id 列表；缺失、非列表、空列表一律归一为 null。
///
/// 元素用 `toString()` 而非直接 `cast<String>()`：messages 列经 `jsonDecode` 后
/// 是 `List<dynamic>`，强转会在回填旧会话时抛异常。
List<String>? _readIds(Map? map, String key) {
  final raw = map?[key];
  if (raw is List && raw.isNotEmpty) {
    return raw.map((e) => e.toString()).toList();
  }
  return null;
}

/// 日记引用在附件条上的展示名（日记标题本身就是一个日期）。
String journalChipTitle(Note note) => '${note.title} 日记';

/// 笔记引用在附件条上的展示名。
String noteChipTitle(Note note) =>
    note.title.isNotEmpty ? note.title : '无标题笔记';

/// 待办引用在附件条上的展示名。
String todoChipTitle(Todo todo) =>
    todo.title.isNotEmpty ? todo.title : '无标题待办';

/// 按 id 回查到的附件标题集合；查不到的 id 不入表，由附件条按类型名兜底。
class ChatAttachmentTitles {
  const ChatAttachmentTitles({
    this.journals = const {},
    this.notes = const {},
    this.todos = const {},
  });

  final Map<String, String> journals;
  final Map<String, String> notes;
  final Map<String, String> todos;
}

/// 回查引用附件的标题。
///
/// 附件条的标题缓存只在打开选择弹窗时填充、不落库，冷启动后是空的：不补标题，
/// 回填的 chip 就只会显示「日记/笔记/待办」，用户无法确认拿回来的是不是原来那几条。
///
/// [noteById]/[todoById] 可注入假实现做单测；默认走各自 Repository 的单行读，
/// 不用 `getAll()`——那会把全表所有记录的完整 content 读进内存，这里只是补标题。
Future<ChatAttachmentTitles> resolveAttachmentTitles(
  ChatAttachmentRefs refs, {
  Future<Note?> Function(String id)? noteById,
  Future<Todo?> Function(String id)? todoById,
}) async {
  if (refs.isEmpty) return const ChatAttachmentTitles();

  final readNote = noteById ?? NoteRepository().getById;
  final readTodo = todoById ?? TodoRepository().getById;
  final journalIds = refs.journalIds ?? const <String>[];
  final noteIds = refs.noteIds ?? const <String>[];
  final todoIds = refs.todoIds ?? const <String>[];

  // 日记与笔记同存 notes 表，合并成一批读；两批各自并发，避免点击到键盘弹起之间
  // 的等待被逐个 await 放大成 N 倍
  final noteFuture = Future.wait(<String>{...journalIds, ...noteIds}.map(readNote));
  final todoFuture = Future.wait(todoIds.map(readTodo));
  final noteList = await noteFuture;
  final todoList = await todoFuture;

  // 查不到（已硬删）或已在回收站的实体不入标题表：getById 不带 is_deleted 过滤，
  // 把回收站里的东西显示成正常标题，用户无从发现重发给模型的是空引用
  final journals = <String, String>{};
  final notes = <String, String>{};
  for (final note in noteList) {
    if (note == null || note.isDeleted) continue;
    if (journalIds.contains(note.id)) {
      journals[note.id] = journalChipTitle(note);
    } else {
      notes[note.id] = noteChipTitle(note);
    }
  }
  final todos = <String, String>{};
  for (final todo in todoList) {
    if (todo == null || todo.isDeleted) continue;
    todos[todo.id] = todoChipTitle(todo);
  }

  return ChatAttachmentTitles(journals: journals, notes: notes, todos: todos);
}

/// 会话里「我最后发的那条提问」的下标；没有用户消息时返回 null。
///
/// 用 `lastIndexWhere` 而非 `length - 1`：最后一条提问后面通常还挂着 assistant/tool
/// 回复，「会话最后一条」是另一个口径（重新生成用的那个），不能混用。
int? reeditableUserIndex(List<ChatMessage> messages) {
  final index = messages.lastIndexWhere((m) => m.role == 'user');
  return index < 0 ? null : index;
}

/// 从 [fromUserIndex] 这条提问起（含其后所有轮次）记录的 VFS 变更条数。
///
/// 撤回是破坏性操作，但拦一次确认也有代价：纯文字问答轮没有任何数据要撤销，
/// 弹窗纯属噪音。因此只有本函数返回 >0 时页面才弹二次确认。
/// 下标越界或指向非用户消息时返回 0——那种情况下 `rollbackToMessage` 本就会拒。
int countTurnUndoChanges(
  List<ChatMessage> messages, {
  required int fromUserIndex,
}) {
  if (fromUserIndex < 0 || fromUserIndex >= messages.length) return 0;
  if (messages[fromUserIndex].role != 'user') return 0;
  var count = 0;
  for (final message in messages.skip(fromUserIndex)) {
    if (message.role == 'user') {
      count += WorkspaceUndoEntry.decodeList(message.undoLog).length;
    }
  }
  return count;
}

/// 编辑态锚点是否仍指向当初点中的那条提问。
///
/// `ChatMessage` 没有主键，只能靠对象引用认人：provider 增删消息重建的都是 List
/// 而非元素，同会话内的正常流转不会误判；而切回会话/冷启动会从库里反序列化出全新
/// 对象，正好判为失效——此时下标可能已指向另一条提问，再按它撤回就删错轮了。
bool isReeditAnchorValid({
  required List<ChatMessage> messages,
  required int index,
  required ChatMessage anchor,
}) {
  if (index < 0 || index >= messages.length) return false;
  return identical(messages[index], anchor);
}

/// 输入区一份「待发送提问」的完整形态：正文 + 图片 + 三类引用 + 引用卡片。
///
/// 只用于比对，不参与发送：发送仍按页面各自的字段逐个传给 `sendMessage`。
class ReeditDraft {
  const ReeditDraft({
    this.text = '',
    this.images = const [],
    this.noteIds = const [],
    this.todoIds = const [],
    this.journalIds = const [],
    this.hasQuote = false,
  });

  final String text;
  final List<String> images;
  final List<String> noteIds;
  final List<String> todoIds;
  final List<String> journalIds;

  /// 是否挂着「给小Q」的框选引用卡片
  final bool hasQuote;

  /// 由被点中的提问还原，作为「原样回填」的比对基准。
  ///
  /// `hasQuote` 恒为 false：引用文本在发送时已整段并入正文，回填也按正文原样拿回，
  /// 不再反解析回引用卡片（措辞模板一改就会静默丢内容）。
  factory ReeditDraft.fromMessage(ChatMessage message) {
    final refs = ChatAttachmentRefs.fromMessage(message);
    return ReeditDraft(
      text: message.content,
      images: message.images ?? const [],
      noteIds: refs.noteIds ?? const [],
      todoIds: refs.todoIds ?? const [],
      journalIds: refs.journalIds ?? const [],
    );
  }

  /// 是否已无任何未发送内容
  bool get isEmpty =>
      text.trim().isEmpty &&
      images.isEmpty &&
      noteIds.isEmpty &&
      todoIds.isEmpty &&
      journalIds.isEmpty &&
      !hasQuote;

  /// 与另一份草稿逐项比对，判断「用户有没有动过这份回填」。
  ///
  /// 附件顺序敏感：附件条就是按这个顺序渲染 chip 的，换了顺序界面确实变了，
  /// 不能算没动过。正文首尾空白除外——发送侧本就会 trim，只敲个空格不算改提问。
  bool matches(ReeditDraft other) =>
      text.trim() == other.text.trim() &&
      hasQuote == other.hasQuote &&
      _sameIds(images, other.images) &&
      _sameIds(noteIds, other.noteIds) &&
      _sameIds(todoIds, other.todoIds) &&
      _sameIds(journalIds, other.journalIds);
}

/// 两份 id 列表是否逐项同序相同。
bool _sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

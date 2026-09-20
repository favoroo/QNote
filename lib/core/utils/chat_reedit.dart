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

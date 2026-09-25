import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/utils/chat_reedit.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';

Note _note(String id, {String title = '标题', bool isDeleted = false}) => Note(
  id: id,
  title: title,
  createdAt: DateTime(2026, 9, 20),
  updatedAt: DateTime(2026, 9, 20),
  isDeleted: isDeleted,
);

Todo _todo(String id, {String title = '买牛奶', bool isDeleted = false}) => Todo(
  id: id,
  title: title,
  createdAt: DateTime(2026, 9, 20),
  updatedAt: DateTime(2026, 9, 20),
  isDeleted: isDeleted,
);

/// 造一条带引用附件的用户消息，形态与 sendMessage 落库时一致
ChatMessage _userMessage({Map<String, dynamic>? attachments}) => ChatMessage(
  role: 'user',
  content: '帮我看看',
  uiDetails: attachments == null ? null : {'attachments': attachments},
);

void main() {
  group('ChatAttachmentRefs.fromMessage', () {
    test('无 uiDetails 的旧消息返回全空实例', () {
      final refs = ChatAttachmentRefs.fromMessage(
        ChatMessage(role: 'user', content: 'hi'),
      );

      expect(refs.noteIds, isNull);
      expect(refs.todoIds, isNull);
      expect(refs.journalIds, isNull);
      expect(refs.isEmpty, isTrue);
    });

    test('三类引用逐一还原', () {
      final refs = ChatAttachmentRefs.fromMessage(
        _userMessage(
          attachments: {
            'notes': ['n1', 'n2'],
            'todos': ['t1'],
            'journals': ['journal_note_2026-09-10'],
          },
        ),
      );

      expect(refs.noteIds, ['n1', 'n2']);
      expect(refs.todoIds, ['t1']);
      expect(refs.journalIds, ['journal_note_2026-09-10']);
      expect(refs.isEmpty, isFalse);
    });

    test('缺失、空列表、非列表一律归一为 null', () {
      final refs = ChatAttachmentRefs.fromMessage(
        _userMessage(attachments: {'notes': <String>[], 'todos': 't1'}),
      );

      expect(refs.noteIds, isNull);
      expect(refs.todoIds, isNull);
      expect(refs.journalIds, isNull);
      expect(refs.isEmpty, isTrue);
    });

    test('messages 列 jsonDecode 出的 List<dynamic> 也能取到 id', () {
      // 从库里读出时元素未必是 String，强转 cast<String> 会在回填旧会话时抛异常
      final refs = ChatAttachmentRefs.fromMessage(
        _userMessage(
          attachments: {
            'notes': <dynamic>['n1', 2, 3],
          },
        ),
      );

      expect(refs.noteIds, ['n1', '2', '3']);
    });
  });

  group('附件 chip 展示名', () {
    test('日记带「日记」后缀，笔记与待办空标题走占位名', () {
      expect(
        journalChipTitle(_note('journal_note_2026-09-10', title: '2026-09-10')),
        '2026-09-10 日记',
      );
      expect(noteChipTitle(_note('n1', title: '周报模板')), '周报模板');
      expect(noteChipTitle(_note('n2', title: '')), '无标题笔记');
      expect(todoChipTitle(_todo('t1', title: '买牛奶')), '买牛奶');
      expect(todoChipTitle(_todo('t2', title: '')), '无标题待办');
    });
  });

  group('resolveAttachmentTitles', () {
    test('无引用时不碰任何 Repository', () async {
      var noteReads = 0;
      var todoReads = 0;

      final titles = await resolveAttachmentTitles(
        const ChatAttachmentRefs(),
        noteById: (id) async {
          noteReads++;
          return _note(id);
        },
        todoById: (id) async {
          todoReads++;
          return _todo(id);
        },
      );

      expect(titles.journals, isEmpty);
      expect(titles.notes, isEmpty);
      expect(titles.todos, isEmpty);
      expect(noteReads, 0);
      expect(todoReads, 0);
    });

    test('日记与笔记同走 notes 表单行读，各自只查一次', () async {
      final readNoteIds = <String>[];
      final readTodoIds = <String>[];

      final titles = await resolveAttachmentTitles(
        const ChatAttachmentRefs(
          noteIds: ['n1'],
          todoIds: ['t1'],
          journalIds: ['journal_note_2026-09-10'],
        ),
        noteById: (id) async {
          readNoteIds.add(id);
          return id.startsWith('journal_')
              ? _note(id, title: '2026-09-10')
              : _note(id, title: '周报模板');
        },
        todoById: (id) async {
          readTodoIds.add(id);
          return _todo(id);
        },
      );

      // 锁住「按 id 单行读」而不是退化成 getAll 全表扫：每个 id 只应出现一次
      expect(readNoteIds..sort(), ['journal_note_2026-09-10', 'n1']);
      expect(readTodoIds, ['t1']);
      expect(titles.journals, {'journal_note_2026-09-10': '2026-09-10 日记'});
      expect(titles.notes, {'n1': '周报模板'});
      expect(titles.todos, {'t1': '买牛奶'});
    });

    test('三类引用并发回查，不逐个串行 await', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      Future<T> track<T>(T value) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return value;
      }

      await resolveAttachmentTitles(
        const ChatAttachmentRefs(
          noteIds: ['n1', 'n2'],
          todoIds: ['t1', 't2'],
          journalIds: ['journal_note_2026-09-10'],
        ),
        noteById: (id) => track(_note(id)),
        todoById: (id) => track(_todo(id)),
      );

      expect(maxInFlight, greaterThan(1));
    });

    test('已硬删或回收站里的实体不入标题表', () async {
      final titles = await resolveAttachmentTitles(
        const ChatAttachmentRefs(
          noteIds: ['gone', 'trashed'],
          todoIds: ['goneT'],
        ),
        noteById: (id) async {
          if (id == 'gone') return null;
          return _note(id, title: '已进回收站', isDeleted: true);
        },
        todoById: (id) async => null,
      );

      // 不入表 → 附件条按类型名兜底，用户看得见异常并能就地移除
      expect(titles.notes, isEmpty);
      expect(titles.todos, isEmpty);
    });
  });

  group('reeditableUserIndex', () {
    ChatMessage msg(String role) => ChatMessage(role: role, content: role);

    test('空会话与无用户消息返回 null', () {
      expect(reeditableUserIndex([]), isNull);
      expect(reeditableUserIndex([msg('assistant'), msg('tool')]), isNull);
    });

    test('取最后一条用户消息，而非会话最后一条', () {
      expect(
        reeditableUserIndex([msg('user'), msg('assistant'), msg('tool')]),
        0,
      );
      expect(
        reeditableUserIndex([msg('user'), msg('user'), msg('assistant')]),
        1,
      );
      expect(
        reeditableUserIndex([msg('user'), msg('assistant'), msg('user')]),
        2,
      );
      expect(
        reeditableUserIndex([
          msg('user'),
          msg('assistant'),
          msg('user'),
          msg('tool_group'),
        ]),
        2,
      );
    });
  });

  group('countTurnUndoChanges', () {
    ChatMessage user(String content, {int changes = 0}) => ChatMessage(
      role: 'user',
      content: content,
      undoLog: changes == 0
          ? null
          : WorkspaceUndoEntry.encodeList([
              for (var i = 0; i < changes; i++)
                WorkspaceUndoEntry(
                  path: '/timeline/$i.md',
                  existedBefore: false,
                ),
            ]),
    );
    ChatMessage ai() => ChatMessage(role: 'assistant', content: '好了');

    test('纯文字问答轮返回 0：不该为它弹确认', () {
      expect(countTurnUndoChanges([user('今天吃了啥'), ai()], fromUserIndex: 0), 0);
    });

    test('累加本轮及其后所有轮次的变更', () {
      // 回退会把后面几轮一并撤掉，确认文案里的数字必须算全，否则低估破坏面
      final messages = [
        user('第一轮', changes: 2),
        ai(),
        user('第二轮', changes: 3),
        ai(),
      ];
      expect(countTurnUndoChanges(messages, fromUserIndex: 0), 5);
      expect(countTurnUndoChanges(messages, fromUserIndex: 2), 3);
    });

    test('下标越界或指向非用户消息返回 0', () {
      final messages = [user('提问', changes: 4), ai()];
      expect(countTurnUndoChanges(messages, fromUserIndex: 9), 0);
      expect(countTurnUndoChanges(messages, fromUserIndex: -1), 0);
      expect(countTurnUndoChanges(messages, fromUserIndex: 1), 0);
      expect(countTurnUndoChanges(const [], fromUserIndex: 0), 0);
    });

    test('undoLog 是畸形 JSON 时归 0，不抛', () {
      final messages = [
        ChatMessage(role: 'user', content: '提问', undoLog: '{不是列表'),
      ];
      expect(countTurnUndoChanges(messages, fromUserIndex: 0), 0);
    });
  });

  group('isReeditAnchorValid', () {
    ChatMessage user([String content = '提问']) =>
        ChatMessage(role: 'user', content: content);

    test('同对象同下标有效', () {
      final anchor = user();
      final messages = [user('更早'), anchor, user('更早')];
      expect(
        isReeditAnchorValid(messages: messages, index: 1, anchor: anchor),
        isTrue,
      );
    });

    test('越界或该下标已非用户消息时失效', () {
      final anchor = user();
      final messages = [anchor, ChatMessage(role: 'assistant', content: 'ok')];
      expect(
        isReeditAnchorValid(messages: messages, index: 5, anchor: anchor),
        isFalse,
      );
      expect(
        isReeditAnchorValid(messages: messages, index: 1, anchor: anchor),
        isFalse,
      );
    });

    test('同下标换成内容与时间戳完全相同的另一条对象：判失效', () {
      // 锁死「不许用内容比对冒充身份」：库里读回来的副本逐字段相同，
      // 但按它撤回就可能删掉另一轮，只有对象引用能认出还是原来那条
      final timestamp = DateTime(2026, 9, 25, 8, 30);
      final anchor = ChatMessage(
        role: 'user',
        content: '记一下',
        timestamp: timestamp,
      );
      final lookAlike = ChatMessage(
        role: 'user',
        content: '记一下',
        timestamp: timestamp,
      );
      expect(lookAlike.content, anchor.content);
      expect(
        isReeditAnchorValid(messages: [lookAlike], index: 0, anchor: anchor),
        isFalse,
      );
    });

    test('回退把列表截到锚点之前：失效', () {
      final anchor = user();
      expect(
        isReeditAnchorValid(messages: [user('更早')], index: 1, anchor: anchor),
        isFalse,
      );
    });
  });

  group('ReeditDraft', () {
    test('fromMessage 还原正文、图片与三类引用', () {
      final draft = ReeditDraft.fromMessage(
        ChatMessage(
          role: 'user',
          content: '帮我看看这几条',
          images: const ['/a.png', '/b.png'],
          uiDetails: {
            'attachments': {
              'notes': ['n1'],
              'todos': ['t1'],
              'journals': ['journal_note_2026-09-10'],
            },
          },
        ),
      );

      expect(draft.text, '帮我看看这几条');
      expect(draft.images, ['/a.png', '/b.png']);
      expect(draft.noteIds, ['n1']);
      expect(draft.todoIds, ['t1']);
      expect(draft.journalIds, ['journal_note_2026-09-10']);
      // 引用文本发送时已并入正文，回填不再还原成引用卡片
      expect(draft.hasQuote, isFalse);
    });

    test('isEmpty：每个字段单独置非空都能翻成 false', () {
      expect(const ReeditDraft().isEmpty, isTrue);
      // 只有一处空白不算内容：发送侧本就会 trim
      expect(const ReeditDraft(text: '   ').isEmpty, isTrue);
      expect(const ReeditDraft(text: '提问').isEmpty, isFalse);
      expect(const ReeditDraft(images: ['a']).isEmpty, isFalse);
      expect(const ReeditDraft(noteIds: ['n']).isEmpty, isFalse);
      expect(const ReeditDraft(todoIds: ['t']).isEmpty, isFalse);
      expect(const ReeditDraft(journalIds: ['j']).isEmpty, isFalse);
      expect(const ReeditDraft(hasQuote: true).isEmpty, isFalse);
    });

    test('matches 对附件顺序敏感', () {
      // 附件条就是按这个顺序渲染 chip 的，换了顺序界面确实变了，不能算没动过
      const a = ReeditDraft(noteIds: ['n1', 'n2']);
      const b = ReeditDraft(noteIds: ['n2', 'n1']);
      expect(a.matches(b), isFalse);
      expect(a.matches(a), isTrue);
    });

    test('matches 忽略正文首尾空白，但比对 hasQuote', () {
      const base = ReeditDraft(text: '记一条待办');
      expect(base.matches(const ReeditDraft(text: '记一条待办\n')), isTrue);
      expect(base.matches(const ReeditDraft(text: '记一条待办 ')), isTrue);
      expect(base.matches(const ReeditDraft(text: '记一条笔记')), isFalse);
      expect(
        base.matches(const ReeditDraft(text: '记一条待办', hasQuote: true)),
        isFalse,
      );
    });
  });
}

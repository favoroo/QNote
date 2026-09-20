import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/chat_time_group.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 固定「现在」，让 7/30 天边界可断言（与 stats_utils 的 today 注入同惯例）
final _now = DateTime(2026, 9, 15, 12);

ChatSession _session(
  String id,
  DateTime updatedAt, {
  String title = '标题',
  bool pinned = false,
  List<String> contents = const [],
  List<String> thoughts = const [],
}) {
  return ChatSession(
    id: id,
    title: title,
    isPinned: pinned,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: [
      for (final content in contents)
        ChatMessage(role: 'user', content: content, timestamp: updatedAt),
      for (final thought in thoughts)
        ChatMessage(role: 'assistant', content: '', thought: thought),
    ],
  );
}

/// 把分组摊平回一维，用于「每个 id 恰好出现一次」这条不变式
List<String> _flattenIds(List<ChatHistoryGroup> groups) => [
  for (final group in groups)
    for (final session in group.sessions) session.id,
];

String? _groupOf(List<ChatHistoryGroup> groups, String id) {
  for (final group in groups) {
    if (group.sessions.any((s) => s.id == id)) {
      return group.id;
    }
  }
  return null;
}

void main() {
  group('时间分桶边界', () {
    test('按自然日归一：偏移 0~6 进「7 天内」，7~29 进「30 天内」', () {
      final groups = buildChatHistoryGroups(
        [
          _session('today', _now),
          _session('d6', DateTime(2026, 9, 9, 13)),
          _session('d7', DateTime(2026, 9, 8, 23, 59)),
          _session('d29', DateTime(2026, 8, 17)),
          _session('d30', DateTime(2026, 8, 16)),
        ],
        now: _now,
      );

      expect(_groupOf(groups, 'today'), 'recent7');
      // 同一天的 13:00 与 23:59 不会因小时差被劈到两个组
      expect(_groupOf(groups, 'd6'), 'recent7');
      expect(_groupOf(groups, 'd7'), 'within30');
      expect(_groupOf(groups, 'd29'), 'within30');
      expect(_groupOf(groups, 'd30'), 'y2026-8');
    });

    test('未来的时间戳按今天算，不产生负偏移', () {
      final groups = buildChatHistoryGroups(
        [_session('future', _now.add(const Duration(days: 3)))],
        now: _now,
      );
      expect(groups.single.id, 'recent7');
    });

    test('组顺序为 置顶 → 7 天内 → 30 天内 → 月组（年月降序）', () {
      final groups = buildChatHistoryGroups(
        [
          _session('aug', DateTime(2026, 8, 10), pinned: true),
          _session('r7', DateTime(2026, 9, 14)),
          _session('w30', DateTime(2026, 9, 1)),
          _session('jul', DateTime(2026, 7, 20)),
        ],
        now: _now,
      );
      expect(
        groups.map((g) => g.id).toList(),
        ['pinned', 'recent7', 'within30', 'y2026-7'],
      );
    });

    test('跨年：2026年1月 排在 2025年12月 之前', () {
      final groups = buildChatHistoryGroups(
        [
          _session('dec', DateTime(2025, 12, 31)),
          _session('jan', DateTime(2026, 1, 1)),
        ],
        now: _now,
      );
      expect(groups.map((g) => g.label).toList(), ['2026年1月', '2025年12月']);
    });

    test('月组 label 的月不补零，闰日单独成组', () {
      final groups = buildChatHistoryGroups(
        [
          _session('leap', DateTime(2024, 2, 29)),
          _session('nov', DateTime(2025, 11, 5)),
        ],
        now: _now,
      );
      expect(groups.map((g) => g.label).toList(), ['2025年11月', '2024年2月']);
    });

    test('空组根本不出现，而不是渲染一个空节头', () {
      final groups = buildChatHistoryGroups(
        [_session('only', _now)],
        now: _now,
      );
      expect(groups.length, 1);
      expect(groups.single.id, 'recent7');
    });
  });

  group('置顶', () {
    test('每个会话恰好进一个组（守住抽屉行 GlobalKey 唯一性）', () {
      final sessions = [
        _session('p1', _now, pinned: true),
        _session('p2', DateTime(2024, 2, 29), pinned: true),
        _session('r1', DateTime(2026, 9, 12)),
        _session('w1', DateTime(2026, 8, 20)),
        _session('m1', DateTime(2026, 3, 3)),
        _session('m2', DateTime(2025, 10, 9)),
      ];
      final groups = buildChatHistoryGroups(sessions, now: _now);
      final ids = _flattenIds(groups);

      expect(ids.length, sessions.length);
      expect(ids.toSet().length, sessions.length);
      expect(ids.toSet(), sessions.map((s) => s.id).toSet());
    });

    test('置顶项从时间桶里被摘走，组内仍按 updatedAt 倒序', () {
      final groups = buildChatHistoryGroups(
        [
          _session('old', DateTime(2025, 5, 5), pinned: true),
          _session('new', DateTime(2026, 9, 14), pinned: true),
          _session('recent', _now),
        ],
        now: _now,
      );

      expect(groups.first.id, 'pinned');
      expect(groups.first.sessions.map((s) => s.id).toList(), ['new', 'old']);
      // 三个月前那条只在置顶组，不重复出现在「7 天内」或月组
      expect(_groupOf(groups, 'old'), 'pinned');
      expect(_flattenIds(groups).where((id) => id == 'old').length, 1);
    });

    test('取消置顶后按原 updatedAt 落回时间桶，无需额外记账', () {
      final pinned = _session('x', DateTime(2026, 3, 3), pinned: true);
      expect(
        _groupOf(buildChatHistoryGroups([pinned], now: _now), 'x'),
        'pinned',
      );
      expect(
        _groupOf(
          buildChatHistoryGroups([pinned.copyWith(isPinned: false)], now: _now),
          'x',
        ),
        'y2026-3',
      );
    });

    test('折叠键只由年月推出：组内新增会话不会让用户折叠的组弹开', () {
      final before = buildChatHistoryGroups(
        [_session('a', DateTime(2026, 3, 3))],
        now: _now,
      ).single;
      final after = buildChatHistoryGroups(
        [_session('a', DateTime(2026, 3, 3)), _session('b', DateTime(2026, 3, 9))],
        now: _now,
      ).single;
      expect(before.id, after.id);
      expect(after.count, 2);
    });
  });

  group('默认展开策略', () {
    test('置顶 / 7 天内 / 30 天内 展开，月组折叠', () {
      final groups = buildChatHistoryGroups(
        [
          _session('p', _now, pinned: true),
          _session('r', DateTime(2026, 9, 14)),
          _session('w', DateTime(2026, 9, 1)),
          _session('m', DateTime(2026, 3, 3)),
        ],
        now: _now,
      );
      expect(
        groups.map((g) => g.isDefaultExpanded).toList(),
        [true, true, true, false],
      );
    });
  });

  group('关键词过滤', () {
    final sessions = [
      _session('by-title', _now, title: '电池容量计算'),
      _session('by-body', DateTime(2026, 9, 1), title: '杂项', contents: ['关于 EMP 参数的说明']),
      _session('no-hit', DateTime(2026, 8, 1), title: '无关', contents: ['nothing here']),
    ];

    test('命中标题或正文', () {
      expect(
        filterChatSessions(sessions: sessions, keyword: '电池').map((s) => s.id),
        ['by-title'],
      );
      expect(
        filterChatSessions(sessions: sessions, keyword: '参数').map((s) => s.id),
        ['by-body'],
      );
      expect(filterChatSessions(sessions: sessions, keyword: 'zzz'), isEmpty);
      // 三选二：不相关的两条不该混进来
      expect(
        filterChatSessions(sessions: sessions, keyword: '容量').map((s) => s.id),
        ['by-title'],
      );
    });

    test('大小写不敏感且两侧空白被 trim', () {
      expect(
        filterChatSessions(sessions: sessions, keyword: '  emp  ').map((s) => s.id),
        ['by-body'],
      );
    });

    test('不扫 thought：只有思考过程含词时不算命中', () {
      final onlyThought = [
        _session('t', _now, title: '标题', thoughts: ['电池容量推导过程']),
      ];
      expect(filterChatSessions(sessions: onlyThought, keyword: '电池'), isEmpty);
    });

    test('空关键词原样返回入参本身，方便上层 identical() 短路', () {
      expect(
        identical(filterChatSessions(sessions: sessions, keyword: '   '), sessions),
        isTrue,
      );
    });

    test('结果顺序为置顶优先、其次 updatedAt 倒序', () {
      final result = filterChatSessions(
        sessions: [
          _session('old-pinned', DateTime(2025, 1, 1), title: '电池', pinned: true),
          _session('new', _now, title: '电池'),
          _session('mid', DateTime(2026, 9, 10), title: '电池'),
        ],
        keyword: '电池',
      );
      expect(result.map((s) => s.id).toList(), ['old-pinned', 'new', 'mid']);
    });
  });
}

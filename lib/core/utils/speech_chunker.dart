import 'dart:math' show min;

/// 流式正文 → 可朗读片段的增量切分器。
///
/// 自动朗读原本要等整段回复生成完才送一次合成，正文越长首声越晚。本类把
/// token 级增量按句读切成"够念一小口气"的片段，第一段攒够就交给合成，
/// 让首声延迟与回复总长解耦。
///
/// 契约（由单测锁住）：
/// - 不吐未写完的半句：切点必须是句末标点，且通过 markdown 标记成对校验；
/// - 不吐代码内容：``` 围栏按行整体丢弃，未闭合期间的代码同样不出声；
/// - 逐字符 feed 与整块 feed 得到完全相同的片段序列。
///
/// 输出的片段仍是原始 markdown，去标记与折行由调用方（`TtsService.cleanSpeechText`）
/// 负责，本类保持零依赖以便直接单测。
class SpeechChunker {
  SpeechChunker({
    this.minChars = defaultMinChars,
    this.maxChars = defaultMaxChars,
    this.hardLimit = defaultHardLimit,
  }) : subsequentMinChars = (minChars ~/ 3).clamp(8, 24);

  /// 首段起播门槛（可朗读字数）：够念十来个字的连续语音，又不必等整段写完
  static const int defaultMinChars = 40;

  /// 目标段长：超过它即使没有句末标点也倾向在子句处收尾
  static const int defaultMaxChars = 160;

  /// 无句末标点时的硬切阈值：宁可断句也不能让下一段无限等下去
  static const int defaultHardLimit = 240;

  final int minChars;
  final int maxChars;
  final int hardLimit;

  /// 后续段门槛：比首段宽松，但仍挡住"好。""对。"这类三字段造成合成请求风暴
  final int subsequentMinChars;

  /// 尚未收到换行的当前行（原始 markdown）
  String _line = '';

  /// 已确认可朗读、但还没凑成出段条件的文本
  String _readable = '';

  /// 是否处于 ``` / ~~~ 围栏代码块内
  bool _inFence = false;

  /// 首段门槛是否已越过（越过后改用较宽松的 [subsequentMinChars]）
  bool _gateCleared = false;

  /// 暂无任何可朗读内容。上层据此判断"还没开口"，就不必去打断正在播的音频。
  bool get isEmpty => _readable.trim().isEmpty && _line.trim().isEmpty;

  /// 喂入一段流式增量，返回 0..n 个可朗读片段。
  List<String> feed(String delta) {
    var rest = delta;
    while (rest.isNotEmpty) {
      final nl = rest.indexOf('\n');
      if (nl < 0) {
        _line = '$_line$rest';
        break;
      }
      _commitLine('$_line${rest.substring(0, nl)}');
      _line = '';
      rest = rest.substring(nl + 1);
    }
    return _drain();
  }

  /// 收尾：把剩余文本作为最后一片吐出（含未满门槛的尾巴）。
  ///
  /// 未闭合代码块里的残留已被丢弃，不会在此刻冒出来。
  List<String> flush() {
    if (_line.isNotEmpty) {
      _commitLine(_line);
      _line = '';
    }
    final tail = _readable.trim();
    _readable = '';
    _gateCleared = false;
    return tail.isEmpty ? const [] : [tail];
  }

  /// 作废本轮（Agent 新一轮 turnStart 会清空正文缓冲，界面与朗读都要跟着重来）
  void discard() {
    _line = '';
    _readable = '';
    _inFence = false;
    _gateCleared = false;
  }

  /// 一行写完：先过围栏状态机，可读才进 [_readable]。
  ///
  /// 逐行判定而非整段正则：流式中途 ``` 可能只到了前两个反引号，
  /// 靠 [_lineIsAmbiguous] 把这种行扣住，才不会把代码块误当正文念出来。
  void _commitLine(String line) {
    if (_fenceLine.hasMatch(line)) {
      _inFence = !_inFence;
      return;
    }
    if (_inFence) return;
    _readable = '$_readable$line\n';
  }

  /// 当前行是否还不能判性：在围栏里，或以反引号开头（可能是还没写全的 ``` 围栏）
  bool get _lineLocked => _inFence || _fenceLead.hasMatch(_line);

  /// 从可读窗口里尽量出段，并推进内部游标。
  List<String> _drain() {
    final tailReadable = !_lineLocked;
    final text = tailReadable ? '$_readable$_line' : _readable;
    final out = <String>[];
    var consumed = 0;

    while (consumed < text.length) {
      final split = _findSplit(text.substring(consumed));
      if (split == null) break;
      consumed += split;
      final segment = text.substring(consumed - split, consumed).trim();
      if (segment.isEmpty) continue;
      _gateCleared = true;
      out.add(segment);
    }

    if (consumed == 0) return out;
    if (!tailReadable) {
      _readable = text.substring(consumed);
      return out;
    }
    // 尾巴行也可以被消费一部分（切点落在句末，剩余仍属同一行）
    final fromReadable = min(consumed, _readable.length);
    _readable = _readable.substring(fromReadable);
    _line = _line.substring(consumed - fromReadable);
    return out;
  }

  /// 返回可出段的前缀长度，null 表示现在还不能出声、需要继续攒。
  ///
  /// 切点取「最靠后且不超过 [maxChars] 的可行句末」：段够长才念得连贯，Edge 每段
  /// 一次握手的固定开销也才摊得薄。全部句末都超长时退而选最短的那个可行切点；
  /// 一个可用切点都没有（长串无标点、或标记未闭合）时，只有文本已长过
  /// [hardLimit] 才降级到子句标点或定长硬切 —— 再等下去首声就没有意义了。
  int? _findSplit(String text) {
    final endings = [
      for (final m in _sentenceEnd.allMatches(text)) m.end,
    ];
    final threshold = _gateCleared ? subsequentMinChars : minChars;
    if (endings.isEmpty) {
      if (text.length < hardLimit) return null;
      return _lastMatchEnd(text, _clauseEnd) ?? min(text.length, maxChars);
    }

    int? overLong;
    for (var i = endings.length - 1; i >= 0; i--) {
      final candidate = endings[i];
      final head = text.substring(0, candidate);
      if (_firstUnclosedMarker(head) != null) continue;
      if (_speechLength(head) < threshold) continue;
      if (candidate <= maxChars) return candidate;
      overLong = candidate;
    }

    if (overLong != null && text.length <= hardLimit) {
      // 句子本身比目标段长，但还没长到该打断的程度：整段送出，不切断一句话
      return overLong;
    }
    if (text.length < hardLimit) return null;
    final clause = _lastMatchEnd(text, _clauseEnd);
    if (clause != null && clause >= threshold) return clause;
    return min(text.length, maxChars);
  }

  static int? _lastMatchEnd(String text, RegExp pattern) {
    int? end;
    for (final m in pattern.allMatches(text)) {
      end = m.end;
    }
    return end;
  }

  /// 句末切点：句子写完即可送合成；换行同样成立（markdown 段落与列表项天然成行）
  static final RegExp _sentenceEnd = RegExp(r'[。！？；…!?;\n]');

  /// 子句标点：等不到句末时的退路，避免硬生生按字数切断词
  static final RegExp _clauseEnd = RegExp(r'[，、,：:]');

  /// 行首围栏标记（缩进 ≤3 空格）
  static final RegExp _fenceLine = RegExp(r'^ {0,3}(?:```|~~~)');

  /// 以反引号开头的行：还可能是围栏，先扣住
  static final RegExp _fenceLead = RegExp(r'^ {0,3}`');

  /// 计数时忽略的排版噪音：空白与 markdown 结构性符号
  static final RegExp _markupNoise = RegExp(r'[\s*`>#~|\-()\[\]!]');

  /// 返回 [text] 中最早一个"开了却没关"的 markdown 标记起始下标，全部闭合返回 null。
  ///
  /// 切点若落在 `**加粗**` / `` `代码` `` / `[链接](url)` 内部，单独成段的半个标记
  /// 会被清洗正则漏掉、朗读时念出星号与反引号，因此这类切点一律不采用。
  static int? _firstUnclosedMarker(String text) {
    var best = -1;
    void consider(int? index) {
      if (index == null) return;
      if (best < 0 || index < best) best = index;
    }

    consider(_unpairedEmphasisStart(text, '**'));
    consider(_unpairedEmphasisStart(text, '~~'));
    consider(_unpairedEmphasisStart(text, '`'));

    // 链接/图片：最后出现的 `[` 之后没有 `]` 就是被切断了
    final openBracket = text.lastIndexOf('[');
    if (openBracket >= 0 && !text.substring(openBracket).contains(']')) {
      consider(openBracket);
    }
    // 停在半个 URL 上时清洗正则认不出完整链接，会把斜杠和点号念出来
    final trailingUrl = RegExp(r'(?:https?://|www\.)\S*$').firstMatch(text);
    if (trailingUrl != null && trailingUrl.group(0)!.endsWith('/')) {
      consider(trailingUrl.start);
    }
    return best < 0 ? null : best;
  }

  /// 成对标记（`**`、`~~`、`` ` ``）未闭合时的开点；全部闭合返回 null。
  static int? _unpairedEmphasisStart(String text, String marker) {
    final occurrences = <int>[];
    var index = text.indexOf(marker);
    while (index >= 0) {
      occurrences.add(index);
      index = text.indexOf(marker, index + marker.length);
    }
    if (occurrences.isEmpty || occurrences.length.isEven) return null;
    // 奇数个：最后一个就是还没关上的那个开点
    return occurrences.last;
  }

  /// 可朗读字符数：剔除空白与 markdown 结构符号，门槛要按"真正念出来的字数"算。
  static int _speechLength(String text) {
    final stripped = text.replaceAll(_markupNoise, '');
    // emoji 与杂类符号不会被念出来，不计入门槛
    return stripped.runes
        .where(
          (r) => !(r >= 0x1F000 && r <= 0x1FAFF) && !(r >= 0x2600 && r <= 0x27BF),
        )
        .length;
  }
}

import 'dart:typed_data';

import 'package:qnote_flutter/core/tts/tts_engine.dart';

export 'package:qnote_flutter/core/tts/tts_engine.dart'
    show TtsException, kOnlineSynthesisSupported;

/// 小Q「语音回复」的统一合成服务：文本清洗、音色目录与在线/系统双通道入口。
///
/// 在线通道（Edge TTS，仅原生端）免费、免密钥，中文神经网络音色接近真人；
/// 失败或 Web 端由调用方（[TtsPlayer]）降级到系统语音。
class TtsService {
  TtsService._();

  /// 朗读文本的最大长度：聊天回复过长的尾部价值低，截断控制在
  /// 一分钟左右的朗读时长，兼顾合成耗时与流量
  static const int maxSpeechChars = 600;

  /// 内置精选的 Edge 中文音色（zh-CN 系），名称与 Azure/Edge 音色表一致
  static const List<TtsVoiceOption> builtinVoices = [
    TtsVoiceOption('zh-CN-XiaoxiaoNeural', '晓晓', '女声 · 温暖自然'),
    TtsVoiceOption('zh-CN-XiaoyiNeural', '晓伊', '女声 · 活泼甜美'),
    TtsVoiceOption('zh-CN-YunxiNeural', '云希', '男声 · 年轻阳光'),
    TtsVoiceOption('zh-CN-YunyangNeural', '云扬', '男声 · 新闻播音'),
    TtsVoiceOption('zh-CN-YunjianNeural', '云健', '男声 · 浑厚有力'),
    TtsVoiceOption('zh-CN-YunxiaNeural', '云夏', '少年音 · 清亮'),
    TtsVoiceOption('zh-CN-liaoning-XiaobeiNeural', '晓贝', '女声 · 东北方言'),
  ];

  /// 默认音色 ID（晓晓：最自然的通用女声）
  static const String defaultVoice = 'zh-CN-XiaoxiaoNeural';

  /// 按 ID 查音色条目，未知 ID（历史配置/平台差异）回退到默认音色条目
  static TtsVoiceOption voiceById(String id) {
    for (final v in builtinVoices) {
      if (v.id == id) return v;
    }
    return builtinVoices.first;
  }

  /// 在线合成：返回 mp3 音频字节。仅原生端支持，Web 端抛 [TtsException]。
  static Future<Uint8List> synthesize({
    required String text,
    required String voice,
    required double rate,
  }) {
    return synthesizeOnline(text, voice: voice, rate: rate);
  }

  /// 系统语音朗读（阻塞至完成）。原生端走 flutter_tts，Web 端走浏览器语音。
  static Future<void> speakNative({required String text, required double rate}) {
    return systemSpeak(text, rate: rate);
  }

  /// 停止系统语音朗读
  static Future<void> stopNative() => systemStop();

  /// 把 markdown 回复清洗成适合朗读的纯文本。
  ///
  /// 聊天回复里的代码块、表格、链接 URL 朗读出来全是噪音，逐一剥离；
  /// 标题/列表降级为普通句子，连续空白折叠为单个空格，超出
  /// [maxChars] 时按句子边界截断。
  static String cleanSpeechText(String raw, {int maxChars = maxSpeechChars}) {
    var text = raw;
    // 围栏代码块整体剔除（代码没有朗读价值）
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    // 行内代码去反引号
    text = text.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1)!);
    // 图片标记整体剔除
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // 链接仅保留文字
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1)!,
    );
    // 裸 URL 剔除
    text = text.replaceAll(RegExp(r'https?://\S+'), ' ');
    // 表格：剔除分隔行，单元格竖线换为空格
    text = text.replaceAllMapped(
      RegExp(r'^\s*\|?[\s:|-]+\|[\s:|-]*$', multiLine: true),
      (_) => ' ',
    );
    text = text.replaceAll('|', ' ');
    // 标题/引用/列表前缀符号剥离（保留正文内容）
    text = text.replaceAll(
      RegExp(r'^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+', multiLine: true),
      '',
    );
    // 加粗/斜体/删除线标记
    text = text.replaceAllMapped(RegExp(r'\*\*([^*]*)\*\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'~~([^~]*)~~'), (m) => m.group(1)!);
    // HTML 标签剥离
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
    // emoji 及杂类符号（朗读时会念出奇怪的描述或被跳过打顿）
    text = text.replaceAll(
      RegExp(
        r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]',
        unicode: true,
      ),
      ' ',
    );
    // markdown 转义符与多余空白
    text = text.replaceAll('\\', ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 符号剔除/替换留下的空格会落在标点前，读起来有停顿异味，回收之
    text = text.replaceAllMapped(
      RegExp(r'\s+([，。！？、；：,.!?;:])'),
      (m) => m.group(1)!,
    );
    if (text.length <= maxChars) return text;
    // 句子边界截断：回退到最后一个句读符号，避免断在半截
    final window = text.substring(0, maxChars);
    final cut = window.lastIndexOf(RegExp(r'[。！？!?.；;，,]'));
    final clipped = cut >= maxChars ~/ 2 ? window.substring(0, cut + 1) : window;
    return '$clipped……后文略。';
  }
}

/// Edge 音色条目
class TtsVoiceOption {
  /// 音色 ID（Edge/Azure 标准名，如 zh-CN-XiaoxiaoNeural）
  final String id;

  /// 展示名（中文昵称）
  final String label;

  /// 风格说明（性别与语气特点）
  final String note;

  const TtsVoiceOption(this.id, this.label, this.note);
}

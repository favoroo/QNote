import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/edge_tts_client.dart';
import 'package:qnote_flutter/core/tts/edge_ws.dart';

void main() {
  group('EdgeTtsClient.generateSecMsGecFor', () {
    test('与上游 edge-tts DRM 算法对齐（固定时间戳期望值）', () {
      // UTC 2026-09-19 04:23:04Z，期望值由同一算法在 Python 端独立计算
      final utc = DateTime.utc(2026, 9, 19, 4, 23, 4);
      expect(
        EdgeTtsClient.generateSecMsGecFor(utc),
        'F1FEBCBC5A69A5C5A5BFF0B2E470829DAD8963EE0A9D1365D48A1FCEF795E7FD',
      );
    });

    test('5 分钟边界内的时间产生相同令牌', () {
      final a = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 20, 1),
      );
      final b = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 24, 59),
      );
      expect(a, b);
    });

    test('跨 5 分钟边界令牌变化', () {
      final a = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 24, 59),
      );
      final b = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 25, 1),
      );
      expect(a, isNot(b));
    });
  });

  group('EdgeTtsClient.buildSsml', () {
    test('包含音色名与语速百分比', () {
      final ssml = EdgeTtsClient.buildSsml(
        text: '你好',
        voice: 'zh-CN-YunxiNeural',
        rate: 1.2,
      );
      expect(ssml, contains("<voice name='zh-CN-YunxiNeural'>"));
      expect(ssml, contains("rate='+20%'"));
      expect(ssml, contains('你好'));
    });

    test('语速倍率换算为百分比偏移', () {
      String rateOf(double multiplier) {
        final ssml = EdgeTtsClient.buildSsml(
          text: 'x',
          voice: 'v',
          rate: multiplier,
        );
        return RegExp(r"rate='([^']+)'").firstMatch(ssml)!.group(1)!;
      }

      expect(rateOf(1.0), '+0%');
      expect(rateOf(0.8), '-20%');
      expect(rateOf(1.05), '+5%');
    });

    test('XML 特殊字符转义', () {
      final ssml = EdgeTtsClient.buildSsml(
        text: 'a&b<c>"d\'e',
        voice: 'v',
        rate: 1.0,
      );
      expect(ssml, contains('a&amp;b&lt;c&gt;&quot;d&apos;e'));
      expect(ssml, isNot(contains('a&b')));
    });
  });

  group('EdgeTtsClient.synthesize 帧解析', () {
    test('拼接 Path:audio 帧的音频负载，收到 turn.end 后返回', () async {
      final connection = _FakeConnection([
        const EdgeWsTextFrame('Path:turn.start'),
        EdgeWsBinaryFrame(_binaryFrame('Content-Type:audio/mpeg\r\nPath:audio', [1, 2, 3])),
        EdgeWsBinaryFrame(_binaryFrame('Content-Type:audio/mpeg\r\nPath:audio', [4, 5])),
        const EdgeWsTextFrame('Path:turn.end'),
      ]);
      final bytes = await EdgeTtsClient.synthesize(
        text: '你好',
        voice: 'zh-CN-XiaoxiaoNeural',
        rate: 1.0,
        connect: (_) async => connection,
      );
      expect(bytes, [1, 2, 3, 4, 5]);
      // 协议要求先 speech.config 再 ssml，两帧都要发出
      expect(connection.sent.map((f) => _framePath(f)).toList(), [
        'speech.config',
        'ssml',
      ]);
    });

    test('头长超出帧体的畸形帧被跳过，不吞掉后续音频', () async {
      final connection = _FakeConnection([
        // 声明头长 10，但帧体被截断到只剩 2 字节：畸形帧必须跳过而非抛越界
        EdgeWsBinaryFrame(_binaryFrame('Path:audio', [9]).sublist(0, 4)),
        EdgeWsBinaryFrame(_binaryFrame('Path:audio', [7, 8])),
        const EdgeWsTextFrame('Path:turn.end'),
      ]);
      final bytes = await EdgeTtsClient.synthesize(
        text: '你好',
        voice: 'zh-CN-XiaoxiaoNeural',
        rate: 1.0,
        connect: (_) async => connection,
      );
      expect(bytes, [7, 8]);
    });

    test('非 audio 头的二进制帧不计入音频', () async {
      final connection = _FakeConnection([
        EdgeWsBinaryFrame(_binaryFrame('Path:audio.metadata', [1, 1, 1])),
        const EdgeWsTextFrame('Path:turn.end'),
      ]);
      expect(
        EdgeTtsClient.synthesize(
          text: '你好',
          voice: 'zh-CN-XiaoxiaoNeural',
          rate: 1.0,
          connect: (_) async => connection,
        ),
        throwsA(
          isA<TtsException>().having((e) => e.code, 'code', 'empty_audio'),
        ),
      );
    });
  });
}

/// 假连接：按脚本回放帧并记录发出的协议帧
class _FakeConnection implements EdgeWsConnection {
  final List<EdgeWsFrame> script;
  final List<String> sent = [];

  _FakeConnection(this.script);

  @override
  Stream<EdgeWsFrame> get frames => Stream.fromIterable(script);

  @override
  void sendText(String data) => sent.add(data);

  @override
  Future<void> close() async {}
}

/// 构造 Edge 二进制帧：2 字节大端头长 + 文本头 + 音频负载
List<int> _binaryFrame(String header, List<int> payload) {
  final head = utf8.encode(header);
  return [(head.length >> 8) & 0xFF, head.length & 0xFF, ...head, ...payload];
}

/// 从发出的协议帧里取 Path 头，用于断言发送顺序
String _framePath(String frame) =>
    RegExp(r'Path:(\S+)').firstMatch(frame)?.group(1) ?? '';

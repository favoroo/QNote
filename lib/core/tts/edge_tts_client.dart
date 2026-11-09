import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'edge_tts_drm.dart';
import 'edge_ws.dart';

/// Edge TTS（微软朗读接口）协议客户端。
///
/// 免费无需密钥；协议为非官方 WebSocket：握手后发送 speech.config 与 SSML
/// 两帧文本，接收二进制帧（2 字节大端头长 + 文本头 + mp3 负载），直到
/// `Path:turn.end` 文本帧结束。SSML 转义对齐上游 edge-tts（rany2），访问令牌
/// 由 [EdgeTtsDrm] 生成（v2 摘要算法，版本标签 `2-`，旧令牌已被服务端 403）。
class EdgeTtsClient {
  EdgeTtsClient._();

  static const String _wssUrl =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';
  /// 帧间空闲超时。分段朗读后单段只有一两百字，45 秒只会把失败感知拖得更久，
  /// 让用户在前一段播完前都等不到降级/报错，故收短到 15 秒。
  static const Duration _synthesisTimeout = Duration(seconds: 15);

  /// 合成一段文本为 mp3 字节（24kHz 48kbit 单声道）。
  ///
  /// [rate] 为语速倍率（1.0 正常）。握手/超时/空音频统一抛 [TtsException]。
  /// [connect] 仅供测试注入假连接，生产走平台真实的 [connectEdgeWs]。
  static Future<Uint8List> synthesize({
    required String text,
    required String voice,
    required double rate,
    @visibleForTesting Future<EdgeWsConnection> Function(Uri uri)? connect,
  }) async {
    final connectionId = _randomHex(16);
    final uri = Uri.parse(
      '$_wssUrl?TrustedClientToken=${EdgeTtsDrm.trustedClientToken}'
      '&ConnectionId=$connectionId'
      '&Sec-MS-GEC=${EdgeTtsDrm.generateSecMsGec()}'
      '&Sec-MS-GEC-Version=${EdgeTtsDrm.secMsGecVersion}',
    );

    final connection = await (connect ?? connectEdgeWs)(uri);
    final audio = BytesBuilder();
    var finished = false;
    try {
      final timestamp = _protocolTimestamp(DateTime.now().toUtc());
      connection.sendText(
        'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
      );
      connection.sendText(
        'X-RequestId:${_randomHex(16)}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:$timestamp\r\n'
        'Path:ssml\r\n\r\n'
        '${buildSsml(text: text, voice: voice, rate: rate)}',
      );

      // 帧间空闲超时：服务端只发了 turn.start 就挂住时，不能把按钮永久留在"生成中"
      await for (final frame in connection.frames.timeout(
        _synthesisTimeout,
        onTimeout: (sink) => sink.addError(
          const TtsException('synthesis_timeout', '语音合成超时中断'),
        ),
      )) {
        switch (frame) {
          case EdgeWsTextFrame(:final text):
            // turn.end 表示本轮音频全部到齐
            if (text.contains('Path:turn.end')) {
              finished = true;
            }
          case EdgeWsBinaryFrame(:final bytes):
            if (bytes.length < 2) continue;
            final headerLength = (bytes[0] << 8) | bytes[1];
            // 头长超出帧体（帧被截断或畸形）时跳过，避免 sublist 越界抛错
            if (headerLength > bytes.length - 2) continue;
            final header = utf8.decode(
              bytes.sublist(2, 2 + headerLength),
              allowMalformed: true,
            );
            if (_isAudioFrameHeader(header)) {
              audio.add(bytes.sublist(2 + headerLength));
            }
        }
        if (finished) break;
      }
    } finally {
      unawaited(connection.close());
    }

    if (!finished) {
      throw const TtsException('synthesis_timeout', '语音合成超时中断');
    }
    final result = audio.toBytes();
    if (result.isEmpty) {
      throw const TtsException('empty_audio', '在线语音合成返回了空音频');
    }
    return result;
  }

  /// 二进制帧头是否为音频帧。
  ///
  /// 必须整行等于 `Path:audio`：`Path:audio.metadata` 的负载是 JSON，
  /// 用包含匹配会把元数据拼进 mp3 流。
  static bool _isAudioFrameHeader(String header) =>
      header.split('\r\n').any((line) => line == 'Path:audio');

  /// 构造 SSML 请求体。[rate] 倍率换算为 Azure prosody 的百分比偏移。
  static String buildSsml({
    required String text,
    required String voice,
    required double rate,
  }) {
    final percent = _ratePercent(rate);
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll("'", '&apos;')
        .replaceAll('"', '&quot;');
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='zh-CN'><voice name='$voice'>"
        "<prosody rate='$percent' pitch='+0Hz' volume='+0%'>"
        '$escaped</prosody></voice></speak>';
  }

  /// 倍率 → SSML 百分比偏移（1.0 → '+0%'，1.2 → '+20%'，0.8 → '-20%'）
  static String _ratePercent(double multiplier) {
    final delta = ((multiplier - 1.0) * 100).round();
    if (delta == 0) return '+0%';
    return delta > 0 ? '+$delta%' : '$delta%';
  }

  /// 协议帧时间戳（毫秒精度 UTC，如 2026-09-19T04:23:04.123Z）
  static String _protocolTimestamp(DateTime utcNow) =>
      '${utcNow.toIso8601String().substring(0, 23)}Z';

  static String _randomHex(int bytesLength) {
    final random = Random.secure();
    return List.generate(
      bytesLength,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// 握手用的 Edge 风格 UA（版本号与 Sec-MS-GEC 令牌声明保持一致）
  static String get chromeUserAgent => EdgeTtsDrm.edgeUserAgent;
}

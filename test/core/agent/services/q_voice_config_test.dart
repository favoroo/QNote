import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';

void main() {
  group('QVoiceSettings.decode', () {
    test('空数据回退默认值', () {
      for (final raw in <String?>[null, '', 'not-json', '[1,2]']) {
        final settings = QVoiceSettings.decode(raw);
        expect(settings.autoRead, QVoiceSettings.defaults.autoRead);
        expect(settings.voice, QVoiceSettings.defaults.voice);
        expect(settings.rate, QVoiceSettings.defaults.rate);
      }
    });

    test('合法 JSON 正常解析', () {
      final settings = QVoiceSettings.decode(
        jsonEncode({'autoRead': true, 'voice': 'zh-CN-YunxiNeural', 'rate': 1.2}),
      );
      expect(settings.autoRead, isTrue);
      expect(settings.voice, 'zh-CN-YunxiNeural');
      expect(settings.rate, 1.2);
    });

    test('非法字段逐项回退默认值', () {
      final settings = QVoiceSettings.decode(
        jsonEncode({'autoRead': 'yes', 'voice': '', 'rate': -1}),
      );
      expect(settings.autoRead, isFalse);
      expect(settings.voice, QVoiceSettings.defaults.voice);
      expect(settings.rate, QVoiceSettings.defaults.rate);
    });

    test('encode/decode 往返一致', () {
      const settings = QVoiceSettings(
        autoRead: true,
        voice: 'zh-CN-YunjianNeural',
        rate: 0.8,
      );
      final decoded = QVoiceSettings.decode(jsonEncode(settings.encode()));
      expect(decoded.autoRead, settings.autoRead);
      expect(decoded.voice, settings.voice);
      expect(decoded.rate, settings.rate);
    });

    test('copyWith 局部覆盖', () {
      const base = QVoiceSettings(autoRead: false, voice: 'a', rate: 1.0);
      final updated = base.copyWith(autoRead: true);
      expect(updated.autoRead, isTrue);
      expect(updated.voice, 'a');
      expect(updated.rate, 1.0);
    });
  });
}

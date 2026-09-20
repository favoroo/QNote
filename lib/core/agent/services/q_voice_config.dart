import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/tts/tts_service.dart';

/// 语音回复配置项
class QVoiceSettings {
  /// 自动朗读：小Q最终回复完成后自动用语音读出（仅当前会话可见时）
  final bool autoRead;

  /// Edge 音色 ID
  final String voice;

  /// 语速倍率（0.8 慢 / 1.0 正常 / 1.2 快）
  final double rate;

  const QVoiceSettings({
    required this.autoRead,
    required this.voice,
    required this.rate,
  });

  /// 默认值：自动朗读关闭（避免打扰），晓晓音色、正常语速
  static const QVoiceSettings defaults = QVoiceSettings(
    autoRead: false,
    voice: TtsService.defaultVoice,
    rate: 1.0,
  );

  /// 从 app_configs 原始 JSON 解析，脏数据/缺字段逐项回退默认值
  factory QVoiceSettings.decode(String? raw) {
    if (raw == null || raw.isEmpty) return QVoiceSettings.defaults;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return QVoiceSettings.defaults;
      return QVoiceSettings(
        autoRead: map['autoRead'] == true,
        voice: map['voice'] is String && (map['voice'] as String).isNotEmpty
            ? map['voice'] as String
            : QVoiceSettings.defaults.voice,
        rate: map['rate'] is num && ((map['rate'] as num) > 0)
            ? (map['rate'] as num).toDouble()
            : QVoiceSettings.defaults.rate,
      );
    } catch (_) {
      return QVoiceSettings.defaults;
    }
  }

  Map<String, dynamic> encode() => {
    'autoRead': autoRead,
    'voice': voice,
    'rate': rate,
  };

  QVoiceSettings copyWith({bool? autoRead, String? voice, double? rate}) =>
      QVoiceSettings(
        autoRead: autoRead ?? this.autoRead,
        voice: voice ?? this.voice,
        rate: rate ?? this.rate,
      );
}

/// 小Q语音回复配置（storageKey `'q_voice'`，随 app_configs 走 WebDAV 同步）
///
/// 设置页与朗读运行时共用同一份状态，仿 AgentToolConfig 的单例 + 内存缓存模式。
class QVoiceConfig {
  static final QVoiceConfig instance = QVoiceConfig._();
  QVoiceConfig._();

  static const String storageKey = 'q_voice';

  /// 音色哨兵值：设备系统自带语音（离线可用，无网络依赖）
  static const String systemVoiceId = 'system';

  /// 语速可选档位（档位值 → 展示名）。double 不具备 const 基元相等性，用 final
  static final Map<double, String> rateOptions = {
    0.8: '慢速',
    1.0: '正常',
    1.2: '快速',
  };

  QVoiceSettings? _cached;

  /// 自动朗读开关的实时视图。
  ///
  /// 语音设置页的 Switch 与小Q对话界面右上角的图标按钮都监听它，
  /// 任一处改动后其它视图同步刷新；真源仍是本类（内存缓存 + app_configs），
  /// 这里只做广播，冷启动首次 [get] 完成前保持默认值。
  final ValueNotifier<bool> autoReadState =
      ValueNotifier<bool>(QVoiceSettings.defaults.autoRead);

  /// 读取配置（未加载时从存储拉取）
  Future<QVoiceSettings> get() async {
    if (_cached != null) return _cached!;
    final raw = await ConfigRepository.instance.getAppConfig(storageKey);
    final settings = QVoiceSettings.decode(raw);
    autoReadState.value = settings.autoRead;
    return _cached = settings;
  }

  /// 自动朗读是否开启（运行时高频查询，走缓存）
  Future<bool> isAutoReadEnabled() async => (await get()).autoRead;

  /// 翻转自动朗读开关，返回翻转后的值（供界面上的开关按钮直接调用）
  Future<bool> toggleAutoRead() async {
    final next = !(await get()).autoRead;
    await setAutoRead(next);
    return next;
  }

  Future<void> setAutoRead(bool enabled) async =>
      _save((await get()).copyWith(autoRead: enabled));

  Future<void> setVoice(String voiceId) async =>
      _save((await get()).copyWith(voice: voiceId));

  Future<void> setRate(double rate) async =>
      _save((await get()).copyWith(rate: rate));

  /// 先落库再更新内存与广播：写失败时界面停留在原状态，不会出现
  /// 「图标显示已开启、重启后却是关闭」的假象
  Future<void> _save(QVoiceSettings settings) async {
    await ConfigRepository.instance.setAppConfig(
      storageKey,
      jsonEncode(settings.encode()),
    );
    _cached = settings;
    autoReadState.value = settings.autoRead;
  }
}

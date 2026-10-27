import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 对话模型的「图片输入（识图）」能力判定
///
/// 为什么需要它：网关对**不支持**图片的模型并不总会报错，有的会 HTTP 200 地
/// 编造内容（历史实测：看不见画面的模型仍会回答「图里是什么」）。因此需要在
/// **发请求前**按能力判定是否要把图片交给当前模型：判定为不支持时，调用方
/// （日记图片提取、view_image 工具）应提示用户切换到支持识图的模型，而不是
/// 让模型对着看不见的画面编造。
///
/// 判定是**纯内存查表**：不发探测请求、不占配额，每轮对话查多少次都是零成本。
/// 结论来自两处：① 用户在设置页手动「识图检测」后按模型名持久化的结论
/// （[recordProbeResult]）；② 模型名里的视觉关键词启发式。
/// 两者都没命中时按**不支持**处理——漏判只多一次提问/换模型，误判则让模型对着
/// 看不见的画面编造内容，代价差得远。
class ModelVisionCapability {
  ModelVisionCapability._();

  /// 自定义模型名里的视觉线索（OpenAI 兼容生态的常见命名，子串匹配）
  ///
  /// 刻意不含 `image`：`gpt-image-1`、`dall-e` 这类**生图**模型名里就带 image
  /// 语义，它们不接受图片输入，命中只会把请求导向一次必然失败的调用。
  static const List<String> _visionNameHints = [
    '-vl',
    'vl-',
    'vision',
    'omni',
    '4o',
    'gemini',
    'claude',
    'kimi',
    'qvq',
  ];

  // 手动检测结果的持久化键（值为 {modelName: bool} 的 JSON）
  static const String _prefsKey = 'model_vision_probe';

  /// 持久化结论的内存镜像；null 表示还没从磁盘读出（按空表处理，不影响判定正确性）
  static Map<String, bool>? _probed;

  /// 启动预热（`preInitializeApp` 调用）
  ///
  /// 之所以要预热而不是每次 `await SharedPreferences`：[supportsVision] 在 AgentLoop
  /// 每轮推理里都会被调用，必须保持同步签名。
  static Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _probed = _decodePrefs(prefs.getString(_prefsKey));
  }

  /// 记录一次「识图检测」的结论并按模型名持久化
  static Future<void> recordProbeResult(String modelName, bool capable) async {
    final name = modelName.trim().toLowerCase();
    if (name.isEmpty) return;
    final next = Map<String, bool>.of(_probed ?? const <String, bool>{})..[name] = capable;
    _probed = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(next));
  }

  /// 该模型是否被手动检测过（null = 未检测），供设置页徽标回显而不再重复发探测请求
  static bool? probedResult(String modelName) {
    final name = modelName.trim().toLowerCase();
    if (name.isEmpty) return null;
    return _probed?[name];
  }

  /// 设置页徽标用的「已知结论」：只有用户实测过才有值
  ///
  /// 刻意**不**把 [supportsVision] 的关键词启发式算进来：那是用来决定要不要
  /// 拦截或绕道的兜底猜测，拿它显示「支持识别」这种断言会把猜测说成事实。
  static bool? probeConclusion(String modelName) {
    final name = modelName.trim().toLowerCase();
    if (name.isEmpty) return null;
    return _probed?[name];
  }

  /// 判定配置对应的模型能否接收图片输入
  static bool supportsVision(AiConfig config) {
    final modelName = config.modelName.trim().toLowerCase();
    if (modelName.isEmpty) return false;
    final probed = _probed?[modelName];
    if (probed != null) return probed;
    return _visionNameHints.any(modelName.contains);
  }

  /// 磁盘里的缓存被写坏时退回空表，而不是让启动抛异常
  static Map<String, bool>? _decodePrefs(String? raw) {
    final text = raw ?? '';
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = <String, bool>{};
      for (final entry in decoded.entries) {
        if (entry.key is String && entry.value is bool) {
          map[(entry.key as String).toLowerCase()] = entry.value as bool;
        }
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  /// 清空内存镜像与磁盘缓存（仅测试用）
  @visibleForTesting
  static Future<void> resetForTest({bool keepDisk = false}) async {
    _probed = null;
    if (keepDisk) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
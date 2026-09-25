import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 对话模型的「图片输入（识图）」能力判定
///
/// 为什么需要它：网关对**不支持**图片的模型并不会报错。2026-09-25 用一张左红右蓝的
/// 64×64 PNG 直连商汤网关实测（`reasoning_effort: none`，其余参数与 App 发信一致）：
/// `sensenova-6.8-flash-lite` 与 `deepseek-flash` 答「左=红色，右=蓝色」，而内置头牌
/// `glm-5.2` 同样 HTTP 200、却答「左=黑色，右=白色」——它在看不见画面的情况下编造。
/// 因此 `AgentLoop` 里「抛异常才剥图」的降级（`agent_loop.dart` 的事后兜底）永远不会触发，
/// 必须在**发请求前**按能力剥离图片，并把识图需求转交给 [BuiltinFreeKeys.createVisionConfig]
/// 这条视觉链路（`describe_image` 工具与日记图片提取兜底）。
///
/// 判定是**纯内存查表**：不发探测请求、不占配额，每轮对话查多少次都是零成本。
/// 结论按优先级来自三处：① [kVisionCapableModelNames] 内置实测表；② 用户在设置页手动
/// 「识图检测」后按模型名持久化的结论（[recordProbeResult]）；③ 模型名里的视觉关键词。
/// 三者都没命中时按**不支持**处理——漏判只多一次工具调用，误判则让模型对着看不见的画面
/// 编造内容，代价差得远。
class ModelVisionCapability {
  ModelVisionCapability._();

  /// 已实测确认支持图片输入的模型名（口径是发给网关的 `modelName`，不是配置 id）
  static const Set<String> kVisionCapableModelNames = {
    BuiltinFreeKeys.visionModelName,
    'deepseek-flash',
  };

  /// 已实测确认**不支持**图片输入的内置模型名
  ///
  /// 与 [kVisionCapableModelNames] 一样排在探测缓存之前：内置模型的正面与反面结论都是
  /// 本仓实测过的，不该被设备上「识图检测」的一次误点或偶发误判翻转 —— 反向被翻转的代价
  /// 最重，等于放开那条会编造画面的链路（glm-5.2 收图返回 200 并瞎答颜色）。
  static const Set<String> kVisionIncapableModelNames = {'glm-5.2'};

  /// 自定义模型名里的视觉线索（OpenAI 兼容生态的常见命名，子串匹配）
  ///
  /// 刻意不含 `image`：网关上 `sensenova-u1*` 这类**生图**模型名里就带 image 语义，
  /// 它们不接受图片输入，命中只会把请求导向一次必然失败的调用。
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

  /// 设置页徽标用的「已知结论」：内置实测表命中或用户检测过才有值
  ///
  /// 刻意**不**把 [supportsVision] 的关键词启发式算进来：那是用来决定要不要绕道识图工具的
  /// 兜底猜测，拿它显示「支持识别」这种断言会把猜测说成事实。
  static bool? probeConclusion(String modelName) {
    final name = modelName.trim().toLowerCase();
    if (name.isEmpty) return null;
    if (kVisionCapableModelNames.contains(name)) return true;
    if (kVisionIncapableModelNames.contains(name)) return false;
    return _probed?[name];
  }

  /// 判定配置对应的模型能否接收图片输入
  static bool supportsVision(AiConfig config) {
    final modelName = config.modelName.trim().toLowerCase();
    if (modelName.isEmpty) return false;
    if (kVisionCapableModelNames.contains(modelName)) return true;
    if (kVisionIncapableModelNames.contains(modelName)) return false;
    final probed = _probed?[modelName];
    if (probed != null) return probed;
    return _visionNameHints.any(modelName.contains);
  }

  /// 本次要发图、而绑定模型看不见时，改用内置视觉链路；其余情况原样返回
  ///
  /// 返回的配置走 `FreeModelService.toAiConfig`，因此同样带内置 Key 池轮换。
  static AiConfig withVisionFallback(
    AiConfig roleConfig, {
    required bool sendingImage,
  }) {
    if (!sendingImage || supportsVision(roleConfig)) return roleConfig;
    return FreeModelService.instance.toAiConfig(
      BuiltinFreeKeys.createVisionConfig(),
    );
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

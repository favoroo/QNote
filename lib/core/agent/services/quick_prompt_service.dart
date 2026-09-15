import 'dart:convert';

import 'package:qnote_flutter/core/storage/config_repository.dart';

/// 常用提示词存储服务
///
/// 持久化于 app_configs（键 [storageKey]），存储 JSON 字符串数组。
/// 首次读取时自动写入默认提示词，之后用户可自由编辑/删除默认项。
class QuickPromptService {
  static final QuickPromptService instance = QuickPromptService._();
  QuickPromptService._();

  static const String storageKey = 'agent_quick_prompts';

  /// 默认提示词，仅首次初始化时写入
  static const List<String> _defaultPrompts = [
    '总结我今天的行为，给出评价',
    '总结一下我本周的行为，看有什么改进的',
  ];

  /// 内存缓存（null 表示未加载），云同步导入后调用 [refresh] 失效
  List<String>? _cached;

  /// 读取全部提示词；首次为空时写入默认值并返回
  Future<List<String>> getPrompts() async {
    if (_cached != null) return List.unmodifiable(_cached!);
    final raw = await ConfigRepository.instance.getAppConfig(storageKey);
    if (raw == null || raw.isEmpty) {
      // 首次初始化：写入默认值
      final defaults = List<String>.from(_defaultPrompts);
      await ConfigRepository.instance.setAppConfig(
        storageKey,
        jsonEncode(defaults),
      );
      return _cached = defaults;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final prompts = decoded
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList();
        return _cached = prompts;
      }
    } catch (_) {}
    // 解析失败回退默认值
    return _cached = List<String>.from(_defaultPrompts);
  }

  /// 整体覆盖保存
  Future<void> setPrompts(List<String> prompts) async {
    _cached = List<String>.from(prompts);
    await ConfigRepository.instance.setAppConfig(
      storageKey,
      jsonEncode(prompts),
    );
  }

  /// 追加一条
  Future<void> addPrompt(String text) async {
    final prompts = await getPrompts();
    prompts.add(text);
    await setPrompts(prompts);
  }

  /// 替换指定索引
  Future<void> updatePrompt(int index, String text) async {
    final prompts = await getPrompts();
    if (index < 0 || index >= prompts.length) return;
    prompts[index] = text;
    await setPrompts(prompts);
  }

  /// 删除指定索引
  Future<void> deletePrompt(int index) async {
    final prompts = await getPrompts();
    if (index < 0 || index >= prompts.length) return;
    prompts.removeAt(index);
    await setPrompts(prompts);
  }

  /// 清除内存缓存（云同步导入后刷新用）
  Future<void> refresh() async {
    _cached = null;
    await getPrompts();
  }
}

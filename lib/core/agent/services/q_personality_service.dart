import 'dart:convert';

import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';

/// 小Q个性配置服务：读写当前激活个性与自定义人格文本
///
/// 对齐 Hermes 的 SOUL.md 语义：个性在每次对话开始时读取一次并注入系统提示词，
/// 本轮中途的修改不回填当前上下文，下轮对话生效。
/// 配置持久化于 app_configs（键 [storageKey]），VFS `/settings/personality.json`
/// 的读写最终也落到这里，保证 UI 设置页与小Q自我调整共用同一份状态。
///
/// 这里**故意不做内存缓存**：每轮对话只读一次单行 `app_configs`，成本可忽略，
/// 而缓存会带来真实的错读——WebDAV 增量同步与备份恢复是直接写库的
/// （见 export_service 的 app_configs 分支），改完不重启就会继续用旧人格，
/// 表现成「性格设置了不生效」。直读把这一类陈旧问题一次性消除。
class QPersonalityService {
  static final QPersonalityService instance = QPersonalityService._();
  QPersonalityService._();

  static const String storageKey = 'agent_personality';

  /// 尾部复述用的语气摘要最多截到多少字（自定义人格文本可能很长）
  static const int _digestMaxLength = 80;

  /// 读取当前激活的个性（custom 时拼接用户自编文本作为 prompt）
  Future<QPersonality> getActivePersonality() async => _resolve(await _loadConfig());

  /// 一次读盘取回设置页需要的全部状态：选中项、自定义原文、实际生效个性。
  ///
  /// 合并成单次读取有两个理由：一是页面不再需要「读两次、两次结果可能不同版」的拼接，
  /// 回退判定（选 custom 却生效 default）在同一次快照里比较即可成立；
  /// 二是减少串行异步往返——在 testWidgets 的 FakeAsync 区块下，
  /// 每一次额外的真实 I/O 跳数都可能让加载卡在骨架态。
  Future<QPersonalitySnapshot> readSnapshot() async {
    final config = await _loadConfig();
    final activeId = (config['activeId'] as String?)?.trim();
    return QPersonalitySnapshot(
      selectedId: (activeId == null || activeId.isEmpty)
          ? QPersonalities.defaultId
          : activeId,
      customPrompt: (config['customPrompt'] as String?) ?? '',
      effective: _resolve(config),
    );
  }

  /// 由配置映射解析实际生效个性（含 custom 空文本 → 经典管家的回退）
  static QPersonality _resolve(Map<String, dynamic> config) {
    final id = (config['activeId'] as String?)?.trim();
    final preset = QPersonalities.byId(id ?? '');
    if (preset.id != QPersonalities.customId) {
      return preset;
    }
    final customText = (config['customPrompt'] as String?)?.trim() ?? '';
    // 自定义为空时回退经典管家，避免拼出无人格的提示词（设置页会显式提示这一回退）
    if (customText.isEmpty) {
      return QPersonalities.byId(QPersonalities.defaultId);
    }
    return QPersonality(
      id: preset.id,
      name: preset.name,
      description: preset.description,
      prompt: customText,
      digest: digestOf(customText),
    );
  }

  /// 从人格文本提炼单行语气摘要（取首个整句，到第一个句末标点，过长再截断）
  ///
  /// 摘要会被复述到系统提示词尾部；设置页也用它预览「自定义人格实际会以哪一句钉在结尾」。
  static String digestOf(String customText) {
    final oneLine = customText.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 中文句末标点直接断句；英文句点要求后接空白或结尾，避免把 "e.g." 之类截断
    final match = RegExp(r'^.{2,}?(?:[。！？；]|\.(?:\s|$))').firstMatch(oneLine);
    final sentence = (match?.group(0) ?? oneLine).trim();
    return sentence.length <= _digestMaxLength
        ? sentence
        : '${sentence.substring(0, _digestMaxLength)}…';
  }

  /// 读取当前激活个性 id（设置页选中态用）
  Future<String> getActiveId() async {
    final config = await _loadConfig();
    return (config['activeId'] as String?) ?? QPersonalities.defaultId;
  }

  /// 切换激活个性（未知 id 拒绝写入）
  Future<void> setActiveId(String id) async {
    final known = QPersonalities.presets.any((p) => p.id == id);
    if (!known) {
      throw Exception('未知的个性标识: $id');
    }
    final config = await _loadConfig();
    config['activeId'] = id;
    await _saveConfig(config);
  }

  /// 读取自定义人格文本
  Future<String> getCustomPrompt() async {
    final config = await _loadConfig();
    return (config['customPrompt'] as String?) ?? '';
  }

  /// 保存自定义人格文本
  Future<void> setCustomPrompt(String text) async {
    final config = await _loadConfig();
    config['customPrompt'] = text;
    await _saveConfig(config);
  }

  /// 从配置映射增量更新（VFS `/settings/personality.json` 写入通道）：
  /// 只接受合法的 activeId 与字符串 customPrompt，其余字段忽略
  Future<void> applyPartialConfig(Map<String, dynamic> partial) async {
    final config = await _loadConfig();
    if (partial.containsKey('activeId')) {
      final id = partial['activeId']?.toString().trim() ?? '';
      if (QPersonalities.presets.any((p) => p.id == id)) {
        config['activeId'] = id;
      }
    }
    if (partial.containsKey('customPrompt')) {
      config['customPrompt'] = partial['customPrompt']?.toString() ?? '';
    }
    await _saveConfig(config);
  }

  Future<Map<String, dynamic>> _loadConfig() async {
    final raw = await ConfigRepository.instance.getAppConfig(storageKey);
    if (raw == null || raw.isEmpty) {
      return {
        'activeId': QPersonalities.defaultId,
        'customPrompt': '',
      };
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return {
      'activeId': QPersonalities.defaultId,
      'customPrompt': '',
    };
  }

  Future<void> _saveConfig(Map<String, dynamic> config) async {
    await ConfigRepository.instance.setAppConfig(
      storageKey,
      jsonEncode(config),
    );
  }
}

/// 个性配置的一次性快照（[QPersonalityService.readSnapshot] 产物）
///
/// [selectedId] 为用户在设置页/VFS 里选的标识，[effective] 为运行时真正注入系统提示词的那个个性
/// （custom 但文本为空、或标识未知时会回退成经典管家）；两者不一致即发生了静默降级，
/// 设置页据此给出可见提示。
class QPersonalitySnapshot {
  const QPersonalitySnapshot({
    required this.selectedId,
    required this.customPrompt,
    required this.effective,
  });

  final String selectedId;
  final String customPrompt;
  final QPersonality effective;

  /// 是否发生了「选了自定义却因描述为空而回退」的降级
  bool get degradedToFallback =>
      selectedId == QPersonalities.customId &&
      effective.id != QPersonalities.customId;
}

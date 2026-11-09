import 'dart:convert';

import 'package:qnote_flutter/models/ai_model_ref.dart';

/// 路由组的成员分配策略
///
/// [id] 是落库字符串（`ai_route_groups.strategy`），刻意与枚举名解耦：
/// 以后增删策略或改名都不会让旧数据解析失败（[fromId] 落到 [rotate]）。
enum RouteStrategy {
  /// 每次请求按顺序轮流使用成员
  rotate('rotate', '轮流', '每个请求换下一个成员，分散限流'),

  /// 始终优先第一个可用成员，失败才切下一个
  failover('failover', '顺序', '优先用第一个成员，它失败时自动切下一个'),

  /// 按成员权重比例分配请求
  weight('weight', '权重', '按权重比例分配请求（如 3:1）'),

  /// 按近期成功率与耗时自动挑最稳最快的成员
  smart('smart', '智能', '自动选当前最稳最快的成员'),

  /// 固定使用手动选中的成员
  manual('manual', '手动', '固定用手动选中的成员，可在组卡片切换');

  const RouteStrategy(this.id, this.label, this.description);

  /// 持久化标识
  final String id;

  /// 界面上的短标签
  final String label;

  /// 一句话行为说明（选项下方展示）
  final String description;

  static RouteStrategy fromId(String? raw) {
    for (final strategy in values) {
      if (strategy.id == raw) return strategy;
    }
    // 未知/缺失一律按「轮流」处理：旧数据与手改配置都能安全打开
    return RouteStrategy.rotate;
  }

  /// 除手动固定外，其余策略在只剩一个成员时轮换/权重/评分都失去意义
  bool get needsMultipleMembers => this != RouteStrategy.manual;
}

/// 路由组里的一个成员：某个厂商条目下的某个已启用模型
class RouteGroupMember {
  final String providerId;
  final String modelName;

  /// 权重策略下的份额（1~9），非权重策略下保留但不参与计算
  final int weight;

  /// 组内临时停用：保留位置与配置，但不参与选路
  final bool enabled;

  const RouteGroupMember({
    required this.providerId,
    required this.modelName,
    this.weight = 1,
    this.enabled = true,
  });

  /// 权重允许范围：太小看不出差别，太大让权重 UI 与轮次都变得难懂
  static const int minWeight = 1;
  static const int maxWeight = 9;

  /// 成员引用（`providerId::modelName`），与角色绑定/展示名共用同一编码
  AiModelRef get ref =>
      AiModelRef(providerId: providerId, modelName: modelName);

  String encode() => ref.encode();

  RouteGroupMember copyWith({int? weight, bool? enabled}) {
    return RouteGroupMember(
      providerId: providerId,
      modelName: modelName,
      weight: (weight ?? this.weight).clamp(minWeight, maxWeight),
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toMap() => {
        'providerId': providerId,
        'modelName': modelName,
        'weight': weight,
        'enabled': enabled,
      };

  factory RouteGroupMember.fromMap(Map<String, dynamic> map) {
    return RouteGroupMember(
      providerId: (map['providerId'] ?? '').toString(),
      modelName: (map['modelName'] ?? '').toString(),
      weight: ((map['weight'] as num?)?.toInt() ?? minWeight)
          .clamp(minWeight, maxWeight),
      enabled: map['enabled'] as bool? ?? true,
    );
  }

  static List<RouteGroupMember> listFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <RouteGroupMember>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final member = RouteGroupMember.fromMap(Map<String, dynamic>.from(item));
        if (member.providerId.isEmpty || member.modelName.isEmpty) continue;
        // 同一模型在一个组里只能有一份，否则轮询会被它重复占用槽位
        if (!seen.add(member.encode())) continue;
        result.add(member);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<RouteGroupMember> members) =>
      jsonEncode(members.map((m) => m.toMap()).toList());

  @override
  bool operator ==(Object other) =>
      other is RouteGroupMember &&
      other.providerId == providerId &&
      other.modelName == modelName &&
      other.weight == weight &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(providerId, modelName, weight, enabled);

  @override
  String toString() => 'RouteGroupMember($providerId::$modelName w=$weight)';
}

/// 模型路由组：把多个已启用模型（可跨厂商）组合成一个「虚拟模型」供角色绑定
///
/// 角色绑定里它编码成 [AiModelRef.routeGroup]（`<groupId>::__route_group__`），
/// 因此选择器、展示名、角色配置与同步都不需要新格式；解析时由
/// `AiRouteService` 按 [strategy] 选出一个真实成员再组装请求配置。
class AiRouteGroup {
  final String id;
  final String name;
  final RouteStrategy strategy;

  /// 成员（顺序即 failover 优先级，也是权重轮询的槽位顺序）
  final List<RouteGroupMember> members;

  /// 手动策略下固定的成员（`providerId::modelName`）；失效时回落首个可用成员
  final String? pinnedMember;

  /// 本次请求带图片时，是否优先选支持识图的成员
  final bool preferVision;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AiRouteGroup({
    required this.id,
    required this.name,
    this.strategy = RouteStrategy.rotate,
    this.members = const [],
    this.pinnedMember,
    this.preferVision = true,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 参与选路的成员（组内启用）
  List<RouteGroupMember> get enabledMembers =>
      members.where((m) => m.enabled).toList();

  bool hasMember(String providerId, String modelName) => members
      .any((m) => m.providerId == providerId && m.modelName == modelName);

  AiRouteGroup copyWith({
    String? id,
    String? name,
    RouteStrategy? strategy,
    List<RouteGroupMember>? members,
    Object? pinnedMember = _unset,
    bool? preferVision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AiRouteGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      strategy: strategy ?? this.strategy,
      members: members ?? this.members,
      pinnedMember: identical(pinnedMember, _unset)
          ? this.pinnedMember
          : pinnedMember as String?,
      preferVision: preferVision ?? this.preferVision,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const Object _unset = Object();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'strategy': strategy.id,
      'members': RouteGroupMember.listToJson(members),
      'pinned_member': pinnedMember,
      'prefer_vision': preferVision ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AiRouteGroup.fromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString();
    return AiRouteGroup(
      id: id,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? (map['name'] as String).trim()
          : '未命名路由组',
      strategy: RouteStrategy.fromId(map['strategy'] as String?),
      members: RouteGroupMember.listFromJson(map['members'] as String?),
      pinnedMember: (map['pinned_member'] as String?)?.trim().isEmpty == true
          ? null
          : map['pinned_member'] as String?,
      preferVision: (map['prefer_vision'] as int? ?? 1) == 1,
      createdAt: _parseTime(map['created_at'] as String?) ?? DateTime.now(),
      updatedAt: _parseTime(map['updated_at'] as String?) ?? DateTime.now(),
    );
  }

  static DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  @override
  String toString() => 'AiRouteGroup($id, $name, ${strategy.id}, '
      '${members.length} members)';
}

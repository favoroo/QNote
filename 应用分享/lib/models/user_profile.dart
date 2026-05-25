import 'dart:convert';
import 'package:qnote_flutter/models/weight_record.dart';

class UserProfile {
  final String id;
  String? name;
  String? nickname;
  String? birthday;
  double? height;
  List<WeightRecord> weightHistory;
  String? gender;
  String? otherInfo;
  String avatarPath;
  DateTime createdAt;
  DateTime updatedAt;

  UserProfile({
    required this.id,
    this.name,
    this.nickname,
    this.birthday,
    this.height,
    this.weightHistory = const [],
    this.gender,
    this.otherInfo,
    this.avatarPath = '',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'nickname': nickname,
      'birthday': birthday,
      'height': height,
      'weight_history': jsonEncode(weightHistory.map((w) => w.toMap()).toList()),
      'gender': gender,
      'other_info': otherInfo,
      'avatar_path': avatarPath,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      id: map['id'] as String,
      name: map['name'] as String?,
      nickname: map['nickname'] as String?,
      birthday: map['birthday'] as String?,
      height: (map['height'] as num?)?.toDouble(),
      weightHistory: map['weight_history'] != null
          ? (jsonDecode(map['weight_history'] as String) as List)
              .map((w) => WeightRecord.fromMap(w as Map<String, dynamic>))
              .toList()
          : [],
      gender: map['gender'] as String?,
      otherInfo: map['other_info'] as String?,
      avatarPath: map['avatar_path'] as String? ?? '',
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  UserProfile copyWith({
    String? id,
    String? name,
    String? nickname,
    String? birthday,
    double? height,
    List<WeightRecord>? weightHistory,
    String? gender,
    String? otherInfo,
    String? avatarPath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      nickname: nickname ?? this.nickname,
      birthday: birthday ?? this.birthday,
      height: height ?? this.height,
      weightHistory: weightHistory ?? this.weightHistory,
      gender: gender ?? this.gender,
      otherInfo: otherInfo ?? this.otherInfo,
      avatarPath: avatarPath ?? this.avatarPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

import 'dart:convert';
import 'package:qnote_flutter/core/storage/database_helper.dart';

class SyncLogEntry {
  final int? id;
  final String tableName;
  final String recordId;
  final String operation;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  SyncLogEntry({
    this.id,
    required this.tableName,
    required this.recordId,
    required this.operation,
    this.data,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'table_name': tableName,
      'record_id': recordId,
      'operation': operation,
      'data': data != null ? jsonEncode(data) : null,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory SyncLogEntry.fromMap(Map<String, dynamic> map) {
    return SyncLogEntry(
      id: map['id'] as int?,
      tableName: map['table_name'] as String,
      recordId: map['record_id'] as String,
      operation: map['operation'] as String,
      data: map['data'] != null
          ? jsonDecode(map['data'] as String) as Map<String, dynamic>
          : null,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }
}

class SyncLogRepository {
  static final SyncLogRepository instance = SyncLogRepository._();
  SyncLogRepository._();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<void> logChange({
    required String tableName,
    required String recordId,
    required String operation,
    Map<String, dynamic>? data,
  }) async {
    final db = await _dbHelper.database;
    await db.insert('sync_log', {
      'table_name': tableName,
      'record_id': recordId,
      'operation': operation,
      'data': data != null ? jsonEncode(data) : null,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> logChanges(List<SyncLogEntry> entries) async {
    if (entries.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final entry in entries) {
      batch.insert('sync_log', entry.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<List<SyncLogEntry>> getAllChanges() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'sync_log',
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => SyncLogEntry.fromMap(m)).toList();
  }

  Future<List<SyncLogEntry>> getChangesSince(DateTime since) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'sync_log',
      where: 'timestamp > ?',
      whereArgs: [since.toIso8601String()],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => SyncLogEntry.fromMap(m)).toList();
  }

  Future<int> getChangeCount() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM sync_log');
    if (result.isEmpty) return 0;
    return (result.first['count'] as int?) ?? 0;
  }

  Future<void> clearAll() async {
    final db = await _dbHelper.database;
    await db.delete('sync_log');
  }

  Future<void> clearChangesBefore(DateTime before) async {
    final db = await _dbHelper.database;
    await db.delete(
      'sync_log',
      where: 'timestamp <= ?',
      whereArgs: [before.toIso8601String()],
    );
  }

  Future<Map<String, dynamic>> buildDeltaJson() async {
    final changes = await getAllChanges();
    if (changes.isEmpty) {
      return {'delta_version': 1, 'changes': {}, 'image_changes': {'added': [], 'deleted': []}};
    }

    final delta = <String, dynamic>{
      'delta_version': 1,
      'delta_time': DateTime.now().toIso8601String(),
      'changes': <String, dynamic>{},
      'image_changes': <String, dynamic>{
        'added': <String>[],
        'deleted': <String>[],
      },
    };

    final grouped = <String, List<SyncLogEntry>>{};
    for (final entry in changes) {
      grouped.putIfAbsent(entry.tableName, () => []).add(entry);
    }

    final imageTables = {'diary_records', 'notes'};

    for (final tableName in grouped.keys) {
      final entries = grouped[tableName]!;

      if (tableName == 'user_profile') {
        final latestUpsert = entries.lastWhere(
          (e) => e.operation == 'upsert',
          orElse: () => entries.last,
        );
        if (latestUpsert.data != null) {
          (delta['changes'] as Map)[tableName] = {
            'upserts': [latestUpsert.data],
          };
        }
        continue;
      }

      if (tableName == 'app_configs') {
        final upserts = <Map<String, dynamic>>[];
        final deletes = <String>[];
        final seenKeys = <String>{};
        for (final entry in entries.reversed) {
          if (seenKeys.contains(entry.recordId)) continue;
          seenKeys.add(entry.recordId);
          if (entry.operation == 'delete') {
            deletes.add(entry.recordId);
          } else if (entry.data != null) {
            upserts.add(entry.data!);
          }
        }
        (delta['changes'] as Map)[tableName] = {
          'upserts': upserts.reversed.toList(),
          'deletes': deletes.reversed.toList(),
        };
        continue;
      }

      final upserts = <Map<String, dynamic>>[];
      final deletes = <String>[];
      final seenIds = <String>{};

      for (final entry in entries.reversed) {
        if (seenIds.contains(entry.recordId)) continue;
        seenIds.add(entry.recordId);

        if (entry.operation == 'delete') {
          deletes.add(entry.recordId);
          if (imageTables.contains(tableName)) {
            _extractImageChanges(entry, delta['image_changes'] as Map<String, dynamic>, isDelete: true);
          }
        } else {
          if (entry.data != null) {
            upserts.add(entry.data!);
            if (imageTables.contains(tableName)) {
              _extractImageChanges(entry, delta['image_changes'] as Map<String, dynamic>, isDelete: false);
            }
          }
        }
      }

      (delta['changes'] as Map)[tableName] = {
        'upserts': upserts.reversed.toList(),
        'deletes': deletes.reversed.toList(),
      };
    }

    return delta;
  }

  void _extractImageChanges(SyncLogEntry entry, Map<String, dynamic> imageChanges, {required bool isDelete}) {
    if (entry.data == null) return;
    final data = entry.data!;
    final tableName = entry.tableName;

    if (tableName == 'diary_records') {
      final photosStr = data['photos'] as String?;
      if (photosStr != null && photosStr.isNotEmpty) {
        try {
          final photos = jsonDecode(photosStr) as List;
          for (final photo in photos) {
            final photoStr = photo.toString();
            if (photoStr.isNotEmpty) {
              final imageName = 'diary_${entry.recordId}_${photoStr.hashCode.abs()}.dat';
              if (isDelete) {
                (imageChanges['deleted'] as List).add(imageName);
              } else {
                (imageChanges['added'] as List).add(imageName);
              }
            }
          }
        } catch (_) {}
      }
    } else if (tableName == 'notes') {
      final imagesStr = data['images'] as String?;
      if (imagesStr != null && imagesStr.isNotEmpty) {
        try {
          final images = jsonDecode(imagesStr) as List;
          for (final image in images) {
            final imageStr = image.toString();
            if (imageStr.isNotEmpty) {
              final imageName = 'note_${entry.recordId}_${imageStr.hashCode.abs()}.dat';
              if (isDelete) {
                (imageChanges['deleted'] as List).add(imageName);
              } else {
                (imageChanges['added'] as List).add(imageName);
              }
            }
          }
        } catch (_) {}
      }
    }
  }
}

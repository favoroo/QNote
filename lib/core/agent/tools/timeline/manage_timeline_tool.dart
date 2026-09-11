import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/fixed_event_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:uuid/uuid.dart';

/// 时间线流水事件与固定事件综合管理工具
class ManageTimelineTool extends AgentTool {
  final DiaryRepository _diaryRepo = DiaryRepository();
  final FixedEventRepository _fixedEventRepo = FixedEventRepository.instance;

  @override
  String get name => 'manage_timeline';

  @override
  String get description =>
      '时间线事件与固定模板管理：添加流水事件 (add_record)、修改事件 (update_record)、删除事件 (delete_record)、按日期查询事件 (get_records)、添加/更新固定事件模板 (manage_template)。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'add_record',
              'update_record',
              'delete_record',
              'get_records',
              'manage_template'
            ],
            'description': '时间线操作类型',
          },
          'id': {
            'type': 'string',
            'description': '记录 ID 或模板 ID（更新/删除时使用）',
          },
          'date': {
            'type': 'string',
            'description': '查询或记录的目标日期，形如 "2026-09-11"',
          },
          'time': {
            'type': 'string',
            'description': '具体事件发生时间，ISO8601 格式或 "2026-09-11 14:30"',
          },
          'title': {
            'type': 'string',
            'description': '事件简要标题（选填，默认根据内容生成）',
          },
          'content': {
            'type': 'string',
            'description': '事件正文内容',
          },
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '关联的分类标签列表，如 ["饮食", "运动", "工作"]',
          },
          'template_name': {
            'type': 'string',
            'description': '固定事件模板名称（如"晨起喝水"、"午休"）',
          },
          'template_time': {
            'type': 'string',
            'description': '固定事件模板预设时间（如"08:00"）',
          },
        },
        'required': ['action'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final action = arguments['action'] as String;

    switch (action) {
      case 'add_record':
        return await _addRecord(arguments);
      case 'update_record':
        return await _updateRecord(arguments);
      case 'delete_record':
        return await _deleteRecord(arguments);
      case 'get_records':
        return await _getRecords(arguments);
      case 'manage_template':
        return await _manageTemplate(arguments);
      default:
        return ToolResult.error('未知 action: $action');
    }
  }

  Future<ToolResult> _addRecord(Map<String, dynamic> args) async {
    final content = args['content'] as String? ?? '';
    if (content.trim().isEmpty) return ToolResult.error('记录 content 不能为空');

    DateTime recordTime = DateTime.now();
    if (args['time'] != null) {
      final parsed = DateTime.tryParse(args['time'].toString());
      if (parsed != null) recordTime = parsed;
    } else if (args['date'] != null) {
      final parsedDate = DateTime.tryParse(args['date'].toString());
      if (parsedDate != null) {
        recordTime = DateTime(
          parsedDate.year,
          parsedDate.month,
          parsedDate.day,
          recordTime.hour,
          recordTime.minute,
        );
      }
    }

    final tags = (args['tags'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final title = args['title'] as String? ?? (content.length > 20 ? '${content.substring(0, 20)}...' : content);

    final record = DiaryRecord(
      id: const Uuid().v4(),
      title: title,
      time: recordTime,
      content: content,
      tags: tags,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final saved = await _diaryRepo.insert(record);
    return ToolResult.success(
      '已成功在时间线添加一条记录：\n- 时间: ${saved.time.toIso8601String().substring(0, 16)}\n- 内容: ${saved.content}\n- 标签: ${saved.tags.join(", ")} (ID: ${saved.id})',
      uiDetails: {
        'type': 'timeline_record_added',
        'record': saved.toMap(),
      },
    );
  }

  Future<ToolResult> _updateRecord(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('更新事件必须提供 id');

    final existing = await _diaryRepo.getById(id);
    if (existing == null) return ToolResult.error('未找到时间线记录: $id');

    DateTime? updatedTime = existing.time;
    if (args['time'] != null) {
      final parsed = DateTime.tryParse(args['time'].toString());
      if (parsed != null) updatedTime = parsed;
    }

    List<String> updatedTags = existing.tags;
    if (args['tags'] != null && args['tags'] is List) {
      updatedTags = (args['tags'] as List).map((e) => e.toString()).toList();
    }

    final updated = existing.copyWith(
      title: args['title'] as String? ?? existing.title,
      content: args['content'] as String? ?? existing.content,
      time: updatedTime,
      tags: updatedTags,
      updatedAt: DateTime.now(),
    );

    final saved = await _diaryRepo.update(updated);
    return ToolResult.success(
      '已更新时间线记录 (ID: ${saved.id})',
      uiDetails: {
        'type': 'timeline_record_updated',
        'record': saved.toMap(),
      },
    );
  }

  Future<ToolResult> _deleteRecord(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('删除事件必须提供 id');

    final existing = await _diaryRepo.getById(id);
    if (existing == null) return ToolResult.error('记录不存在: $id');

    await _diaryRepo.softDelete(id);
    return ToolResult.success(
      '已从时间线删除记录 (ID: $id)',
      uiDetails: {
        'type': 'timeline_record_deleted',
        'id': id,
      },
    );
  }

  Future<ToolResult> _getRecords(Map<String, dynamic> args) async {
    DateTime targetDate = DateTime.now();
    if (args['date'] != null) {
      final parsed = DateTime.tryParse(args['date'].toString());
      if (parsed != null) targetDate = parsed;
    }

    final records = await _diaryRepo.getByDate(targetDate);
    if (records.isEmpty) {
      return ToolResult.success(
        '日期 ${targetDate.toIso8601String().substring(0, 10)} 没有时间线记录。',
      );
    }

    final sb = StringBuffer();
    sb.writeln('时间线记录 (${targetDate.toIso8601String().substring(0, 10)}, 共 ${records.length} 条):');
    for (final r in records) {
      final timeStr = r.time.toIso8601String().substring(11, 16);
      final tagsStr = r.tags.isNotEmpty ? ' [${r.tags.join(",")}]' : '';
      sb.writeln('- $timeStr$tagsStr: ${r.content} (ID: ${r.id})');
    }

    return ToolResult.success(
      truncateOutput(sb.toString()),
      uiDetails: {
        'type': 'timeline_records_list',
        'date': targetDate.toIso8601String().substring(0, 10),
        'count': records.length,
        'records': records.map((e) => e.toMap()).toList(),
      },
    );
  }

  Future<ToolResult> _manageTemplate(Map<String, dynamic> args) async {
    final name = args['template_name'] as String? ?? '';
    if (name.isEmpty) return ToolResult.error('固定模板名称不能为空');

    final time = args['template_time'] as String? ?? '08:00';
    final template = FixedEventTemplate(
      id: const Uuid().v4(),
      name: name,
      startTime: time,
      endTime: '',
      isTimePoint: true,
      isEnabled: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _fixedEventRepo.insert(template);
    return ToolResult.success(
      '已成功创建固定事件模板：[$name]，预设时间: $time (ID: ${template.id})',
      uiDetails: {
        'type': 'fixed_template_created',
        'template': template.toMap(),
      },
    );
  }
}

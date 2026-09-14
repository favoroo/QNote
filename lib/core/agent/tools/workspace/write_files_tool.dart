import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 批量写入工具：一次调用写入多个文件
///
/// 与 [WriteFileTool] 共用 VFS 写入链路，区别只在于「一次多条」：跨域联动场景
/// （把笔记里的行动项提取成待办、一次性记多条流水）逐条调用 write_file 会迅速吃满
/// 单轮步数上限，批量入口把这些条目收敛到一次调用里。
class WriteFilesTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  /// 单次批量写入的条目数上限，防止一次调用灌爆上下文与执行时长
  static const int maxBatchSize = 20;

  /// 与 write_file 对齐的写入模式
  static const String modeOverwrite = 'overwrite';
  static const String modeAppend = 'append';

  @override
  String get name => 'write_files';

  @override
  String get description =>
      '一次调用写入多个文件的批量版本。适用于「把笔记/日记里的行动项提取成多条待办」'
      '「一次记好几条时间线流水」这类多条目场景，比逐条 write_file 省掉大量轮次。'
      '逐条串行执行，单条失败不影响其余条目，返回值会列出每条的成功/失败明细。'
      '单次最多 $maxBatchSize 条；条目极少（1~2 条）时直接用 write_file 即可。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'files': {
            'type': 'array',
            'description': '要写入的文件列表，逐条串行执行',
            'items': {
              'type': 'object',
              'properties': {
                'path': {
                  'type': 'string',
                  'description': '虚拟文件绝对路径（以 "/" 开头）',
                },
                'content': {
                  'type': 'string',
                  'description': '写入内容，格式规范与 write_file 完全一致',
                },
                'mode': {
                  'type': 'string',
                  'enum': [modeOverwrite, modeAppend],
                  'description': '写入模式：overwrite 覆写（默认）；append 追加到末尾',
                },
              },
              'required': ['path', 'content'],
            },
          },
        },
        'required': ['files'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final rawFiles = arguments['files'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      return ToolResult.error('files 不能为空，请提供要写入的文件列表');
    }
    if (rawFiles.length > maxBatchSize) {
      return ToolResult.error('单次批量写入最多 $maxBatchSize 条，当前 ${rawFiles.length} 条，请拆分调用');
    }

    final results = <Map<String, dynamic>>[];
    final buffer = StringBuffer();
    int succeeded = 0;

    for (final raw in rawFiles) {
      if (raw is! Map) {
        results.add({'ok': false, 'error': '条目格式不合法（应为对象）'});
        continue;
      }
      final path = (raw['path'] as String? ?? '').trim();
      final content = raw['content'] as String? ?? '';
      final mode = (raw['mode'] as String? ?? modeOverwrite).trim();
      if (path.isEmpty) {
        results.add({'ok': false, 'error': '路径为空'});
        buffer.writeln('- ✗ (路径为空)：已跳过');
        continue;
      }

      onProgress?.call('正在批量写入：$path');
      try {
        final res = await _vfs.writeFile(
          path,
          content,
          append: mode == modeAppend,
        );
        succeeded++;
        results.add({
          'ok': true,
          'path': path,
          'status': res['status'] ?? 'saved',
          'title': res['title'] ?? path,
          'reminder_time': res['reminder_time'],
        });
        // 逐条回显提醒时间，便于模型自检待办是否真的写入了通知
        final reminder = res['reminder_time'];
        buffer.writeln(
          '- ✓ $path（${res['status'] ?? 'saved'}）'
          '${reminder == null ? '' : ' 提醒时间: $reminder'}',
        );
      } catch (e) {
        results.add({'ok': false, 'path': path, 'error': e.toString()});
        buffer.writeln('- ✗ $path：$e');
      }
    }

    final failed = results.length - succeeded;
    final summary = StringBuffer()
      ..writeln('批量写入完成：成功 $succeeded 条，失败 $failed 条。')
      ..writeln(buffer.toString().trimRight());
    if (failed > 0) {
      summary.writeln('失败条目请修正后重试；不要声称已写入未成功的条目。');
    }

    final details = {
      'type': 'write_files',
      'total': results.length,
      'succeeded': succeeded,
      'failed': failed,
      'files': results,
    };

    // 全部失败按错误上报，部分成功按成功上报（明细里带失败原因，避免掩盖已生效的写入）
    return succeeded == 0
        ? ToolResult(
            modelOutput: summary.toString(),
            uiDetails: details,
            isError: true,
          )
        : ToolResult.success(summary.toString(), uiDetails: details);
  }
}

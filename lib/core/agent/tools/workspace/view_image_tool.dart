import 'package:flutter/foundation.dart';

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';

/// 查看图片工具：把本地图片加载为多模态输入注入本轮 Agent 上下文
///
/// 时间线/日记/笔记中的图片在 VFS 里只是文本路径，模型本身"看不见"画面；
/// 本工具读取图片文件并压缩为 data URI，由 AgentLoop 以合成 user 消息的方式
/// 附加给多模态模型，从而让小Q具备"看图"能力。
class ViewImageTool extends AgentTool {
  final ImageRepository _imageRepo = ImageRepository();

  @override
  String get name => 'view_image';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '查看（读取）本地图片文件的内容。当时间线/日记记录的「- 图片:」字段、笔记中的图片链接，'
      '或用户消息里出现本地图片路径（如 "/data/.../images/xxx.jpg" 或 "/images/xxx.jpg"）时，'
      '调用本工具即可加载图片并"看到"画面内容（需当前模型支持图片输入）。'
      '路径必须来自数据中真实存在的图片字段，不要自行构造路径。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '图片文件路径（时间线/日记/笔记中列出的完整路径，或以 /images/ 开头的相对路径）',
          },
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = arguments['path'] as String? ?? '';
    if (path.trim().isEmpty) {
      return ToolResult.error('图片路径为空，请提供时间线/日记/笔记中列出的图片路径');
    }

    // ImageRepository 依赖 dart:io 本地文件系统，Web 端无法读取本地图片
    if (kIsWeb) {
      return ToolResult.error('当前运行在 Web 平台，暂不支持读取本地图片');
    }

    try {
      final exists = await _imageRepo.imageExists(path);
      if (!exists) {
        return ToolResult.error(
          '图片文件不存在: $path。请确认路径来自时间线/日记的图片字段或笔记中的图片链接，不要自行构造路径',
        );
      }

      final base64 = await _imageRepo.getCompressedBase64Image(path);
      if (base64.isEmpty) {
        return ToolResult.error('图片读取失败: $path（文件可能已被移动或删除）');
      }

      // 压缩后统一为 JPEG 编码，data URI 由 AgentLoop 注入本轮模型上下文
      final dataUri = 'data:image/jpeg;base64,$base64';
      final sizeKB = (base64.length * 3 / 4 / 1024).round();
      return ToolResult.success(
        '已成功加载图片: $path（约 $sizeKB KB）。图片已附加到本轮对话中，请直接基于图片画面内容进行分析与回答。',
        images: [dataUri],
        uiDetails: {
          'path': path,
          'sizeKB': sizeKB,
        },
      );
    } catch (e) {
      return ToolResult.error('读取图片失败: $e（当前模型或平台可能不支持图片输入）');
    }
  }
}

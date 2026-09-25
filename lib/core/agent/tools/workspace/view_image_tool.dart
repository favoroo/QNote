import 'package:flutter/foundation.dart';

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';

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
      '查看（读取）本地图片文件的内容。仅当时间线/日记记录的「- 图片:」字段或笔记中的图片链接'
      '出现真实存在的本地图片路径（如 "/images/xxx.jpg"）时调用，用于加载并"看到"画面内容'
      '（需当前模型支持图片输入；不支持时请改用 describe_image 获取文字版识别结果）。'
      '注意：用户在消息中直接附带/发送的图片已随消息注入上下文，你已能直接看到画面，'
      '严禁再调用本工具读取，也不要为其虚构路径。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                '图片文件路径（须来自时间线/日记/笔记等数据中真实记录的路径，或以 /images/ 开头的相对路径；不可用于对话附件图片）',
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

    // 当前模型看不了图时，压一张 base64 注入上下文只会喂给一个读不懂它的请求
    // （实测网关对不支持图片的模型照常返回 200，模型于是凭空编画面），
    // 因此在这里就改指 describe_image，别让它拿到一份可被编造的素材
    final boundConfig = await _assistantConfig();
    if (boundConfig != null && !ModelVisionCapability.supportsVision(boundConfig)) {
      return ToolResult.error(
        '当前对话模型不支持图片输入，view_image 加载了也看不到画面。'
        '请改用识图工具：describe_image(path: "$path", question: "写下你要问的具体问题")，'
        '它会把图片交给内置识图模型并返回文字结果。',
      );
    }

    // ImageRepository 依赖 dart:io 本地文件系统，Web 端无法读取本地图片
    if (kIsWeb) {
      return ToolResult.error('当前运行在 Web 平台，暂不支持读取本地图片');
    }

    try {
      final exists = await _imageRepo.imageExists(path);
      if (!exists) {
        return ToolResult.error(
          '图片文件不存在: $path。请确认路径来自时间线/日记的图片字段或笔记中的图片链接，不要自行构造路径；'
          '若用户消息中已附带图片，该图片已直接可见，请基于其画面内容回答，无需调用本工具',
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

  /// 读当前小Q绑定的生效配置，用于判断能不能看图；读不到时返回 null（按原流程继续）
  ///
  /// 刻意不因配置读取失败就拒绝执行：那是比"模型看不了图"更罕见的故障，
  /// 拦掉一次正常的看图反而更糟。
  Future<AiConfig?> _assistantConfig() async {
    try {
      return await AiRoleService.instance.getEffectiveConfigForRole('assistant');
    } catch (_) {
      return null;
    }
  }
}

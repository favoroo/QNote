import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:uuid/uuid.dart';

/// 系统设置、个人信息、WebDAV同步、快捷按钮综合管理工具
class ManageSettingsTool extends AgentTool {
  final ConfigRepository _configRepo = ConfigRepository.instance;

  @override
  String get name => 'manage_settings';

  @override
  String get description =>
      '修改 App 设置：包括个人资料设置 (profile)、WebDAV 云同步设置 (webdav)、快捷记录按钮 (shortcut) 等。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'target': {
            'type': 'string',
            'enum': ['profile', 'webdav', 'shortcut'],
            'description': '要配置的设置模块',
          },
          'action': {
            'type': 'string',
            'enum': ['get', 'update', 'add_shortcut', 'delete_shortcut'],
            'description': '操作类型',
          },
          // 个人资料相关字段
          'nickname': {'type': 'string', 'description': '用户昵称'},
          'name': {'type': 'string', 'description': '用户真实姓名'},
          'gender': {'type': 'string', 'description': '性别（男/女/其他）'},
          'birthday': {'type': 'string', 'description': '出生年月日，如 1995-05-20'},
          'height': {'type': 'number', 'description': '身高 (cm)'},
          'weight': {'type': 'number', 'description': '最新体重 (kg)'},
          'other_info': {'type': 'string', 'description': '个人其他特征或背景偏好'},
          // WebDAV 相关字段
          'webdav_url': {'type': 'string', 'description': 'WebDAV 服务器地址'},
          'webdav_username': {'type': 'string', 'description': 'WebDAV 账号'},
          'webdav_password': {'type': 'string', 'description': 'WebDAV 密码'},
          'webdav_auto_sync': {'type': 'boolean', 'description': '是否开启自动同步'},
          // 快捷按钮相关字段
          'shortcut_id': {'type': 'string', 'description': '快捷按钮 ID'},
          'shortcut_name': {'type': 'string', 'description': '快捷记录按钮名称'},
        },
        'required': ['target', 'action'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final target = arguments['target'] as String;
    final action = arguments['action'] as String;

    if (target == 'profile') {
      return await _handleProfile(action, arguments);
    } else if (target == 'webdav') {
      return await _handleWebdav(action, arguments);
    } else if (target == 'shortcut') {
      return await _handleShortcut(action, arguments);
    }

    return ToolResult.error('未知设置目标: $target');
  }

  Future<ToolResult> _handleProfile(String action, Map<String, dynamic> args) async {
    final current = await _configRepo.getUserProfile() ??
        UserProfile(
          id: const Uuid().v4(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    if (action == 'get') {
      return ToolResult.success(
        '当前个人资料：\n'
        '- 昵称: ${current.nickname ?? "未填写"}\n'
        '- 姓名: ${current.name ?? "未填写"}\n'
        '- 性别: ${current.gender ?? "未填写"}\n'
        '- 生日: ${current.birthday ?? "未填写"}\n'
        '- 身高: ${current.height != null ? "${current.height} cm" : "未填写"}\n'
        '- 其他信息: ${current.otherInfo ?? "无"}',
        uiDetails: {'type': 'profile_info', 'profile': current.toMap()},
      );
    }

    final updated = current.copyWith(
      nickname: args['nickname'] as String? ?? current.nickname,
      name: args['name'] as String? ?? current.name,
      gender: args['gender'] as String? ?? current.gender,
      birthday: args['birthday'] as String? ?? current.birthday,
      height: (args['height'] as num?)?.toDouble() ?? current.height,
      otherInfo: args['other_info'] as String? ?? current.otherInfo,
      updatedAt: DateTime.now(),
    );

    await _configRepo.upsertUserProfile(updated);
    return ToolResult.success(
      '已成功更新个人资料信息。',
      uiDetails: {'type': 'profile_updated', 'profile': updated.toMap()},
    );
  }

  Future<ToolResult> _handleWebdav(String action, Map<String, dynamic> args) async {
    final current = await _configRepo.getWebdavConfig() ??
        WebdavConfig(
          id: const Uuid().v4(),
          serverUrl: '',
          username: '',
          password: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    if (action == 'get') {
      return ToolResult.success(
        '当前 WebDAV 配置：\n'
        '- URL: ${current.serverUrl.isNotEmpty ? current.serverUrl : "未配置"}\n'
        '- 用户名: ${current.username.isNotEmpty ? current.username : "未配置"}\n'
        '- 密码: ${current.password.isNotEmpty ? "******" : "未配置"}\n'
        '- 自动同步: ${current.autoSync ? "开启" : "关闭"}',
        uiDetails: {'type': 'webdav_info', 'config': current.toMap()},
      );
    }

    final updated = current.copyWith(
      serverUrl: args['webdav_url'] as String? ?? current.serverUrl,
      username: args['webdav_username'] as String? ?? current.username,
      password: args['webdav_password'] as String? ?? current.password,
      autoSync: args['webdav_auto_sync'] as bool? ?? current.autoSync,
      updatedAt: DateTime.now(),
    );

    await _configRepo.upsertWebdavConfig(updated);
    return ToolResult.success(
      '已成功更新 WebDAV 同步配置。',
      uiDetails: {'type': 'webdav_updated', 'config': updated.toMap()},
    );
  }

  Future<ToolResult> _handleShortcut(String action, Map<String, dynamic> args) async {
    if (action == 'get') {
      final shortcuts = await _configRepo.getAllShortcutConfigs();
      final sb = StringBuffer();
      sb.writeln('快捷记录按钮列表 (共 ${shortcuts.length} 个):');
      for (final s in shortcuts) {
        sb.writeln('- [按钮] ${s.name} (ID: ${s.id})');
      }
      return ToolResult.success(sb.toString());
    }

    if (action == 'add_shortcut') {
      final name = args['shortcut_name'] as String? ?? '快捷记录';

      final shortcut = ShortcutConfig(
        id: const Uuid().v4(),
        name: name,
        sortOrder: 100,
        fields: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await _configRepo.insertShortcutConfig(shortcut);
      return ToolResult.success(
        '已成功新增快捷记录按钮：[$name] (ID: ${shortcut.id})',
        uiDetails: {'type': 'shortcut_added', 'shortcut': shortcut.toMap()},
      );
    }

    if (action == 'delete_shortcut') {
      final id = args['shortcut_id'] as String? ?? '';
      if (id.isEmpty) return ToolResult.error('删除快捷按钮必须提供 shortcut_id');
      await _configRepo.deleteShortcutConfig(id);
      return ToolResult.success('已删除快捷按钮 ID: $id');
    }

    return ToolResult.error('未知 shortcut action: $action');
  }
}

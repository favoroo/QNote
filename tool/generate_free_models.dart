// 生成 free_models.json 远程配置文件
//
// 用法：
//   dart run tool/generate_free_models.dart
//
// 生成后会将 free_models.json 输出到项目根目录，
// 用户需要手动推送到 GitHub 仓库 https://github.com/favoroo/QNote 的 main 分支根目录。

import 'dart:convert';
import 'dart:io';

import 'package:qnote_flutter/core/utils/obfuscation_utils.dart';

void main() {
  // 免费模型配置（apikey 为明文，生成后会自动混淆）
  final models = <Map<String, dynamic>>[
    {
      'id': 'sensenova-flash-lite',
      'displayName': 'SenseNova Flash Lite',
      'provider': 'openai',
      'baseUrl': 'https://token.sensenova.cn/v1',
      'modelName': 'sensenova-6.7-flash-lite',
      'apiKey': 'sk-5DxsypDwruQsrdKmNfgYlUg9rsbzNuxj',
      'authType': 'bearer',
      'priority': 0,
    },
    {
      'id': 'agnes-flash',
      'displayName': 'Agnes Flash',
      'provider': 'openai',
      'baseUrl': 'https://apihub.agnes-ai.com/v1',
      'modelName': 'agnes-2.0-flash',
      'apiKey': 'sk-ywtKENdgygWK82Rx5ZPI6QLp5hJZ5EIdXgSL4SJ1fu4OAcJG',
      'authType': 'bearer',
      'priority': 1,
    },
    {
      'id': 'gemini-flash-lite',
      'displayName': 'Gemini Flash Lite',
      'provider': 'gemini',
      'baseUrl': '',
      'modelName': 'gemini-3.1-flash-lite',
      'apiKey': 'AIzaSyCeA18RmAb0hoKeJVeh7SB99oIkpG0hJeg',
      'authType': 'query',
      'priority': 2,
    },
    {
      'id': 'gemma',
      'displayName': 'Gemma',
      'provider': 'gemini',
      'baseUrl': '',
      'modelName': 'gemma-4-31b-it',
      'apiKey': 'AIzaSyCeA18RmAb0hoKeJVeh7SB99oIkpG0hJeg',
      'authType': 'query',
      'priority': 3,
    },
  ];

  // 混淆 apikey
  final obfuscatedModels = models.map((m) {
    final plainKey = m['apiKey'] as String;
    final obfuscated = ObfuscationUtils.obfuscate(plainKey);
    // 创建新 map，避免修改原 map
    final result = Map<String, dynamic>.from(m)..remove('apiKey');
    result['obfuscatedApiKey'] = obfuscated;
    return result;
  }).toList();

  final manifest = {
    'version': '1.0',
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'models': obfuscatedModels,
  };

  const encoder = JsonEncoder.withIndent('  ');
  final jsonStr = encoder.convert(manifest);

  final outputFile = File('free_models.json');
  outputFile.writeAsStringSync(jsonStr);

  print('已生成 ${outputFile.path}');
  print('');
  print('请将此文件推送到 GitHub 仓库 https://github.com/favoroo/QNote 的 main 分支根目录。');
  print('');
  print('推送命令示例：');
  print('  git add free_models.json');
  print('  git commit -m "chore: update free models config"');
  print('  git push origin main');
  print('');
  print('注意：free_models.json 包含混淆后的 apikey，请勿提交到项目代码仓库。');
  print('建议在 .gitignore 中添加 free_models.json（如果此文件在项目仓库中生成）。');

  // 验证：解混淆后应与原文一致
  print('');
  print('=== 验证混淆/解混淆 ===');
  for (final m in models) {
    final plain = m['apiKey'] as String;
    final obfuscated = ObfuscationUtils.obfuscate(plain);
    final deobfuscated = ObfuscationUtils.deobfuscate(obfuscated);
    final ok = plain == deobfuscated;
    print('${m['id']}: ${ok ? "✓" : "✗"} (原文长度=${plain.length}, 混淆后长度=${obfuscated.length})');
  }
}

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/skills/skill_market_service.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/skill_market_tool.dart';

void main() {
  group('SkillMarketTool 元信息与参数校验', () {
    test('工具声明为串行执行（安装会写用户技能库）', () {
      final tool = SkillMarketTool(service: _FakeMarketService());
      expect(tool.name, 'skill_market');
      expect(tool.executionMode, ToolExecutionMode.sequential);
      expect(tool.parametersSchema['properties'], contains('search'));
      expect(tool.parametersSchema['properties'], contains('install'));
    });

    test('search 与 install 不能同时传', () async {
      final result = await SkillMarketTool(
        service: _FakeMarketService(),
      ).execute({'search': 'pdf', 'install': 'anthropics/skills/pdf'});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('不能同时使用'));
    });

    test('两者都不传时给出用法提示', () async {
      final result = await SkillMarketTool(service: _FakeMarketService()).execute({});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('search'));
      expect(result.modelOutput, contains('install'));
    });

    test('as / overwrite 不能脱离 install 使用', () async {
      final tool = SkillMarketTool(service: _FakeMarketService());
      final byAlias = await tool.execute({'search': 'pdf', 'as': 'my-pdf'});
      expect(byAlias.isError, isTrue);

      final byOverwrite = await tool.execute({'search': 'pdf', 'overwrite': true});
      expect(byOverwrite.isError, isTrue);
    });

    test('安装标识格式错误时在发请求前拒绝', () async {
      final fake = _FakeMarketService();
      final result = await SkillMarketTool(service: fake).execute({'install': 'pdf'});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('格式不正确'));
      expect(fake.installCalls, 0);
    });
  });

  group('SkillMarketTool 搜索', () {
    test('返回候选清单与结构化 uiDetails', () async {
      final fake = _FakeMarketService()
        ..searchResults = [
          const SkillMarketItem(
            id: 'anthropics/skills/pdf',
            source: 'anthropics/skills',
            skillId: 'pdf',
            name: 'pdf',
            installs: 227573,
          ),
          const SkillMarketItem(
            id: 'openai/skills/pdf',
            source: 'openai/skills',
            skillId: 'pdf',
            name: 'pdf',
            installs: 13778,
          ),
        ];
      final result = await SkillMarketTool(service: fake).execute({'search': 'pdf', 'limit': 5});

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('anthropics/skills/pdf'));
      expect(result.modelOutput, contains('安装量 227573'));
      expect(result.modelOutput, contains('向用户展示候选'));
      expect(result.uiDetails?['action'], 'search');
      expect((result.uiDetails?['results'] as List).length, 2);
      expect(fake.lastQuery, 'pdf');
      expect(fake.lastLimit, 5);
    });

    test('无结果时提示换英文关键词且不编造', () async {
      final fake = _FakeMarketService()..searchResults = [];
      final result = await SkillMarketTool(service: fake).execute({'search': '不存在的技能'});
      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('没有搜到'));
      expect(result.modelOutput, contains('换英文关键词'));
      expect(result.modelOutput, contains('不要编造'));
    });

    test('市场异常转换为工具错误', () async {
      final fake = _FakeMarketService()..error = const SkillMarketException('技能市场暂时不可用');
      final result = await SkillMarketTool(service: fake).execute({'search': 'pdf'});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('技能市场暂时不可用'));
      expect(result.uiDetails?['action'], 'search');
    });
  });

  group('SkillMarketTool 安装', () {
    test('安装成功后返回名称、来源与后续载入提示', () async {
      final fake = _FakeMarketService()
        ..installResult = const SkillInstallResult(
          name: 'pdf',
          path: '/skills/pdf.md',
          source: 'anthropics/skills',
          description: '处理 PDF 文件（来源：skills.sh · anthropics/skills）',
          overwritten: false,
          contentLength: 12345,
        );
      final result = await SkillMarketTool(service: fake).execute({'install': 'anthropics/skills/pdf'});

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('已安装技能「pdf」'));
      expect(result.modelOutput, contains('/skills/pdf.md'));
      expect(result.modelOutput, contains('anthropics/skills'));
      expect(result.modelOutput, contains('skill(name: "pdf")'));
      expect(result.modelOutput, contains('脚本、附件与命令行步骤无法在 App 内执行'));
      expect(result.uiDetails?['action'], 'install');
      expect(fake.lastInstall, 'anthropics/skills/pdf');
    });

    test('as 与 overwrite 透传给服务，并在覆盖时提示', () async {
      final fake = _FakeMarketService()
        ..installResult = const SkillInstallResult(
          name: 'my-pdf',
          path: '/skills/my-pdf.md',
          source: 'anthropics/skills',
          description: '处理 PDF',
          overwritten: true,
          contentLength: 100,
        );
      final result = await SkillMarketTool(
        service: fake,
      ).execute({'install': 'anthropics/skills/pdf', 'as': 'my-pdf', 'overwrite': true});

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('已覆盖原同名技能'));
      expect(fake.lastAs, 'my-pdf');
      expect(fake.lastOverwrite, isTrue);
    });

    test('安装异常转换为工具错误', () async {
      final fake = _FakeMarketService()..error = const SkillMarketException('已存在用户技能「pdf」');
      final result = await SkillMarketTool(service: fake).execute({'install': 'anthropics/skills/pdf'});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('已存在用户技能'));
      expect(result.uiDetails?['action'], 'install');
    });
  });
}

class _FakeMarketService extends SkillMarketService {
  List<SkillMarketItem> searchResults = [];
  SkillInstallResult? installResult;
  SkillMarketException? error;

  String? lastQuery;
  int? lastLimit;
  String? lastInstall;
  String? lastAs;
  bool? lastOverwrite;
  int installCalls = 0;

  @override
  Future<List<SkillMarketItem>> search(String query, {int limit = 10}) async {
    lastQuery = query;
    lastLimit = limit;
    final failure = error;
    if (failure != null) throw failure;
    return searchResults;
  }

  @override
  Future<SkillInstallResult> install({required String id, String? as, bool overwrite = false}) async {
    installCalls++;
    lastInstall = id;
    lastAs = as;
    lastOverwrite = overwrite;
    final failure = error;
    if (failure != null) throw failure;
    return installResult ??
        const SkillInstallResult(
          name: 'skill',
          path: '/skills/skill.md',
          source: 'owner/repo',
          description: '',
          overwritten: false,
          contentLength: 0,
        );
  }
}

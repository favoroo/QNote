import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/raccoon_account_router.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';

/// 订阅账号选号与亲和（纯内存逻辑，不触库、不联网）
void main() {
  // 选号会写 AI 日志，需要绑定初始化，否则日志持久化会打一堆噪音
  TestWidgetsFlutterBinding.ensureInitialized();

  final router = RaccoonAccountRouter.instance;

  AiAccount account(String id, {String providerId = 'p1', bool enabled = true, int sortOrder = 0, String phone = ''}) {
    final now = DateTime(2026, 1, 1);
    return AiAccount(
      id: id,
      providerId: providerId,
      accessToken: 'token-$id',
      phone: phone,
      enabled: enabled,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
  }

  const scope = AiRequestScope(sessionKey: 's1', turnKey: 's1#1');
  const otherScope = AiRequestScope(sessionKey: 's2', turnKey: 's2#1');

  AccountSelection? select(
    List<AiAccount> accounts, {
    AccountRouting routing = AccountRouting.rotate,
    AccountAffinity affinity = AccountAffinity.off,
    AiRequestScope? requestScope,
    Set<String> tried = const {},
    bool advance = true,
  }) {
    return router.select(
      providerId: 'p1',
      accounts: accounts,
      routing: routing,
      affinity: affinity,
      scope: requestScope,
      triedAccountIds: tried,
      advance: advance,
    );
  }

  setUp(() => router.resetForTest());

  test('轮流策略按顺序推进游标', () {
    final accounts = [account('a'), account('b'), account('c')];

    expect(select(accounts)!.account.id, 'a');
    expect(select(accounts)!.account.id, 'b');
    expect(select(accounts)!.account.id, 'c');
    expect(select(accounts)!.account.id, 'a');
  });

  test('顺序策略始终用第一个可用账号，不受游标影响', () {
    final accounts = [account('a'), account('b')];

    expect(select(accounts, routing: AccountRouting.failover)!.account.id, 'a');
    expect(select(accounts, routing: AccountRouting.failover)!.account.id, 'a');
  });

  test('停用的账号不参与选号', () {
    final accounts = [account('a', enabled: false), account('b')];

    expect(select(accounts, routing: AccountRouting.failover)!.account.id, 'b');
  });

  test('会话亲和：同一会话固定，另一个会话按策略轮到下一个', () {
    final accounts = [account('a'), account('b')];

    final first = select(accounts, affinity: AccountAffinity.session, requestScope: scope)!;
    expect(first.account.id, 'a');
    expect(first.keptByAffinity, isFalse);

    // 同一会话再来一次仍用它，且是「亲和命中」而非又抽一次
    final second = select(accounts, affinity: AccountAffinity.session, requestScope: scope)!;
    expect(second.account.id, 'a');
    expect(second.keptByAffinity, isTrue);

    // 新会话轮换到下一个账号
    final another = select(accounts, affinity: AccountAffinity.session, requestScope: otherScope)!;
    expect(another.account.id, 'b');
  });

  test('每轮轮换：同一轮内固定，换一轮就换账号', () {
    final accounts = [account('a'), account('b')];

    final turn1 = select(
      accounts,
      affinity: AccountAffinity.turn,
      requestScope: const AiRequestScope(sessionKey: 's1', turnKey: 's1#1'),
    )!;
    expect(turn1.account.id, 'a');
    // 同一条消息内的第二次发信（工具循环）沿用同一账号
    final turn1Again = select(
      accounts,
      affinity: AccountAffinity.turn,
      requestScope: const AiRequestScope(sessionKey: 's1', turnKey: 's1#1'),
    )!;
    expect(turn1Again.account.id, 'a');
    // 用户再说一条：轮到下一个账号
    final turn2 = select(
      accounts,
      affinity: AccountAffinity.turn,
      requestScope: const AiRequestScope(sessionKey: 's1', turnKey: 's1#2'),
    )!;
    expect(turn2.account.id, 'b');
  });

  test('不亲和：每个请求都按策略重新选', () {
    final accounts = [account('a'), account('b')];

    expect(select(accounts, affinity: AccountAffinity.off, requestScope: scope)!.account.id, 'a');
    expect(select(accounts, affinity: AccountAffinity.off, requestScope: scope)!.account.id, 'b');
  });

  test('账号失败进入冷却后让位给下一个，冷却结束自动回池', () {
    final accounts = [account('a'), account('b')];
    final a = accounts.first;

    router.markFailed(a, Exception('429 rate limit'));
    expect(router.isCooling('a'), isTrue);
    expect(select(accounts, routing: AccountRouting.failover)!.account.id, 'b');

    router.forget('a');
    expect(router.isCooling('a'), isFalse);
    expect(select(accounts, routing: AccountRouting.failover)!.account.id, 'a');
  });

  test('失败会清掉该账号占着的亲和位置（下次不会回到刚失败的账号）', () {
    final accounts = [account('a'), account('b')];
    select(accounts, affinity: AccountAffinity.session, requestScope: scope);

    router.markFailed(accounts.first, Exception('429 rate limit'), affinity: AccountAffinity.session);

    final next = router.select(
      providerId: 'p1',
      accounts: accounts,
      routing: AccountRouting.rotate,
      affinity: AccountAffinity.session,
      scope: scope,
    )!;
    expect(next.account.id, 'b');
    expect(next.keptByAffinity, isFalse);
  });

  test('严格亲和：本次已试过该账号时不再返回它（避免死循环）', () {
    final accounts = [account('a'), account('b')];
    select(accounts, affinity: AccountAffinity.strict, requestScope: scope);

    expect(select(accounts, affinity: AccountAffinity.strict, requestScope: scope, tried: {'a'}), isNull);
  });

  test('严格亲和：即使限流也不换账号', () {
    final accounts = [account('a'), account('b')];
    select(accounts, affinity: AccountAffinity.strict, requestScope: scope);

    router.markFailed(accounts.first, Exception('429 rate limit'), affinity: AccountAffinity.strict);

    final next = select(accounts, affinity: AccountAffinity.strict, requestScope: scope)!;
    expect(next.account.id, 'a');
    expect(next.keptByAffinity, isTrue);
  });

  test('本次已试过的账号会被排除，试完则返回 null', () {
    final accounts = [account('a'), account('b')];

    expect(select(accounts, routing: AccountRouting.failover, tried: {'a'})!.account.id, 'b');
    expect(select(accounts, routing: AccountRouting.failover, tried: {'a', 'b'}), isNull);
  });

  test('单账号：策略与亲和都不影响结果，试过即返回 null', () {
    final single = [account('only')];

    expect(select(single, routing: AccountRouting.failover, requestScope: scope)!.account.id, 'only');
    expect(select(single, tried: {'only'}), isNull);
  });

  test('advance 为 false 时只看当前轮到谁、不推进轮次', () {
    final accounts = [account('a'), account('b')];

    expect(select(accounts, advance: false)!.account.id, 'a');
    expect(select(accounts, advance: false)!.account.id, 'a');
    expect(select(accounts)!.account.id, 'a');
  });

  test('智能策略避开失败过的账号', () {
    final accounts = [account('a'), account('b')];

    router.markSucceeded(accounts[0]);
    router.markSucceeded(accounts[0]);
    router.markSucceeded(accounts[0]);
    router.markFailed(accounts[0], Exception('429 rate limit'));
    // 冷却期内的 a 被跳过；解除冷却后仍按成功率与使用次数评分
    expect(select(accounts, routing: AccountRouting.smart)!.account.id, 'b');

    router.forget('a');
    router.markSucceeded(accounts[1]);
    expect(select(accounts, routing: AccountRouting.smart)!.account.id, 'a');
  });

  test('无启用账号时返回 null', () {
    expect(select([account('a', enabled: false)]), isNull);
    expect(select(const []), isNull);
  });

  test('resetProvider 清掉该厂商的游标与账号健康度', () {
    final accounts = [account('a'), account('b')];
    select(accounts); // 推进游标到 b
    router.markFailed(accounts.first, Exception('429 rate limit'));

    router.resetProvider('p1', accounts: accounts);

    expect(router.isCooling('a'), isFalse);
    expect(select(accounts)!.account.id, 'a');
  });
}

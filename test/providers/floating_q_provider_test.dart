import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';

void main() {
  group('悬浮小Q上下文注册与会话签名', () {
    test('初始状态为待机且无会话', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(floatingQProvider);
      expect(state.phase, FloatingQPhase.idle);
      expect(state.contextSignature, isNull);
      expect(state.messages, isEmpty);
      expect(state.panelOpen, isFalse);
    });

    test('基础上下文设置后签名跟随生效上下文', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      const diary = QPageContext(
        type: QContextType.diaryList,
        signature: 'page:diary',
        displayLabel: '时间线',
      );
      notifier.setBaseContext(diary);

      final state = container.read(floatingQProvider);
      expect(state.baseContext, diary);
      expect(state.contextSignature, 'page:diary');
      expect(state.effectiveContext, diary);
    });

    test('编辑页压栈覆盖基础上下文，出栈回落', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      const notes = QPageContext(
        type: QContextType.notesList,
        signature: 'page:notes',
        displayLabel: '笔记库',
      );
      const note = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        signature: 'note:n1',
        displayLabel: '笔记《A》',
      );
      notifier.setBaseContext(notes);
      notifier.pushOverlayContext(note);
      expect(container.read(floatingQProvider).effectiveContext, note);
      expect(container.read(floatingQProvider).contextSignature, 'note:n1');

      notifier.popOverlayContext(note);
      final after = container.read(floatingQProvider);
      expect(after.overlayStack, isEmpty);
      expect(after.effectiveContext, notes);
      expect(after.contextSignature, 'page:notes');
    });

    test('出栈按值匹配移除最后压入的同类上下文', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      // 模拟两次进入同签名上下文（如先后打开又关闭同类编辑页）
      const noteA = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        signature: 'note:n1',
        displayLabel: '笔记《A》',
      );
      const noteB = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        targetTitle: 'B',
        signature: 'note:n1',
        displayLabel: '笔记《B》',
      );
      notifier.pushOverlayContext(noteA);
      notifier.pushOverlayContext(noteB);
      notifier.popOverlayContext(noteB);
      expect(container.read(floatingQProvider).overlayStack, [noteA]);
    });

    test('面板开关与手动新对话重置', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      notifier.openPanel();
      expect(container.read(floatingQProvider).panelOpen, isTrue);
      notifier.closePanel();
      expect(container.read(floatingQProvider).panelOpen, isFalse);

      // 工作中不允许重置会话（此处为待机，重置生效但会话本就为空）
      notifier.newConversation();
      expect(container.read(floatingQProvider).contextSignature, isNull);
    });

    test('空闲时 undo 不可用（返回 null）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      expect(await notifier.undo(), isNull);
    });

    test('stop 在无任务时安全调用', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      expect(() => notifier.stop(), returnsNormally);
    });
  });

  group('「给小Q」引用挂起与消费', () {
    const quote = QTextQuote(
      source: QQuoteSource.note,
      sourceId: 'n1',
      sourceTitle: '自我介绍',
      quotedText: '我是 QNote 内置的全能终端管家',
      locationDesc: '第 3 行附近',
    );

    test('openWithQuote 挂起引用并展开面板', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      notifier.openWithQuote(quote);
      final state = container.read(floatingQProvider);
      expect(state.pendingQuote, quote);
      expect(state.panelOpen, isTrue);
    });

    test('clearPendingQuote 移除挂起引用（面板保持打开）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      notifier.openWithQuote(quote);
      notifier.clearPendingQuote();

      final state = container.read(floatingQProvider);
      expect(state.pendingQuote, isNull);
      expect(state.panelOpen, isTrue);
    });

    test('会话签名切换（切页）时挂起引用一并作废', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      // 笔记编辑页内挂起引用
      const note = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        signature: 'note:n1',
        displayLabel: '笔记《A》',
      );
      notifier.pushOverlayContext(note);
      notifier.openWithQuote(quote);
      expect(container.read(floatingQProvider).pendingQuote, quote);

      // 返回列表页（签名变化）→ 引用属于旧会话上下文，随之清空
      notifier.popOverlayContext(note);
      expect(container.read(floatingQProvider).pendingQuote, isNull);
    });

    test('手动开启新对话清空挂起引用', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      notifier.openWithQuote(quote);
      notifier.newConversation();
      expect(container.read(floatingQProvider).pendingQuote, isNull);
    });

    test('openWithText 预填文本并展开面板，clearPendingInputText 消费清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(floatingQProvider.notifier);

      expect(container.read(floatingQProvider).pendingInputText, isNull);
      expect(container.read(floatingQProvider).panelOpen, isFalse);

      notifier.openWithText('帮我总结这段来自第三方应用的内容');
      expect(container.read(floatingQProvider).panelOpen, isTrue);
      expect(
        container.read(floatingQProvider).pendingInputText,
        '帮我总结这段来自第三方应用的内容',
      );

      notifier.clearPendingInputText();
      expect(container.read(floatingQProvider).pendingInputText, isNull);
      expect(container.read(floatingQProvider).panelOpen, isTrue);
    });
  });

  group('QTargetBridge 编辑页桥接', () {
    test('指纹未变时任务结束触发重载', () async {
      final bridge = QTargetBridge.test();
      var reloaded = false;
      bridge.register('note:t1', QTargetHooks(
        fingerprint: () => 'v1',
        reload: () async => reloaded = true,
      ));

      bridge.notifyTaskStart('note:t1');
      final reloadedByEnd = await bridge.notifyTaskEnd('note:t1');
      expect(reloadedByEnd, isTrue);
      expect(reloaded, isTrue);
    });

    test('任务期间用户手动编辑（指纹变化）则保留用户版本不重载', () async {
      final bridge = QTargetBridge.test();
      var reloaded = false;
      var version = 'v1';
      bridge.register('note:t2', QTargetHooks(
        fingerprint: () => version,
        reload: () async => reloaded = true,
      ));

      bridge.notifyTaskStart('note:t2');
      version = 'user-edited';
      final reloadedByEnd = await bridge.notifyTaskEnd('note:t2');
      expect(reloadedByEnd, isFalse);
      expect(reloaded, isFalse);
    });

    test('未注册签名时通知安全返回', () async {
      final bridge = QTargetBridge.test();
      expect(() => bridge.notifyTaskStart('note:none'), returnsNormally);
      expect(await bridge.notifyTaskEnd('note:none'), isFalse);
      await bridge.reload('note:none');
      await bridge.reloadAll();
    });

    test('reloadAll 重载所有已注册编辑页', () async {
      final bridge = QTargetBridge.test();
      var count = 0;
      bridge.register('note:r1', QTargetHooks(reload: () async => count++));
      bridge.register('note:r2', QTargetHooks(reload: () async => count++));
      bridge.register('note:r3', QTargetHooks());

      await bridge.reloadAll();
      expect(count, 2);
    });

    test('unregister 后不再触发', () async {
      final bridge = QTargetBridge.test();
      var reloaded = false;
      bridge.register('note:u1', QTargetHooks(
        fingerprint: () => 'v',
        reload: () async => reloaded = true,
      ));
      bridge.unregister('note:u1');

      bridge.notifyTaskStart('note:u1');
      expect(await bridge.notifyTaskEnd('note:u1'), isFalse);
      expect(reloaded, isFalse);
    });

    test('captureQuote 返回编辑页注册的框选捕获结果', () {
      final bridge = QTargetBridge.test();
      const quote = QTextQuote(
        source: QQuoteSource.note,
        sourceId: 'n1',
        sourceTitle: '自我介绍',
        quotedText: '选中的文本',
        locationDesc: '第 1 行附近',
      );
      bridge.register('note:q1', QTargetHooks(quoteSelection: () => quote));

      expect(bridge.captureQuote('note:q1'), quote);
      // 未注册签名 / 空签名均视为无框选
      expect(bridge.captureQuote('note:none'), isNull);
      expect(bridge.captureQuote(null), isNull);
    });

    test('captureQuote 钩子抛异常时安全返回 null', () {
      final bridge = QTargetBridge.test();
      bridge.register(
        'note:q2',
        QTargetHooks(quoteSelection: () => throw Exception('boom')),
      );
      expect(bridge.captureQuote('note:q2'), isNull);
    });
  });
}

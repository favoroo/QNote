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
  });
}

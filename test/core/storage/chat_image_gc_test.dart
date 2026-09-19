import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/storage/chat_image_gc.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 生成图片回收的保护集测试。
///
/// 这里锁的是「只删无人引用的、且只在 images/ai 目录内删」：
/// 误删一张仍被笔记引用的图，用户看到的就是一辈子的破图，比空间没释放严重得多。
void main() {
  late Database db;
  late Directory gcRoot;
  late Directory aiDir;
  final gc = ChatImageGc.instance;
  final repo = ConfigRepository.instance;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  String testId(String name) => 'gc_${name}_$stamp';

  /// 造一张假的生成图片文件，返回其绝对路径（与真实落盘形态一致）
  Future<String> createAiImage(String fileName, {int bytes = 1024}) async {
    final file = File(p.join(aiDir.path, fileName));
    await file.writeAsBytes(List<int>.filled(bytes, 137));
    return file.path;
  }

  Future<void> insertSessionWithImage(String id, String imagePath) async {
    await repo.insertChatSession(
      ChatSession(
        id: id,
        title: '测试对话',
        messages: [
          ChatMessage(role: 'user', content: '画一张图'),
          ChatMessage(
            role: 'tool',
            content: '已生成',
            toolName: 'generate_image',
            uiDetails: {'type': 'generate_image', 'paths': [imagePath]},
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<bool> exists(String fileName) =>
      File(p.join(aiDir.path, fileName)).exists();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
    // 目录结构必须与真实落盘一致（…/images/ai/xxx.png）：引用识别靠的就是
    // 路径里的 images/ai 段，夹具少了这一段会让整套保护集形同虚设
    gcRoot = await Directory.systemTemp.createTemp('qnote_gc_');
    aiDir = Directory(p.join(gcRoot.path, 'images', 'ai'));
    await aiDir.create(recursive: true);
    gc.aiImagesDirOverride = aiDir;
  });

  tearDownAll(() {
    gc.aiImagesDirOverride = null;
    if (gcRoot.existsSync()) {
      gcRoot.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    await db.delete('chat_sessions', where: 'id LIKE ?', whereArgs: ['gc_%']);
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id LIKE ?",
      whereArgs: ['gc_%'],
    );
    await db.delete('notes', where: 'id LIKE ?', whereArgs: ['gc_%']);
    for (final entity in aiDir.listSync()) {
      await entity.delete();
    }
  });

  test('从未被任何数据引用的孤儿图可被回收并回报释放字节', () async {
    // 模拟旧版本遗留：会话早已删除，图片文件还躺在 images/ai 里
    await createAiImage('orphan.png', bytes: 2048);

    final result = await gc.deleteUnreferencedAiImages();

    expect(result.deletedFiles, 1);
    expect(result.freedBytes, 2048);
    expect(await exists('orphan.png'), isFalse);
  });

  test('删除会话时它独占的生成图当场被回收', () async {
    final path = await createAiImage('mine.png', bytes: 3072);
    final id = testId('owner');
    await insertSessionWithImage(id, path);

    final report = await repo.hardDeleteChatSession(id);

    expect(report.deletedImageFiles, 1);
    expect(report.imageFreedBytes, 3072);
    expect(await exists('mine.png'), isFalse);
  });

  test('仍被其它会话引用的图片必须保留', () async {
    final sharedPath = await createAiImage('shared.png');
    await insertSessionWithImage(testId('keepA'), sharedPath);
    await insertSessionWithImage(testId('keepB'), sharedPath);

    await repo.hardDeleteChatSession(testId('keepA'));

    expect(await exists('shared.png'), isTrue, reason: 'keepB 还在引用这张图');
    final result = await gc.deleteUnreferencedAiImages();
    expect(result.deletedFiles, 0);
    expect(await exists('shared.png'), isTrue);
  });

  test('仍被笔记引用的图片必须保留', () async {
    final now = DateTime.now().toIso8601String();
    final path = await createAiImage('in_note.png');
    await insertSessionWithImage(testId('noteOwner'), path);
    await db.insert('notes', {
      'id': testId('note'),
      'title': '小Q把图放进了笔记',
      'content': '正文',
      'images': '["$path"]',
      'created_at': now,
      'updated_at': now,
    });

    await repo.hardDeleteChatSession(testId('noteOwner'));

    expect(
      await exists('in_note.png'),
      isTrue,
      reason: '会话删了但笔记还在显示这张图',
    );
  });

  test('同批删除两个共用一张图的会话后，图片被彻底回收', () async {
    final path = await createAiImage('batch_shared.png', bytes: 4096);
    await insertSessionWithImage(testId('pairA'), path);
    await insertSessionWithImage(testId('pairB'), path);

    final report = await repo.hardDeleteChatSessions([
      testId('pairA'),
      testId('pairB'),
    ]);

    expect(report.deletedSessions, 2);
    expect(report.deletedImageFiles, 1);
    expect(report.imageFreedBytes, 4096);
    expect(await exists('batch_shared.png'), isFalse);
  });

  test('删除只影响 images/ai 目录，同名文件放在别处不受波及', () async {
    final victim = await createAiImage('target.png');
    final outsideDir = await Directory.systemTemp.createTemp('qnote_outside_');
    final outside = File(p.join(outsideDir.path, 'target.png'));
    await outside.writeAsBytes(List<int>.filled(512, 7));
    await insertSessionWithImage(testId('outside'), victim);

    await repo.hardDeleteChatSession(testId('outside'));

    expect(await exists('target.png'), isFalse);
    expect(outside.existsSync(), isTrue);
    outsideDir.deleteSync(recursive: true);
  });

  test('盘点能区分总体积与可回收体积', () async {
    final usedPath = await createAiImage('used.png', bytes: 1000);
    await createAiImage('free.png', bytes: 500);
    await insertSessionWithImage(testId('inventory'), usedPath);

    final inventory = await gc.inventoryAiImages();

    expect(inventory.fileCount, 2);
    expect(inventory.totalBytes, 1500);
    expect(inventory.orphanCount, 1);
    expect(inventory.orphanBytes, 500);
  });

  test('空键集合与目录不存在时安全返回', () async {
    expect((await gc.deleteFilesForKeys({})).deletedFiles, 0);

    gc.aiImagesDirOverride = Directory(
      p.join(aiDir.path, 'not_exist_dir'),
    );
    final missing = await gc.deleteUnreferencedAiImages();
    expect(missing.deletedFiles, 0);
    expect((await gc.inventoryAiImages()).fileCount, 0);
    gc.aiImagesDirOverride = aiDir;
  });

  test('待回收判定只认 basename，绝对路径前缀变化不影响结论', () async {
    // 重装 App 后 documents 绝对路径会变，但文件名不变：保护集必须仍能认出同一张图
    final fileName = 'moved.png';
    final oldAbsolute = '/old/install/path/images/ai/$fileName';
    final file = File(p.join(aiDir.path, fileName));
    await file.writeAsBytes(List<int>.filled(300, 9));
    await insertSessionWithImage(testId('moved'), oldAbsolute);

    final inventory = await gc.inventoryAiImages();
    expect(inventory.orphanCount, 0, reason: '老路径前缀不同但同文件名，仍算在用');

    await repo.hardDeleteChatSession(testId('moved'));
    expect(
      await exists('moved.png'),
      isFalse,
      reason: '引用它的会话删掉后，按文件名仍能对上并回收',
    );
  });
}

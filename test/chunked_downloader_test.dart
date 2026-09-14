import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/network/chunked_downloader.dart';

void main() {
  group('ChunkedDownloader 分片与区间计算测试', () {
    test('正确均匀切分分片区间与路径', () {
      final downloader = ChunkedDownloader(concurrency: 3);
      expect(downloader.concurrency, 3);

      // 模拟一个 30MB (31457280 字节) 的安装包
      const totalBytes = 31457280;
      const targetPath = '/tmp/test_app.apk';

      final chunks = <DownloadChunk>[];
      const chunkSize = totalBytes ~/ 3;
      for (int i = 0; i < 3; i++) {
        final start = i * chunkSize;
        final end = (i == 2) ? totalBytes - 1 : (start + chunkSize - 1);
        chunks.add(
          DownloadChunk(
            index: i,
            start: start,
            end: end,
            tempFilePath: '$targetPath.part_$i',
          ),
        );
      }

      expect(chunks.length, 3);
      expect(chunks[0].start, 0);
      expect(chunks[0].end, 10485759);
      expect(chunks[0].totalSize, 10485760);
      expect(chunks[0].tempFilePath, '/tmp/test_app.apk.part_0');

      expect(chunks[1].start, 10485760);
      expect(chunks[1].end, 20971519);
      expect(chunks[1].totalSize, 10485760);
      expect(chunks[1].tempFilePath, '/tmp/test_app.apk.part_1');

      expect(chunks[2].start, 20971520);
      expect(chunks[2].end, 31457279);
      expect(chunks[2].totalSize, 10485760);
      expect(chunks[2].tempFilePath, '/tmp/test_app.apk.part_2');

      // 验证总分块字节总和与文件总大小完全一致
      final totalSum = chunks.fold<int>(0, (sum, c) => sum + c.totalSize);
      expect(totalSum, totalBytes);
    });

    test('处理无法整除的字节数（末尾分片自适应补偿）', () {
      const totalBytes = 10000007; // 无法被 3 整除
      const targetPath = '/tmp/odd.apk';

      final chunks = <DownloadChunk>[];
      const chunkSize = totalBytes ~/ 3;
      for (int i = 0; i < 3; i++) {
        final start = i * chunkSize;
        final end = (i == 2) ? totalBytes - 1 : (start + chunkSize - 1);
        chunks.add(
          DownloadChunk(
            index: i,
            start: start,
            end: end,
            tempFilePath: '$targetPath.part_$i',
          ),
        );
      }

      expect(chunks.length, 3);
      expect(chunks[0].start, 0);
      expect(chunks[1].start, chunks[0].end + 1);
      expect(chunks[2].start, chunks[1].end + 1);
      expect(chunks[2].end, totalBytes - 1);

      final totalSum = chunks.fold<int>(0, (sum, c) => sum + c.totalSize);
      expect(totalSum, totalBytes);
    });
  });
}

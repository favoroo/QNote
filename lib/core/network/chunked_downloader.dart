import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';

/// 分片下载进度回调。
///
/// [receivedBytes] 已接收的字节数。
/// [totalBytes] 文件的总字节数（若未知则为 -1）。
/// [speedBytesPerSec] 实时下载速度（字节/秒）。
typedef OnChunkedDownloadProgress = void Function(
  int receivedBytes,
  int totalBytes,
  double speedBytesPerSec,
);

/// 单个分块信息模型。
class DownloadChunk {
  /// 分块序号（从 0 开始）。
  final int index;

  /// 该分块在全量文件中的起始字节偏移（包含）。
  final int start;

  /// 该分块在全量文件中的结束字节偏移（包含）。
  final int end;

  /// 该分块对应的本地临时文件路径。
  final String tempFilePath;

  /// 该分块预期总大小。
  int get totalSize => end - start + 1;

  DownloadChunk({
    required this.index,
    required this.start,
    required this.end,
    required this.tempFilePath,
  });
}

/// 服务端 Range 支持与直链元数据探测结果。
class _ProbeResult {
  /// 经过重定向后的最终下载直链。
  final String finalUrl;

  /// 文件总字节数（若未能解析出则为 -1）。
  final int totalBytes;

  /// 服务端是否明确支持 HTTP Range 请求（HTTP 206）。
  final bool supportsRange;

  const _ProbeResult({
    required this.finalUrl,
    required this.totalBytes,
    required this.supportsRange,
  });
}

/// 高性能分片多线程并发下载器。
///
/// 特性：
/// 1. 自动探测服务端 Range（分块）支持情况与 302 重定向直链；
/// 2. 支持 Range 时将文件拆解为 [concurrency] 个分片并发拉取，突破单连接速率限制；
/// 3. 支持分片级别的断点续传（基于 `.part_*` 临时分片文件增量请求）；
/// 4. 若服务端不支持分块（返回 200）、缺少长度或文件小于阈值，自动降级为单连接流式下载；
/// 5. 实时平滑计算下载速率（字节/秒），并完整支持 [CancelToken] 取消。
class ChunkedDownloader {
  /// 默认并发分块数量（3~4 条线程既能跑满带宽，又可避免触发对象存储防刷限流）。
  static const int defaultConcurrency = 3;

  /// 启用分片多线程的最小文件大小阈值（默认 4MB，小于此阈值单连接开销更小）。
  static const int minChunkSizeThreshold = 4 * 1024 * 1024;

  final Dio _dio;
  final int concurrency;

  ChunkedDownloader({
    Dio? dio,
    this.concurrency = defaultConcurrency,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(minutes: 5),
                followRedirects: true,
                maxRedirects: 8,
              ),
            );

  /// 启动下载任务。
  ///
  /// [url] 下载源地址。
  /// [savePath] 最终合并保存的本地绝对路径。
  /// [onProgress] 进度与网速回调。
  /// [cancelToken] 取消令牌。
  /// 返回下载完成后的本地文件路径。
  Future<String> download({
    required String url,
    required String savePath,
    OnChunkedDownloadProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final targetFile = File(savePath);

    // 1. 发起轻量探测，确定最终直链、文件总大小以及是否支持 Range
    final probe = await _probeDownloadCapability(url, cancelToken);

    // 2. 判断是否满足多线程并发分块条件
    final canUseChunks = probe.supportsRange &&
        probe.totalBytes >= minChunkSizeThreshold &&
        concurrency > 1;

    if (!canUseChunks) {
      LoggerService.instance.info(
        '下载降级为单连接下载 (supportsRange: ${probe.supportsRange}, totalBytes: ${probe.totalBytes})',
        category: LogCategory.network,
      );
      return await _downloadSingleStream(
        url: probe.finalUrl,
        targetFile: targetFile,
        totalBytes: probe.totalBytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }

    // 3. 执行多线程分片并发下载
    LoggerService.instance.info(
      '开启 $concurrency 线程分片并发加速下载: ${probe.finalUrl} (总大小: ${probe.totalBytes} 字节)',
      category: LogCategory.network,
    );

    return await _downloadInChunks(
      finalUrl: probe.finalUrl,
      targetFile: targetFile,
      totalBytes: probe.totalBytes,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// 探测服务端的 Range 分片支持与文件长度。
  Future<_ProbeResult> _probeDownloadCapability(
    String url,
    CancelToken? cancelToken,
  ) async {
    try {
      // 发送一个只请求第一个字节的微型 Range 请求 (bytes=0-0)
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
        cancelToken: cancelToken,
      );

      final realUrl = response.realUri.toString();
      final statusCode = response.statusCode ?? 0;
      final headers = response.headers;

      // 及时关闭探测响应的流，避免泄露
      unawaited(response.data?.stream.listen((_) {}).cancel());

      int totalBytes = -1;
      bool supportsRange = false;

      if (statusCode == HttpStatus.partialContent) {
        // 206 说明完全支持 Range
        supportsRange = true;
        // 尝试从 Content-Range 中提取总字节数，格式如: bytes 0-0/52428800
        final contentRange = headers.value('content-range');
        if (contentRange != null) {
          final match = RegExp(r'/(\d+)').firstMatch(contentRange);
          if (match != null) {
            totalBytes = int.tryParse(match.group(1) ?? '') ?? -1;
          }
        }
      } else if (statusCode == HttpStatus.ok) {
        // 返回 200 说明服务端忽略了 Range 头，返回了全量文件
        supportsRange = false;
        final contentLength = headers.value('content-length');
        if (contentLength != null) {
          totalBytes = int.tryParse(contentLength) ?? -1;
        }
      }

      return _ProbeResult(
        finalUrl: realUrl,
        totalBytes: totalBytes,
        supportsRange: supportsRange,
      );
    } catch (e) {
      LoggerService.instance.warning(
        '探测下载能力失败，降级使用原始地址单线程处理: $e',
        category: LogCategory.network,
      );
      return _ProbeResult(
        finalUrl: url,
        totalBytes: -1,
        supportsRange: false,
      );
    }
  }

  /// 单连接流式下载（降级模式）。
  Future<String> _downloadSingleStream({
    required String url,
    required File targetFile,
    required int totalBytes,
    required OnChunkedDownloadProgress? onProgress,
    required CancelToken? cancelToken,
  }) async {
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await targetFile.parent.create(recursive: true);

    int lastTime = DateTime.now().millisecondsSinceEpoch;
    int lastReceived = 0;
    double currentSpeed = 0.0;

    await _dio.download(
      url,
      targetFile.path,
      cancelToken: cancelToken,
      deleteOnError: true,
      onReceiveProgress: (received, total) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final deltaMs = now - lastTime;
        if (deltaMs >= 500) {
          final deltaBytes = received - lastReceived;
          currentSpeed = (deltaBytes / (deltaMs / 1000.0));
          lastTime = now;
          lastReceived = received;
        }
        final finalTotal = total > 0 ? total : totalBytes;
        onProgress?.call(received, finalTotal, currentSpeed);
      },
    );

    return targetFile.path;
  }

  /// 多线程分片并发下载并在完成后合并。
  Future<String> _downloadInChunks({
    required String finalUrl,
    required File targetFile,
    required int totalBytes,
    required OnChunkedDownloadProgress? onProgress,
    required CancelToken? cancelToken,
  }) async {
    await targetFile.parent.create(recursive: true);

    // 计算分片范围
    final chunks = _calculateChunks(targetFile.path, totalBytes, concurrency);

    // 记录每个分块当前已下载的字节数（支持断点续传）
    final chunkReceivedBytes = List<int>.filled(chunks.length, 0);

    // 检查已存在的分块进度
    for (int i = 0; i < chunks.length; i++) {
      final partFile = File(chunks[i].tempFilePath);
      if (await partFile.exists()) {
        final len = await partFile.length();
        if (len <= chunks[i].totalSize) {
          chunkReceivedBytes[i] = len;
        } else {
          // 分块文件异常超长，删除重下
          await partFile.delete();
          chunkReceivedBytes[i] = 0;
        }
      }
    }

    // 速度平滑计算器
    int lastTime = DateTime.now().millisecondsSinceEpoch;
    int lastTotalReceived = chunkReceivedBytes.fold<int>(0, (sum, val) => sum + val);
    double smoothedSpeed = 0.0;

    void updateProgress() {
      final currentTotal = chunkReceivedBytes.fold<int>(0, (sum, val) => sum + val);
      final now = DateTime.now().millisecondsSinceEpoch;
      final deltaMs = now - lastTime;

      if (deltaMs >= 400) {
        final deltaBytes = currentTotal - lastTotalReceived;
        final instantSpeed = deltaBytes / (deltaMs / 1000.0);
        // 使用一阶低通滤波平滑瞬时速度抖动
        smoothedSpeed = smoothedSpeed == 0.0
            ? instantSpeed
            : (smoothedSpeed * 0.7 + instantSpeed * 0.3);
        lastTime = now;
        lastTotalReceived = currentTotal;
      }

      onProgress?.call(currentTotal, totalBytes, smoothedSpeed);
    }

    // 初始化先通知一次初始进度
    updateProgress();

    // 并发启动所有分块的下载
    final futures = <Future<void>>[];
    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      futures.add(
        _downloadSingleChunk(
          url: finalUrl,
          chunk: chunk,
          initialDownloaded: chunkReceivedBytes[i],
          onChunkProgress: (receivedDelta) {
            chunkReceivedBytes[chunk.index] += receivedDelta;
            updateProgress();
          },
          cancelToken: cancelToken,
        ),
      );
    }

    try {
      await Future.wait(futures);
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) {
        LoggerService.instance.info('用户取消了分片下载任务', category: LogCategory.network);
      } else {
        LoggerService.instance.error(
          '分片下载发生异常: $e',
          category: LogCategory.network,
        );
      }
      rethrow;
    }

    // 所有分片下载完毕，进行流式合并
    LoggerService.instance.info('所有分片下载完毕，开始合并文件...', category: LogCategory.network);
    await _mergeChunks(chunks, targetFile, totalBytes);

    // 合并成功后通知 100% 进度
    onProgress?.call(totalBytes, totalBytes, 0.0);

    return targetFile.path;
  }

  /// 单个分块下载实现（带断点续传）。
  Future<void> _downloadSingleChunk({
    required String url,
    required DownloadChunk chunk,
    required int initialDownloaded,
    required void Function(int receivedDelta) onChunkProgress,
    required CancelToken? cancelToken,
  }) async {
    final partFile = File(chunk.tempFilePath);

    // 若该分块此前已经完全下载完成，无需重复请求
    if (initialDownloaded >= chunk.totalSize) {
      return;
    }

    final startByte = chunk.start + initialDownloaded;
    final endByte = chunk.end;

    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=$startByte-$endByte'},
        followRedirects: true,
      ),
      cancelToken: cancelToken,
    );

    final stream = response.data?.stream;
    if (stream == null) {
      throw Exception('分块 ${chunk.index} 响应体为空');
    }

    // 以 append 模式写入分片临时文件，实现断点续传
    final sink = partFile.openWrite(mode: FileMode.append);

    try {
      await for (final data in stream) {
        if (cancelToken?.isCancelled ?? false) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.cancel,
            error: '用户取消下载',
          );
        }
        sink.add(data);
        onChunkProgress(data.length);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// 将多个分块文件按序合并写入目标文件。
  Future<void> _mergeChunks(
    List<DownloadChunk> chunks,
    File targetFile,
    int totalBytes,
  ) async {
    if (await targetFile.exists()) {
      await targetFile.delete();
    }

    final raf = await targetFile.open(mode: FileMode.write);

    try {
      for (final chunk in chunks) {
        final partFile = File(chunk.tempFilePath);
        if (!await partFile.exists()) {
          throw Exception('分片文件丢失: ${chunk.tempFilePath}');
        }

        final partLength = await partFile.length();
        if (partLength != chunk.totalSize) {
          throw Exception(
            '分片 ${chunk.index} 大小异常: 实际 $partLength 字节，预期 ${chunk.totalSize} 字节',
          );
        }

        final inputRaf = await partFile.open(mode: FileMode.read);
        try {
          const bufferSize = 64 * 1024; // 64KB 缓冲区
          final buffer = List<int>.filled(bufferSize, 0);
          int bytesRead = 0;
          while ((bytesRead = inputRaf.readIntoSync(buffer)) > 0) {
            raf.writeFromSync(buffer, 0, bytesRead);
          }
        } finally {
          await inputRaf.close();
        }
      }

      await raf.flush();
    } finally {
      await raf.close();
    }

    // 校验合并后总大小
    final finalSize = await targetFile.length();
    if (finalSize != totalBytes) {
      await targetFile.delete();
      throw Exception('文件合并校验失败: 最终大小 $finalSize != 预期 $totalBytes');
    }

    // 合并完成，安全清理分片临时文件
    for (final chunk in chunks) {
      try {
        final partFile = File(chunk.tempFilePath);
        if (await partFile.exists()) {
          await partFile.delete();
        }
      } catch (e) {
        // 清理临时文件失败仅记录日志，不阻断主流程
        LoggerService.instance.warning(
          '清理分片临时文件失败: ${chunk.tempFilePath}, $e',
          category: LogCategory.network,
        );
      }
    }
  }

  /// 根据总字节数和并发数均匀切分分片区间。
  List<DownloadChunk> _calculateChunks(
    String targetPath,
    int totalBytes,
    int chunkCount,
  ) {
    final chunks = <DownloadChunk>[];
    final chunkSize = totalBytes ~/ chunkCount;

    for (int i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1) ? totalBytes - 1 : (start + chunkSize - 1);
      chunks.add(
        DownloadChunk(
          index: i,
          start: start,
          end: end,
          tempFilePath: '$targetPath.part_$i',
        ),
      );
    }

    return chunks;
  }
}

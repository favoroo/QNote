import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:qnote_flutter/core/logger/logger_service.dart';

import 'package:qnote_flutter/core/storage/image_repository.dart';

class UnifiedImage extends StatefulWidget {
  final String? imagePath;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;

  const UnifiedImage({
    super.key,
    this.imagePath,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
  });

  @override
  State<UnifiedImage> createState() => _UnifiedImageState();
}

class _UnifiedImageState extends State<UnifiedImage> {
  bool _hasChecked = false;
  bool _fileExists = false;
  String? _resolvedPath;

  static bool _isValidWebUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return true;
    if (path.startsWith('data:')) return true;
    if (path.startsWith('blob:')) return true;
    if (path.startsWith('asset:')) return true;
    return false;
  }

  @override
  void initState() {
    super.initState();
    _checkFileExistence();
  }

  @override
  void didUpdateWidget(UnifiedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _checkFileExistence();
    }
  }

  void _checkFileExistence() async {
    if (widget.imagePath == null || widget.imagePath!.isEmpty) {
      if (mounted) {
        setState(() {
          _hasChecked = true;
          _fileExists = false;
          _resolvedPath = null;
        });
      }
      return;
    }

    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _hasChecked = true;
          _fileExists = _isValidWebUrl(widget.imagePath!);
          _resolvedPath = widget.imagePath;
        });
      }
      return;
    }

    String path = widget.imagePath!;
    bool exists = await File(path).exists();
    if (!exists) {
      try {
        final resolved = await ImageRepository().resolveLocalPath(path);
        path = resolved;
        exists = await File(path).exists();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _hasChecked = true;
        _fileExists = exists;
        _resolvedPath = path;
      });
      
      if (!exists) {
        LoggerService.instance.logUI(
          '图片文件不存在',
          details: widget.imagePath,
          level: LogLevel.warning
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imagePath == null || widget.imagePath!.isEmpty) {
      return _buildPlaceholder(context);
    }

    if (!_hasChecked) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: _buildLoading(context),
      );
    }

    if (!_fileExists) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: _buildError(context),
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
        child: kIsWeb
            ? Image.network(
                widget.imagePath!,
                width: widget.width,
                height: widget.height,
                fit: widget.fit,
                headers: const {'Cache-Control': 'no-cache'},
                errorBuilder: (context, error, stackTrace) {
                  LoggerService.instance.logUI(
                    '图片加载失败 (Web): $error',
                    level: LogLevel.error,
                    details: widget.imagePath
                  );
                  return _buildError(context);
                },
              )
            : Image.file(
                File(_resolvedPath ?? widget.imagePath!),
                width: widget.width,
                height: widget.height,
                fit: widget.fit,
                // Downsample image decoding sizes on mobile to prevent memory spikes (OOM) and black screen freezes.
                // We use 2.0x display width to match device pixel ratios for sharp rendering.
                cacheWidth: widget.width != null 
                    ? (widget.width! * 2.0).clamp(100.0, 1080.0).round() 
                    : 720,
                errorBuilder: (context, error, stackTrace) {
                  LoggerService.instance.logUI(
                    '图片加载失败: $error',
                    level: LogLevel.error,
                    details: widget.imagePath
                  );
                  return _buildError(context);
                },
              ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
      ),
      child: Icon(
        Icons.image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: _iconSize,
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
      ),
      child: Center(
        child: SizedBox(
          width: _iconSize,
          height: _iconSize,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
      ),
      child: Icon(
        Icons.broken_image_outlined,
        color: Theme.of(context).colorScheme.error,
        size: _iconSize,
      ),
    );
  }

  double? get _iconSize {
    if (widget.width != null && widget.height != null) {
      return (widget.width! + widget.height!) / 4;
    }
    return null;
  }
}

class FullScreenImageGallery extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const FullScreenImageGallery({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenImageGallery> createState() => _FullScreenImageGalleryState();
}

class _FullScreenImageGalleryState extends State<FullScreenImageGallery> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_currentIndex + 1} / ${widget.images.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: UnifiedImage(
                imagePath: widget.images[index],
                fit: BoxFit.contain,
              ),
            ),
          );
        },
      ),
    );
  }
}


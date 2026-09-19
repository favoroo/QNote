import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/storage/image_saver.dart';
import 'package:qnote_flutter/core/utils/chat_image_dedupe.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

/// 回复正文里的 markdown 内联图。
///
/// 生图工具卡片已经把生成结果展示过一次，模型按提示词回显到正文的同一张图在这里
/// 直接不占位（只保留文字说明）；不属于生图卡片的图片（如正文引用的已有笔记图）
/// 仍渲染为可点击放大、可长按的 [ChatImageView]。
class ChatBodyImage extends StatelessWidget {
  const ChatBodyImage({
    super.key,
    required this.src,
    required this.generatedImageKeys,
    this.onSendToQ,
  });

  /// markdown 图片语法里的 src 原文（文件路径或 data URI）。
  final String src;

  /// 本会话内已由生图卡片展示过的图片键集合。
  final Set<String> generatedImageKeys;

  final ValueChanged<String>? onSendToQ;

  @override
  Widget build(BuildContext context) {
    if (isRedundantGeneratedImage(src, generatedImageKeys)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // 限高避免原始尺寸（生图常见 1024x1024）把气泡撑爆；RenderImage 会按约束
      // 等比收缩，配合 contain 不会留下留白
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ChatImageView(
          imagePath: src,
          fit: BoxFit.contain,
          onSendToQ: onSendToQ,
        ),
      ),
    );
  }
}

/// 聊天场景的统一图片视图：点击进入可翻页的大图预览，长按弹出操作菜单。
///
/// 生图结果卡、正文 markdown 内联图、用户上传附件缩略图、`view_image` 缩略图共用此组件，
/// 避免每处各写一套 GestureDetector 与预览入口。
///
/// 宿主语义通过 [onSendToQ] 注入：为 null 时菜单与大图页都不出现「给小Q」，
/// 因此本组件也可安全用于没有小Q 语境的场景。
class ChatImageView extends StatefulWidget {
  const ChatImageView({
    super.key,
    required this.imagePath,
    this.galleryImages,
    this.galleryIndex = 0,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.fit = BoxFit.cover,
    this.enableLongPressMenu = true,
    this.onSendToQ,
  });

  /// 本张图片的图片来源（原生端为文件路径，Web 端可能为 data URI）。
  final String imagePath;

  /// 大图预览的可翻页图片列表；为 null 时退化为仅本页一张。
  final List<String>? galleryImages;

  /// [imagePath] 在 [galleryImages] 中的下标。
  final int galleryIndex;

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;

  /// 附件条这类自带移除入口的缩略图可关闭长按菜单。
  final bool enableLongPressMenu;

  /// 「给小Q」：把图片挂到小Q 输入框，由宿主决定挂进主页附件还是悬浮面板附件。
  final ValueChanged<String>? onSendToQ;

  @override
  State<ChatImageView> createState() => _ChatImageViewState();
}

class _ChatImageViewState extends State<ChatImageView> {
  /// ActionMenu 需要一个指向图片本身的 GlobalKey 来定位浮层位置
  final GlobalKey _anchorKey = GlobalKey(debugLabel: 'chatImage');

  List<String> get _gallery =>
      widget.galleryImages ?? <String>[widget.imagePath];

  int get _galleryIndex => widget.galleryIndex.clamp(
    0,
    _gallery.isEmpty ? 0 : _gallery.length - 1,
  );

  void _openGallery() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullScreenImageGallery(
          images: _gallery,
          initialIndex: _galleryIndex,
          onSave: _save,
          onSendToQ: widget.onSendToQ,
        ),
      ),
    );
  }

  void _save(String path) {
    ImageSaver.saveWithToast(context, path);
  }

  void _copyPath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    Toast.info(context, '已复制图片路径');
  }

  void _showLongPressMenu() {
    HapticFeedback.lightImpact();
    ActionMenu.show(context: context, key: _anchorKey, items: _menuItems());
  }

  List<ActionMenuItem> _menuItems() {
    final path = widget.imagePath;
    return <ActionMenuItem>[
      ActionMenuItem(
        icon: Icons.zoom_out_map,
        label: '查看大图',
        onTap: _openGallery,
      ),
      if (widget.onSendToQ != null)
        ActionMenuItem(
          icon: Icons.forum_outlined,
          label: '给小Q',
          onTap: () => widget.onSendToQ!(path),
        ),
      ActionMenuItem(
        icon: Icons.download_outlined,
        label: '下载',
        onTap: () => _save(path),
      ),
      // Web 端生图结果是超长的 base64 内联串，复制出来没有任何用处
      if (!ImageSaver.isInlineData(path))
        ActionMenuItem(
          icon: Icons.link,
          label: '复制路径',
          onTap: () => _copyPath(path),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _anchorKey,
      behavior: HitTestBehavior.opaque,
      onTap: _openGallery,
      onLongPress: widget.enableLongPressMenu ? _showLongPressMenu : null,
      child: ClipRRect(
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
        child: UnifiedImage(
          imagePath: widget.imagePath,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
        ),
      ),
    );
  }
}

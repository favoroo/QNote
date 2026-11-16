import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/mermaid_er_repair.dart';
import 'package:qnote_flutter/core/utils/mermaid_html.dart';
import 'package:qnote_flutter/core/utils/mermaid_theme.dart';
import 'package:qnote_flutter/widgets/notes/file_preview/mermaid_assets.dart';
import 'package:qnote_flutter/widgets/notes/html_preview/html_preview_view.dart';

/// Mermaid 笔记预览：把 `.mmd` 源码包成完整 HTML（内联本地 mermaid 运行库），
/// 复用网页预览容器在 WebView/iframe 中渲染，离线可用。
///
/// 主题对象由当前 [ThemeData] 生成，深浅色、强调色与笔记页保持一致。
class MermaidPreviewView extends StatefulWidget {
  final String source;
  final String? noteId;

  const MermaidPreviewView({super.key, required this.source, this.noteId});

  @override
  State<MermaidPreviewView> createState() => _MermaidPreviewViewState();
}

class _MermaidPreviewViewState extends State<MermaidPreviewView> {
  String? _runtime;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadRuntime();
  }

  Future<void> _loadRuntime() async {
    final runtime = await MermaidAssets.load();
    if (!mounted) return;
    setState(() {
      _runtime = runtime;
      _failed = runtime == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.source.trim().isEmpty) {
      return const _PreviewState(
        icon: Icons.schema_outlined,
        title: '暂无可预览图表',
        message: '当前 Mermaid 文件为空，点右上角查看源码并添加内容',
      );
    }
    if (_failed) {
      return _fallbackSource(theme);
    }
    if (_runtime == null) {
      return const _LoadingState();
    }
    // ER 的中文字段名/类型是 Mermaid 语法硬限制；预览期先做保守替换（不改源码），
    // 中文保留在字段注释列，并在顶部提示条说明，避免整张图直接报错看不到。
    final repaired = repairMermaidErSource(widget.source);
    final html = buildMermaidHtml(
      source: repaired.source,
      mermaidRuntime: _runtime!,
      theme: MermaidTheme.fromThemeData(theme),
      notice: repaired.notice,
    );
    return HtmlPreviewView(htmlContent: html, noteId: widget.noteId);
  }

  /// 运行库缺失（资源未打包）时的兜底：仍把源码展示出来，并说明预览不可用
  Widget _fallbackSource(ThemeData theme) {
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _StateIcon(icon: Icons.code_off_outlined, size: 40, iconSize: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '预览组件未就绪',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: AppTypography.subtitle,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Mermaid 运行库未加载，暂以源码显示',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: AppTypography.bodySmall,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: SelectableText(
              widget.source,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: AppTypography.bodySmall,
                height: 1.55,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 加载运行库期间的主题化提示；真正渲染图形时 HTML 内部还有一层 spinner。
class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: theme.accentInk)),
          const SizedBox(height: 12),
          Text(
            '正在加载预览组件…',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: AppTypography.bodySmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态：图标放在主色 8% 透明度的圆底中，标题 15/w600，说明 12/次要文字。
class _PreviewState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _PreviewState({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StateIcon(icon: icon, size: 52, iconSize: 24),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: AppTypography.subtitle,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: AppTypography.bodySmall,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主色 8% 圆底 + 可读强调色图标，空态/错误态共用。
class _StateIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;

  const _StateIcon({required this.icon, required this.size, required this.iconSize});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.08), shape: BoxShape.circle),
      child: Icon(icon, size: iconSize, color: theme.accentInk),
    );
  }
}

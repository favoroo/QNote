import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/utils/mermaid_gantt.dart';
import 'package:qnote_flutter/widgets/notes/file_preview/gantt_chart_view.dart';
import 'package:qnote_flutter/widgets/notes/file_preview/mermaid_preview_view.dart';

/// `.mmd` 预览分流：甘特图走原生视图，其余图型交给 Mermaid 通用渲染。
///
/// 原生视图能固定任务列、独立滚动时间轴并按日/周/月缩放；遇到解析器不支持的
/// 甘特写法（excludes、自定义日期格式等）自动回退 Mermaid，避免画错日期。
class MermaidOrGanttPreview extends StatefulWidget {
  final String source;
  final String? noteId;

  const MermaidOrGanttPreview({super.key, required this.source, this.noteId});

  @override
  State<MermaidOrGanttPreview> createState() => _MermaidOrGanttPreviewState();
}

class _MermaidOrGanttPreviewState extends State<MermaidOrGanttPreview> {
  String? _cachedSource;
  GanttPlan? _plan;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant MermaidOrGanttPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source) {
      _parse();
    }
  }

  void _parse() {
    _cachedSource = widget.source;
    _plan = parseMermaidGantt(widget.source);
  }

  @override
  Widget build(BuildContext context) {
    // build 期间源码可能刚被外部替换，先确保解析结果与当前源码一致
    if (_cachedSource != widget.source) {
      _parse();
    }
    final plan = _plan;
    if (plan != null) {
      return GanttChartView(plan: plan);
    }
    return MermaidPreviewView(source: widget.source, noteId: widget.noteId);
  }
}

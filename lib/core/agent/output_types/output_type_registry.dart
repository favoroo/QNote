/// 对话「输出类型」注册表。
///
/// 用户在小Q 对话的「+」面板里选定一个输出类型后：该条目的 [OutputTypeOption.skillName]
/// （若有）会把对应技能手册注入本轮上下文，[OutputTypeOption.hint] 说明本次目标产物与
/// 目标后缀；仅对下一条消息生效，发送后清除。纯 Dart、不依赖 Flutter，便于 Provider 与 UI 共用。
class OutputTypeOption {
  /// 稳定标识（写入会话参数与日志用）
  final String id;

  /// 面板显示名
  final String label;

  /// 卡片副标题：一句话说明这种形态产出什么（6~12 个汉字）
  final String description;

  /// 分组（见 [kOutputTypeCategories]）
  final String category;

  /// 需要注入手册的内置技能名；null 表示无需技能（仅用 hint 指引）
  final String? skillName;

  /// 目标文件后缀（供提示词说明与展示），如 mmd/csv/json/html/md
  final String? extension;

  /// 注入上下文的本次目标说明
  final String hint;

  const OutputTypeOption({
    required this.id,
    required this.label,
    required this.description,
    required this.category,
    required this.hint,
    this.skillName,
    this.extension,
  });
}

/// 类别常量（面板分组标题与排序）
const String kOutputCategoryDiagram = '图示';
const String kOutputCategoryData = '数据与图表';
const String kOutputCategoryDocument = '文档';

/// 类别展示顺序（只列实际有内容的三类，面板按此顺序分组）
const List<String> kOutputTypeCategories = [kOutputCategoryDiagram, kOutputCategoryData, kOutputCategoryDocument];

/// 可选输出类型清单
///
/// 只保留移动端真正会用的形态：图示 / 数据与图表 / 文档。
/// 每个条目的 [OutputTypeOption.hint] 都按手机屏幕约束收紧（节点数、列数、层级、日期跨度），
/// 避免模型产出在窄屏上糊成一团。
const List<OutputTypeOption> kOutputTypes = [
  // ---- 图示（Mermaid，写入 .mmd）----
  OutputTypeOption(
    id: 'flowchart',
    label: '流程图',
    description: '步骤、判断与分支',
    category: kOutputCategoryDiagram,
    skillName: 'mermaid-diagram',
    extension: 'mmd',
    hint: '用 Mermaid `flowchart TD/LR` 表达步骤与分支，节点文案短，写入 /notes/<标题>.mmd',
  ),
  OutputTypeOption(
    id: 'sequence',
    label: '时序图',
    description: '多方交互先后顺序',
    category: kOutputCategoryDiagram,
    skillName: 'mermaid-diagram',
    extension: 'mmd',
    hint: '用 Mermaid `sequenceDiagram` 表达多方交互的先后顺序，参与者 ≤5 个，写入 /notes/<标题>.mmd',
  ),
  OutputTypeOption(
    id: 'gantt',
    label: '甘特图',
    description: '任务排期与进度',
    category: kOutputCategoryDiagram,
    skillName: 'mermaid-diagram',
    extension: 'mmd',
    hint:
        '用 Mermaid `gantt` 排期：必写 `dateFormat YYYY-MM-DD` 与 `section`；'
        '任务格式 `任务名 :状态, id, 开始, 结束/持续`；日期范围尽量 ≤60 天，任务 ≤8 个；'
        '写入 /notes/<标题>.mmd',
  ),
  OutputTypeOption(
    id: 'mindmap',
    label: '思维导图',
    description: '层级梳理与发散',
    category: kOutputCategoryDiagram,
    skillName: 'mermaid-diagram',
    extension: 'mmd',
    hint:
        '用 Mermaid `mindmap` 梳理层级：缩进表层级、节点直接写文本；不超过 3 层、12 个节点，根节点文案短；'
        '写入 /notes/<标题>.mmd',
  ),

  // ---- 数据与图表 ----
  OutputTypeOption(
    id: 'table',
    label: '表格',
    description: '排序、搜索、复制',
    category: kOutputCategoryData,
    skillName: 'data-file',
    extension: 'csv',
    hint: '整理为规整 CSV：首行列头，列数尽量 ≤6 且列名简短；字段含逗号/引号需转义；写入 /notes/<标题>.csv',
  ),
  OutputTypeOption(
    id: 'chart',
    label: '数据图表',
    description: '趋势与对比可视化',
    category: kOutputCategoryData,
    skillName: 'frontend-design',
    extension: 'html',
    hint:
        '按 QStyle 瑞士风主题（数据报告默认克莱因蓝）做成单文件 HTML 数据可视化页面'
        '（优先纯 CSS/内联 SVG，需要交互图表用 Chart.js），写入 /notes/<标题>.html',
  ),

  // ---- 文档 ----
  OutputTypeOption(
    id: 'web',
    label: '网页·海报',
    description: '网页海报与落地页',
    category: kOutputCategoryDocument,
    skillName: 'frontend-design',
    extension: 'html',
    hint:
        '按 QStyle 选定风格家族与主题，做成有设计感的单文件 HTML 网页/海报/落地页（移动端优先），'
        '写入 /notes/<标题>.html',
  ),
  OutputTypeOption(
    id: 'note',
    label: '笔记文档',
    description: '结构清晰的笔记',
    category: kOutputCategoryDocument,
    skillName: 'note-manager',
    extension: 'md',
    hint: '整理成结构清晰的 Markdown 笔记（标题层级克制），写入 /notes/<笔记本>/<标题>.md',
  ),
];

/// 按 id 查输出类型；未命中返回 null
OutputTypeOption? outputTypeById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final option in kOutputTypes) {
    if (option.id == id) return option;
  }
  return null;
}

/// 按类别分组（保持 [kOutputTypeCategories] 的顺序；空类别跳过）
List<MapEntry<String, List<OutputTypeOption>>> groupedOutputTypes() {
  final result = <MapEntry<String, List<OutputTypeOption>>>[];
  for (final category in kOutputTypeCategories) {
    final items = kOutputTypes.where((o) => o.category == category).toList();
    if (items.isNotEmpty) result.add(MapEntry(category, items));
  }
  return result;
}

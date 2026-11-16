/// 笔记文件类型：按标题后缀识别，决定编辑器渲染方式与列表图标。
/// 不引入数据库字段，标题携带的后缀（如 `xiaop.html`）即类型标识，
/// 小Q 等工具通过 `write_file` 写入带后缀的标题即可自动获得对应预览能力。
enum NoteFileType {
  /// Markdown / 纯文本笔记（默认，沿用现有行内样式渲染）
  markdown,

  /// HTML 网页，支持 WebView 渲染预览与源码编辑切换
  html,

  /// SVG 矢量图，支持矢量预览与源码编辑切换
  svg,

  /// Mermaid 图（流程图/时序图/甘特图/时间线/思维导图等），源码即 Mermaid 文本，
  /// 预览时包一层 HTML 交给 WebView 用本地打包的 mermaid 渲染
  mermaid,

  /// CSV/TSV 表格，原生表格预览（排序/搜索），源码可编辑
  csv,

  /// JSON 文件，支持一键格式化
  json,

  /// 其他代码文件（js/css/py/sql 等），等宽字体源码查看
  code,
}

class NoteFileTypeHelper {
  const NoteFileTypeHelper._();

  /// 代码类扩展名集合（小Q 等工具可能写入的常见文本代码格式）
  static const Set<String> _codeExtensions = {
    'js', 'jsx', 'ts', 'tsx', 'css', 'scss', 'less', //
    'py', 'java', 'kt', 'kts', 'swift', 'dart', //
    'c', 'h', 'cpp', 'hpp', 'cs', 'go', 'rs', 'rb', 'php', //
    'sh', 'bash', 'bat', 'ps1', 'sql', 'xml', 'yml', 'yaml', //
    'toml', 'ini', 'lua', 'r', //
  };

  /// 按标题后缀识别文件类型；无后缀或未识别的后缀视为 Markdown
  static NoteFileType fromTitle(String title) {
    final ext = extensionOf(title);
    if (ext == null) return NoteFileType.markdown;
    switch (ext) {
      case 'html':
      case 'htm':
        return NoteFileType.html;
      case 'svg':
        return NoteFileType.svg;
      case 'mmd':
      case 'mermaid':
        return NoteFileType.mermaid;
      case 'csv':
      case 'tsv':
        return NoteFileType.csv;
      case 'json':
        return NoteFileType.json;
      default:
        return _codeExtensions.contains(ext) ? NoteFileType.code : NoteFileType.markdown;
    }
  }

  /// 取标题末尾的文件后缀（小写、不含点）；无有效后缀返回 null
  static String? extensionOf(String title) {
    final name = title.trim();
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  /// 标题是否已带 App 认识的文件后缀（文档类或代码类）。
  ///
  /// 供 VFS 判定「列出/写入路径时是否还需要补 `.md`」——否则标题 `架构图.mmd`
  /// 会被无脑拼成 `架构图.mmd.md`，小Q 据此改写就会落到错路径。
  static bool hasRecognizedExtension(String title) {
    final ext = extensionOf(title);
    if (ext == null) return false;
    return _documentExtensions.contains(ext) || _codeExtensions.contains(ext);
  }

  /// 是否支持渲染预览（可在预览与源码之间切换）
  ///
  /// `.json` 不做专属预览（移动端树视图对用户没有实际价值）：打开即源码，
  /// 靠 AppBar 的「格式化 JSON」按钮整理结构。
  static bool supportsPreview(NoteFileType type) => switch (type) {
    NoteFileType.html || NoteFileType.svg || NoteFileType.mermaid || NoteFileType.csv => true,
    _ => false,
  };

  /// 打开笔记时是否默认进入渲染预览（仍可一键切回源码）
  static bool prefersPreviewByDefault(NoteFileType type) => supportsPreview(type);

  /// 是否按源码类内容处理：
  /// 等宽字体显示、不做 Markdown 行内渲染与 URL 自动拆分（html/svg/json/code 等）
  static bool isCodeLike(NoteFileType type) => type != NoteFileType.markdown;

  /// 文档类后缀集合（非 Markdown 正文，App 有专属预览或纯源码展示）
  static const Set<String> _documentExtensions = {
    'md', 'markdown', 'html', 'htm', 'svg', 'mmd', 'mermaid', 'csv', 'tsv', 'json', //
  };
}

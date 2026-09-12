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
    final name = title.trim();
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return NoteFileType.markdown;
    final ext = name.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'html':
      case 'htm':
        return NoteFileType.html;
      case 'svg':
        return NoteFileType.svg;
      case 'json':
        return NoteFileType.json;
      default:
        return _codeExtensions.contains(ext)
            ? NoteFileType.code
            : NoteFileType.markdown;
    }
  }

  /// 是否按源码类内容处理：
  /// 等宽字体显示、不做 Markdown 行内渲染与 URL 自动拆分（html/svg/json/code）
  static bool isCodeLike(NoteFileType type) => type != NoteFileType.markdown;
}

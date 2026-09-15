/// 面向用户的简短更新日志，发布新版本时在列表头部追加即可。
class ChangelogEntry {
  final String version;
  final String date;
  final List<String> notes;

  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.notes,
  });
}

/// 最近几个版本的更新日志，按版本倒序排列。
const List<ChangelogEntry> kAppChangelog = [
  ChangelogEntry(
    version: '0.1.36',
    date: '2026-09-15',
    notes: [
      '时间线卡片标签优化，运动子类型与指标胶囊化展示',
      '修复睡眠分期详情外层卡片不可见问题',
      '小米运动健康界面极简重构，内置日期切换与体征面板',
      '支持按需补拉历史日期健康数据',
    ],
  ),
  ChangelogEntry(
    version: '0.1.35',
    date: '2026-09-15',
    notes: [
      '原生接入小米运动健康云端协议，支持扫码免密授权',
      '运动与睡眠记录自动同步并沉淀为时间线专属卡片',
      '数据统计中心扩展「体征」监测独立仪表盘',
      '小Q Agent深度融合健康数据，支持客观指标AI每日复盘',
    ],
  ),
  ChangelogEntry(
    version: '0.1.34',
    date: '2026-09-15',
    notes: [
      '悬浮球面板打开时常驻可见，支持对话内容引用给小Q',
      '饮食评价扩充为健康/一般/不健康/过于放纵四档',
      '统计评分接入小Q，支持AI直接评估全天生活质量并打分',
      '设置界面精简，移除冗余副标题说明',
    ],
  ),
  ChangelogEntry(
    version: '0.1.33',
    date: '2026-09-14',
    notes: [
      'APK更新接入分片并发下载引擎，大幅提速',
      '更新弹窗新增实时下载网速与预计剩余时间',
      '待办编辑胶囊按钮紧凑化，文案精简',
    ],
  ),
  ChangelogEntry(
    version: '0.1.32',
    date: '2026-09-14',
    notes: [
      '待办编辑弹窗重构为全圆角悬浮卡片与圆形完成按钮',
      '小Q人格预设卡片选中态通透微光重设计',
      '停止按钮LoadingRing细线精致化',
      '修复悬浮球靠边折叠态点击难以触发的问题',
    ],
  ),
  ChangelogEntry(
    version: '0.1.31',
    date: '2026-09-14',
    notes: [
      '桌面小组件快速记录弹窗输入框与图片内嵌一体化，防键盘遮挡',
      '仿小米待办全新交互：底部大弹窗编辑、回车连续添加、已完成折叠',
      '小Q设置一体化（个性/技能/记忆三合一）与动效升级',
    ],
  ),
  ChangelogEntry(
    version: '0.1.30',
    date: '2026-09-14',
    notes: [
      '悬浮球静置靠边半折叠与拖拽磁吸贴边动画',
      '设置界面精简，移除冗余副标题说明与宣传横幅',
      '时间线模型选择支持6大内置免费模型',
      '小Q最大工作轮次由20升至60',
    ],
  ),
  ChangelogEntry(
    version: '0.1.29',
    date: '2026-09-13',
    notes: [
      '修复编辑日记备注时内容变空的问题',
      'AI提取图片注解去重',
      '停止按钮主题色流光重塑',
    ],
  ),
  ChangelogEntry(
    version: '0.1.28',
    date: '2026-09-13',
    notes: [
      '小Q任务绑定发起会话，切走继续后台跑、切回恢复流式',
      '历史会话列表生成中显示转圈动画',
      '时间线标准分类标签体系规整',
    ],
  ),
  ChangelogEntry(
    version: '0.1.27',
    date: '2026-09-12',
    notes: [
      '发送按钮工作态流光动效',
      '修复第三方分享图片重复的问题',
      '悬浮面板长按可切换模型',
    ],
  ),
];

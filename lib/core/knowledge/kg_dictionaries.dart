import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 规则抽取命中的实体候选。
class KgEntityCandidate {
  final String name;
  final String type;

  /// 命中的字段/词典来源，写入提及的 `field` 便于回溯
  final String field;

  const KgEntityCandidate({required this.name, required this.type, this.field = 'dictionary'});
}

/// 个人生活图谱的轻量词典与字段映射。
///
/// 不追求覆盖所有词汇：词典只负责「高精度、可解释」的常见实体，未知实体交给
/// 笔记/日记的可选 LLM 语义抽取。词典匹配按最长词优先，避免「奶茶」里再命中「茶」。
abstract final class KgDictionaries {
  /// 词典命中的实体名过滤：纯泛词/时间词不建节点
  static const Set<String> stopwords = {
    '今天',
    '昨天',
    '明天',
    '早上',
    '上午',
    '中午',
    '下午',
    '晚上',
    '夜里',
    '凌晨',
    '最近',
    '现在',
    '时候',
    '感觉',
    '有点',
    '比较',
    '真的',
    '还是',
    '可能',
    '应该',
    '需要',
    '东西',
    '事情',
    '问题',
    '记录',
    '时间',
    '之后',
    '之前',
    '然后',
    '而且',
    '但是',
    '因为',
    '所以',
    '如果',
    '就是',
    '一个',
    '一些',
    '这个',
    '那个',
    '自己',
    '大家',
    '别人',
    '其他',
    '一般',
    '正常',
    '还好',
    '不错',
    '可以',
    '没有',
    '很多',
    '一点',
    '一下',
    '这里',
    '那里',
    '什么',
    '怎么',
    '为什么',
    '如何',
  };

  /// 饮食渠道/形态词：它们是「怎么吃」而不是「吃了什么」，归 topic 而不是 food
  static const Set<String> dietContextWords = {
    '自制',
    '外卖',
    '堂食',
    '零食',
    '水果',
    '饮品',
    '补剂',
    '正餐',
    '夜宵',
    '早餐',
    '午餐',
    '晚餐',
    '加餐',
  };

  static final List<_KgDictionaryTerm> _terms = _buildTerms();

  /// 从自由文本中匹配已知实体。
  ///
  /// [limit] 控制单篇文档的实体数，防止长笔记一次抽出上百个泛词；
  /// [exclude] 用于跳过当前源记录自身标题等自我指涉。
  static List<KgEntityCandidate> matchText(String text, {int limit = 30, Set<String> exclude = const {}}) {
    if (text.trim().isEmpty) return const [];
    final lower = text.toLowerCase();
    final matched = <_KgSpan>[];
    final seenNames = <String>{};

    for (final term in _terms) {
      if (seenNames.length >= limit) break;
      if (exclude.contains(term.name)) continue;
      var start = lower.indexOf(term.lower);
      while (start >= 0 && seenNames.length < limit) {
        // 「没有头痛」「不跑步」「无发热」不是一次真实发生，不能进图谱
        if (_isNegated(lower, start)) {
          start = lower.indexOf(term.lower, start + 1);
          continue;
        }
        final end = start + term.lower.length;
        final overlaps = matched.any((span) => start < span.end && end > span.start);
        if (!overlaps) {
          matched.add(_KgSpan(start: start, end: end, term: term));
          seenNames.add(term.name);
          break;
        }
        start = lower.indexOf(term.lower, start + 1);
      }
    }

    matched.sort((a, b) => a.start.compareTo(b.start));
    return matched.take(limit).map((span) => KgEntityCandidate(name: span.term.name, type: span.term.type)).toList();
  }

  /// 把标签字段值归一成实体候选。
  ///
  /// 只处理语义明确的字段：症状/用药/活动类型/支出类型/饮食条目；严重程度、
  /// 金额、热量等是度量值，写入源节点 metadata，不建实体。
  static List<KgEntityCandidate> fromTagField({
    required String tagId,
    required String fieldId,
    required dynamic value,
  }) {
    final rawValues = value is List ? value.map((e) => e.toString()) : [value.toString()];
    final result = <KgEntityCandidate>[];
    for (final raw in rawValues) {
      final text = raw.trim();
      if (text.isEmpty || stopwords.contains(text)) continue;
      switch (tagId) {
        case 'health':
        case '健康':
          if (fieldId == 'symptom' || fieldId == '症状') {
            result.add(KgEntityCandidate(name: text, type: KgEntityType.symptom, field: fieldId));
          } else if (fieldId == 'medication' || fieldId == '用药') {
            result.add(KgEntityCandidate(name: text, type: KgEntityType.medication, field: fieldId));
          }
        case 'activity':
        case '活动':
          if (fieldId == 'type' || fieldId == '类型') {
            final type = text == '运动' ? KgEntityType.sport : KgEntityType.activity;
            result.add(KgEntityCandidate(name: text, type: type, field: fieldId));
          }
        case 'diet':
        case '饮食':
          if (fieldId == 'item' || fieldId == 'type' || fieldId == '种类' || fieldId == '类别') {
            final type = dietContextWords.contains(text) ? KgEntityType.topic : KgEntityType.food;
            result.add(KgEntityCandidate(name: text, type: type, field: fieldId));
          }
        case 'consumption':
        case '记账':
          if (fieldId == 'type' || fieldId == '支出类型' || fieldId == 'incomeType' || fieldId == '收入类型') {
            result.add(KgEntityCandidate(name: text, type: KgEntityType.topic, field: fieldId));
          }
        case 'thought':
        case '随想':
          // 随想没有字段；情绪/主题由正文词典匹配
          break;
      }
    }
    return result;
  }

  /// 该标签字段是否应该跳过（度量值/枚举值）
  static bool isMetricField(String fieldId) {
    return const {
      'duration',
      'calories',
      'amount',
      'severity',
      'rating',
      'quality',
      'fallAsleepTime',
      'mood',
      'time',
      'status',
    }.contains(fieldId);
  }

  static List<_KgDictionaryTerm> _buildTerms() {
    final terms = <_KgDictionaryTerm>[];
    void add(String type, List<String> names) {
      for (final name in names) {
        final trimmed = name.trim();
        if (trimmed.length < 2 || stopwords.contains(trimmed)) continue;
        terms.add(_KgDictionaryTerm(name: trimmed, lower: trimmed.toLowerCase(), type: type));
      }
    }

    add(KgEntityType.food, const [
      '米饭',
      '面条',
      '拉面',
      '炒饭',
      '盖饭',
      '馒头',
      '包子',
      '饺子',
      '粥',
      '火锅',
      '烧烤',
      '炸鸡',
      '汉堡',
      '披萨',
      '薯条',
      '薯片',
      '蛋糕',
      '面包',
      '饼干',
      '巧克力',
      '冰淇淋',
      '苹果',
      '香蕉',
      '橙子',
      '西瓜',
      '葡萄',
      '草莓',
      '蓝莓',
      '芒果',
      '梨',
      '桃子',
      '樱桃',
      '番茄',
      '西红柿',
      '黄瓜',
      '生菜',
      '白菜',
      '菠菜',
      '西兰花',
      '胡萝卜',
      '土豆',
      '红薯',
      '玉米',
      '鸡蛋',
      '鸡肉',
      '牛肉',
      '猪肉',
      '羊肉',
      '鱼肉',
      '虾',
      '螃蟹',
      '豆腐',
      '香菇',
      '蘑菇',
      '木耳',
      '海带',
      '坚果',
      '花生',
      '核桃',
      '三明治',
      '寿司',
      '麻辣烫',
      '螺蛳粉',
      '米线',
      '煎饼',
      '油条',
      '沙拉',
      '燕麦',
      '酸奶',
      '芝士',
      '奶油',
      '培根',
      '香肠',
      '火腿',
      '披萨饼',
    ]);
    add(KgEntityType.drink, const [
      '牛奶',
      '豆浆',
      '咖啡',
      '拿铁',
      '美式',
      '卡布奇诺',
      '摩卡',
      '奶茶',
      '珍珠奶茶',
      '可乐',
      '雪碧',
      '果汁',
      '啤酒',
      '红酒',
      '白酒',
      '绿茶',
      '红茶',
      '乌龙茶',
      '矿泉水',
      '气泡水',
      '能量饮料',
      '运动饮料',
      '豆奶',
    ]);
    add(KgEntityType.symptom, const [
      '头痛',
      '头晕',
      '恶心',
      '呕吐',
      '腹泻',
      '便秘',
      '胃痛',
      '胃胀',
      '腹痛',
      '发烧',
      '发热',
      '咳嗽',
      '喉咙痛',
      '咽痛',
      '鼻塞',
      '流鼻涕',
      '打喷嚏',
      '过敏',
      '皮疹',
      '失眠',
      '嗜睡',
      '疲劳',
      '乏力',
      '心慌',
      '胸闷',
      '气短',
      '腰痛',
      '背痛',
      '肩颈痛',
      '关节痛',
      '牙痛',
      '眼睛干涩',
      '焦虑',
      '情绪低落',
      '抑郁',
      '烦躁',
    ]);
    add(KgEntityType.medication, const [
      '布洛芬',
      '对乙酰氨基酚',
      '阿司匹林',
      '感冒药',
      '退烧药',
      '止痛药',
      '消炎药',
      '抗生素',
      '维生素c',
      '维生素d',
      '鱼油',
      '钙片',
      '益生菌',
      '褪黑素',
      '蒙脱石散',
      '奥美拉唑',
      '氯雷他定',
      '感冒灵',
      '连花清瘟',
    ]);
    add(KgEntityType.activity, const [
      '工作',
      '学习',
      '运动',
      '社交',
      '娱乐',
      '通勤',
      '家务',
      '休息',
      '阅读',
      '写作',
      '编程',
      '开会',
      '加班',
      '上课',
      '复习',
      '考试',
      '看电影',
      '追剧',
      '游戏',
      '逛街',
      '旅行',
      '做饭',
      '打扫',
      '整理',
      '冥想',
      '聊天',
      '聚会',
    ]);
    add(KgEntityType.sport, const [
      '跑步',
      '慢跑',
      '快走',
      '散步',
      '骑行',
      '游泳',
      '健身',
      '瑜伽',
      '力量训练',
      '撸铁',
      '跳绳',
      '爬山',
      '徒步',
      '篮球',
      '足球',
      '羽毛球',
      '乒乓球',
      '网球',
      '拳击',
      '普拉提',
      '拉伸',
    ]);
    add(KgEntityType.emotion, const [
      '开心',
      '快乐',
      '高兴',
      '满足',
      '幸福',
      '兴奋',
      '平静',
      '放松',
      '焦虑',
      '紧张',
      '压力',
      '烦躁',
      '生气',
      '愤怒',
      '难过',
      '伤心',
      '委屈',
      '失落',
      '孤独',
      '无聊',
      '疲惫',
      '迷茫',
      '期待',
      '感恩',
    ]);
    add(KgEntityType.place, const [
      '公司',
      '办公室',
      '学校',
      '医院',
      '超市',
      '商场',
      '餐厅',
      '咖啡馆',
      '健身房',
      '公园',
      '图书馆',
      '地铁',
      '机场',
      '车站',
      '银行',
      '药店',
    ]);

    // 长词优先：先匹配「珍珠奶茶」再匹配「奶茶」
    terms.sort((a, b) {
      final byLength = b.name.length.compareTo(a.name.length);
      return byLength != 0 ? byLength : a.name.compareTo(b.name);
    });
    return terms;
  }
}

/// 判断命中词前 4 个字符内是否有否定词。
///
/// 只做高精度短窗口判断：「没有/没/不/无/未/别/并非/不是/否认」。
/// 无法处理复杂双重否定，但能挡住「没有头痛」「今天没跑步」这类最常见误报。
bool _isNegated(String text, int start) {
  if (start <= 0) return false;
  final prefixStart = start - 4 < 0 ? 0 : start - 4;
  final prefix = text.substring(prefixStart, start);
  return RegExp(r'(没有|没|不|无|未|别|并非|不是|否认)').hasMatch(prefix);
}

class _KgDictionaryTerm {
  final String name;
  final String lower;
  final String type;

  const _KgDictionaryTerm({required this.name, required this.lower, required this.type});
}

class _KgSpan {
  final int start;
  final int end;
  final _KgDictionaryTerm term;

  const _KgSpan({required this.start, required this.end, required this.term});
}

// 字幕清洗层（v1.28）。
//
// 用户的原话是「文字截取感觉不智能、有的是识别不准」。我把真实日志摊开逐行
// 看过之后发现：真正扎眼的**不全是识别错**，而是三类东西被当成做菜步骤塞了
// 进去，而且塞得很难看：
//
//   ① 锅具广告水印被当成字幕
//      「Royalstar荣事达」「余事达」「MAX L」「两用连樓體熄火保护」
//      「高效节能 灣高效1」「二点不着你」——全是锅的广告词，混进了步骤里。
//   ② 同一条字幕被 OCR 读成六七个错版，然后**全部拼进同一步**
//      日志第 12 步有 200 多字，就是「生抽40g(薄盐,正常咸度的生抽减少至
//      25-30g)」这一行被读了 6 遍拼起来的结果。
//   ③ 纯乱码行：「(*」「ā80g」「ö) a80g」「D6a80g」「請水EOn」
//
// 这一层的职责就是挡住这三类，并且**在多个错版里挑出最靠谱的那一条**——
// 不是像以前那样「见到重复就丢掉第一条」，因为丢掉的往往恰好是最准的那条。
//
// 诚实边界：这是规则清洗，能挡掉可枚举的脏东西，挡不掉「模型听不清」。
// 认不出来的字，这里不会编一个出来。
import 'kitchen_lexicon.dart';

class SubtitleClean {
  SubtitleClean._();

  /// 广告 / 品牌 / 产品包装词。
  ///
  /// 为什么认得这么细：抖音美食视频里锅具、调味料的广告贴片常年挂在画面上，
  /// OCR 分不清「这是字幕」还是「这是包装上的字」，一视同仁全读出来。
  /// 这些词在做菜步骤里**永远不可能出现**，命中即判广告。
  static const List<String> _adWords = <String>[
    // 锅具品牌（用户这段视频里的）
    'Royalstar', '荣事达', '余事达', 'SUPOR', '苏泊尔', '九阳', '美的', '爱仕达',
    // 电器卖点
    '熄火保护', '高效节能', '不粘', '涂层', '导热', '受热均匀', '燃氣灶', '燃气灶',
    // 包装 / 标签
    '净含量', '保质期', '生产日期', '配料表', '执行标准', '食品添加剂', '贮存',
    '厂名', '厂址', '产地', '联系电话', '条形码', '固形物', '含量不低于',
    '野生采集', '原生态', '无添加', '零添加', '精选原料', '传统工艺', '生食',
    // 电商 / 引导
    '旗舰店', '同款', '点击', '下单', '购买链接', '淘宝', '天猫', '京东', '拼多多',
    '关注我', '双击', '点个赞',
  ];

  /// 包装标签的模糊形态。
  ///
  /// OCR 读瓶子上的小字从不准：「净含量」被读成「净会量」、「固形物含量」被读成
  /// 「团形物含量」、「保质期至」被读成「保医期至」。这些字逐一对不上词表，
  /// 但形态有规律，用正则抓比穷举词更靠谱。
  static final List<RegExp> _adPatterns = <RegExp>[
    RegExp(r'净.{0,2}量'), // 净含量 / 净会量
    RegExp(r'含.{0,2}量'), // 固形物含量 / 团形物含量
    RegExp(r'保.{0,2}[期质]'), // 保质期 / 保医期至
    RegExp(r'生产[日许]'), // 生产日期 / 生产许可
    RegExp(r'喷码|运码'), // 见喷码
    RegExp(r'执行标准'),
    RegExp(r'SC\d{6,}'), // 食品生产许可证号
  ];

  /// 广告行判定：命中品牌词，或是「纯大写英文/数字」这种贴片字。
  static bool isAdLine(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    final low = t.toLowerCase();
    for (final w in _adWords) {
      if (low.contains(w.toLowerCase())) return true;
    }
    for (final p in _adPatterns) {
      if (p.hasMatch(t)) return true;
    }
    // 「MAX L」「MAN」「MAX」这种：全是英文大写 + 数字 + 空格，没有汉字
    if (!RegExp(r'[\u4e00-\u9fa5]').hasMatch(t) &&
        RegExp(r'^[A-Za-z0-9\s\.\-_/:]{2,12}$').hasMatch(t)) {
      return true;
    }
    return false;
  }

  /// 乱码行判定：汉字太少、符号/英文太多。
  ///
  /// 阈值是照着日志里的真实数据调的：
  ///   「(*」→ 没汉字，丢
  ///   「ā80g」→ 没汉字，丢
  ///   「請水EOn」→ 3 个汉字 3 个字母，字母占比过高，丢
  ///   「再稍微煎一煎」→ 6 汉字 0 符号，留
  ///   「生抽40g」→ 2 汉字 + 数字单位，属于正常配料行，**不能**误杀
  static bool isGarbageLine(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    final compact = t.replaceAll(RegExp(r'\s'), '');
    final han = RegExp(r'[\u4e00-\u9fa5]').allMatches(compact).length;
    final latin = RegExp(r'[A-Za-z]').allMatches(compact).length;
    final digit = RegExp(r'[0-9]').allMatches(compact).length;
    final sym = compact.length - han - latin - digit;

    if (han == 0) return true; // 一个汉字都没有，不可能是中文做菜步骤
    // 汉字只有 1~2 个，而英文+符号比汉字还多 → 乱码
    if (han <= 2 && latin + sym > han) return true;
    // 符号数量远超汉字（正常字幕里符号不该比汉字多一倍）
    if (sym > han * 2) return true;
    return false;
  }

  /// 剥离括号里的解释性内容。
  ///
  /// 「生抽40g(薄盐,正常咸度的生抽减少至25-30g)」→「生抽40g」
  /// 括号里是作者对「薄盐生抽要减量」的补充说明，不是主料用量。
  /// 留着它有两个坏处：步骤变长变糊；用量抽取会把 25-30g 当成生抽的量。
  ///
  /// 只剥**长括号**（>4 字），短的如「(约)」这种留着不碍事。
  static String stripComment(String text) {
    var s = text;
    s = s.replaceAllMapped(RegExp(r'[（(]([^）)]*)[）)]'), (m) {
      final inner = m.group(1) ?? '';
      return inner.trim().length > 4 ? '' : m.group(0)!;
    });
    // 括号只读到左半边（OCR 常漏掉右括号）：从「(」处整段截断。
    // 日志里的真实例子：「生抽40g (薄盐，正常咸虔的轴减少至25-30元」——
    // 后面全是作者对薄盐生抽的补充说明，不截断就跟着进度条一样长。
    final open = s.indexOf(RegExp(r'[（(]'));
    if (open > 0) {
      final rest = s.substring(open);
      if (!rest.contains(RegExp(r'[）)]'))) {
        s = s.substring(0, open);
      }
    }
    return s.trim();
  }

  /// 把「六个错版里最靠谱的那条」挑出来。
  ///
  /// 打分逻辑（分数只用来排序，绝对值没意义）：
  ///   + 汉字数（封顶 8，避免长垃圾串靠字多取胜）
  ///   + 每个规范「数字 + 单位」×6   ← 最关键的信号：OCR 数字容易错，
  ///     但一旦读成规范写法（25g、1根、20g），基本就是对的
  ///   + 每个「中文数字 + 计数单位」×6（两个鸡蛋、一根小米辣）
  ///   − 残留符号扣分
  ///   − 长度超 24 字按超标长度扣分（说明是多个错版被拼在一起了）
  /// 同分时取更短的那条（更短 = 更可能是原始字幕，长的是拼接产物）。
  static int score(String text) {
    final t = stripComment(text);
    if (t.isEmpty) return -999;
    final han = RegExp(r'[\u4e00-\u9fa5]').allMatches(t).length;
    var s = han > 8 ? 8 : han;

    s += RegExp(r'\d+(?:\.\d+)?\s*(?:g|克|ml|毫升|个|根|只|片|勺|瓣|颗|斤|两|把|袋|包|碗|杯)')
            .allMatches(t)
            .length *
        6;
    s += RegExp(r'[一二两三四五六七八九十半]+\s*(?:个|根|只|片|勺|瓣|颗|把|袋|包|碗|杯)')
            .allMatches(t)
            .length *
        6;
    s -= RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9\s，。、,\.\-~～%]').allMatches(t).length * 2;
    if (t.length > 24) s -= (t.length - 24) ~/ 4;
    // v1.43.1：补上「语义证据」。以前两个错版只差一个字的对错时，
    // 两者汉字数、数字单位、符号分几乎一样，只能靠字频猜；现在命中了
    // 规范调料词的那条多拿分，例如「小米辣」压过「小米鎌」。
    s += KitchenLexicon.semanticScore(t);
    return s;
  }

  /// 从一组「说的同一句话」的变体里选代表。
  static String pickBest(List<String> variants) {
    if (variants.isEmpty) return '';
    if (variants.length == 1) return stripComment(variants[0]);
    var best = variants.first;
    var bestScore = score(best);
    for (var i = 1; i < variants.length; i++) {
      final v = variants[i];
      final sc = score(v);
      if (sc > bestScore ||
          // 同分取更短的（长的大概率是错版拼接）
          (sc == bestScore && stripComment(v).length < stripComment(best).length)) {
        best = v;
        bestScore = sc;
      }
    }
    return stripComment(best);
  }

  /// 繁简混用归一。
  ///
  /// OCR 同一个字在不同帧能读出简体也能读出繁体：「虾肉清新鮮嫩」和
  /// 「虾肉清新鲜燉」在日志里是同一句话的两帧，但「鮮/鲜」不是同一个字符，
  /// 相似度算下来只有 0.5，永远认不出是一句。统一成简体再比就正常了。
  ///
  /// 只收「简体唯一对应」的常用字，不做通用繁简转换。
  static const Map<String, String> _variant = <String, String>{
    '鮮': '鲜', '燉': '炖', '蝦': '虾', '魚': '鱼', '雞': '鸡', '豬': '猪',
    '麵': '面', '鹽': '盐', '醬': '酱', '蘿': '萝', '蔥': '葱', '薑': '姜',
    '湯': '汤', '飯': '饭', '滷': '卤', '燜': '焖', '燒': '烧', '鍋': '锅',
    '醃': '腌', '灑': '撒', '絲': '丝', '條': '条', '塊': '块', '顆': '颗',
    '個': '个', '兩': '两', '盤': '盘', '爐': '炉', '煙': '烟',
  };

  static String toSimplified(String text) {
    if (text.isEmpty) return text;
    var s = text;
    _variant.forEach((from, to) {
      if (s.contains(from)) s = s.replaceAll(from, to);
    });
    return s;
  }

  /// 中文数字 → 阿拉伯数字（只支持 0~9999，够覆盖厨房用量）。
  ///
  /// 为什么要它：口播常说「准备六百五十克的大虾」，而抓用量的正则只认
  /// 阿拉伯数字，于是这句里的 650g 就丢了，用料表上大虾后面空着。
  static int? cnToInt(String s) {
    const digits = <String, int>{
      '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    if (s.isEmpty) return null;
    var total = 0;
    var section = 0;
    var number = 0;
    for (final ch in s.split('')) {
      if (digits.containsKey(ch)) {
        number = digits[ch]!;
      } else if (ch == '十') {
        section += (number == 0 ? 1 : number) * 10;
        number = 0;
      } else if (ch == '百') {
        section += (number == 0 ? 1 : number) * 100;
        number = 0;
      } else if (ch == '千') {
        section += (number == 0 ? 1 : number) * 1000;
        number = 0;
      } else if (ch == '半') {
        // 「半勺」「半碗」不转数字，交给原样保留
        return null;
      } else {
        return null;
      }
    }
    total = section + number;
    return total == 0 && !s.contains('零') && !s.contains('〇') ? null : total;
  }

  // ── 量词单位归一（v1.29） ──
  //
  // OCR 最系统性的一个错：把数字后面的「g」读成「8 / A / p / 元 / ä」。
  // 真实日志里同一份菜谱出现四种写法：
  //   大葱208。  大葱20g   白糖108   白糖10A   减少至25-30元
  // 这不是随机噪声（随机噪声靠投票能压掉），而是**字形上真的有够像**：
  // 8 和 g 在小字号下几乎同形，A 是 g 的下半截，p 是 g 的镜像。
  //
  // 所以单独做一层：先把整份字幕里「数字+g」和「数字+可疑字符」都数一遍，
  // 证据够了才动手改。只改「数字串尾部」这一个位置，且后面不能跟量词 ——
  // 「1-8个」「10分8秒」这种是真的数字，不能碰。

  /// 被误认成 g 的字符。全部来自真实日志。
  static const String _fakeUnitChars = '8AapP元EeäöB';

  /// 「数字 + 可疑单位字符」的模式。用上面那张字符表拼出来，改表即生效。
  static final RegExp _fakeUnitRe =
      RegExp('(\\d{1,3})([$_fakeUnitChars])(?![0-9A-Za-z])');

  /// 紧跟在这些字后面的数字是真的数量，不是「数字+g」。
  static const String _measureChars = '个根只片克斤两勺瓣颗把袋包碗杯秒分度成倍层张条块滴升步';

  /// 整份字幕层面的单位归一。返回改好的行，[hits] 收到改了几处。
  ///
  /// 为什么要有「证据门槛」：如果这份视频压根没有 g 这个单位（比如全是
  /// 「两个鸡蛋」「一根葱」），把「108」改成「10g」就是凭空造单位。
  /// 只有同时满足「数字+g ≥ 3 处」和「可疑写法 ≥ 2 处」才认定这视频在用 g。
  static List<String> normalizeUnits(List<String> lines, {List<String>? hits}) {
    if (lines.isEmpty) return lines;
    final fakeRe = _fakeUnitRe;
    final goodRe = RegExp(r'\d{1,3}\s*[gG](?![0-9A-Za-z])');
    var good = 0;
    var bad = 0;
    for (final l in lines) {
      good += goodRe.allMatches(l).length;
      bad += fakeRe.allMatches(l).length;
    }
    if (good < 3 || bad < 2) return lines;

    var count = 0;
    final out = List<String>.generate(lines.length, (i) {
      final l = lines[i];
      return l.replaceAllMapped(fakeRe, (m) {
        final end = m.end;
        // 「1-8个」的 8 后面是量词 → 这是真数字，别动
        if (end < l.length && _measureChars.contains(l[end])) {
          return m.group(0)!;
        }
        count++;
        return '${m.group(1)}g';
      });
    });
    if (count > 0 && hits != null) {
      hits.add('数字后的 8/A/p/元 → g 共 $count 处');
    }
    return out;
  }

  // ── 数字 + 「勺」的形近误认（v1.44） ──
  //
  // 逐行诊断 2026-11-15 日志发现，调料行错得最狠，而且错在同一个地方：
  //   「1河老抽」  ← 应是 1勺老抽
  //   「再票小句水稀联我匀调一地」 ← 应是 再来小勺水稀释搅匀一勺
  // 数字后面跟着「河 / 句 / 勾」，OCR 把「勺」认成了形近字。
  // 和 g 那套一样：整份字幕得先有规范「数字+勺」作证才动手，
  // 否则这份视频可能压根不用勺（全是克、个、根），改了就是凭空造单位。

  /// 被误认成「勺」的字符，全部来自真实日志。
  /// 「河」只在数字后出现才改（「小河」可能是真词，不能碰）；
  /// 「句 / 勾」另外支持「小句 / 小勾」→「小勺」，因为日志里的原句就是
  /// 「再票小句水稀联我匀调一地」（应是「再来小勺水稀释搅匀一勺」），
  /// 这类错字前面往往连数字都读错了。
  static const String _fakeSpoonChars = '河句勾';

  static final RegExp _fakeSpoonNumRe =
      RegExp('(\\d{1,3})([$_fakeSpoonChars])(?![0-9A-Za-z])');
  static final RegExp _fakeSpoonSmallRe =
      RegExp(r'(小)([句勾])(?![0-9A-Za-z])');

  /// 整份字幕层面的「勺」单位归一。
  static List<String> normalizeSpoonUnits(
    List<String> lines, {
    List<String>? hits,
  }) {
    if (lines.isEmpty) return lines;
    final goodRe = RegExp(r'(?:\d{1,3}\s*)?小?勺(?![0-9A-Za-z])');
    var good = 0;
    for (final l in lines) {
      good += goodRe.allMatches(l).length;
    }
    if (good < 1) return lines;

    var count = 0;
    final out = <String>[];
    for (final l in lines) {
      final digitFixed = l.replaceAllMapped(_fakeSpoonNumRe, (m) {
        count++;
        return '${m.group(1)}勺';
      });
      final fixed = digitFixed.replaceAllMapped(_fakeSpoonSmallRe, (m) {
        count++;
        return '${m.group(1)}勺';
      });
      out.add(fixed);
    }
    if (count > 0 && hits != null) {
      hits.add('数字后的 河/句/勾 → 勺 共 $count 处'
          '（同份字幕有 $good 处规范「勺」作证）');
    }
    return out;
  }

  /// 把文本里「六百五十克」这类改写成「650克」，便于后续统一抽用量。
  ///
  /// 只转 ≥10 的数：「两个鸡蛋」「一根大葱」「两勺生抽」保留中文，
  /// 那是人话，改成「2个鸡蛋」反而生硬；「六百五十克」转成 650克 才好读。
  /// [hits] 会收到改写的说明，写进日志方便核对。
  static String digitsOf(String text, {List<String>? hits}) {
    return text.replaceAllMapped(
      RegExp(r'([一二两三四五六七八九十百千]{1,6})\s*'
          r'(克|g|毫升|ml|个|根|只|片|瓣|斤|两|袋|包|碗|杯|勺|汤匙|茶匙|把|颗)'),
      (m) {
        final n = cnToInt(m.group(1)!);
        if (n == null || n < 10) return m.group(0)!;
        final rep = '$n${m.group(2)!}';
        hits?.add('${m.group(0)!}→$rep');
        return rep;
      },
    );
  }
}

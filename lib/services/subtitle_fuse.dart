// 多帧投票融合（v1.29）。
//
// 用户的原话是：「视频这个功能很好，文字截取出的感觉不智能，有的识别的不准确。」
//
// 我把 187 秒那条视频的真实 OCR 结果摊开逐行看，发现一个被白白浪费掉的事实：
//
//   OCR 不是只读了一次。90 帧里同一行配料被读了 5~10 次。
//
//   大蒜巧。美 大葱20g
//   大蒜5粒
//   大蒜258。姜Fg大葱208。
//   大蒜258。Eg大20g,
//   大蒜至8,美大葱208。
//
// 五条说的是同一行配料（正确答案「大蒜25g 姜1g 大葱20g」）。五次独立采样，
// 每次认错的字**并不一样** —— 一次把「g」读成「8」，一次把「25」读成「巧」，
// 一次把「姜」读成「美」。错误随机，正确答案稳定。
//
// 所以最该做的不是「事后猜哪条对」，而是把多次采样合起来用。这一层之前的做法
// 恰好是反的：nearDupMask 把第 2~N 条当成「抖动」直接丢掉，只留最先出现的那条。
// 九成的采样信息就这么扔了，而留下的那条往往并不最准。
//
// 这里做三件事：
//   1. 聚簇 —— 先认出「哪几行说的是同一句」。判定除了原来的字面相似度，
//      还加了「配料行互证」（两边都是配料行且汉字重合够多）和「时间邻近」
//      （同一句字幕在相邻帧被读成两个完全不同的样子时，只能靠时间认出来）。
//   2. medoid —— 在簇里选「跟其它版本平均最像」的那条当代表。
//      真值会被所有错版包围（每个错版只错一两个字），所以平均相似度最高的
//      通常就是真值；而按「谁打分高」选容易被长垃圾串骗。
//   3. 投票 —— 长度接近的错版逐字投票，把个别认错的字压掉。
//      投出来的串如果跟代表差太多就整个弃用（防投出怪串）。
//
// 诚实边界：
//   · 投票救得回「多数帧读对了」的字；
//   · 救不回「每一帧都错成同一个样子」的系统性偏差（例如把「g」每帧都读成「8」）。
//     那类交给 SubtitleClean.normalizeUnits 按整份字幕的证据去修；
//   · 也救不回「某一帧根本没读到」—— 那是抽帧密度的事。
import 'kitchen_lexicon.dart';

class SubtitleFuse {
  SubtitleFuse._();

  /// 字面相似度阈值。与 TextSim.nearDupMask 保持一致，免得同一句在两处判得不一样。
  static const double _threshold = 0.72;

  /// 只在「最近这么多簇」里找同伙。太小会漏（同一行配料隔几帧才又读到），
  /// 太大会把几分钟后那句相似但不同的话误吸进来。
  static const int _window = 60;

  /// 长度差超过这个值就不参与逐字投票。
  ///
  /// 长度差太多说明不是同一句的错版（或者中间被拼进了别的东西），
  /// 硬对齐会让字符整体错位，投出来的串比原来更坏。这类留在簇里当旁证，不进票箱。
  static const int _alignLenGap = 3;

  /// 时间贴近的阈值（秒）。同一句字幕通常连续 2~4 秒，跨 2~3 帧。
  static const int _nearSec = 8;

  // 正则全部预编译。这份字幕有上百行、每行要跟几十个簇比，
  // 在循环里现建 RegExp 会白白多出几万次对象分配（实测 40ms 级）。
  static final RegExp _hanRe = RegExp(r'[\u4e00-\u9fa5]');
  static final RegExp _amountRe = RegExp(
      r'\d+\s*(?:g|G|克|ml|ML|毫升|勺|个|根|只|片|粒|瓣|颗|斤|两|把|袋|包|碗|杯)');
  static final RegExp _amountCnRe =
      RegExp(r'[一二两三四五六七八九十半]+\s*(?:个|根|只|片|勺|瓣|颗|粒|把|袋|包|碗|杯)');
  static final RegExp _fakeAmountRe =
      RegExp(r'\d{1,3}[8AapP元](?![0-9A-Za-z])');
  static final RegExp _unitRe = RegExp(
      r'\d+(?:\.\d+)?\s*(?:g|G|克|ml|ML|毫升|个|根|只|片|勺|瓣|颗|粒|斤|两|把|袋|包|碗|杯)');
  static final RegExp _badUnitRe = RegExp(r'\d[8AapP元]\s*(?:[，。、,;；]|$)');
  static final RegExp _symRe =
      RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9\s，。、,\.\-~～%()（）]');
  static final RegExp _alphaRe = RegExp(r'[^\u4e00-\u9fa5A-Za-z]');
  static final RegExp _gramRe = RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]');

  /// 把 [texts] 聚成簇，返回每行的簇号（从 0 开始，按首次出现顺序编号）。
  ///
  /// 和 nearDupMask 的区别只有一点，但很关键：这里**不丢任何一行**，
  /// 只回答「这几行说的是不是同一句」。丢不丢、怎么合成，由 fuseCluster 决定。
  ///
  /// [secs] 给出行对应的时间（秒）。传了才能用「时间邻近」这条信号 ——
  /// 真实数据里「大蒜巧。美 大葱20g」和「大蒜258。姜Fg大葱208。」字面相似度
  /// 只有 0.36，纯字面判永远认不出是同一句，但它们出现在相邻两秒。
  static List<int> clusterIds(
    List<String> texts, {
    List<int>? secs,
    double threshold = _threshold,
    int window = _window,
  }) {
    final ids = List<int>.filled(texts.length, -1);
    // 每个簇的「参考串」：簇里当前质量最高的那条，用来跟后来的行比相似度。
    final refs = <String>[];
    // 每个簇最近一次出现的秒数
    final lastSec = <int>[];

    for (var i = 0; i < texts.length; i++) {
      final t = texts[i];
      final sec = (secs != null && i < secs.length) ? secs[i] : -1;
      var hit = -1;
      final from = refs.length > window ? refs.length - window : 0;
      for (var c = from; c < refs.length; c++) {
        final gap = (sec >= 0 && c < lastSec.length && lastSec[c] >= 0)
            ? (sec - lastSec[c]).abs()
            : null;
        if (_sameLine(t, refs[c], threshold, gap)) {
          hit = c;
          break;
        }
      }
      if (hit >= 0) {
        ids[i] = hit;
        // 新来的这条如果比参考串更靠谱，就升级成新的参考串
        if (_better(t, refs[hit])) refs[hit] = t;
        if (sec >= 0) lastSec[hit] = sec;
      } else {
        refs.add(t);
        lastSec.add(sec);
        ids[i] = refs.length - 1;
      }
    }
    return ids;
  }

  /// 一簇变体 → 一条融合结果。这是整个 v1.29 的核心。
  ///
  /// 步骤：
  ///   1. medoid：选跟其它版本平均最像的那条当参考。
  ///   2. 长度接近的变体按编辑距离对齐到参考上，逐位投票。
  ///   3. 平票时保留参考串的字符（参考本身最接近共识，让它当裁判最稳）。
  ///   4. 投完跟参考比相似度，掉太多就整个退回参考（防投出怪串）。
  static String fuseCluster(
    List<String> variants, {
    Map<String, int>? common,
  }) {
    if (variants.isEmpty) return '';
    if (variants.length == 1) return variants.first;

    // ① 先看有没有「明显更靠谱」的一条。
    //
    // 投票不是万灵药：几条都烂的时候，投票出来的东西可能比任何一条都怪
    // （真实案例：三条错版投出「大蒜至8美美大葱208。」—— 对齐错位把「美」
    // 放了两遍）。所以只有当几条**势均力敌**时才值得投票；只要有一条
    // 明显更靠谱（比如它的数字后面跟着规范的 g，而其它几条跟的是 8），
    // 就直接用它 —— 那本身就是最可信的横向证据。
    final scored = <int>[for (final v in variants) _score(v)];
    var topIdx = 0;
    for (var i = 1; i < variants.length; i++) {
      if (scored[i] > scored[topIdx]) topIdx = i;
    }
    var second = -9999;
    for (var i = 0; i < variants.length; i++) {
      if (i != topIdx && scored[i] > second) second = scored[i];
    }
    if (scored[topIdx] - second >= 3) return variants[topIdx];

    final ref = _medoid(variants, common);
    if (variants.length == 2) {
      // 两条时投票没有意义（一比一，永远平票），原来只能靠「哪个字更常见」
      // 裁决：错字几乎总是罕见字。但字频在两者都只出现一次时也没辙。
      // v1.43.1：先比语义分 —— 「小米辣1根」命中三字专名，
      // 「小米鎌1根」只命中「小米」这个泛词，前者直接胜出；
      // 真平了再退回 medoid，行为不变。
      final sa = KitchenLexicon.semanticScore(variants[0]);
      final sb = KitchenLexicon.semanticScore(variants[1]);
      if (sa != sb) return sa > sb ? variants[0] : variants[1];
      return ref;
    }

    // 票箱：votes[位置] = 该位置上出现过的字符
    final votes = List<List<String>>.generate(ref.length, (_) => <String>[]);
    var voted = 0;
    for (final v in variants) {
      if (v == ref) {
        for (var i = 0; i < ref.length; i++) {
          votes[i].add(ref[i]);
        }
        voted++;
        continue;
      }
      if ((v.length - ref.length).abs() > _alignLenGap) continue;
      final aligned = _align(ref, v);
      for (var i = 0; i < ref.length && i < aligned.length; i++) {
        final c = aligned[i];
        if (c != null) votes[i].add(c);
      }
      voted++;
    }
    if (voted <= 1) return ref;

    final buf = StringBuffer();
    for (var i = 0; i < ref.length; i++) {
      final bucket = votes[i];
      if (bucket.isEmpty) {
        buf.write(ref[i]);
        continue;
      }
      final freq = <String, int>{};
      for (final c in bucket) {
        freq[c] = (freq[c] ?? 0) + 1;
      }
      var best = ref[i];
      var bestN = freq[ref[i]] ?? 0;
      freq.forEach((c, n) {
        // 票多者胜；票数相同时选「整份字幕里更常见」的那个字
        // （错字几乎总是罕见字，见 _medoid 的说明）
        if (n > bestN) {
          best = c;
          bestN = n;
        } else if (n == bestN && bestN > 0 && common != null) {
          if ((common[c] ?? 0) > (common[best] ?? 0)) best = c;
        }
      });
      buf.write(best);
    }
    final fused = buf.toString();

    // 防投出怪串：跟参考差太多就整个不用。
    // 正常错版互相都在 0.6 以上，投完只会更接近真值；
    // 掉到 0.7 以下说明这簇里混进了不相干的行，或者长度错位了。
    if (_sim(fused, ref) < 0.7) return ref;
    return fused;
  }

  /// 选「跟其它版本平均最像」的那条（medoid）。
  ///
  /// 为什么不用「打分最高」：打分只看单条自身（汉字数、单位数量），
  /// 一条把三句拼在一起的长垃圾串也能拿高分。而 medoid 用的是**横向证据**：
  /// 真值会被所有错版包围（每个错版只错一两个字，跟真值都挺像；
  /// 而错版之间可能互相不像），所以平均相似度最高的那条就最可能是真值。
  ///
  /// 平均相似度打平时（两条错版的情况永远打平），用**用词的常见程度**裁决：
  /// OCR 认错的字绝大多数是罕见字（鎌 / 搶 / 團 / 樓），
  /// 而它对应的正确字是这份字幕里反复出现的常用字（辣 / 枪 / 圈 / 漏）。
  /// [common] 是整份字幕的字符频次表，来自 [charFreq]。
  static String _medoid(List<String> vs, Map<String, int>? common) {
    if (vs.length == 1) return vs.first;
    var bestIdx = 0;
    var bestAvg = -1.0;
    for (var i = 0; i < vs.length; i++) {
      var sum = 0.0;
      for (var j = 0; j < vs.length; j++) {
        if (i == j) continue;
        sum += _sim(vs[i], vs[j]);
      }
      final avg = sum / (vs.length - 1);
      if (avg > bestAvg + 1e-9) {
        bestAvg = avg;
        bestIdx = i;
      } else if ((avg - bestAvg).abs() < 1e-9) {
        // 平均相似度打平：先比用词常见程度，再比打分
        final ci = _commonScore(vs[i], common);
        final cb = _commonScore(vs[bestIdx], common);
        if (ci > cb + 1e-9 || ((ci - cb).abs() < 1e-9 && _better(vs[i], vs[bestIdx], common))) {
          bestIdx = i;
        }
      }
    }
    return vs[bestIdx];
  }

  /// 一条串里汉字的「平均常见程度」。越高越像正常中文。
  static double _commonScore(String s, Map<String, int>? common) {
    if (common == null) return 0;
    final han = _hanRe.allMatches(s).map((m) => m.group(0)!).toList();
    if (han.isEmpty) return 0;
    var sum = 0;
    for (final c in han) {
      sum += common[c] ?? 0;
    }
    return sum / han.length;
  }

  /// 整份字幕的字符频次。
  ///
  /// 用途见 [_medoid]：错字几乎都是罕见字，靠这个能把「小米鎌」纠回「小米辣」。
  static Map<String, int> charFreq(List<String> lines) {
    final m = <String, int>{};
    for (final l in lines) {
      for (final c in _hanRe.allMatches(l)) {
        final ch = c.group(0)!;
        m[ch] = (m[ch] ?? 0) + 1;
      }
    }
    return m;
  }

  /// 两行是不是「同一句的不同错版」。
  ///
  /// 三条信号并联，任一命中即算：
  ///   ① 两字组 Jaccard ≥ threshold —— 结构没乱，只是个别字错
  ///   ② 去掉数字后单字集合 Jaccard ≥ 0.8 —— 数字读成乱码但汉字基本对
  ///   ③ 配料行互证 —— 两边都是「食材 + 用量」结构，汉字重合 ≥ 0.55；
  ///      如果时间还贴得很近（≤ 8 秒），放宽到 0.4
  ///
  /// 第 ③ 条是 v1.29 加的，因为它救的是一种真实存在、但前两条永远认不出的情况：
  /// 「大蒜巧。美 大葱20g」和「大蒜258。姜Fg大葱208。」字面相似度只有 0.36，
  /// 却是同一行配料的两个错版（连错的位置都不一样）。
  static bool _sameLine(String a, String b, double threshold, int? secGap) {
    if (a == b) return true;
    if (_sim(a, b) >= threshold) return true;
    final aa = _alpha(a);
    final bb = _alpha(b);
    if (aa.length >= 3 && bb.length >= 3 && _charSim(aa, bb) >= 0.8) {
      return true;
    }
    if (!_isAmountLine(a) || !_isAmountLine(b)) return false;
    final ha = _hanSet(a);
    final hb = _hanSet(b);
    if (ha.isEmpty || hb.isEmpty) return false;
    final inter = ha.intersection(hb).length;
    final j = inter / (ha.length + hb.length - inter);
    // 长句（配料说明那种「生抽40g(薄盐,正常咸度的生抽减少至25-30g)」）阈值放低：
    // 句子越长，一个错字带崩的两字组越多，Jaccard 天然被稀释，
    // 用短句的阈值去卡会永远认不出它们是同一句。
    final longLine =
        _hanRe.allMatches(a).length > 8 || _hanRe.allMatches(b).length > 8;
    var need = longLine ? 0.45 : 0.55;
    // 时间贴得很近（同一句字幕的相邻帧）：再放宽一档
    if (secGap != null && secGap <= _nearSec) need -= 0.1;
    return j >= need;
  }

  /// 是不是一行「配料」：带规范用量写法，且短。
  ///
  /// 只对配料行开第 ③ 条信号，是因为配料行有强结构（食材 + 数字 + 单位），
  /// 而普通台词没有 —— 对台词放宽会误把两句不同的话合成一句。
  static bool _isAmountLine(String t) {
    if (t.length > 24) return false;
    if (_hanRe.allMatches(t).length < 2) return false;
    final hasAmount = _amountRe.hasMatch(t) ||
        _amountCnRe.hasMatch(t) ||
        // 单位本身被 OCR 读错（g→8/A/p/元）也仍然是一行配料。
        // 这一支是必须的：「大蒜258。姜Fg大葱208。」里的 g 全被读成 8，
        // 不认它就会判成「不是配料行」，于是同一行的几个错版永远聚不到一起。
        _fakeAmountRe.hasMatch(t);
    return hasAmount;
  }

  static Set<String> _hanSet(String s) =>
      _hanRe.allMatches(s).map((m) => m.group(0)!).toSet();

  /// 打分更高 = 更可能是真字幕。同分时「更短」胜（长的大概率是多版拼接）。
  static bool _better(String a, String b, [Map<String, int>? common]) {
    final sa = _score(a);
    final sb = _score(b);
    if (sa != sb) return sa > sb;
    if (common != null) {
      final ca = _commonScore(a, common);
      final cb = _commonScore(b, common);
      if ((ca - cb).abs() > 1e-9) return ca > cb;
    }
    return a.length < b.length;
  }

  /// 打分口径跟 SubtitleClean.score 基本一致，但**不剥括号**。
  ///
  /// 为什么不剥：融合发生在清洗之前，这时候剥括号会把「(薄盐…25-30g)」
  /// 里的规范数字一起剥掉，而那段数字恰恰是判断这条对不对的重要依据。
  static int _score(String text) {
    final t = text.trim();
    if (t.isEmpty) return -999;
    final han = _hanRe.allMatches(t).length;
    var s = han > 8 ? 8 : han;
    // 规范「数字+单位」是 OCR 里最可靠的信号：一旦读成 25g、20g，基本就对了
    s += _unitRe.allMatches(t).length * 6;
    s += _amountCnRe.allMatches(t).length * 6;
    // 数字后面跟着 8 / A / p / 元 这种「本该是 g」的写法，扣分
    s -= _badUnitRe.allMatches(t).length * 3;
    s -= _symRe.allMatches(t).length * 2;
    if (t.length > 24) s -= (t.length - 24) ~/ 4;
    // v1.43.1：和 SubtitleClean.score 同一口径，把「是否含规范厨房词」
    // 加进错版打分。这是以前缺的那条语义证据。
    s += KitchenLexicon.semanticScore(t);
    return s;
  }

  /// 编辑距离对齐：返回「参考串每个位置在变体里对应的字符」，null = 变体里没有。
  ///
  /// 为什么必须对齐而不能直接按位置比：错版的长度常常不一样
  /// （「大蒜5粒」5 字 vs「大蒜258。姜Fg大葱208。」14 字），
  /// 直接按下标对会让第三个字之后全部错位，投票就变成了投票给噪音。
  static List<String?> _align(String ref, String s) {
    final n = ref.length;
    final m = s.length;
    // dp[i][j] = ref 前 i 个 与 s 前 j 个 的最小编辑距离
    final dp = List<List<int>>.generate(
      n + 1,
      (_) => List<int>.filled(m + 1, 0),
      growable: false,
    );
    for (var i = 0; i <= n; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= m; j++) {
      dp[0][j] = j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final cost = ref[i - 1] == s[j - 1] ? 0 : 1;
        var v = dp[i - 1][j - 1] + cost;
        if (dp[i - 1][j] + 1 < v) v = dp[i - 1][j] + 1;
        if (dp[i][j - 1] + 1 < v) v = dp[i][j - 1] + 1;
        dp[i][j] = v;
      }
    }
    final out = List<String?>.filled(n, null);
    var i = n;
    var j = m;
    while (i > 0 && j > 0) {
      final cost = ref[i - 1] == s[j - 1] ? 0 : 1;
      if (dp[i][j] == dp[i - 1][j - 1] + cost) {
        out[i - 1] = s[j - 1];
        i--;
        j--;
      } else if (dp[i][j] == dp[i - 1][j] + 1) {
        // 参考串这个字，变体里缺了
        i--;
      } else {
        // 变体多出来一个字（多半是乱码尾巴），丢掉
        j--;
      }
    }
    return out;
  }

  static String _alpha(String s) => s.replaceAll(_alphaRe, '');

  static Set<String> _grams(String s) {
    final x = s.replaceAll(_gramRe, '');
    if (x.isEmpty) return <String>{};
    if (x.length < 2) return <String>{x};
    return {for (var i = 0; i < x.length - 1; i++) x.substring(i, i + 2)};
  }

  static double _sim(String a, String b) {
    final ga = _grams(a);
    final gb = _grams(b);
    if (ga.isEmpty || gb.isEmpty) return 0;
    final inter = ga.intersection(gb).length;
    return inter / (ga.length + gb.length - inter);
  }

  static double _charSim(String a, String b) {
    final sa = a.split('').toSet();
    final sb = b.split('').toSet();
    if (sa.isEmpty || sb.isEmpty) return 0;
    final inter = sa.intersection(sb).length;
    return inter / (sa.length + sb.length - inter);
  }
}

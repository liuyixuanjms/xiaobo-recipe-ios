// 两句话有多像（v1.16）。
//
// 只用在「重新精校之后，把旧步骤的配图搬回新步骤」这一处：
// 重整理会把「把梨切片」改写成「将梨切成薄片」，字面变了但说的是同一件事，
// 按两字组算 Jaccard 相似度，改动一点也认得出是同一步。
//
// 没用编辑距离：步骤文字长度差得远（「翻炒」vs「转大火快速翻炒三十秒上色」），
// 编辑距离会被长度带偏，Jaccard 对长度不敏感。
class TextSim {
  /// 去掉标点、空格、表情，只留中文/字母/数字。
  static String normalize(String s) =>
      s.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');

  /// 两字组集合。单字成句（「炒」）时退化成单元素集合，不返回空。
  static Set<String> _grams(String s) {
    final x = normalize(s);
    if (x.isEmpty) return <String>{};
    if (x.length < 2) return <String>{x};
    return {for (var i = 0; i < x.length - 1; i++) x.substring(i, i + 2)};
  }

  /// 只留中文/字母，去掉数字和标点。
  ///
  /// 为什么去数字：OCR 最不可靠的恰恰是数字和单位 ——
  /// 「大蒜25g」被读成「大蒜258」「大蒜25g0」，两字组相似度会被这些错字拉到 0.4，
  /// 明明是同一条字幕却认不出来。去掉数字后两边都是「大蒜g」，一眼就知道是同一句。
  static String alphaOnly(String s) =>
      s.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z]'), '');

  /// 单字集合的 Jaccard（不看重顺序）。
  ///
  /// 专给 OCR 抖动用：错版往往把「蒜g」读成「蒜姜」，两字组全崩，
  /// 但「出现过哪些字」几乎不变 —— 单字集合对单点插入/替换更宽容。
  static double charJaccard(String a, String b) {
    final sa = alphaOnly(a).split('').toSet();
    final sb = alphaOnly(b).split('').toSet();
    if (sa.isEmpty || sb.isEmpty) return 0;
    final inter = sa.intersection(sb).length;
    return inter / (sa.length + sb.length - inter);
  }

  static double jaccard(String a, String b) {
    final ga = _grams(a);
    final gb = _grams(b);
    if (ga.isEmpty || gb.isEmpty) return 0;
    final inter = ga.intersection(gb).length;
    return inter / (ga.length + gb.length - inter);
  }

  /// 标出「OCR 抖动的近似重复行」（v1.27）。
  ///
  /// 背景：视频画面上那行配料表，在 90 帧里被 OCR 读成了十几个错版
  /// （「大蒜25g 姜1g 大葱20g」→「大蒜258。姜Fg大葱208。」→「大蒜25g,姜1g大葱20g0」）。
  /// 精确去重认不出它们是同一行，于是一份菜谱里这行出现十几遍，
  /// 步骤被切碎、用料越抽越乱。按两字组相似度判断才认得出来。
  ///
  /// 返回与 [texts] 等长的掩码，true = 这行和前面某行几乎一样，可以丢。
  /// 只跟「最近 [window] 条被保留的行」比：既够压掉同屏抖动，
  /// 又不会把几分钟后那句相似但不同的台词误杀。
  static List<bool> nearDupMask(
    List<String> texts, {
    double threshold = 0.72,
    int window = 60,
  }) {
    final mask = List<bool>.filled(texts.length, false);
    final kept = <String>[];
    final keptAlpha = <String>[];
    for (var i = 0; i < texts.length; i++) {
      final t = texts[i];
      final ta = alphaOnly(t);
      var dup = false;
      final from = kept.length > window ? kept.length - window : 0;
      for (var k = from; k < kept.length; k++) {
        // 两条信号：原样比 + 去掉数字后比。
        // 去数字那一路专治 OCR 把量写成乱码的情况（「大蒜258」vs「大蒜25g」）。
        final same = jaccard(t, kept[k]) >= threshold;
        final sameAlpha = ta.length >= 3 &&
            keptAlpha[k].length >= 3 &&
            charJaccard(t, kept[k]) >= 0.8;
        if (same || sameAlpha) {
          dup = true;
          break;
        }
      }
      if (dup) {
        mask[i] = true;
      } else {
        kept.add(t);
        keptAlpha.add(ta);
      }
    }
    return mask;
  }
}

// 扫「原文里提到了、用料表里却没有」的食材。
//
// 【为什么要有这个文件】
// 用户做「酸甜大冷面」，视频里明明有这些配料：
//   一个梨切片 / 苹果比梨少一点 / 一根整的尖青椒不去根 / 一把香菜
// 最后菜谱的用料只有 8 项，四样配料全没了。
//
// 原因是这三样都不是「主料」，作者只是顺口提一句，字幕也没上屏，
// AI 整理时按「主料 + 调料」的思维惯性把它们筛掉了。
// 让 AI 自己复查这一项不可靠 —— 它自己漏的东西，自己也看不见；
// 但「拿一份常见食材词表，去原文和用料表里各扫一遍」是确定性的，
// 不联网、不花一分钱，而且每一版都能跑。
//
// 【v1.43.1】词表搬到 KitchenLexicon，这里只留「怎么扫」的逻辑。
// 以前三处各存一份词表，改了一处另两处不知道，越用越飘；
// 现在择优、纠错、扫料共用同一份，加一个词三处同时生效。
//
// 说话的分寸：这里只报「可能漏了」，不能断言「一定漏了」。
// 词表命中不等于作者真的要用（原文可能是在说「别放梨」），
// 所以最后一条永远是「你自己看一眼」。
import '../models/recipe.dart';
import 'kitchen_lexicon.dart';

class IngredientScan {
  /// 原文里出现、用料表里没有的食材名。
  /// 返回值已按「长词优先、去重」排好，直接拼成一句话就能给用户看。
  static List<String> missing(Recipe r, String rawText) {
    final text = _clean(rawText);
    if (text.isEmpty) return const <String>[];

    // 用料表里现有的名字，用来判断「这样东西是不是已经列了」
    final have = r.ingredients
        .map((e) => _clean(e.name))
        .where((e) => e.isNotEmpty)
        .toList();
    if (have.isEmpty) {
      // 一项用料都没有的情况另有人管（RulesCheck 会直接报「没整理出菜谱」），
      // 这里再报二十样食材只会把日志刷满。
      return const <String>[];
    }

    final out = <String>[];
    for (final word in KitchenLexicon.ingredientsByLength) {
      if (!text.contains(word)) continue;
      if (have.any((h) => _sameThing(h, word))) continue;
      // 「五花肉」已经报过，就别再报它里面含着的短词
      if (out.any((o) => o.contains(word))) continue;
      out.add(word);
    }
    return out;
  }

  /// 判断两个名字是不是同一样东西。
  /// 单纯 `contains` 不够：「尖青椒」和「青椒」、「土鸡蛋」和「鸡蛋」都算同一个，
  /// 但谁也不是谁的子串，得看有没有两字以上的公共片段。
  static bool _sameThing(String a, String b) {
    if (a == b) return true;
    if (a.contains(b) || b.contains(a)) return true;
    return _lcs(a, b) >= 2;
  }

  /// 最长公共子串长度。名字都很短（2~6 字），直接 O(n·m) 暴力。
  static int _lcs(String a, String b) {
    var best = 0;
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) {
        var k = 0;
        while (i + k < a.length && j + k < b.length && a[i + k] == b[j + k]) {
          k++;
        }
        if (k > best) best = k;
      }
    }
    return best;
  }

  /// 只留汉字、数字、字母，去掉标点换行，避免「生抽 10g」这类断行影响 contains。
  static String _clean(String s) =>
      s.replaceAll(RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9]'), '');
}

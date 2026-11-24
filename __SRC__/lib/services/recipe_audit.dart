// 出图前自检（v1.11）。
//
// 用户的要求是「一次就完事，不用再改」。AI 整理 + 自动配图这条链再稳，
// 也总有几步配不到图、或者两步撞了同一张。这些不会让程序崩，
// 但会让长图看着不专业 —— 而且用户往往保存之后才发现。
//
// 所以生成前先过一遍，把「不完美的地方」明确写出来：
//   · 哪一步没配到画面（不是笼统说一句「部分缺图」）
//   · 哪两步用了同一张（长图里出现两次同一画面，很扎眼）
//   · 哪几步的图是「勉强配」的（区间里没有文字对得上的，只能挑清晰的）
// 这样用户在校对页扫一眼就知道要不要补，而不用整张重做。
import '../models/recipe.dart';
import 'frame_matcher.dart';

class RecipeAudit {
  /// 返回一堆人话提示。空列表 = 这张长图没毛病。
  ///
  /// [matches] 传了才能判断「勉强配」；没传就只做结构检查。
  static List<String> check(Recipe r, {List<FrameMatch>? matches}) {
    final notes = <String>[];

    // ---- ① 步骤有没有配到图 ----
    final missing = <int>[];
    for (var i = 0; i < r.steps.length; i++) {
      if (r.steps[i].photoPath.trim().isEmpty) missing.add(i + 1);
    }
    if (missing.isNotEmpty) {
      if (missing.length == r.steps.length) {
        notes.add('这次一张画面都没配上 —— 长图会用纯文字排版（照样能看）。');
      } else {
        notes.add('第 ${missing.join('、')} 步没配到画面，长图里这几步只有文字。'
            '想补的话，回到上一步「加图」补几张实拍就行。');
      }
    }

    // ---- ② 同一张图被两步共用 ----
    final seen = <String, int>{};
    final dup = <String>[];
    for (var i = 0; i < r.steps.length; i++) {
      final p = r.steps[i].photoPath.trim();
      if (p.isEmpty) continue;
      final prev = seen[p];
      if (prev != null) {
        dup.add('第 $prev 步和第 ${i + 1} 步');
      } else {
        seen[p] = i + 1;
      }
    }
    if (dup.isNotEmpty) {
      notes.add('${dup.join('、')}用了同一张画面 —— 视频里这段可能一直在拍同一个镜头。');
    }

    // ---- ③ 哪几步是「勉强配」的 ----
    if (matches != null && matches.isNotEmpty) {
      final weakSteps = <int>[];
      final farSteps = <int>[];
      for (final m in matches) {
        if (m.frame == null) continue;
        if (m.weak) weakSteps.add(m.stepIndex + 1);
        // 【v1.14】AI 标了秒数，但附近没有画面、只能从 15 秒外拿一张：
        // 这段视频多半一直是同一个长镜头，图上看着像，其实不是这一步。
        // 旧版本把这种情况打成「✓按时间」，用户根本不知道要留意。
        if (m.byTime && m.atDiff > 15) farSteps.add(m.stepIndex + 1);
      }
      if (weakSteps.isNotEmpty && weakSteps.length < r.steps.length) {
        notes.add('第 ${weakSteps.join('、')} 步的画面是「就近挑的」，可能不完全贴合这一步 —— '
            '扫一眼，不对就换一张。');
      }
      if (farSteps.isNotEmpty) {
        notes.add('第 ${farSteps.join('、')} 步讲的位置附近没有画面，只能从远处借一张 —— '
            '视频这段可能一直没换镜头。介意的话把这步的图删掉，纯文字反而清楚。');
      }
    }

    // ---- ④ 菜名太长，长图标题会挤 ----
    final t = r.title.trim();
    if (t.length > 12) {
      notes.add('菜名「$t」有 ${t.length} 个字，长图标题会显得挤，'
          '建议改成 8 字以内（比如「${t.substring(0, 6)}」）。');
    }

    // ---- ⑤ 用料全是空的 ----
    if (r.ingredients.isEmpty) {
      notes.add('用料表是空的 —— 照着做会不知道放多少。');
    } else {
      final noAmount =
          r.ingredients.where((i) => i.amount.trim().isEmpty).length;
      if (noAmount > 0 && noAmount == r.ingredients.length) {
        notes.add('${r.ingredients.length} 项用料都没写用量，作者原文里可能也没有 —— '
            '做的时候按自己口味来。');
      }
    }

    // ---- ⑥ 步骤太少 ----
    if (r.steps.length < 2) {
      notes.add('只有 ${r.steps.length} 步，可能原文写得太简略，做的时候留意一下火候。');
    }
    return notes;
  }

  /// 一句话总结，给日志用。
  static String summary(List<String> notes) =>
      notes.isEmpty ? '自检通过：图、料、步骤都齐' : '自检发现 ${notes.length} 处要注意';
}

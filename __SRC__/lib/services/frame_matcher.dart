// 把抽出来的视频帧，一一对上菜谱的每一步（v1.8 建立，v1.11 重写匹配策略）。
//
// 用户的原话：「截取的照片跟每一步的食材准备对应不上，有的是无效的照片」。
// 以前的做法是从 40 帧里均匀挑 6 张，一股脑堆在长图顶部 —— 既不管这一步在做什么，
// 也不管那张图是不是黑屏。现在分两步：
//   1) 先由 douyin_reader 筛掉黑屏 / 糊帧 / 重复画面（帧自带清晰度与哈希）；
//   2) 这里再用「时间锚点」+「画面文字相似度」+「顺序单调」给每一步挑一张。
//
// 【v1.11 改了什么，为什么改】
// v1.8 的兜底是「按步骤序号把帧平均切段」：3 步就把 30 帧切成 3 段，每段取中间。
// 问题是做菜视频的时长分布极不均匀 —— 炖 20 分钟的步骤占一半时长，切菜只占 5 秒。
// 平均切段的结果就是「第 3 步配到了第 5 步的画面」，用户一眼就看出来。
//
// 现在改成「锚点 + 区间搜索」：
//   ① AI 标了秒数的步骤 → 在秒数附近找帧（窗口不够就自动放宽），这是硬锚点；
//   ② 没标秒数的步骤 → 在「前一个锚点」和「后一个锚点」之间找文字最像的一帧，
//      而不是按序号硬切；区间里全都对不上，才退回区间里比较清晰的一帧；
//   ③ 全程保证「帧的时间顺序」和「步骤顺序」一致，不会出现第 2 步用第 5 步的画面。
//
// 两条都要的理由：
//   - 只用时间：步骤 3 和 4 之间可能隔着 20 秒空镜，硬切一定切到空镜。
//   - 只用文字：「加入生抽老抽」和「翻炒上色」常出现在同一屏，光看文字会把两步指到同一帧。

import 'dart:typed_data';

import '../models/recipe.dart';
import 'douyin_reader.dart';

class FrameMatch {
  final int stepIndex;
  final VideoFrame? frame;
  final double score; // 文字相似度 0~1，仅用于日志与调参

  /// true = 这一张是**按 AI 标的秒数**配的，不是靠文字相似度猜的。
  /// 两者可信度差一大截，日志里要分开数。
  final bool byTime;

  /// 这一张是「区间里实在没有像的，退而求其次」拿的。
  /// 长图自检会把它标成「可能对不上」，让用户自己判断要不要换。
  final bool weak;

  /// 实际取到的帧，和 AI 标的秒数差了几秒。-1 = 这一步没有标注、或不是按时间取的。
  ///
  /// 旧日志把「差 51 秒」也打成「✓按时间」，读起来像配准了，其实是取到了片尾
  /// 那张同款画面。这个字段让日志能把「准」和「偏」分开数，自检也用它。
  final int atDiff;

  const FrameMatch(
    this.stepIndex,
    this.frame,
    this.score, {
    this.byTime = false,
    this.weak = false,
    this.atDiff = -1,
  });

  /// 5 秒内才算「真指着这一步」。做菜视频的镜头切换通常慢于 5 秒，
  /// 超过 5 秒基本已经切到下一个动作了。
  bool get accurate => byTime && atDiff >= 0 && atDiff <= 5;

  @override
  String toString() => '第 ${stepIndex + 1} 步 → '
      '${frame == null ? '（没配到）' : frame.toString()}'
      '${byTime ? '｜按秒数' : '｜按文字 ${score.toStringAsFixed(2)}'}'
      '${weak ? '｜勉强配' : ''}';
}

class FrameMatcher {
  /// 给每一步配一帧。返回与 steps 等长的列表，配不上的是 null。
  ///
  /// [allowRepeat] 为 false 时，同一帧不会被两步共用（默认）；
  /// 步骤远多于帧时才允许重复，否则后面几步会全空。
  static List<FrameMatch> assign(
    List<StepItem> steps,
    List<VideoFrame> frames, {
    bool allowRepeat = false,
  }) {
    if (steps.isEmpty || frames.isEmpty) {
      return List<FrameMatch>.generate(
        steps.length,
        (i) => FrameMatch(i, null, 0),
      );
    }

    // 帧按时间排一遍，后面切段才对
    final pool = List<VideoFrame>.from(frames)
      ..sort((a, b) => a.sec.compareTo(b.sec));

    final n = steps.length;
    final used = <int>{};

    // 先占位，锚点定完再回头填中间那些
    final picked = List<int?>.filled(n, null);
    final byTime = List<bool>.filled(n, false);
    final score = List<double>.filled(n, 0);
    final weak = List<bool>.filled(n, false);
    final atDiff = List<int>.filled(n, -1);

    // ---- ① 第一轮：AI 标了秒数的，直接在时间点上取 ----
    //
    // 【v1.14】先剔掉「自相矛盾」的秒数。实测（酸甜大冷面，182 秒视频）：
    //   第 6 步标 178s，第 7/8/9 步却标 127/143/162s —— AI 自己标反了。
    // 旧代码不管这个，第一轮照单全收，然后 _enforceMonotonic 发现第 7 步的 127s
    // 早于第 6 步的 178s，就把它「往上顶」到最后，于是 7、8、9 三步全变成同一张
    // 结尾画面（日志里三个 178s、差 51s/35s/16s 还标 ✓按时间）。
    //
    // 现在先求「最长的一段递增序列」当锚点：上面那 4 个点里，
    // [127,143,162] 比 [178] 更长，于是保留后三个、把第 6 步的 178s 当「没标」，
    // 交给区间搜索。错一个不会连累其他三个。
    final trusted = _trustedAnchors(steps);
    for (var i = 0; i < n; i++) {
      if (!trusted.contains(i)) continue;
      final at = steps[i].atSec;
      if (at < 0) continue;
      final idx = _nearestInWindow(pool, at, used, allowRepeat, steps[i].text);
      if (idx == null) continue;
      picked[i] = idx;
      byTime[i] = true;
      score[i] = 1.0;
      atDiff[i] = (pool[idx].sec - at).abs();
      if (!allowRepeat) used.add(idx);
    }

    // ---- ② 第二轮：没标的，在相邻锚点之间按文字找 ----
    for (var i = 0; i < n; i++) {
      if (picked[i] != null) continue;

      // 前一个已定的帧下标（严格小于 i），后一个已定的（严格大于 i）
      int? prev;
      int? next;
      for (var k = i - 1; k >= 0; k--) {
        if (picked[k] != null) {
          prev = picked[k];
          break;
        }
      }
      for (var k = i + 1; k < n; k++) {
        if (picked[k] != null) {
          next = picked[k];
          break;
        }
      }

      var lo = prev == null ? 0 : prev + 1;
      var hi = next == null ? pool.length - 1 : next - 1;

      // 区间被压缩空了（前后锚点紧挨着）：允许借用锚点的位置，
      // 但绝不抢走锚点已经用掉的那一帧。
      if (lo > hi) {
        lo = prev ?? 0;
        hi = next ?? pool.length - 1;
      }

      var bestIdx = -1;
      var bestScore = 0.0;
      for (var k = lo; k <= hi && k < pool.length; k++) {
        if (!allowRepeat && used.contains(k)) continue;
        final s = _similarity(steps[i].text, pool[k].text);
        if (s > bestScore) {
          bestScore = s;
          bestIdx = k;
        }
      }

      // 文字对不上：区间里挑一张「没被用、清晰度最高」的。
      // 以前是「区间正中间那一帧」—— 中间经常正好是空镜或灶台特写。
      if (bestIdx < 0 || bestScore < 0.06) {
        var bestSharp = -1.0;
        for (var k = lo; k <= hi && k < pool.length; k++) {
          if (!allowRepeat && used.contains(k)) continue;
          if (pool[k].sharp > bestSharp) {
            bestSharp = pool[k].sharp;
            bestIdx = k;
          }
        }
        // 整个区间都被用光了：退回区间中点（宁可有重复，也别整步没图）
        if (bestIdx < 0) {
          bestIdx = ((lo + hi) ~/ 2).clamp(0, pool.length - 1);
        }
        bestScore = 0;
        weak[i] = true;
      }

      picked[i] = bestIdx;
      score[i] = bestScore;
      if (!allowRepeat) used.add(bestIdx);
    }

    final out = <FrameMatch>[];
    for (var i = 0; i < n; i++) {
      final idx = picked[i];
      out.add(FrameMatch(
        i,
        idx == null ? null : pool[idx],
        score[i],
        byTime: byTime[i],
        weak: weak[i],
        atDiff: atDiff[i],
      ));
    }
    // 顺序约束的兜底校验：万一还有逆序（理论上不会了），就地换掉。
    _enforceMonotonic(out, pool);
    return out;
  }

  /// 挑出「秒数可信」的那几步：在标了 at 的步骤里，找最长的一段「时间不倒退」的子序列。
  ///
  /// 为什么不干脆按顺序 clamp：AI 只标错一个点（比如把「装盘」标到了片尾，
  /// 但它排在中间），clamp 会把后面所有步骤一起拖到最后，几秒的误差变成几十秒，
  /// 还出现三张一模一样的画面。用最长递增子序列，错的那一个自己掉出去，
  /// 其余三个照样当锚点用。
  ///
  /// 返回的是 steps 的下标集合。
  static Set<int> _trustedAnchors(List<StepItem> steps) {
    final idx = <int>[];
    final ats = <int>[];
    for (var i = 0; i < steps.length; i++) {
      final a = steps[i].atSec;
      if (a >= 0) {
        idx.add(i);
        ats.add(a);
      }
    }
    // 只有一个锚点、或者本来就单调：全都信
    if (idx.length <= 1) return idx.toSet();

    final m = ats.length;
    final len = List<int>.filled(m, 1);
    final prev = List<int>.filled(m, -1);
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < i; j++) {
        if (ats[j] <= ats[i] && len[j] + 1 > len[i]) {
          len[i] = len[j] + 1;
          prev[i] = j;
        }
      }
    }
    var best = 0;
    for (var i = 1; i < m; i++) {
      if (len[i] > len[best]) best = i;
    }
    final keep = <int>{};
    var k = best;
    while (k >= 0) {
      keep.add(idx[k]);
      k = prev[k];
    }
    return keep;
  }

  /// 在 [at] 附近找一帧。
  ///
  /// 窗口从小到大放开：±3 秒 → ±7 秒 → ±15 秒 → 全片最近。
  /// 为什么要放开：AI 标的秒数是「这句话开始说」的时刻，画面往往晚一两秒才切过去；
  /// 而那段如果刚好是空镜，会被前面的筛帧去掉，窄窗口里就一帧都没有。
  ///
  /// 同一个窗口里有多帧时，按「文字像 > 清晰」排序，而不是只看清晰度 ——
  /// 秒数只是大致定位，真正决定「这张是不是在讲这一步」的还是画面上的字。
  static int? _nearestInWindow(
    List<VideoFrame> pool,
    int at,
    Set<int> used,
    bool allowRepeat,
    String stepText,
  ) {
    for (final win in <int>[3, 7, 15, 100000]) {
      final cands = <int>[];
      for (var k = 0; k < pool.length; k++) {
        if (!allowRepeat && used.contains(k)) continue;
        if ((pool[k].sec - at).abs() <= win) cands.add(k);
      }
      if (cands.isEmpty) continue;

      cands.sort((a, b) {
        final sa = _similarity(stepText, pool[a].text);
        final sb = _similarity(stepText, pool[b].text);
        // 文字像度差 0.1 以上，直接按文字排
        if ((sa - sb).abs() > 0.1) return sb.compareTo(sa);
        final da = (pool[a].sec - at).abs();
        final db = (pool[b].sec - at).abs();
        if (da != db) return da.compareTo(db);
        return pool[b].sharp.compareTo(pool[a].sharp);
      });
      return cands.first;
    }
    return null;
  }

  /// 保证「第 i 步用的帧」不晚于「第 i+1 步用的帧」。
  /// 逆序的图放进长图会让人以为步骤乱了，这比配错一张更糟。
  static void _enforceMonotonic(List<FrameMatch> out, List<VideoFrame> pool) {
    var lastSec = -1;
    for (var i = 0; i < out.length; i++) {
      final f = out[i].frame;
      if (f == null) continue;
      if (f.sec >= lastSec) {
        lastSec = f.sec;
        continue;
      }
      // 在它后面找一张时间更晚的帧替换（用同一份 pool 里没被用过的优先）
      VideoFrame? replacement;
      for (final cand in pool) {
        if (cand.sec >= lastSec) {
          replacement = cand;
          break;
        }
      }
      if (replacement != null) {
        out[i] = FrameMatch(
          out[i].stepIndex,
          replacement,
          out[i].score,
          byTime: false, // 被换过位置就不再是「按 AI 标的秒数」了
          weak: true,
          atDiff: -1,
        );
        lastSec = replacement.sec;
      }
    }
  }

  /// 两句中文的相似度：按 2 字词重叠算 Jaccard。
  /// 用 2-gram 而不是单字，是因为「加盐」和「加糖」单字各对一半，2-gram 能分开。
  static double _similarity(String stepText, String frameText) {
    final a = _bigrams(stepText);
    final b = _bigrams(frameText);
    if (a.isEmpty || b.isEmpty) return 0;
    var inter = 0;
    for (final g in a) {
      if (b.contains(g)) inter++;
    }
    return inter / (a.length + b.length - inter);
  }

  static Set<String> _bigrams(String s) {
    final clean = s.replaceAll(RegExp(r'[\s，。、！？：；""''（）()#@,.!?:;]+'), '');
    final out = <String>{};
    for (var i = 0; i + 1 < clean.length; i++) {
      out.add(clean.substring(i, i + 2));
    }
    // 太短的句子（「翻炒均匀」4 字）2-gram 太少，补上单字降低误判
    if (out.length < 3) {
      for (var i = 0; i < clean.length; i++) {
        out.add(clean[i]);
      }
    }
    return out;
  }

  /// 从帧里挑一张当封面：取视频后 40% 里最清晰的一帧。
  /// 做菜视频的成品特写基本都在结尾，「开锅那一下」比开头切菜更有食欲。
  static VideoFrame? cover(List<VideoFrame> frames) {
    if (frames.isEmpty) return null;
    final sorted = List<VideoFrame>.from(frames)
      ..sort((a, b) => a.sec.compareTo(b.sec));
    final tail = sorted.sublist((sorted.length * 0.5).floor());
    if (tail.isEmpty) return sorted.last;

    // 先看画面上的字：带「出锅 / 装盘 / 成品 / 开吃」的那几帧，
    // 基本就是成品特写，比单纯挑「最清晰」靠谱得多 ——
    // 最清晰的往往是灶台边一张正在翻炒的手，当封面不好看。
    const doneWords = ['出锅', '装盘', '成品', '开吃', '盛出', '上桌', '完成', '做好', '搞定'];
    final done = tail
        .where((f) => f.text.isNotEmpty && doneWords.any((w) => f.text.contains(w)))
        .toList();
    final pick = done.isNotEmpty ? done : tail;
    pick.sort((a, b) => b.sharp.compareTo(a.sharp));
    return pick.first;
  }

  /// 给「一步步做」页用：把匹配结果拆成每步一个 jpeg。
  static List<Uint8List> imagesFor(List<FrameMatch> matches) =>
      matches.map((m) => m.frame?.jpeg ?? Uint8List(0)).toList();
}

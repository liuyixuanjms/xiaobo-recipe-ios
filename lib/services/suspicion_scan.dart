// 审阅页的「可疑错字」扫描（v1.47）。
//
// 为什么不直接在整理阶段全改掉：字幕阶段已经跑过一遍 KitchenLexicon.correct，
// 但作品文案（作者写的介绍）和用户手贴的配方文字没走那一遍，整理成菜谱后
// 仍可能带着「老迪」「耗油」这类错字。与其悄悄改（可能改错语义），不如
// 在用户亲眼校对这一步，只把**有确凿证据**的地方标出来，让他一键采用。
//
// 铁律：只报词表里写得明明白白的错→对映射（老迪→老抽、耗油→蚝油…），
// 和整份文案里有规范「勺」作证时的「1河/小句→勺」。绝不模糊猜、绝不自造词。
// 猜错一个字比留着错字更伤——用户会以为 App 连调料都懂，结果把菜做错。
import 'kitchen_lexicon.dart';

/// 一处可疑：在某个字段里发现了 [from]，建议改成 [to]。
class Suspicion {
  /// '用料' / '步骤' —— 给人看的分区名
  final String section;

  /// 第几条（0 起）。用料是第几行用料，步骤是第几步。
  final int index;

  /// 字段键：name / amount / text / tip。用来定位到具体输入框。
  final String field;

  final String from;
  final String to;

  /// 为什么报它（人话），例如「词表里的常见错字」。
  final String reason;

  const Suspicion({
    required this.section,
    required this.index,
    required this.field,
    required this.from,
    required this.to,
    required this.reason,
  });

  /// 给卡片上那行短说明用。
  String get label => '$section ${index + 1} · $from → $to';

  @override
  String toString() => 'Suspicion($label)';
}

class SuspicionScan {
  SuspicionScan._();

  /// 扫一条文本，返回这段里所有「错→对」建议。
  ///
  /// [wholeDoc] 是整份菜谱拼起来的文本，用来判断「勺」类误认有没有规范作证，
  /// 跟字幕阶段 normalizeSpoonUnits 的门槛保持一致。
  static List<Suspicion> scanText(
    String text, {
    required String section,
    required int index,
    required String field,
    String wholeDoc = '',
  }) {
    if (text.trim().isEmpty) return const <Suspicion>[];
    final out = <Suspicion>[];

    // 一、词表里写死的错→对映射。命中原文里出现的每个错字各报一次。
    for (final e in KitchenLexicon.corrections.entries) {
      if (text.contains(e.key)) {
        out.add(Suspicion(
          section: section,
          index: index,
          field: field,
          from: e.key,
          to: e.value,
          reason: '词表里的常见错字',
        ));
      }
    }

    // 二、用量里的「勺」误认。必须整份文案里有规范「勺」作证才报，
    // 否则「1河老抽」也可能是 part of 某个地名，不敢乱改。
    final hasGoodSpoon =
        RegExp(r'(?:\d+\s*)?小?勺').hasMatch(wholeDoc) ||
        text.contains('勺');
    if (hasGoodSpoon) {
      final numRe = RegExp(r'(\d{1,3})(河|句|勾)(?![0-9A-Za-z])');
      for (final m in numRe.allMatches(text)) {
        out.add(Suspicion(
          section: section,
          index: index,
          field: field,
          from: '${m.group(1)}${m.group(2)}',
          to: '${m.group(1)}勺',
          reason: '同份菜谱里有规范的「勺」作证',
        ));
      }
      final smallRe = RegExp(r'小(句|勾)(?![0-9A-Za-z])');
      for (final m in smallRe.allMatches(text)) {
        out.add(Suspicion(
          section: section,
          index: index,
          field: field,
          from: '小${m.group(1)}',
          to: '小勺',
          reason: '同份菜谱里有规范的「勺」作证',
        ));
      }
    }
    return out;
  }

  /// 应用一处建议到原文：把 [from] 全部换成 [to]。
  /// 只做整词精确替换，和 KitchenLexicon.correct 同一个口径。
  static String apply(String text, Suspicion s) =>
      text.replaceAll(s.from, s.to);
}

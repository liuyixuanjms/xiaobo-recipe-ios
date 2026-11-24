// 本地硬校验：不调用 DeepSeek、不花一分钱，用确定性规则先拦一遍「驴唇不对马嘴」。
// 目的：AI 审稿会漏、会客气，而这些硬伤用字符串规则反而 100% 抓得住。
// 它检查的是「草稿」，输出一段中文问题清单，同时喂给审稿 AI 让它别重复报。
import '../models/recipe.dart';
import 'ingredient_scan.dart';

class RulesCheck {
  /// 返回问题清单（每条一句中文）。空列表 = 没发现硬伤。
  static List<String> run(Recipe r, String rawText) {
    final flags = <String>[];

    // ① 平台水印 / 口令 / 话题标签 / @ / 表情，绝不能出现在菜谱正文里
    final noise = <String>[
      '复制打开抖音',
      '长按复制',
      '打开抖音搜索',
      '抖音搜索',
      '查看TA的更多作品',
      '查看TA',
      '点赞',
      '关注',
      '小红书',
      'https://',
      'http://',
      'v.douyin.com',
      '#',
      '@',
    ];
    final fields = <String, String>{
      '菜名': r.title,
      '简介': r.intro,
    };
    for (var i = 0; i < r.ingredients.length; i++) {
      fields['用料第${i + 1}项名称'] = r.ingredients[i].name;
      fields['用料第${i + 1}项用量'] = r.ingredients[i].amount;
    }
    for (var i = 0; i < r.steps.length; i++) {
      fields['步骤${i + 1}'] = r.steps[i].text;
      fields['步骤${i + 1}关键点'] = r.steps[i].tip;
    }
    fields.forEach((where, value) {
      for (final n in noise) {
        if (value.contains(n)) {
          flags.add('【严重】$where 里混进了「$n」这类平台文案/话题标签，必须删掉，它不是菜谱内容。');
          break;
        }
      }
    });

    // ② 百分比误读：字幕里「鸡腿净重的 13.33%」是比例，不是用量
    for (var i = 0; i < r.ingredients.length; i++) {
      final amt = r.ingredients[i].amount;
      if (amt.contains('%') || amt.contains('％')) {
        flags.add('【严重】用料第${i + 1}项「${r.ingredients[i].name}」的用量写成了「$amt」，这是原文里的比例/补充说明，不是用量，应清空或改为原文标注的克数。');
      }
    }

    // ③ 编造用量的典型词：原文没写具体数，却冒出「适量/少许/若干/按口味」
    //    只有「原文里确实没出现这些词」时才算可疑，避免误伤原文自带的「适量」。
    final raw = rawText.replaceAll(' ', '');
    final fabricate = <String>['适量', '少许', '若干', '按口味', '一点点'];
    for (var i = 0; i < r.ingredients.length; i++) {
      final amt = r.ingredients[i].amount.trim();
      for (final f in fabricate) {
        if (amt == f && !raw.contains(f)) {
          flags.add('【严重】用料第${i + 1}项「${r.ingredients[i].name}」用量是「$amt」，但原始素材里并没有，属于编造，应留空让用户自己补。');
          break;
        }
      }
    }

    // ④ 结构完整性：连用料和步骤都没有，基本等于没读出来
    if (r.ingredients.isEmpty && r.steps.isEmpty) {
      flags.add('【严重】草稿既没有用料也没有步骤，等于没整理出菜谱，需要让用户补充更全的文字或换张清楚的截图。');
    }
    if (r.steps.isEmpty && r.ingredients.isNotEmpty) {
      flags.add('【严重】有用料但没有做法步骤，缺了最关键的部分。');
    }

    // ⑤ 步骤编号残留：「第 1 步」「步骤一」这类不该出现在做法正文里
    for (var i = 0; i < r.steps.length; i++) {
      final t = r.steps[i].text;
      if (RegExp(r'^第\s*[0-9一二三四五六七八九十]+\s*步').hasMatch(t.trim()) ||
          t.trim().startsWith('步骤')) {
        flags.add('【提醒】步骤${i + 1}的正文以「${t.trim().substring(0, t.trim().length > 6 ? 6 : t.trim().length)}…」开头，混进了步骤编号，App 会自动编号，正文里请删掉。');
        break;
      }
    }

    // ⑥ 关键点写成空话
    final emptyTips = <int>[];
    for (var i = 0; i < r.steps.length; i++) {
      final tip = r.steps[i].tip.trim();
      if (tip.isEmpty || tip == '注意火候' || tip == '适量即可' || tip == '小心一点') {
        emptyTips.add(i + 1);
      }
    }
    if (r.steps.isNotEmpty && emptyTips.length == r.steps.length) {
      flags.add('【提醒】所有步骤都没有「关键点」，而这正是用户做饭时最需要的（火候/状态/时间/手法），请从原文里补。');
    }

    // ⑦ 漏料：原文提到了、用料表里没有。
    //    这是 v1.14 加的重点项 —— 用户那道「酸甜大冷面」里，
    //    「一个梨、苹果比梨少一点、一根整的尖青椒不去根、一把香菜」
    //    四样配料全被 AI 筛掉了，就是因为它们「看起来不像主料」，
    //    而作者只是顺口提了一句。这类漏项 AI 自查发现不了，只能靠词表比对。
    final missing = IngredientScan.missing(r, rawText);
    if (missing.isNotEmpty) {
      flags.add('【严重】原文提到了这些食材，用料表里却没有：${missing.join('、')}。'
          '它们可能被当成「不是主料」筛掉了。逐项核对原文：确实要用的，补进用料表'
          '（用量原文没写就留空字符串，不许编）；原文明确说「不放」的才跳过。');
    }

    return flags;
  }
}

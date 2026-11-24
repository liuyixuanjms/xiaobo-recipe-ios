// 纯本地菜谱整理器（v1.25）——不调用任何 AI 接口、不联网、不花钱。
//
// 为什么能做：做菜视频的硬字幕是「一句一个动作」的分步口播，而且 OCR 已经给
// 每一行标了出现秒数（见 SubLine）。这类素材用确定性规则就能拼出一份能照着做的
// 菜谱，不必非得等大模型。质量不如大模型润色（步骤是字幕原句、用量多为原文照抄），
// 但胜在：离线可用、零费用、不受限流、秒出。
//
// 拆解的四个部件，全是项目里已经过实战检验的模块或同类确定性规则：
//   ① 菜名     TitleFixer        ——把标题党洗成菜名
//   ② 用料     本文件 _extractIngredients + IngredientScan 词表
//   ③ 步骤     本文件 _buildSteps ——带秒数字幕行按「动作行」聚合成步骤
//   ④ 纠正/校验 AsrFixer + RulesCheck + RecipeAudit（在上层链路里跑）
//
// 诚实边界：
//   - 用量只抄原文出现过的数字/量词，绝不推断、绝不编「适量」。
//   - 字幕是连续叙述（不是分步口播）时，步骤切分质量会下降，报告里会如实提醒。
//   - 这是「够照着做」的菜谱，不是「润色好的」菜谱。
import '../models/recipe.dart';
import '../models/chef_review.dart';
import 'asr_fixer.dart';
import 'douyin_reader.dart' show SubLine;
import 'rules_check.dart';
import 'subtitle_clean.dart';
import 'text_sim.dart';
import 'title_fixer.dart';

class LocalBuildResult extends SmartOrganizeResult {
  LocalBuildResult(Recipe recipe, ChefReviewReport report)
      : super(recipe: recipe, report: report);
}

class LocalRecipeBuilder {
  /// 烹饪动作信号词：一行里出现这些，多半是在讲「怎么做」而非报菜名/报配料。
  ///
  /// 【v1.28】把「酱」去掉了：它既是动词（酱牛肉）也是名词（黑松露酱、豆瓣酱），
  /// 留在动作表里会让「黑松露酱丰富口感」这类配料行被判成动作行，
  /// 结果用料表里只剩「黑松露」、丢掉「黑松露酱」。做菜动作里带酱的写法很罕见，
  /// 去掉的收益远大于损失。
  static const _actionChars = '切炒烧炖煮蒸煎炸拌焖煲烤卤爆熘烩汆涮腌焗翻搅倒加放盛捞出下入盖晃淋滤';

  /// 火候 / 状态 / 时间词：抽出来当「关键点」，正是做饭时最需要的。
  static const _keyHints = [
    '大火', '中火', '小火', '大火烧开', '转小火', '保持大火',
    '变色', '断生', '熟透', '出香味', '冒泡', '微黄', '金黄', '上色',
    '翻炒均匀', '搅匀', '抓匀', '腌制', '静置', '焯水', '过凉',
    '煮开', '烧开', '收汁', '焖一会儿', '焯一下',
  ];
  static final _timeRe = RegExp(r'(\d+\s*(?:分钟|分|秒|小时|个呼吸))');

  /// 纯本地整理入口。subtitleLines 来自 OCR，已带秒数；可为空（纯文字录入）。
  static SmartOrganizeResult build({
    required String rawText,
    required String titleHint,
    required String sourceUrl,
    List<SubLine> subtitleLines = const <SubLine>[],
    LogSinkLike? onLog,
  }) {
    void log(String m) => onLog?.call('本地整理', m);
    final warnings = <String>[]; // 每次整理独立收集，绝不跨菜谱串味

    // 同音字纠正先走一遍（食材名错了，后面词表就扫不出来）
    final fixedHits = <String>[];
    var fixed = AsrFixer.fix(rawText, hits: fixedHits);
    if (fixedHits.isNotEmpty) {
      log('同音字纠正 ${fixedHits.length} 处：${fixedHits.join('、')}');
    }
    // 中文数字用量转阿拉伯数字：「准备六百五十克的大虾」这类口播很常见，
    // 抓用量的正则只认数字，不转就白丢一条用量。
    final digitHits = <String>[];
    fixed = SubtitleClean.digitsOf(fixed, hits: digitHits);
    if (digitHits.isNotEmpty) {
      log('中文用量转数字 ${digitHits.length} 处：${digitHits.take(6).join('、')}');
    }

    final title = _pickTitle(titleHint, fixed);
    final ingredients = _extractIngredients(fixed, log: log);
    final steps = _buildSteps(subtitleLines, fixed, warnings: warnings, onLog: onLog);
    log('本地拼装完成｜菜名「$title」｜用料 ${ingredients.length} 项｜步骤 ${steps.length} 步');

    final recipe = Recipe(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      intro: '',
      sourceUrl: sourceUrl,
      ingredients: ingredients,
      steps: steps,
    );

    final report = ChefReviewReport()
      ..reviewDone = false
      ..planSummary = '纯本地整理：从带秒数的画面字幕切步骤、词表抽用料，未调用 AI。'
      ..note = '这份菜谱是 App 在本地整理的，零费用、离线可用。'
          '步骤用的是视频画面上的字幕原话；字幕由 OCR 识别，'
          '个别字仍可能读错（尤其配料表那种小字、快闪的贴片）。'
          '动火之前请把用量那一栏扫一眼，错字的顺手改掉。'
      ..changes.add('本地模式：无 AI 润色，步骤保持字幕原话');

    // 硬伤 / 漏料照跑（这些本来就不花钱）
    report.localFlags = RulesCheck.run(recipe, fixed);
    for (final f in report.localFlags) {
      report.issues.add(ReviewIssue(level: '提醒', where: '本地检查', problem: f, fix: '对照原视频核对'));
    }
    report.remainingRisks.addAll(warnings);
    return LocalBuildResult(recipe, report);
  }

  static String _pickTitle(String titleHint, String rawText) {
    // 【v1.43】完整素材里带着 #话题，那才是作者亲手写的菜名。
    // 旧版只看被砍掉话题后的标题党长句，于是切出「不会炸酱」「低成本」。
    final picked = TitleFixer.pick(titleHint, source: rawText);
    if (picked.confident) return picked.title;

    // 话题和标题都洗不出来，才退到字幕第一行找，而且必须真的像菜名。
    final firstLine = rawText.split(RegExp(r'[\n。！？]')).firstWhere(
          (l) => l.trim().length >= 2,
          orElse: () => '',
        );
    final fromBody = TitleFixer.fix(firstLine);
    if (fromBody.isNotEmpty && TitleFixer.looksLikeDish(fromBody)) {
      return fromBody;
    }

    // 宁可让用户在校对页填一个名字，也不要把「东北四大炖菜之一」这种
    // 标题党长句端上去 —— 那正是「出来的菜名都不是菜名」的根源。
    return '未命名菜谱';
  }

  /// 用词表从全文扫食材，就近抽用量。
  ///
  /// 【v1.27 修正】老版本有个严重 bug：词表里 72 个词**无条件全部**塞进用料表，
  /// 于是不管做的是茄汁大虾还是清蒸鱼，用户看到的都是「五花肉、西兰花、娃娃菜、
  /// 五香粉、豆瓣酱……」一大串厨房全景——72 项正好等于词表条数。
  /// 现在改成三道闸门，宁可少列也不列错：
  ///   ① 文中必须真的出现过这个词，否则直接丢；
  ///   ② 出现过但既没写用量、也不在配料列举行里（只是叙述里提一嘴）→ 丢；
  ///   ③ 和已收录的长词重复（收了「大虾」就不收「虾」）→ 丢。
  /// 没列进来的东西用户可以在校对页自己手动加，这比塞一堆假料强。
  static List<Ingredient> _extractIngredients(
    String text, {
    void Function(String msg)? log,
  }) {
    // 逐行处理，绝不跨行抓量 —— "西红柿 3 个约 650g\n生抽 10g" 里
    // 不能把上一行的 650g 当成"生抽"的用量。
    final lines = text
        .split(RegExp(r'[\n，,；;。]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final out = <Ingredient>[];
    final picked = <String>[];
    var notAppeared = 0; // 词表里有、但这段视频全程没提
    var noAmount = 0; // 提过一嘴但没用量，也不在配料表里
    // v1.40：这些「提过但没量」的食材先别扔，把名字记下来。
    // 万一最后一项料都没抽出来，就靠它们救场（见下面的 rescued）。
    final ignored = <String>[];

    for (final food in _knownFoods) {
      var appears = false;
      var inListing = false;
      var amount = '';
      for (final line in lines) {
        final idx = line.indexOf(food);
        if (idx < 0) continue;
        appears = true;
        // 是不是在「报用料」，而不是叙述里随口提一嘴。
        //
        // 老版本这里写的是 `line.length <= 14`，于是
        // 「我用的这个虾皮比较厚」（11 字）被当成配料行，
        // 用料表里就凭空多出一条「虾皮 = 个」（那个「个」来自「这个」）。
        if (_isIngredientTableLine(line) || _looksLikeListing(line, food)) {
          inListing = true;
        }
        if (amount.isEmpty) {
          final got = _grabAmount(line, idx, food.length);
          if (got.isNotEmpty) amount = got;
        }
      }
      if (!appears) {
        notAppeared++;
        continue;
      }
      if (amount.isEmpty && !inListing) {
        noAmount++;
        ignored.add(food);
        continue;
      }
      // 「大虾」已收录就不再收「虾」——词表按长度倒序，长词先过
      if (picked.any((p) => p.contains(food))) continue;
      picked.add(food);
      out.add(Ingredient(name: food, amount: amount));
    }

    // v1.40：一条料都没抽出来时的救场。
    //
    // 来自真实日志（2026-11-13 17:46 导出的那份，记录 3「盐蒸橙子」）：
    // 全程字幕只有
    //   「橙子用盐搓一搓」「用刀切开一个小盖子」「然后均匀的撒上一点盐」
    // 橙子和盐其实都提到了，但一句克数都没有，又都夹在动作句里被判成
    // 「不是在报配料」，于是用料 0 项 —— 后面的硬拦截直接把整条判死，
    // 用户连已经读出来的 6 个步骤都看不到，白等 47 秒。
    //
    // 这类素材缺的是**用量**，不是**用料**。缺用量可以留空让用户在校对页补一句，
    // 缺用料才是真的没内容。所以这里退一步：严格规则抽不出料时，把提过名的
    // 都收回来，用量留空，最多 6 项。
    //
    // 门槛放在「少于 2 项」而不是「等于 0 项」：正常菜谱只要正经报过一次料，
    // 就不会只剩 1 项；一旦只剩 0~1 项，说明这份素材压根没在报菜谱，
    // 这时候放宽没有副作用。反过来，茄汁大虾那种已经抽到 8 项的，
    // 绝不会触发这里 —— 「我用的这个虾皮比较厚」也就不会被误收进用料表。
    var rescued = 0;
    if (out.length < 2 && ignored.isNotEmpty) {
      for (final food in ignored) {
        if (out.length >= 6) break;
        if (picked.any((p) => p.contains(food) || food.contains(p))) continue;
        picked.add(food);
        out.add(Ingredient(name: food, amount: ''));
        rescued++;
      }
    }

    // 一份菜 24 项用料已经到顶了（再多就没人看）。超了优先留有明确用量的。
    const maxItems = 24;
    var capped = 0;
    if (out.length > maxItems) {
      out.sort((a, b) {
        final byAmount = (b.amount.isEmpty ? 0 : 1) - (a.amount.isEmpty ? 0 : 1);
        if (byAmount != 0) return byAmount;
        return b.name.length.compareTo(a.name.length);
      });
      capped = out.length - maxItems;
      out.removeRange(maxItems, out.length);
    }
    // 长词优先显示（「大虾」在「虾」前，虽然已经去重过，排序仍保持一致观感）
    out.sort((a, b) => b.name.length.compareTo(a.name.length));
    log?.call('用料 ${out.length} 项（词表 ${_knownFoods.length} 词：'
        '$notAppeared 个视频里没提、$noAmount 个提过但没用量'
        '${rescued > 0 ? '，其中 $rescued 个没用量但先收回来（用量留空，校对页可补）' : '，已丢弃'}'
        '${capped > 0 ? '；超 24 项又砍掉 $capped' : ''}）');
    return out;
  }

  /// 这一行是不是在「报用料」：没有做菜动作，且食材名在行首（或在几乎只有它一行的短行里）。
  ///
  /// 关键区别在「食材名出现在哪儿」：
  ///   「大虾650-700g」     → 行首就是食材，是在报料     → 收
  ///   「我用的这个虾皮比较厚」→ 食材在句中，是叙述     → 不收
  static bool _looksLikeListing(String line, String food) {
    final t = line.replaceAll(RegExp(r'[\s，,。、：:；;]'), '');
    if (!t.contains(food)) return false;
    // 很短的句子（「放点香菜」「加盐调味」）就是在报料，哪怕带动作字。
    // 这类句子多半没写用量，但确实要用到，必须收进来（用量留空让用户自己定）。
    if (t.length <= food.length + 4) return true;
    if (_hasAction(line)) return false; // 有动作又是长句 → 是步骤，不是报料
    final idx = t.indexOf(food);
    // 行首就是它 → 在报料；否则只有「整行几乎只有它」才算
    return idx == 0 || t.length <= food.length + 2;
  }

  /// 抓食材的用量：先看食材「前面」紧邻的中文量词（两个鸡蛋），
  /// 再看「后面」紧邻的数字/量（鸡蛋 2 个、西红柿 3 个约 650g）。
  /// 抓不到就留空，绝不编。保留原文里的空格，显示更自然。
  static String _grabAmount(String text, int idx, int foodLen) {
    final before = idx > 0 ? text.substring(0, idx) : '';
    final after = text.substring(idx + foodLen);
    // 区间也要认：「大虾650-700g」不能只抄成 700g
    final numUnit = r'[一二两三四五六七八九十半\d]+(?:\.\d+)?'
        r'(?:\s*[-~到]\s*[一二两三四五六七八九十半\d]+(?:\.\d+)?)?'
        r'\s*(?:g|克|ml|毫升|L|升|个|根|只|块|片|把|勺|瓣|颗|粒|斤|两|袋|包|杯|碗|茶匙|汤匙)';
    // 「两个鸡蛋」这种前置量词只可能是「计数单位」。重量单位出现在前面时
    // （「姜1g 大葱20g」里的 1g）那是上一项的量，绝不能算到大葱头上。
    //
    // 【v1.28】数词前缀必须**真的存在**（+ 而不是 *）。
    // 老写法 `[一二两三四五六七八九十半\d\s]*` 允许零个字符，于是
    // 「我用的这个虾皮比较厚」里的「个」被当成用量，用料表凭空多出
    // 「虾皮 = 个」一条 —— 用户截图里的怪现象就是这么来的。
    final countUnit = r'[一二两三四五六七八九十半\d]+'
        r'(?:个|根|只|块|片|把|勺|瓣|颗|粒|袋|包|杯|碗)';

    // ① 前面紧邻：中文数字+计数单位，且紧贴食材（中间最多一个空格）
    final pre = RegExp(r'(' + countUnit + r')\s*$').firstMatch(before);
    if (pre != null && pre.group(1)!.trim().isNotEmpty) {
      return pre.group(1)!.trim();
    }

    // ② 后面紧邻：数字+单位（取离食材最近的一个）
    final post =
        RegExp(r'^\s*(' + numUnit + r')', caseSensitive: false).firstMatch(after);
    if (post != null) return post.group(1)!.trim();

    // ③ 后面不远处有「约 N g」这类补充（西红柿 3 个约 650g 优先取 3 个，这里兜底）
    final window = after.substring(0, (after.length > 8 ? 8 : after.length));
    final near = RegExp('($numUnit)', caseSensitive: false).firstMatch(window);
    if (near != null) return near.group(1)!.trim();

    // ④ 原文明确写的「适量 / 少许」照抄
    final m3 = RegExp(r'(适量|少许|一点点|若干)').firstMatch(window);
    if (m3 != null) return m3.group(1)!;
    return '';
  }

  /// 把带秒数的字幕行拼成步骤。
  /// 策略：
  ///   1. 丢掉「配料表行」（连续食材+数字、占比很高）和过短/口水行。
  ///   2. 剩下的按「动作信号」判定是否新步骤；连续的非动作行并入上一步。
  ///   3. 每步的 atSec 取这一组第一行的秒数（配图直接用）。
  static List<StepItem> _buildSteps(
    List<SubLine> lines,
    String rawText, {
    required List<String> warnings,
    LogSinkLike? onLog,
  }) {
    void log(String m) => onLog?.call('本地整理', m);

    if (lines.isEmpty) {
      // 没有带秒数的字幕（纯文字录入）：按标点粗切，不标秒数
      log('没有带秒数的字幕，按句子切步骤（不标秒数，配图改用画面文字匹配）');
      return _stepsFromPlainText(rawText, warnings: warnings);
    }

    // ── ① 逐行清洗：广告水印 / 乱码 / 括号长注释 ──
    //
    // 不挡的后果（用户 2026-11-12 19:24 日志里的真实样子）：
    // 一段 187 秒的做菜视频，步骤里会冒出「Royalstar荣事达」「余事达」
    // 「高效节能 灣高效1」「两用连樓體熄火保护」「(*」「ā80g」，
    // 还有「生抽40g(薄盐,正常咸度的生抽减少至25-30g)=」连着出现六遍。
    // 这不是「识别不准」，是锅的广告贴片和错版被当成菜谱了。
    var adLines = 0;
    var garbageLines = 0;
    final cleaned = <SubLine>[];
    for (final l in lines) {
      // 字幕行也要过同音字纠正 ——
      // 老版本只把 rawText 纠了一遍，步骤用的却是原始字幕行，
      // 于是「虾抢」「虹虾」「自糖」这些错字原样印在步骤里，用户看着当然不准。
      final t = AsrFixer.fix(_cleanLine(l.text));
      if (t.length < 2) continue;
      if (_isNoise(t) || SubtitleClean.isAdLine(t)) {
        adLines++;
        continue;
      }
      if (SubtitleClean.isGarbageLine(t)) {
        garbageLines++;
        continue;
      }
      // 中文数字用量（「六百五十克」）在字幕里也常见，一并转成数字；
      // 繁简混用也在这里归一（「鮮/鲜」是同一句的两个错版，不归一对不上）
      final s = SubtitleClean.digitsOf(
          SubtitleClean.toSimplified(SubtitleClean.stripComment(t)));
      if (s.length < 2) continue;
      cleaned.add(SubLine(l.sec, s));
    }
    if (adLines > 0 || garbageLines > 0) {
      log('挡掉广告水印 $adLines 行、乱码 $garbageLines 行');
    }

    // ── ② 同一句的多个错版合成一条，留最规范的那条 ──
    //
    // 老逻辑是「见到重复就丢」，丢掉的常常正好是最准的那条：
    // 日志里「大蒜25g 姜1g 大葱20g」排在三个错版后面，先到先得就轮不到它，
    // 结果用料表上大蒜、姜的量全是空的。
    final fusedLines = <SubLine>[];
    var fusedCount = 0;
    for (final l in cleaned) {
      var hit = -1;
      final from = fusedLines.length > 8 ? fusedLines.length - 8 : 0;
      for (var k = from; k < fusedLines.length; k++) {
        if (_isSameLine(l.text, fusedLines[k].text)) {
          hit = k;
          break;
        }
      }
      if (hit < 0) {
        fusedLines.add(l);
      } else {
        fusedLines[hit] = SubLine(
          fusedLines[hit].sec < l.sec ? fusedLines[hit].sec : l.sec,
          SubtitleClean.pickBest(<String>[fusedLines[hit].text, l.text]),
        );
        fusedCount++;
      }
    }
    if (fusedCount > 0) {
      log('同一句的多个错版合并 $fusedCount 次（留最规范的那条）');
    }

    final usable = <SubLine>[];
    var ingredientLike = 0;
    var introLines = 0;
    var started = false; // 是否已见到第一句「动作」
    for (final l in fusedLines) {
      final t = l.text;
      if (t.length < 2) continue;
      if (_isIngredientTableLine(t)) {
        ingredientLike++;
        continue;
      }
      // 第一句动作之前的都是开场白（标题、栏目名、"保姆级教程"），不算步骤
      if (!started && !_hasAction(t)) {
        introLines++;
        continue;
      }
      if (_hasAction(t)) started = true;
      usable.add(l);
    }
    log('字幕 ${lines.length} 行 → 跳过开场白 $introLines 行、配料表 $ingredientLike 行，剩 ${usable.length} 行动作');

    final steps = <StepItem>[];
    StepItem? cur;
    for (final l in usable) {
      final isAction = _hasAction(l.text);
      if (isAction || cur == null) {
        // 新起一步
        if (cur != null) steps.add(cur);
        cur = StepItem(
          text: l.text,
          tip: _extractTip(l.text),
          atSec: l.sec,
        );
      } else {
        // 不是动作行，并到上一步（很可能是补充描述）
        cur = StepItem(
          text: '${cur.text}，${l.text}',
          tip: _mergeTip(cur.tip, _extractTip(l.text)),
          atSec: cur.atSec,
        );
      }
    }
    if (cur != null) steps.add(cur);

    if (steps.length < 2) {
      warnings.add('这段字幕被判定为连续叙述（只切出 ${steps.length} 步）。'
          '步骤仍可用，但可能不够分步；对照视频看要不要在校对页手动拆开。');
    }
    // 拆掉重复的相邻步骤（同一句被相邻两帧各读一次）
    final dedup = <StepItem>[];
    for (final s in steps) {
      if (dedup.isNotEmpty) {
        final last = dedup.last.text;
        if (last == s.text) continue;
        // 相邻两步几乎一模一样（「虾肉清新鲜嫩」/「虾肉清新鲜炖」）：
        // 那是同一处画面被读了两遍，不是两个步骤
        if (TextSim.charJaccard(last, s.text) >= 0.7) continue;
      }
      dedup.add(StepItem(
        text: _dropChatter(s.text),
        tip: s.tip,
        atSec: s.atSec,
      ));
    }

    // ── ③ 合并碎片，让步数落到「照着做刚好」的区间 ──
    //
    // 老版本把 187 秒的菜切成 37 步，其中「先不要开火」「切成小圈」
    // 「它是增加风味的」各占一步 —— 屏幕上翻十几次才做一半，没人这么做饭。
    final totalSec = usable.isEmpty ? 0 : usable.last.sec;
    final target = _targetSteps(totalSec);
    final compact = _coalesceSteps(dedup, target);
    if (compact.length < dedup.length) {
      log('碎片合并｜${dedup.length} 步 → ${compact.length} 步'
          '（$totalSec 秒的视频，$target 步以内照着手顺）');
    }
    return compact;
  }

  /// 去掉每步里「作者的闲聊尾巴」。
  ///
  /// 视频里常跟着这些：「非常简单」「我用的这个虾皮比较厚」「二点不着你」
  /// （锅盖广告贴片的残句）。那是给观众的话，不是做菜动作，留在步骤里很出戏。
  ///
  /// 只删两类，其余一律保留：
  ///   ① 明确的闲聊套话；
  ///   ② 五个字以内、且没有任何动作/火候/时间/数字信号的碎片。
  /// 状态描述（「粘稠了但是底下还有点」）不动 —— 那正是做饭要看的东西。
  static String _dropChatter(String text) {
    const chatter = <String>[
      '非常简单', '特别简单', '特别好吃', '非常好吃', '超级好吃', '真的好吃',
      '一定要试试', '建议收藏', '记得关注', '点个赞', '双击', '关注我',
      '我用的这个', '我觉得', '你们可以', '大家可以试试', '学起来', '安排上',
    ];
    final parts = text.split(RegExp(r'[，,]'));
    final kept = <String>[];
    for (final p in parts) {
      final s = p.trim();
      if (s.isEmpty) continue;
      var drop = false;
      for (final c in chatter) {
        if (s.contains(c)) {
          drop = true;
          break;
        }
      }
      if (!drop && s.length <= 5 && !_hasAnySignal(s)) drop = true;
      if (!drop) kept.add(s);
    }
    if (kept.isEmpty) return text; // 全被判成闲聊就别删了，宁可留着
    return kept.join('，');
  }

  static bool _hasAnySignal(String s) {
    if (_hasAction(s)) return true;
    for (final h in _keyHints) {
      if (s.contains(h)) return true;
    }
    if (_timeRe.hasMatch(s)) return true;
    if (RegExp(r'\d').hasMatch(s)) return true;
    return false;
  }

  /// 目标步数：按每 16 秒一步估，夹在 6~14 之间。
  /// 时长未知（纯文字录入）时给 10 —— 一般菜谱就这个量级。
  static int _targetSteps(int totalSec) {
    if (totalSec <= 0) return 10;
    final n = totalSec ~/ 16;
    if (n < 6) return 6;
    if (n > 14) return 14;
    return n;
  }

  /// 两行是不是「同一句话的两个错版」。
  static bool _isSameLine(String a, String b) {
    final x = a.replaceAll(RegExp(r'\s'), '');
    final y = b.replaceAll(RegExp(r'\s'), '');
    if (x == y) return true;
    // 一行完整包含另一行（「腌制10分钟」⊂「腌制10分钟，放入黑虎虾」）：
    // 同一句字幕在两帧上截取长度不同，留信息多的那条。
    if (x.length >= 4 && y.length >= 4) {
      if (x.contains(y) || y.contains(x)) return true;
    }
    // 短句：只差一两个字的多半是同一句的两个错版，但「切成小片」和「切成小段」
    // 只差一个字却是两个动作 —— 用单字集合相似度区分：前者 0.71，后者 0.60。
    if (x.length <= 6 || y.length <= 6) {
      return TextSim.charJaccard(x, y) >= 0.7;
    }
    if (TextSim.jaccard(x, y) >= 0.62) return true;
    // OCR 错版常把一个字读成另一个字，两字组会全崩，但「出现过哪些字」几乎不变
    return TextSim.alphaOnly(x).length >= 4 &&
        TextSim.alphaOnly(y).length >= 4 &&
        TextSim.charJaccard(x, y) >= 0.78;
  }

  /// 动作族：判断两步能不能合在一起讲（同一族合并后读起来才顺）。
  static String _actionFamily(String t) {
    if (RegExp(r'[切剁剪压剥洗擦吸腌拌调]').hasMatch(t)) return 'prep';
    if (RegExp(r'[煎炸炒煮蒸烤烧焖炖煲焯]').hasMatch(t)) return 'heat';
    if (RegExp(r'[倒加放撒淋浇入]').hasMatch(t)) return 'add';
    if (RegExp(r'[盛收摆过滤关盖]').hasMatch(t)) return 'finish';
    return 'other';
  }

  /// 把碎步合并到 [target] 步以内：每轮挑最短的一步，优先和同族的邻步合并。
  /// 合并后秒数取两者较早的（配图要对得上「开始做这一步」那一刻）。
  ///
  /// 单步有字数上限：做饭时是站在灶台前看，一步 200 字根本没法照做。
  /// 超过上限就换个对象合并，实在合不了就停在中途 —— 步数多一点也好过一步看不完。
  static List<StepItem> _coalesceSteps(List<StepItem> steps, int target) {
    const maxStepChars = 80;
    final cur = List<StepItem>.from(steps);
    var guard = 0;
    while (cur.length > target && cur.length > 1 && guard++ < 400) {
      // 按字数从短到长试，找到第一个「合起来不超字数」的
      final order = List<int>.generate(cur.length, (i) => i)
        ..sort((a, b) => cur[a].text.length.compareTo(cur[b].text.length));
      var pick = -1;
      var mate = -1;
      for (final i in order) {
        final fam = _actionFamily(cur[i].text);
        final candidates = <int>[];
        if (i > 0) candidates.add(i - 1);
        if (i + 1 < cur.length) candidates.add(i + 1);
        // 同族优先
        final sameFamily =
            candidates.where((c) => _actionFamily(cur[c].text) == fam).toList();
        for (final c in <int>[...sameFamily, ...candidates]) {
          if (cur[i].text.length + cur[c].text.length + 1 <= maxStepChars) {
            pick = i;
            mate = c;
            break;
          }
        }
        if (pick >= 0) break;
      }
      if (pick < 0) break; // 都合并不动了，保留现状

      final a = cur[pick];
      final b = cur[mate];
      final first = a.atSec <= b.atSec ? a : b;
      final second = identical(first, a) ? b : a;
      final merged = StepItem(
        text: '${first.text}，${second.text}',
        tip: _mergeTip(first.tip, second.tip),
        atSec: first.atSec,
      );
      final lo = pick < mate ? pick : mate;
      final hi = pick < mate ? mate : pick;
      cur.removeAt(hi);
      cur[lo] = merged;
    }
    return cur;
  }

  static List<StepItem> _stepsFromPlainText(String rawText, {required List<String> warnings}) {
    final parts = rawText
        .split(RegExp(r'[。！？\n]'))
        .map((s) => SubtitleClean.stripComment(_cleanLine(s)))
        .where((s) =>
            s.length >= 3 &&
            !_isNoise(s) &&
            !SubtitleClean.isAdLine(s) &&
            !SubtitleClean.isGarbageLine(s) &&
            !_isIngredientTableLine(s))
        .toList();
    final out = <StepItem>[];
    for (final p in parts) {
      out.add(StepItem(text: p, tip: _extractTip(p), atSec: -1));
    }
    if (out.length < 2) {
      warnings.add('素材里没读出分步信息，只拼出 ${out.length} 步。'
          '可以在校对页手动拆成多步，照着做更清楚。');
    }
    return out;
  }

  static String _cleanLine(String s) {
    var t = s.trim();
    // 步骤编号残留
    t = t.replaceAll(RegExp(r'^第\s*[0-9一二三四五六七八九十]+\s*步[:：]?\s*'), '');
    t = t.replaceAll(RegExp(r'^步骤\s*[0-9一二三四五六七八九十]+[:：]?\s*'), '');
    // 行首的项目符号 / 边框残留（OCR 会把画面上的「|」「、」「-」读成文字）
    t = t.replaceAll(RegExp(r'^[•·\-\*、|｜,，。.~～:：;；\s]+'), '');
    // 行尾的残渣符号（「先不要开火、」「腌制10分钟-」）
    t = t.replaceAll(RegExp(r'[\-、,，.。;；:：~～\s]+$'), '');
    // 夹在汉字中间的孤立英文字母：「剪n虾须」→「剪虾须」
    t = t.replaceAllMapped(
      RegExp(r'([\u4e00-\u9fa5])[a-zA-Z]{1,2}([\u4e00-\u9fa5])'),
      (m) => '${m.group(1)!}${m.group(2)!}',
    );
    return t.trim();
  }

  static bool _isNoise(String t) {
    const noise = [
      '复制打开抖音', '长按复制', '打开抖音搜索', '抖音搜索', '查看TA',
      '点赞', '关注', '收藏', '转发', '小红书', 'https', 'http', 'www.',
    ];
    for (final n in noise) {
      if (t.contains(n)) return true;
    }
    // 纯话题标签 / @ 账号
    if (RegExp(r'^[#@]').hasMatch(t)) return true;
    return false;
  }

  /// 像配料表的一行：整行基本由「食材名 + 用量」组成，没有动作词。
  /// 做菜视频常在开头整屏列配方（"西红柿 3 个约 650g"），这些不是步骤。
  ///
  /// 【v1.28】判据从「有没有数字+单位」放宽到「汉字里过半是食材名」——
  /// 因为 OCR 会把单位读飞：「大蒜25g 姜1g 大葱20g」被读成
  /// 「大蒜258。姜Fg大葱208。」，一个规范单位都没有，老判据认不出来，
  /// 于是这些配料错版全当成了步骤。现在按「食材字占比」认，照样拦得住，
  /// 而「我们家的大蒜特别香」这种叙述句（食材字占比低）不会被误伤。
  static bool _isIngredientTableLine(String t) {
    if (_hasAction(t)) return false; // 有动作就是步骤，哪怕带数字
    final compact = t.replaceAll(RegExp(r'\s'), '');
    if (compact.length > 20) return false; // 长句是叙述，不按配料表处理
    var foodChars = 0;
    for (final f in _knownFoods) {
      if (t.contains(f)) foodChars += f.length;
    }
    if (foodChars == 0) return false;
    final han = RegExp(r'[\u4e00-\u9fa5]').allMatches(compact).length;
    if (foodChars * 2 + 2 >= han) return true;
    // 老判据保留：明确带数字单位的短行
    final hasAmount =
        RegExp(r'\d+\s*(g|克|ml|毫升|个|根|只|勺|斤|两|把|瓣|颗|粒)').hasMatch(t);
    return hasAmount;
  }

  static bool _hasAction(String t) {
    for (final ch in _actionChars.split('')) {
      if (t.contains(ch)) return true;
    }
    // 「先…再…然后…」也是分步信号
    if (RegExp(r'^(先|再|然后|接着|随后|最后|起锅|热锅|准备)').hasMatch(t)) return true;
    return false;
  }

  static String _extractTip(String t) {
    final found = <String>[];
    for (final h in _keyHints) {
      if (t.contains(h) && !found.contains(h)) found.add(h);
    }
    for (final m in _timeRe.allMatches(t)) {
      final v = m.group(1)!.trim();
      if (!found.contains(v)) found.add(v);
    }
    return found.join(' · ');
  }

  static String _mergeTip(String a, String b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final parts = <String>[...a.split(' · '), ...b.split(' · ')];
    return parts.toSet().join(' · ');
  }

  /// 精简食材词表：和 IngredientScan 的主表对齐（能抽用量的重点食材）。
  /// 完整漏料扫描仍由 RulesCheck → IngredientScan.missing 负责。
  /// 食材/调料白名单（按长度倒序，长词优先）。
  ///
  /// 【v1.27】原来只有 72 个词，连「大蒜、姜」这种最家常的都没有 ——
  /// 于是剥出来的用料表既有一堆没用的、又漏了真正在用的。
  /// 现在补齐常用项；因为有了「文中必须真出现」的闸门，
  /// 词表变长**不会**再让用料表变长，只会让该有的不漏。
  static final _knownFoods = <String>[
    // 蔬菜 / 菌菇
    '西红柿', '番茄', '胡萝卜', '金针菇', '西兰花', '娃娃菜', '尖青椒', '青椒',
    '洋葱', '大葱', '小葱', '蒜薹', '蒜苗', '韭菜', '香菜', '芹菜', '菠菜',
    '香菇', '木耳', '海带', '黄瓜', '茄子', '土豆', '豆角', '四季豆', '山药',
    '莲藕', '白萝卜', '南瓜', '冬瓜', '丝瓜', '苦瓜', '玉米', '豌豆', '豆芽',
    '包菜', '白菜', '粉丝', '粉条', '生菜', '油麦菜', '茼蒿', '秋葵', '芦笋',
    // 肉蛋水产
    '五花肉', '排骨', '里脊', '牛肉', '鸡腿', '鸡翅', '鸡胸', '鸡肉', '猪肉',
    '羊肉', '大虾', '虾仁', '虾皮', '鲈鱼', '带鱼', '鱿鱼', '鸡蛋', '皮蛋', '鸭蛋',
    // 豆制品 / 主食
    '豆腐', '豆干', '腐竹', '面条', '米饭', '面粉', '淀粉', '生粉', '糯米',
    // 调味
    '生抽', '老抽', '蚝油', '料酒', '香油', '白醋', '陈醋', '香醋', '豆瓣酱',
    '番茄酱', '番茄沙司', '黄豆酱', '甜面酱', '辣椒油', '花椒粉', '胡椒粉',
    '五香粉', '十三香', '孜然粉', '冰糖', '白糖', '蜂蜜', '鸡精', '味精',
    '花椒', '八角', '桂皮', '香叶', '孜然', '干辣椒', '小米辣', '小米椒',
    '芝麻', '花生', '枸杞', '红枣', '大蒜', '生姜', '大料',
    // 【v1.28】油脂 / 酱料 / 香草：这份名单原来一个都没有，
    // 于是「宴客被夸爆」那道菜（黄油 + 橄榄油 + 黑松露酱 + 柠檬）
    // 整理出来的用料表只有 1 项 —— 不是抽错，是词表里压根没这些词。
    '橄榄油', '黄油', '猪油', '菜籽油', '玉米油', '色拉油', '辣椒油', '藤椒油',
    '黑松露酱', '松露酱', '芝麻酱', '花生酱', '沙拉酱', '蛋黄酱', '千岛酱',
    '椰浆', '淡奶油', '牛奶', '芝士', '奶酪', '马苏里拉',
    '罗勒', '迷迭香', '欧芹', '黑胡椒', '白胡椒', '黑松露',
    '韩式辣酱', '泰式甜辣酱', '鱼露', '蒸鱼豉油', '辣椒面', '辣椒粉',
    // 【v1.40】水果：这份名单原来只有「梨 / 苹果 / 柠檬」三个。
    // 真实日志（2026-11-13）里那条「盐蒸橙子」，字幕明明是
    // 「橙子用盐搓一搓」「把橙子盖上切开的盖子」，可词表里没有橙子，
    // 最后只认出 1 项料（盐），主料整个消失 —— 用户看到的就是
    // 「这菜的主料去哪了」。甜品、糖水、凉拌、果茶、果酱这些内容
    // 全靠这份名单，缺一个词就等于那一类内容全废。
    '橙子', '橘子', '柚子', '金桔', '青柠', '香蕉', '菠萝', '凤梨',
    '葡萄', '草莓', '蓝莓', '芒果', '猕猴桃', '奇异果', '桃子', '西瓜',
    '哈密瓜', '火龙果', '石榴', '山楂', '枇杷', '车厘子', '樱桃', '荔枝', '龙眼',
    '雪梨', '香梨', '牛油果', '百香果',
    // 单字兜底（同长度时排最后，能被上面的长词覆盖就覆盖）
    '盐', '糖', '醋', '蒜', '姜', '葱', '梨', '苹果', '柠檬',
  ]..sort((a, b) => b.length.compareTo(a.length));
}

/// 极简日志回调：页面传 LogService.log 进来（签名一致即可，不强依赖）。
typedef LogSinkLike = Future<void> Function(String tag, String msg);

// 页面 3 · 校对 & 生成：本地整理出的每一格都能改（用量最需要人工核对）。
// v1.25 起完全离线：整理引擎是 LocalRecipeBuilder，不调用任何 AI 接口。
// 顶部展示「核对报告」；改完点「预览长图」进预览页；有原始内容时可「重新整理」本地再走一遍。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chef_review.dart';
import '../models/recipe.dart';
import '../services/douyin_reader.dart' show SubLine;
import '../services/ingredient_scan.dart';
import '../services/local_recipe_builder.dart';
import '../services/recipe_audit.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../services/suspicion_scan.dart';
import '../services/text_sim.dart';
import '../theme/app_theme.dart';
import '../widgets/chef_review_card.dart';
import 'cook_screen.dart';
import 'preview_screen.dart';

class ReviewScreen extends StatefulWidget {
  final Recipe recipe;
  final String rawText;
  final String sourceUrl;
  final String? titleHint;
  final Uint8List? imageBytes;
  /// v1.25：带秒数的画面字幕，重新整理时本地据此切步骤
  final List<SubLine> subtitleLines;
  /// 用户带进来的一整组实拍图（V0.12），预览前落盘、成组排进长图
  final List<Uint8List>? photos;
  final ChefReviewReport? report;

  /// v1.11 出图前自检的结果（缺图 / 撞图 / 勉强配 / 菜名太长…）。
  /// 由新建页在配图后算好带进来，进页面就先让用户看见。
  final List<String> auditNotes;

  const ReviewScreen({
    super.key,
    required this.recipe,
    required this.rawText,
    required this.sourceUrl,
    this.titleHint,
    this.imageBytes,
    this.subtitleLines = const <SubLine>[],
    this.photos,
    this.report,
    this.auditNotes = const <String>[],
  });

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  static const List<String> tags = ['家常菜', '汤羹', '烘焙', '凉菜', '早餐', '其他'];

  late Recipe _recipe;
  /// 展开/收起「机器从视频里读到的原文」
  bool _showRaw = false;

  late TextEditingController _titleCtrl;
  late TextEditingController _introCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _tipsCtrl;

  final List<TextEditingController> _ingNameCtrls = [];
  final List<TextEditingController> _ingAmountCtrls = [];
  final List<TextEditingController> _stepTextCtrls = [];
  final List<TextEditingController> _stepTipCtrls = [];

  String _tag = '家常菜';
  bool _busy = false;
  String _stage = '';
  // 首次 _rebuild 时控制器还没建，不能先 dispose，否则会抛 LateInitializationError
  bool _controllersReady = false;
  final SettingsService _settings = SettingsService();
  ChefReviewReport? _report;

  bool get _canReOrganize => widget.rawText.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _report = widget.report;
    _rebuild(widget.recipe);
  }

  void _disposeAll() {
    _titleCtrl.dispose();
    _introCtrl.dispose();
    _urlCtrl.dispose();
    _tipsCtrl.dispose();
    for (final c in [
      ..._ingNameCtrls,
      ..._ingAmountCtrls,
      ..._stepTextCtrls,
      ..._stepTipCtrls
    ]) {
      c.dispose();
    }
    _ingNameCtrls.clear();
    _ingAmountCtrls.clear();
    _stepTextCtrls.clear();
    _stepTipCtrls.clear();
  }

  /// 用一份 Recipe 重建所有输入框；重新整理成功后再调一次即可整体换新
  void _rebuild(Recipe r) {
    if (_controllersReady) _disposeAll();
    _recipe = r.copy();
    _tag = tags.contains(_recipe.tag) ? _recipe.tag : '家常菜';
    _titleCtrl = TextEditingController(text: _recipe.title);
    _introCtrl = TextEditingController(text: _recipe.intro);
    _urlCtrl = TextEditingController(text: _recipe.sourceUrl);
    _tipsCtrl = TextEditingController(text: _recipe.tips.join('\n'));
    for (final i in _recipe.ingredients) {
      _ingNameCtrls.add(TextEditingController(text: i.name));
      _ingAmountCtrls.add(TextEditingController(text: i.amount));
    }
    for (final s in _recipe.steps) {
      _stepTextCtrls.add(TextEditingController(text: s.text));
      _stepTipCtrls.add(TextEditingController(text: s.tip));
    }
    _controllersReady = true;
  }

  @override
  void dispose() {
    _disposeAll();
    super.dispose();
  }

  /// 把界面上改过的内容收集回 Recipe
  Recipe _collect() {
    final r = _recipe.copy();
    r.title = _titleCtrl.text.trim().isEmpty ? '未命名菜谱' : _titleCtrl.text.trim();
    r.intro = _introCtrl.text.trim();
    r.sourceUrl = _urlCtrl.text.trim();
    r.tag = _tag;
    r.ingredients = List.generate(
      _ingNameCtrls.length,
      (i) => Ingredient(
        name: _ingNameCtrls[i].text.trim(),
        amount: _ingAmountCtrls[i].text.trim(),
      ),
    );
    r.steps = List.generate(
      _stepTextCtrls.length,
      (i) => StepItem(
        text: _stepTextCtrls[i].text.trim(),
        tip: _stepTipCtrls[i].text.trim(),
        // v1.8：校对只改文字，这一步配好的画面按原位置跟着走。
        // 用户删了一行，后面的图会往前顶一格——比全部丢图好，也比按内容重新匹配稳。
        photoPath:
            i < _recipe.steps.length ? _recipe.steps[i].photoPath : '',
        // 时间点跟着走：万一以后要重新配图，这一格还能用上
        atSec: i < _recipe.steps.length ? _recipe.steps[i].atSec : -1,
      ),
    );
    r.tips = _tipsCtrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    // 编辑后原有长图已过期，重新生成时会覆盖同一路径
    return r;
  }

  void _addIngredient() => setState(() {
        _ingNameCtrls.add(TextEditingController());
        _ingAmountCtrls.add(TextEditingController());
      });

  void _removeIngredient(int i) => setState(() {
        _ingNameCtrls.removeAt(i).dispose();
        _ingAmountCtrls.removeAt(i).dispose();
      });

  void _addStep() => setState(() {
        _stepTextCtrls.add(TextEditingController());
        _stepTipCtrls.add(TextEditingController());
      });

  void _removeStep(int i) => setState(() {
        _stepTextCtrls.removeAt(i).dispose();
        _stepTipCtrls.removeAt(i).dispose();
      });

  void _moveStep(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _stepTextCtrls.length) return;
    setState(() {
      final a = _stepTextCtrls.removeAt(i);
      _stepTextCtrls.insert(j, a);
      final b = _stepTipCtrls.removeAt(i);
      _stepTipCtrls.insert(j, b);
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 把旧步骤上已经配好的画面，搬到重整理出来的新步骤上。
  ///
  /// 【v1.16 修复】`_reOrganize()` 原来直接把 AI 新生成的 Recipe 推给新页面，
  /// 而新 Recipe 的 steps 全是 `photoPath: ''` —— 用户点一下「重新精校」，
  /// 十张配图就全没了，还得整条链接重跑一遍才能回来。
  /// 重整理本质上只是「换一种说法」，步骤指的仍是同一批动作，图应当跟着走。
  void _carryPhotos(Recipe fresh) {
    final olds = _collect().steps;
    if (olds.isEmpty) return;
    final oldWithImg = olds.where((s) => s.photoPath.isNotEmpty).toList();
    if (oldWithImg.isEmpty) return;

    // 步骤数一样：按序号搬。重整理很少增删步骤，这样最符合直觉，
    // 也不会出现「第 2 步的图跑到第 5 步」这种错位。
    if (olds.length == fresh.steps.length) {
      for (var i = 0; i < fresh.steps.length; i++) {
        fresh.steps[i].photoPath = olds[i].photoPath;
        fresh.steps[i].atSec = olds[i].atSec;
      }
      return;
    }

    // 数量变了：按文字最像的一对一匹配，宁可少搬也不搬错。
    final used = List<bool>.filled(olds.length, false);
    for (final s in fresh.steps) {
      var best = -1;
      var bestScore = 0.42;
      for (var j = 0; j < olds.length; j++) {
        if (used[j] || olds[j].photoPath.isEmpty) continue;
        final sc = TextSim.jaccard(s.text, olds[j].text);
        if (sc > bestScore) {
          bestScore = sc;
          best = j;
        }
      }
      if (best >= 0) {
        used[best] = true;
        s.photoPath = olds[best].photoPath;
        s.atSec = olds[best].atSec;
      }
    }
  }

  Future<void> _reOrganize() async {
    if (_busy || !_canReOrganize) return;
    setState(() {
      _busy = true;
      _stage = '准备重整理…';
    });
    try {
      final detailed = await _settings.isChefReviewEnabled();
      if (mounted) setState(() => _stage = '本地正在重新切步骤、抽用料…');
      final result = LocalRecipeBuilder.build(
        rawText: widget.rawText,
        titleHint: widget.titleHint ?? '',
        sourceUrl: widget.sourceUrl,
        subtitleLines: widget.subtitleLines,
      );
      Recipe fresh = result.recipe;
      ChefReviewReport report = result.report;
      if (!detailed) {
        report.note = '快速整理：本地切步骤 + 抽用料，未听口播（用量、火候可能缺），未逐条合并补充描述。';
      }
      fresh.id = _recipe.id;
      fresh.imagePath = _recipe.imagePath;
      // v1.16：视频也跟着走 —— 重整理改的是文字，没必要让人再下载一遍几十兆
      fresh.videoPath = _recipe.videoPath;
      fresh.tag = _tag;
      // v1.16：把已经配好的画面搬过来，别再让「重新精校」把图全清空
      _carryPhotos(fresh);
      if (!mounted) return;
      // 用新页面替换当前页，彻底避开「dispose 掉仍被 TextField 引用的控制器」这个坑
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ReviewScreen(
            recipe: fresh,
            rawText: widget.rawText,
            sourceUrl: widget.sourceUrl,
            titleHint: widget.titleHint,
            imageBytes: widget.imageBytes,
            subtitleLines: widget.subtitleLines,
            photos: widget.photos,
            report: report,
          ),
        ),
      );
    } catch (e) {
      _snack('重新整理失败：$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 打开「一步一步做」：先用当前编辑内容同步一份，再进沉浸式步骤页
  Future<void> _goCook() async {
    final r = _collect();
    if (r.steps.every((s) => s.text.trim().isEmpty)) {
      _snack('还没有步骤，先补两步再来做');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CookScreen(recipe: r)),
    );
  }

  Future<void> _goPreview() async {
    final r = _collect();
    // 【V1.4 第二道防线】校对页允许手动删行，删到没有步骤就出图 = 又变回废图。
    // 这里再挡一次，并且给「继续去加步骤」的选项，不是死拦。
    final hasIng = r.ingredients.any(
      (i) => i.name.trim().isNotEmpty || i.amount.trim().isNotEmpty,
    );
    final hasStep = r.steps.any((s) => s.text.trim().isNotEmpty);
    if (!hasIng || !hasStep) {
      final what = !hasIng && !hasStep
          ? '用料和做法都空着'
          : (!hasIng ? '一样用料都没有' : '一步做法都没有');
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('这张图会没法照着做'),
          content: Text(
            '现在$what。这样生成的长图，菜名下面要么没料、要么没步骤，'
            '做饭时用不上。\n\n'
            '建议先在页面上补几行，或者点「加图」把配料表 / 步骤截图带进来。',
            style: const TextStyle(height: 1.55),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('回去补'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('就这样出图'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    // 把整组实拍图落盘，长图组件才能读到本机文件（不依赖原链接）
    final ps = widget.photos;
    if (ps != null && ps.isNotEmpty) {
      r.photoPaths = await StorageService().savePhotos(r.id, ps);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PreviewScreen(recipe: r)),
    );
  }

  /// 原文里提到、用料表里却没有的食材。
  ///
  /// 用户那道「酸甜大冷面」漏了梨、苹果、尖青椒、香菜四样 —— 全是作者顺口提一句的
  /// 配菜，AI 按「主料 + 调料」的惯性筛掉了。这里拿词表扫一遍，
  /// 把话摆在用户面前，而不是让他自己一行行比对。
  ///
  /// 实时算：用户把这几样补进用料，卡片立刻消失。
  List<String> _missingIngredients() {
    try {
      return IngredientScan.missing(_collect(), widget.rawText);
    } catch (_) {
      return const <String>[];
    }
  }

  /// 一键把漏掉的食材补进用料表（用量留空，让用户按原文填）。
  void _addMissingIngredients(List<String> words) {
    if (words.isEmpty) return;
    setState(() {
      for (final w in words) {
        _ingNameCtrls.add(TextEditingController(text: w));
        _ingAmountCtrls.add(TextEditingController());
      }
    });
    _snack('已补进用料：${words.join('、')} —— 用量按原文填，原文没写就留空');
  }

  Widget _missingCard(List<String> words) {
    const ink = Color(0xFF8A3A1B);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDEFE9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF5C4AE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shopping_basket_outlined,
                  size: 16, color: Color(0xFFC0491E)),
              const SizedBox(width: 6),
              Text(
                '原文里有、菜谱里没有（${words.length} 样）',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFC0491E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            words.join('、'),
            style: const TextStyle(
                fontSize: 13.5, height: 1.6, color: ink, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            '这几样都是从视频原文里扫出来的。有的是作者顺口提的配菜，'
            '自动整理容易当成「不是主料」筛掉；你自己看一眼，要用的补上。',
            style: TextStyle(fontSize: 12, height: 1.5, color: ink),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              onPressed: () => _addMissingIngredients(words),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('全部补进用料', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                foregroundColor: WidgetStateProperty.all(const Color(0xFFC0491E)),
                side: const BorderSide(color: Color(0xFFE5A98E)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前内容的自检结果。
  ///
  /// 结构问题（缺图、撞图、菜名太长）**实时算** —— 用户在这里把菜名改短了、
  /// 删掉重复的步骤，提示要立刻消失，不能拿进来时的旧结论吓人。
  /// 只有「画面是就近挑的」这一条依赖配图过程，实时算不出来，沿用带进来的。
  List<String> _auditNotes() {
    final live = RecipeAudit.check(_recipe);
    // 「画面是就近挑的 / 只能从远处借一张」这两条依赖配图过程，实时算不出来，
    // 沿用带进来那份；其余（缺图、撞图、菜名太长）都按当前内容重算。
    final weakOnly = widget.auditNotes
        .where((n) =>
            (n.contains('就近挑的') || n.contains('只能从远处借一张')) &&
            !live.contains(n))
        .toList();
    return <String>[...live, ...weakOnly];
  }

  /// v1.47：按**当前输入框里的字**实时扫可疑错字。
  /// 跟 _auditNotes 一个思路——用户改好了标记立刻消失，不拿进门时的旧结论吓人。
  /// 只报词表里有确凿「错→对」映射的，绝不模糊猜。
  List<Suspicion> _suspicions() {
    // 整份文案拼起来，给「勺」类误认当规范作证（跟字幕阶段同一个门槛）。
    final whole = StringBuffer()
      ..writeln(_titleCtrl.text)
      ..writeln(_introCtrl.text)
      ..writeln(_tipsCtrl.text);
    for (final c in _ingNameCtrls) {
      whole.writeln(c.text);
    }
    for (final c in _ingAmountCtrls) {
      whole.writeln(c.text);
    }
    for (final c in _stepTextCtrls) {
      whole.writeln(c.text);
    }
    for (final c in _stepTipCtrls) {
      whole.writeln(c.text);
    }
    final doc = whole.toString();

    final out = <Suspicion>[];
    for (var i = 0; i < _ingNameCtrls.length; i++) {
      out.addAll(SuspicionScan.scanText(_ingNameCtrls[i].text,
          section: '用料', index: i, field: 'name', wholeDoc: doc));
      out.addAll(SuspicionScan.scanText(_ingAmountCtrls[i].text,
          section: '用料', index: i, field: 'amount', wholeDoc: doc));
    }
    for (var i = 0; i < _stepTextCtrls.length; i++) {
      out.addAll(SuspicionScan.scanText(_stepTextCtrls[i].text,
          section: '步骤', index: i, field: 'text', wholeDoc: doc));
      out.addAll(SuspicionScan.scanText(_stepTipCtrls[i].text,
          section: '步骤', index: i, field: 'tip', wholeDoc: doc));
    }
    // 基本信息也可以有错字（菜名/简介/小贴士），一并报。它们用 index=-1 表示「基本信息」。
    for (final e in <MapEntry<String, TextEditingController>>[
      MapEntry('title', _titleCtrl),
      MapEntry('intro', _introCtrl),
      MapEntry('tips', _tipsCtrl),
    ]) {
      out.addAll(SuspicionScan.scanText(e.value.text,
          section: '基本信息', index: -1, field: e.key, wholeDoc: doc));
    }
    return out;
  }

  /// 把某条建议应用到对应输入框，并刷新（标记随即消失）。
  void _applySuspicion(Suspicion s) {
    TextEditingController? ctrl;
    if (s.section == '用料') {
      if (s.field == 'name' && s.index < _ingNameCtrls.length) {
        ctrl = _ingNameCtrls[s.index];
      } else if (s.field == 'amount' && s.index < _ingAmountCtrls.length) {
        ctrl = _ingAmountCtrls[s.index];
      }
    } else if (s.section == '步骤') {
      if (s.field == 'text' && s.index < _stepTextCtrls.length) {
        ctrl = _stepTextCtrls[s.index];
      } else if (s.field == 'tip' && s.index < _stepTipCtrls.length) {
        ctrl = _stepTipCtrls[s.index];
      }
    } else if (s.section == '基本信息') {
      // 不用 switch 表达式——项目锁在 Dart 2.17。
      ctrl = s.field == 'title'
          ? _titleCtrl
          : (s.field == 'intro'
              ? _introCtrl
              : (s.field == 'tips' ? _tipsCtrl : null));
    }
    if (ctrl == null) return;
    setState(() => ctrl!.text = SuspicionScan.apply(ctrl.text, s));
  }

  /// v1.47：可疑错字卡片。集中在顶部一处，每条给「换一个字」按钮就地改。
  /// 措辞克制：说「常见错字」而不是「错误」，因为终究要用户拍板。
  Widget _suspicionCard(List<Suspicion> items) {
    const ink = Color(0xFF8A3A1B);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDEFE9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF5C4AE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.spellcheck, size: 16, color: Color(0xFFC0491E)),
              const SizedBox(width: 6),
              Text(
                '这几处像是认错字了（${items.length} 处）',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFC0491E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '只标了词表里写死的常见错字，没把握的一处都不猜。'
            '点「换成对的」直接改，不合适就手动改回来。',
            style: TextStyle(fontSize: 12, height: 1.5, color: ink),
          ),
          const SizedBox(height: 6),
          for (final s in items)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 12.5, height: 1.5, color: ink),
                        children: [
                          TextSpan(text: '${s.section}：'),
                          TextSpan(
                            text: s.from,
                            style: const TextStyle(
                              color: Color(0xFFC0491E),
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                          const TextSpan(text: ' → '),
                          TextSpan(
                            text: s.to,
                            style: const TextStyle(
                              color: Color(0xFF2E7D32),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 36,
                    child: OutlinedButton(
                      onPressed: () => _applySuspicion(s),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: WidgetStateProperty.all(const Color(0xFFC0491E)),
                        side: const BorderSide(color: Color(0xFFE5A98E)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('换成对的', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _auditCard(List<String> notes) {
    const ink = Color(0xFF8A5A1B);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD9A8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_outlined,
                  size: 16, color: Color(0xFFB26A00)),
              const SizedBox(width: 6),
              Text(
                '出图前自检 · ${notes.length} 处要注意',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFB26A00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '· $n',
                style: const TextStyle(fontSize: 12.5, height: 1.5, color: ink),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('校对一下'),
        actions: [
          if (_canReOrganize)
            TextButton(
              onPressed: _busy ? null : _reOrganize,
              child: Text(_busy
                  ? (_stage.isEmpty ? '整理中…' : '复核中…')
                  : '重新精修'),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 厨师复核报告：规划 / 挑错 / 修订都摊开给你看，不是黑箱
            if (_report != null) ChefReviewCard(report: _report!),
            if (_busy && _stage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                     SizedBox(width: 10),
                    Expanded(
                      child: Text(_stage,
                          style:  TextStyle(
                              fontSize: 12, color: AppColors.subInk)),
                    ),
                  ],
                ),
              ),
            Container(
              padding:  EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child:  Text(
                '厨师已先规划做法、逐条复核并按意见改过一遍。但用量这一栏最后还是要你自己扫一眼，改完再生成。',
                style: TextStyle(color: AppColors.primary, fontSize: 13, height: 1.5),
              ),
            ),
            // v1.47 可疑错字：只标有确凿映射的（老迪→老抽…），一键采用。
            // 放在漏料卡上面——「把料写错」和「漏了料」是一类问题，都比配图不准严重。
            if (_suspicions().isNotEmpty) _suspicionCard(_suspicions()),
            // v1.14 漏料提醒：原文提到、用料表里没有的。放在自检上面，
            // 因为「少放一样东西」比「图不太贴」严重得多。
            if (_missingIngredients().isNotEmpty)
              _missingCard(_missingIngredients()),
            // v1.11 出图前自检：实时按当前内容算（改好了这条就消失），
            // 只有「画面是就近挑的」这种依赖配图过程的提示才沿用带进来的那份。
            if (_auditNotes().isNotEmpty) _auditCard(_auditNotes()),
            _section('基本信息'),
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: '菜名'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _introCtrl,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '一句话简介', alignLabelWithHint: true),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _tag,
              decoration: const InputDecoration(labelText: '分类'),
              items: tags
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setState(() => _tag = v ?? '家常菜'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              maxLines: 1,
              decoration: const InputDecoration(labelText: '来源链接（仅作记录）'),
            ),
            _section('用料'),
            ..._ingredientRows(),
            _addTile('加一行用料', _addIngredient),
            _section('做法步骤'),
            ..._stepRows(),
            _addTile('加一步', _addStep),
            _section('小贴士'),
            TextField(
              controller: _tipsCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '一行一条，没有就留空',
                alignLabelWithHint: true,
              ),
            ),
            _rawTextBlock(),
          ],
        ),
      ),
      bottomSheet: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: Row(
              children: [
                // 做饭时更常用的其实是「一步一步来」，所以它跟「预览长图」并排放在最下面
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 50,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _goCook,
                      icon:  Icon(Icons.play_circle_outline,
                          size: 20, color: AppColors.primary),
                      label:  Text(
                        '一步一步做',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        // 背景色由主题 colorScheme.primary 统一提供（兼容新旧 Flutter 按钮 API）
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _goPreview,
                      icon: const Icon(Icons.preview_outlined),
                      label: const Text('预览长图',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「机器从视频里读到了什么」—— 可展开的原文。
  ///
  /// 用户发现菜谱漏了东西时，第一反应是「是没读出来，还是读出来了没写进去」。
  /// 把原始素材原样摊在这儿，一眼就能分清：
  ///   · 原文里压根没有 → 视频没讲，得自己补；
  ///   · 原文里有、上面却没有 → AI 漏了，点漏料卡片的「补进用料」。
  /// 不用再靠猜，也不用再发日志问人。
  Widget _rawTextBlock() {
    final raw = widget.rawText.trim();
    if (raw.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _showRaw = !_showRaw),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding:  EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                   Icon(Icons.article_outlined,
                      size: 18, color: AppColors.subInk),
                   SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _showRaw ? '收起机器读到的原文' : '看看机器从视频里读到了什么',
                      style:  TextStyle(
                          fontSize: 13.5, color: AppColors.subInk),
                    ),
                  ),
                  Icon(_showRaw ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: AppColors.subInk),
                ],
              ),
            ),
          ),
          if (_showRaw)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F6F4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                raw,
                style:  TextStyle(
                    fontSize: 12.5, height: 1.7, color: Color(0xFF55524C)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _section(String text) => Padding(
        padding:  EdgeInsets.fromLTRB(0, 22, 0, 10),
        child: Text(text, style: AppText.section),
      );

  Widget _addTile(String text, VoidCallback onTap) => Padding(
        padding:  EdgeInsets.only(top: 4),
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon:  Icon(Icons.add, size: 18),
          label: Text(text, style: TextStyle(color: AppColors.primary)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: AppColors.primary),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );

  /// 给可疑字段的输入框角上挂一个小警告图标，点一下就是对那条建议的说明。
  /// 只在有确凿证据时出现，平时不增加视觉噪音。
  Widget? _fieldWarning(String section, int index, String field) {
    final hit = _suspicions().firstWhere(
          (s) => s.section == section && s.index == index && s.field == field,
          orElse: () => const Suspicion(
              section: '', index: -1, field: '', from: '', to: '', reason: ''),
        );
    if (hit.from.isEmpty) return null;
    return Tooltip(
      message: '像是「${hit.from}」，可能该写「${hit.to}」',
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(Icons.error_outline, size: 16, color: AppColors.danger),
      ),
    );
  }

  List<Widget> _ingredientRows() {
    return List.generate(_ingNameCtrls.length, (i) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _ingNameCtrls[i],
                decoration: InputDecoration(
                  hintText: '食材',
                  suffixIcon: _fieldWarning('用料', i, 'name'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _ingAmountCtrls[i],
                decoration: InputDecoration(
                  hintText: '用量',
                  suffixIcon: _fieldWarning('用料', i, 'amount'),
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.remove_circle_outline, size: 20, color: AppColors.danger),
              onPressed: () => _removeIngredient(i),
            ),
          ],
        ),
      );
    });
  }

  List<Widget> _stepRows() {
    return List.generate(_stepTextCtrls.length, (i) {
      return Container(
        margin:  EdgeInsets.only(bottom: 12),
        padding:  EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('第 ${i + 1} 步', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.primary)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 17),
                  onPressed: () => _moveStep(i, -1),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 17),
                  onPressed: () => _moveStep(i, 1),
                  padding: EdgeInsets.zero,
                  constraints:  BoxConstraints(),
                ),
                 SizedBox(width: 12),
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
                  onPressed: () => _removeStep(i),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _stepTextCtrls[i],
              maxLines: 2,
              decoration: InputDecoration(
                hintText: '这一步做什么',
                alignLabelWithHint: true,
                suffixIcon: _fieldWarning('步骤', i, 'text'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _stepTipCtrls[i],
              maxLines: 2,
              decoration: InputDecoration(
                hintText: '关键点：火候 / 状态 / 时间 / 手法（没有就留空）',
                alignLabelWithHint: true,
                suffixIcon: _fieldWarning('步骤', i, 'tip'),
              ),
            ),
          ],
        ),
      );
    });
  }
}

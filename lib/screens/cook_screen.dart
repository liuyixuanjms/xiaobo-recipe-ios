// 页面 6 · 一步一步做（v1.8 新增）。
//
// 用户的原话：「菜谱的显示顺序能不能优化，做菜的时候更方便看……上面是照片，
// 下面是步骤，先前期准备，这样很混乱。能不能让我有一个选择，一步一步做下去。」
//
// 所以这一页只做一件事：把一道菜拆成「一步一屏」，手指一划就往下走。
// 屏幕上是：这一步的画面（大图）→ 这一步要做什么（大字）→ 关键点（醒目条）。
// 左手边始终能翻出用料清单，做菜中途不用退回首页。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/recipe.dart';
import '../services/alarm_service.dart';
import '../services/portion_scaler.dart';
import '../services/video_file.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/step_clip.dart';
import '../widgets/step_photo.dart';
import 'video_screen.dart';

class CookScreen extends StatefulWidget {
  final Recipe recipe;

  const CookScreen({super.key, required this.recipe});

  @override
  State<CookScreen> createState() => _CookScreenState();
}

class _CookScreenState extends State<CookScreen> {
  final PageController _pager = PageController();
  int _index = 0;

  /// v1.23：用料换算倍率。1.0 = 原配方量。只缩放带数字的用量，
  /// "适量 / 比梨少一点" 这类定性描述原样保留（见 PortionScaler）。
  double _portionFactor = 1.0;
  static const List<double> _portionOptions = [0.5, 1.0, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    // 做饭时手上都是油，别让屏幕自己灭
    _setKeepScreenOn(true);
  }

  @override
  void dispose() {
    _setKeepScreenOn(false);
    _pager.dispose();
    super.dispose();
  }

  static const MethodChannel _ch =
      MethodChannel('com.xiaobo.recipe/share');

  Future<void> _setKeepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod('keepScreenOn', <String, dynamic>{'on': on});
    } catch (_) {
      // 拿不到就算了，不影响做菜
    }
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.recipe.steps.length - 1);
    if (next == _index) return;
    HapticFeedback.selectionClick();
    _pager.animateToPage(
      next,
      duration:  Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _showIngredients() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          maxChildSize: 0.92,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              Row(
                children: [
                  Icon(Icons.shopping_basket_outlined, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text('用料', style: AppText.section),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '人多吃一点、人少吃一点，按倍率换算。带数字的用量会自动算，"适量 / 比梨少一点"保持原样自己拿捏。',
                // v1.48：这句是换算说明，做菜时要读；11px 的 caption 偏小，
                // 单独抬到 13。全局字号另有设置里的「偏大/特大」档位兜底。
                style: TextStyle(
                    fontSize: 13, color: AppColors.subInk, height: 1.5),
              ),
              const SizedBox(height: 12),
              // 份量倍率切换
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppColors.cream,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: _portionOptions.map((v) {
                    final label = v == 1.0 ? '原量' : '${v}x';
                    final selected = (v - _portionFactor).abs() < 0.01;
                    return Expanded(
                      child: InkWell(
                        onTap: () => setSheet(() => _portionFactor = v),
                        borderRadius: BorderRadius.circular(9),
                        child: Container(
                          // v1.48：份量切换做到 48dp 高，沾油手也点得准。
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected ? AppColors.primary : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: selected ? Colors.white : AppColors.subInk,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              if ((_portionFactor - 1.0).abs() > 0.01) ...[
                const SizedBox(height: 8),
                Text(
                  '已按 ${_portionFactor}x 换算，绿色数字是算过的；没数字的用量没动。',
                  style: AppText.tip,
                ),
              ],
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 6),
              ...widget.recipe.ingredients.map((i) {
                final r = PortionScaler.scale(i.amount, _portionFactor);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          i.name.trim().isEmpty ? '—' : i.name.trim(),
                          style: AppText.body,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          r.text.isEmpty ? '—' : r.text,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: r.scaled ? AppColors.primary : AppColors.subInk,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.recipe.steps;
    if (steps.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.recipe.title)),
        body: Center(child: Text('这道菜还没有步骤', style: AppText.bodySub)),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.card,
      appBar: AppBar(
        title: Text(
          widget.recipe.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // v1.16：做菜做到一半想看人家怎么翻的，不用退出这一页
          if (VideoFile.usable(widget.recipe.videoPath))
            IconButton(
              icon: const Icon(Icons.smart_display_outlined),
              tooltip: '看原视频',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VideoScreen(
                    path: widget.recipe.videoPath,
                    title: widget.recipe.title,
                    recipeId: widget.recipe.id,
                    sourceUrl: widget.recipe.sourceUrl,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.shopping_basket_outlined),
            tooltip: '看用料',
            onPressed: _showIngredients,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Padding(
            padding:  EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(
                  '第 ${_index + 1} 步 / 共 ${steps.length} 步',
                  style:  TextStyle(
                    fontSize: 12,
                    color: AppColors.subInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (_index + 1) / steps.length,
                      minHeight: 5,
                      backgroundColor: AppColors.cream,
                      valueColor:  AlwaysStoppedAnimation<Color>(
                          AppColors.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: PageView.builder(
        controller: _pager,
        itemCount: steps.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => _StepView(
          index: i,
          total: steps.length,
          step: steps[i],
          videoPath: widget.recipe.videoPath,
          sourceUrl: widget.recipe.sourceUrl,
          // 「动起来」播到下一步开头就回卷 —— 用下一步的时间当终点，
          // 比固定 8 秒更贴合真实节奏（有的步骤 3 秒，有的要 20 秒）。
          nextSec: i + 1 < steps.length ? steps[i + 1].atSec : -1,
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _index == 0 ? null : () => _go(-1),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppColors.line),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child:  Text(
                      '上一步',
                      style: TextStyle(fontSize: 16, color: AppColors.ink),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _index == steps.length - 1
                        ? _finish
                        : () => _go(1),
                    style: ElevatedButton.styleFrom(
                      foregroundColor: WidgetStateProperty.all(AppColors.primary),
                      onForegroundColor: WidgetStateProperty.all(Colors.white),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      _index == steps.length - 1 ? '做完了' : '下一步',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _finish() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }
}

class _StepView extends StatefulWidget {
  final int index;
  final int total;
  final StepItem step;

  /// 这一步对应的原视频（有就允许就地「动起来」）
  final String videoPath;
  final String sourceUrl;

  /// 下一步从第几秒开始（-1 表示没有/没标），当「动起来」的回卷终点
  final int nextSec;

  const _StepView({
    required this.index,
    required this.total,
    required this.step,
    this.videoPath = '',
    this.sourceUrl = '',
    this.nextSec = -1,
  });

  @override
  State<_StepView> createState() => _StepViewState();
}

class _StepViewState extends State<_StepView> {
  Timer? _timer;

  /// 剩余秒数。这个数只在「时间真的过去」时才变，
  /// 暂停时它必须冻住 —— 以前暂停后按钮失灵，就是因为它既当"剩余时间"
  /// 又当"是否在跑"两个用途，停了 Timer 却没清它，界面就永远以为还在跑。
  int _left = 0;
  int _totalSec = 0;

  /// 是否正在走秒。和 _left 彻底分开：暂停 = 停掉 Timer + _running=false，
  /// _left 保持原样，再点就是接着走。
  bool _running = false;

  /// v1.16：从设置里读出来的默认时长（用户上次亲手调过就记住那个数）。
  int _defaultSec = SettingsService.fallbackTimerSec;

  /// 本步用户手动调过的秒数，0 = 没调过（用文字里检测到的那个）。
  ///
  /// 用户的原话：「倒计时是固定的，不能来回拉动长度……我希望它有个默认值，
  /// 不准就调一下，调完退出返回它还记着。」
  /// 所以这里不只改这一次的显示，还回写进设置，下次任何一步没写时间的都用它。
  int _override = 0;

  /// 有没有可放的原视频（文件真在才算）
  bool get _hasVideo => VideoFile.usable(widget.videoPath);

  /// 点「看这一步的视频」：带着这一步的秒数进去，打开就定位到这里。
  void _openVideo() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoScreen(
          path: widget.videoPath,
          title: widget.step.text.trim().isEmpty
              ? widget.step.text
              : widget.step.text.substring(0, widget.step.text.length > 12 ? 12 : widget.step.text.length),
          recipeId: '',
          sourceUrl: widget.sourceUrl,
          initialSec: widget.step.atSec,
          stepNo: widget.index + 1,
        ),
      ),
    );
  }

  /// 点画面看大图：做饭时手上有油，图小看不清就放大看一眼。
  void _openPhoto(String path) {
    if (!File(path).existsSync()) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text('第 ${widget.index + 1} 步的画面'),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Image.file(File(path), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadDefault();
  }

  Future<void> _loadDefault() async {
    final v = await SettingsService().getDefaultTimerSec();
    if (mounted) setState(() => _defaultSec = v);
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 离开这一步（翻页 / 退出做菜页）就把铃停掉，别让它在后台一直响
    AlarmService.stop();
    super.dispose();
  }

  /// 从这一步的文字里**把所有**时间点都抠出来。
  ///
  /// 一步里常常有两三个时间（「焖 3 分钟，再大火收 1 分钟」），
  /// 以前只取第一个，第二个时间就没人提醒 —— 这恰恰是最容易翻车的一步。
  List<int> _detectTimes() {
    var t = '${widget.step.text} ${widget.step.tip}';
    final out = <int>[];

    // 「1 分 30 秒」这种连写先合成一个数，并把它从文字里剔掉，
    // 否则会被下面的规则拆成 60 和 30 两个独立时间，变成两个按钮。
    t = t.replaceAllMapped(RegExp(r'(\d+)\s*分\s*(\d+)\s*秒'), (m) {
      final sec = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
      if (sec > 0 && sec <= 3600 && !out.contains(sec)) out.add(sec);
      return ' ';
    });

    final re = RegExp(r'(\d+(?:\.\d+)?)\s*(分钟|分|min|秒钟|秒|s\b)');
    for (final m in re.allMatches(t)) {
      final v = double.parse(m.group(1)!);
      final u = m.group(2)!;
      final sec = (u.startsWith('分') || u == 'min') ? (v * 60).round() : v.round();
      if (sec <= 0 || sec > 3600) continue; // 排除「100 秒」以外的离谱数字
      if (!out.contains(sec)) out.add(sec);
    }
    return out;
  }

  void _beginTimer(int sec) {
    _timer?.cancel();
    setState(() {
      _left = sec;
      _totalSec = sec;
      _running = true;
    });
    _arm();
  }

  /// 起一条每秒减一的表。开始和继续都走这里，保证同一时刻只有一条在跑。
  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_left <= 1) {
        t.cancel();
        setState(() {
          _left = 0;
          _running = false;
        });
        _ring();
        return;
      }
      setState(() => _left--);
    });
  }

  /// 暂停：只停表，剩余时间原样保留，下次点「继续」从这儿接着走。
  void _pause() {
    _timer?.cancel();
    setState(() => _running = false);
  }

  /// 继续：拿剩下的秒数接着走，不重新从头算。
  void _resume() {
    if (_left <= 0) return;
    setState(() => _running = true);
    _arm();
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _running = false;
      _left = 0;
      _totalSec = 0;
    });
  }

  void _ring() {
    // v1.13：以前只有 HapticFeedback.vibrate()，一下极短的震动，
    // 放桌上都听不见，更别说人在灶台前。现在真的响闹铃 + 循环震动，
    // 最多 30 秒自己停，点「知道了」立刻停。
    AlarmService.ring(seconds: 30);
    HapticFeedback.vibrate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⏰ 第 ${widget.index + 1} 步的时间到了'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: '知道了',
          onPressed: AlarmService.stop,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.step;
    final hasImg = s.photoPath.trim().isNotEmpty && File(s.photoPath).existsSync();
    final times = _detectTimes();

    return ListView(
      padding:  EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        // v1.30：图不只是图。点右下角「动起来」，就把这一步那几秒静音循环出来，
        // 看得清刀往哪边落、手怎么翻。默认不播（省电、不吵），停下即释放解码器。
        StepClip(
          videoPath: widget.videoPath,
          startSec: s.atSec,
          endSec: widget.nextSec,
          child: hasImg
              // 按图片真实比例自适应，竖屏帧不再左右留一大条米色空边；
              // 比例极端时用同一张图模糊铺底，看着是自然的暗边而不是"没铺满"。
              ? StepPhoto(
                  path: s.photoPath,
                  minHeight: 150,
                  maxHeight: 380,
                  radius: 16,
                  onTap: () => _openPhoto(s.photoPath),
                )
              : Container(
                  height: 120,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.cream,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '这一步没截到画面，照着下面的字做',
                    style: AppText.bodySub,
                  ),
                ),
        ),
        // ── v1.27：这一步的原视频入口 ──────────────────────────────────
        // 用户原话：「留存视频这个事是好的，让视频能更好、更在显眼的位置看到做菜步骤。」
        // 所以把入口从右上角那个小图标挪到画面正下方，并且直接写清楚「第几秒」——
        // 点进去就是从这一步开始播，不用再自己拖进度条找。
        if (_hasVideo)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _openVideo,
              icon: const Icon(Icons.open_in_full, size: 15),
              label: Text(
                s.atSec >= 0 ? '全屏看这段（带原声）' : '全屏看原视频',
                style: const TextStyle(fontSize: 13.5),
              ),
              style: TextButton.styleFrom(
                foregroundColor: WidgetStateProperty.all(AppColors.subInk),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                // v1.48：从 30px 抬到 48dp——看画面是做菜时的高频动作。
                minimumSize: const Size(0, 48),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
            ),
          ),
         SizedBox(height: 22),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration:  BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${widget.index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding:  EdgeInsets.only(top: 3),
                child: Text(
                  s.text.trim().isEmpty ? '（这一步还没写）' : s.text.trim(),
                  style:  TextStyle(
                    fontSize: 20,
                    height: 1.55,
                    color: AppColors.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (s.tip.trim().isNotEmpty) ...[
           SizedBox(height: 16),
          Container(
            padding:  EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                 Icon(Icons.priority_high_rounded,
                    size: 18, color: AppColors.primary),
                 SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.tip.trim(),
                    style:  TextStyle(
                      fontSize: 15.5,
                      height: 1.5,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        // v1.16：计时条改成**每一步都有**。
        // 以前只在文字里出现「3 分钟」才显示，于是「小火慢炖到收汁」这种
        // 没写具体时间的步骤完全没法计时，用户只能自己掏手机另开一个表。
        const SizedBox(height: 18),
        _timerBlock(times),
      ],
    );
  }

  /// 这一步该用多少秒：用户手调过的 > 文字里写的 > 设置里的默认值。
  int _pickSec(List<int> times) {
    if (_override > 0) return _override;
    if (times.isNotEmpty) return times.first;
    return _defaultSec;
  }

  /// 调时长。未开始时只改「准备用多少」；已经在走就同时改剩余时间。
  ///
  /// 无论哪种，都把新值写进设置 —— 用户要的「退出返回还记着」就是这一步。
  Future<void> _adjust(int delta) async {
    final cur = _pickSec(_detectTimes());
    final next = (cur + delta).clamp(10, 3 * 3600);
    if (next == cur && _left == 0) return;
    setState(() {
      _override = next;
      if (_left > 0) {
        // 已经在计时：剩余和总时长一起挪，进度条才不会瞬间跳到底
        _left = (_left + delta).clamp(1, 3 * 3600);
        _totalSec = (_totalSec + delta).clamp(1, 3 * 3600);
        if (_left > _totalSec) _totalSec = _left;
      }
    });
    await SettingsService().setDefaultTimerSec(next);
  }

  /// 直接输入一个时间。做饭时想「再炖 12 分钟」，按 ± 要按 7 下，不如打字。
  Future<void> _askCustom() async {
    final cur = _pickSec(_detectTimes());
    final ctrl = TextEditingController(
      text: (cur / 60).toStringAsFixed(cur % 60 == 0 ? 0 : 1),
    );
    final minutes = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这一步要多少分钟？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:  InputDecoration(
                suffixText: '分钟',
                helperText: '可以写小数，比如 7.5',
              ),
            ),
             SizedBox(height: 8),
             Text(
              '调完会记住这个时长，下次遇到没写时间的步骤自动用它。',
              style: TextStyle(fontSize: 12, color: AppColors.subInk, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, v);
            },
            child: const Text('就用这个'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (minutes == null || minutes <= 0) return;
    final sec = (minutes * 60).round().clamp(10, 3 * 3600);
    setState(() => _override = sec);
    await SettingsService().setDefaultTimerSec(sec);
  }

  /// v1.48：计时器的 −/+/重置 是做菜时手上沾油也要点的高频按钮。
  /// 从 40 抬到 48dp（约 96px@2x），符合最小点击热区；图标同步放大到 20。
  /// 视觉上仍是「小按钮」，只是更好点——不做成主按钮那样抢眼。
  Widget _tinyBtn(IconData icon, String tip, VoidCallback onTap) => SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 20),
          color: AppColors.subInk,
          tooltip: tip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        ),
      );

  String _mmss(int sec) =>
      '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';

  /// 计时条。三种状态界面上各自清楚，不再共用一个「_left > 0」：
  ///   没开始 → 开始计时 05:00
  ///   在走   → 暂停
  ///   暂停中 → 继续（剩余时间冻住不动）
  /// 以前「暂停」只是把 Timer 掐了，_left 还留着，界面就一直以为在跑，
  /// 再点等于去掐一条已经停掉的表，所以完全没反应。
  Widget _timerBlock(List<int> times) {
    final started = _left > 0;
    final pick = _pickSec(times);

    final String label;
    final IconData icon;
    if (_running) {
      label = '暂停';
      icon = Icons.pause_rounded;
    } else if (started) {
      label = '继续';
      icon = Icons.play_arrow_rounded;
    } else {
      label = '开始计时 ${_mmss(pick)}';
      icon = Icons.timer_outlined;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                // v1.48：开始/暂停计时也抬到 48dp，和旁边的 −/+ 一致。
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _running
                      ? _pause
                      : (started ? _resume : () => _beginTimer(pick)),
                  icon: Icon(icon, size: 18),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: _running ? AppColors.primary : AppColors.line,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  label: Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: _running ? AppColors.primary : AppColors.ink,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 没开始的时候：−、+、直接输入
            if (!started) ...[
              _tinyBtn(Icons.remove, '少 1 分钟', () => _adjust(-60)),
              _tinyBtn(Icons.add, '多 1 分钟', () => _adjust(60)),
              _tinyBtn(Icons.edit_outlined, '自己填一个时间', _askCustom),
            ],
          ],
        ),
        if (started) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${(_left ~/ 60).toString().padLeft(2, '0')}:'
                '${(_left % 60).toString().padLeft(2, '0')}',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: _running ? AppColors.primary : AppColors.subInk,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _totalSec == 0
                        ? 0
                        : (1 - _left / _totalSec).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: AppColors.cream,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _running ? AppColors.primary : AppColors.subInk,
                    ),
                  ),
                ),
              ),
              // 走到一半发现不够，直接加：做菜时最常发生的就是这个
              _tinyBtn(Icons.add, '多 1 分钟', () => _adjust(60)),
              _tinyBtn(Icons.remove, '少 1 分钟', () => _adjust(-60)),
              _tinyBtn(Icons.refresh_rounded, '重新计时', _reset),
            ],
          ),
        ],
        if (started && !_running)
           Padding(
            padding: EdgeInsets.only(top: 6, left: 2),
            child: Text(
              '已暂停，点「继续」接着走',
              style: TextStyle(fontSize: 13.5, color: AppColors.subInk),
            ),
          ),
        // 一步里往往不止一个时间：全部列出来，按哪个都能一键计时
        if (!started && times.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final t in times)
                  SizedBox(
                    // v1.48：一步里有多个时间时，这些「3 分钟 / 5 分钟」
                    // 是点得最勤的快捷入口，从 32 抬到 44dp 热区。
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => _beginTimer(t),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        side: BorderSide(color: AppColors.line),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                      child: Text(
                        _human(t),
                        style: TextStyle(
                          fontSize: 13.5,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _human(int sec) {
    if (sec < 60) return '$sec 秒';
    final m = sec / 60;
    return '${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)} 分钟';
  }
}

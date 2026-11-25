// 页面 2 · 新建菜谱：录入原始内容（粘贴文字 / 系统分享带入 / 一组实拍图），调当前 AI 服务商整理。
// V0.9 起默认走「厨师精修」四步流水线（规划→整理→审稿→修订），带进度提示。
// V0.12 重要修正：
//  1) 链接不自动抓取内容 —— 抖音/小红书页面需要浏览器跑脚本且风控不稳，实测现在读不到，
//     所以不再含糊其辞，直接在页面上讲清楚要用户把字幕文字/视频截图带进来；
//  2) AI 返回「0 用料 0 步」时硬拦截，绝不再把空壳存成一道菜谱骗人；
//  3) 支持一组实拍图，会成组排进最终长图（不只是喂给 AI 读字）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config/build_flavor.dart';
import '../services/app_info.dart';
import '../services/asr_model_service.dart';
import '../services/douyin_reader.dart';
import '../services/ingest_job.dart';
import '../services/log_service.dart';
import '../services/settings_service.dart';
import '../services/xhs_reader.dart';
import '../theme/app_theme.dart';
import '../widgets/waiting_buddy.dart';
import 'log_screen.dart';
import 'review_screen.dart';

class NewRecipeScreen extends StatefulWidget {
  final String initialText;
  final String initialUrl;
  final bool fromShare;

  const NewRecipeScreen({
    super.key,
    this.initialText = '',
    this.initialUrl = '',
    this.fromShare = false,
  });

  @override
  State<NewRecipeScreen> createState() => _NewRecipeScreenState();
}

class _NewRecipeScreenState extends State<NewRecipeScreen> {
  static const List<String> tags = ['家常菜', '汤羹', '烘焙', '凉菜', '早餐', '其他'];
  static const int maxPhotos = 6;

  final _urlCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  String _tag = '家常菜';
  final List<Uint8List> _photos = [];

  // v1.25：本次会话是否已经就语音包问过用户，避免每整理一道菜都弹
  bool _asrPromptedThisSession = false;
  bool _advancedOpen = false; // 「想自己补点东西」折叠区默认收起
  bool _loggedIn = false; // 抖音是否已在本机登录（决定平台给不给作品数据）

  /// v1.33：上架版的素材入口 —— 用户从相册/文件里自己选的那段视频。
  /// 自用版不会用到它，链接入口才是主路。
  String _localVideoPath = '';
  final SettingsService _settings = SettingsService();

  // ── v1.31：进度不再归页面管 ─────────────────────────────────────────────
  // 用户的原话：「这一步返回就断了，能不能返回也不影响」。
  // 老实现把整条流水线跑在这个 State 里，退出页面 → mounted 变 false →
  // 后面每一个 `if (!mounted) return;` 都把已经读到的字幕、抽到的帧、拼好的
  // 菜谱丢掉，十几秒白干。
  //
  // 现在活干在 IngestJob（单例）里，页面只是显示器：下面这几个 getter 直接
  // 读作业的状态，所以退出再进来能接着看到 40%，而不是从 0 重来。
  IngestJob get _job => IngestJob.instance;
  bool get _busy => _job.busy;
  String get _stage => _job.stage;
  double get _progress => _job.progress;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = widget.initialUrl;
    _textCtrl.text = widget.initialText;
    _refreshLogin();
    // 回到这个页面时，作业可能还在跑、甚至已经跑完了 —— 接上它，别从零开始。
    _job.addListener(_onJobChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handoffIfReady());
  }

  void _onJobChanged() {
    if (!mounted) return;
    setState(() {});
    // 这一单没有人在 await（用户退出后又进来），成果已经躺在 pending 里 ——
    // 由监听接住，别让「做好了」在首页挂着、进来看却什么都没有。
    if (!_job.busy && _job.pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handoffIfReady());
    }
  }

  /// v1.46：点「取消整理」先确认一次。取消会丢掉这一步已经读到的一半素材，
  /// 是不可逆的，所以给一次明确的二次确认；但文案说清「菜谱不会存」，
  /// 别让人以为只是暂停。
  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('停下这次整理？'),
        content: const Text(
          '已经读到的画面和文字会丢掉，这道菜不会保存。'
          '想接着做，重新贴一次就行。',
          style: TextStyle(height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续整理'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('停下'),
          ),
        ],
      ),
    );
    if (ok == true) _job.cancel();
  }

  /// 查一下本机有没有登录过抖音，决定首页那句提示怎么写。
  Future<void> _refreshLogin() async {
    final ok = await DouyinReader().hasLogin();
    if (mounted) setState(() => _loggedIn = ok);
  }

  /// 引导登录（只需一次）。登录成功后 cookie 留在本机，之后贴链接才读得到内容。
  Future<void> _doLogin() async {
    final ok = await DouyinReader().openLogin(
      (tag, msg) => LogService.instance.log(tag, msg),
    );
    await _refreshLogin();
    if (!mounted) return;
    _snack(ok ? '已登录，现在贴链接就能读' : '没登录也没关系，随时可以再点');
  }

  @override
  void dispose() {
    // 只摘掉「显示器」，不停作业 —— 这正是「返回也不影响」的关键一行。
    _job.removeListener(_onJobChanged);
    _urlCtrl.dispose();
    _textCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ── 进度条的三件小工具 ────────────────────────────────────────────────

  /// 切阶段。真正的状态在作业里（`setStage` 自己保证只前进不后退），
  /// 这里留一个同名方法，是为了让下面那些调用点读起来还是原来的样子。
  void _setStage(String label, {double? forced}) =>
      _job.setStage(label, forced: forced);

  /// v1.46：把「可以返回」的承诺并进 ETA 行——腾出右侧空间放取消按钮，
  /// 但这句话不能丢，它是让用户敢离开、不干等的关键。
  String get _etaText {
    final e = _job.etaText;
    return e.isEmpty ? e : '$e · 可返回';
  }

  /// 一次加一张，可累加到 6 张。不用 pickMultiImage 是为了兼容旧版 image_picker。
  Future<void> _pickImage() async {
    if (_photos.length >= maxPhotos) {
      _snack('最多放 $maxPhotos 张，够做一道菜了');
      return;
    }
    try {
      final xFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (xFile == null) return;
      final bytes = await File(xFile.path).readAsBytes();
      if (!mounted) return;
      setState(() => _photos.add(bytes));
    } catch (_) {
      _snack('选图没成功，检查一下相册权限或换一张试试');
    }
  }

  // ── v1.33 · 上架版的主入口：本地视频 ──────────────────────────────────
  //
  // 上架版不提供「贴链接」入口，素材完全由用户自己提供：
  // 他在相册里选一段视频，剩下的处理和自用版一模一样。
  // 这一条路线不发任何网络请求，也不认任何平台链接。

  /// 从相册选一段视频，选完立刻开跑。
  Future<void> _pickVideo({bool autoStart = true}) async {
    if (_busy) return;
    try {
      final xFile = await _picker.pickVideo(source: ImageSource.gallery);
      if (xFile == null) return;
      if (!mounted) return;
      setState(() => _localVideoPath = xFile.path);
      if (autoStart) await _organizeLocal(xFile.path);
    } catch (_) {
      _snack('选视频没成功，检查一下相册权限，或者换一个文件试试');
    }
  }

  /// 把「用户选的那一个本机视频」交给后台作业。
  ///
  /// 和 [_organize] 的差别只有一处：素材不是从链接读的，而是用户自己点的文件。
  /// 后面切步骤、抽用料、配图、自检、存视频，全部走同一套代码。
  Future<void> _organizeLocal(String path) async {
    if (_busy) return;
    final logs = LogService.instance;
    Future<void> sink(String tag, String msg) => logs.log(tag, msg);

    final text = _textCtrl.text.trim();
    final titleHint =
        _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim();

    await logs.startSession('本地视频 → 本地整理成菜谱', <String, String>{
      'App 版本': AppInfo.version,
      '系统': LogService.platformInfo,
      '构建变体': flavorName,
      '整理引擎': '纯本地（零 API、离线、不花钱）',
      '素材来源': '本机视频（用户自己选的，全程不联网）',
      '视频文件': path.split(Platform.pathSeparator).last,
      '手打文字': '${text.length} 字',
      '手动加图': '${_photos.length} 张',
    });

    final outcome = await _job.run(
      url: '',
      text: text,
      titleHint: titleHint,
      tag: _tag,
      photos: List<Uint8List>.from(_photos),
      isXhs: false,
      readLink: false,
      sink: sink,
      localVideoPath: path,
    );

    if (!mounted) return;

    if (outcome == null) {
      final err = _job.takeError();
      // 故意不走 _showJobError：那一套的 'read' 出口是「打开网页验证 / 登录抖音」，
      // 对本地文件毫无意义。
      if (err != null) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(err.title),
            content: Text(err.detail, style: const TextStyle(height: 1.55)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
      return;
    }
    await _openReview(outcome);
  }

  /// 一条链接是不是「能拿去自动读」的分享链接。**抖音和小红书都在里面**（v1.11）。
  ///
  /// 【V1.4】抖音分享文案里的链接**经常不带 https://**，只写 `v.douyin.com/xxx`，
  /// 所以协议头做成可选的，最后统一补上。小红书短链同理（`xhslink.com/a/xxx`）。
  static final RegExp _recipeLinkRe = RegExp(
    r'(?:https?://)?(?:v\.douyin\.com|www\.douyin\.com|www\.iesdouyin\.com|douyin\.com'
    r'|xhslink\.com|xhslink\.cn|www\.xiaohongshu\.com|xiaohongshu\.com)'
    r'/[^\s，,。；;、）)\]】]+',
    caseSensitive: false,
  );

  /// 单独判一下平台：两条链路的取料方式完全不同，不能混着走。
  static bool _isXhsLink(String url) => XhsReader.looksLikeXhs(url);

  /// 从一段文字里找出第一个受支持的链接（返回 Match，便于连位置一起删掉）。
  static Match? _extractRecipeLink(String raw) => _recipeLinkRe.firstMatch(raw);

  /// 补全协议头，`v.douyin.com/xx` → `https://v.douyin.com/xx`。
  static String _normalizeLink(String s) {
    final t = s.trim();
    return t.startsWith('http') ? t : 'https://$t';
  }

  /// 这段文字像不像「真正的配方」，而不是平台分享文案。
  /// 分享文案通常只有标题 + 几个 #话题 + "复制打开抖音"之类的引导语，没有任何用量和做法。
  ///
  /// 注意别用单个动作词判断：菜名里就常带「炒」（酱炒韭菜鸡蛋），
  /// 用「先/再/然后」这类**顺序词**才靠谱 —— 分享文案里几乎不会出现。
  static bool _looksLikeRecipeText(String t) {
    final s = t.trim();
    if (s.length < 15) return false;
    // 有明确用量：数字 + 常见单位
    final hasAmount = RegExp(
      r'\d+(?:\.\d+)?\s*(?:克|g|G|kg|毫升|ml|mL|升|勺|大勺|小勺|汤匙|茶匙|碗|杯|个|颗|根|片|瓣|斤|两|把|撮|滴|度|分钟|秒)',
    ).hasMatch(s);
    // 有「用料/食材/主料/配料/调料/做法/步骤」这类分段小标题
    final hasSection = RegExp(r'用料|食材|主料|辅料|配料|调料|做法|步骤').hasMatch(s);
    // 有操作顺序词（比单个「炒」靠谱得多）
    final hasSequence = RegExp(
      r'先|再|然后|接着|最后|之后|第一步|第二步|1[.、]|2[.、]',
    ).hasMatch(s);
    final hasAction = RegExp(
      r'翻炒|煸|焯|炖|煮|蒸|炸|煎|烤|腌|打散|淋|收汁|出锅|装盘|热锅|倒油|切好|切段|切片',
    ).hasMatch(s);
    return hasAmount || hasSection || (hasSequence && hasAction);
  }

  /// AI 整理结果够不够格出图：**用料和步骤必须都有**。
  ///
  /// 【V1.4 修正】以前写成「有料 或 有步骤」，结果日志里那条
  /// 「用料 3 项 / 步骤 0 步」的残废菜谱照样通过、照样出图 —— 用户拿到一张
  /// 只有配料没有做法的图，等于白做。菜谱没有步骤就不成立，这里改成「且」。
  /// 自动读链接失败：说清楚是平台侧的限制，并给出能救回来的动作，
  /// 不再让用户自己去截图/打字来救场。
  ///
  /// v1.11：抖音和小红书的失败原因不是一回事，提示必须分开 ——
  /// 小红书根本不需要登录，给它弹「登录一次」只会让人更困惑。
  Future<void> _showAutoReadFailDialog(String reason, {bool isXhs = false}) async {
    if (!mounted) return;
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isXhs ? '这条小红书没读出来' : '这条链接这次没读出来'),
        content: Text(
          isXhs
              ? '$reason\n\n'
                  '小红书这两点最容易出问题：\n'
                  '① 链接要「原样整段」复制 —— 少一个字符、或者手动改过，'
                  '里面的访问凭证就失效了；\n'
                  '② 私密笔记、仅粉丝可见、已删除的，网页版本来就打不开。'
              : '$reason\n\n'
                  '按顺序试这两个，基本能解决：\n'
                  '① 「登录一次再试」——抖音要登录后才把作品内容给网页，登一次就长期有效；\n'
                  '② 还不行就「打开网页验证」——平台偶尔弹人机验证，你在网页里滑一下、点一下就过。',
          style: const TextStyle(height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogScreen()),
              );
            },
            child: const Text('看运行日志'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('再试一次'),
          ),
          if (!isXhs)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'open'),
              child: const Text('打开网页验证'),
            ),
          if (!isXhs)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'login'),
              child: const Text('登录一次再试'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (pick == 'open') {
      final raw = _urlCtrl.text.trim().isEmpty ? _textCtrl.text : _urlCtrl.text;
      final url = DouyinReader.extractUrl(raw);
      if (url.isEmpty) {
        _snack('先把链接贴进上面的框，再点这个');
        return;
      }
      final back = await DouyinReader().openPage(
        url,
        (tag, msg) => LogService.instance.log(tag, msg),
      );
      if (!mounted) return;
      if (back) {
        _snack('回来了，正在重读这条链接…');
        _organize();
      }
    } else if (pick == 'retry') {
      _organize();
    } else if (pick == 'login') {
      final ok = await DouyinReader().openLogin(
        (tag, msg) => LogService.instance.log(tag, msg),
      );
      if (!mounted) return;
      if (ok) {
        _snack('已登录，正在重新读这条链接…');
        _organize();
      } else {
        _snack('没登录也没关系，可以换一条公开的作品再试');
      }
    }
  }

  Future<void> _organize() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    // 【V0.14】每次整理开一份日志会话。所有底层服务都把细节回吐到 sink，
    // 由这里统一写盘 —— 用户「跑不通」时导出来就能看见断在哪一步。
    final logs = LogService.instance;
    Future<void> sink(String tag, String msg) => logs.log(tag, msg);

    var url = _urlCtrl.text.trim();
    var text = _textCtrl.text.trim();
    var titleHint =
        _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim();

    // 【V1.4 关键修正】用户实际最常见的操作，是把抖音/小红书那**整段分享文案**
    // （"3.87 复制打开抖音… https://v.douyin.com/xxx/ …"）一股脑粘进某个输入框。
    // 以前只认「来源链接」框里是干净网址，于是：
    //   · 粘进「原始内容」→ url 为空，自动读视频整条链路从不启动；
    //   · 粘进「来源链接」→ 整段 107 字被当成网址去请求，必然失败。
    // 现在两个框都做一次归一化：抠出真正的链接，剩下的文字并回正文。
    final urlMatch = _extractRecipeLink(url);
    if (urlMatch != null) {
      // 链接框里可能是「整段文案」，也可能只是「不带 https:// 的裸链接」，都归一化一次。
      final link = _normalizeLink(urlMatch.group(0)!);
      final rest = url.replaceRange(urlMatch.start, urlMatch.end, ' ').trim();
      if (rest.isNotEmpty) {
        text = text.isEmpty ? rest : '$rest\n$text';
        _textCtrl.text = text;
      }
      if (link != url) {
        await sink('链接修正', '「来源链接」框里抓出链接并补全协议头：$link');
      }
      url = link;
      _urlCtrl.text = url;
      if (mounted) setState(() {});
    } else if (url.isEmpty) {
      final picked = _extractRecipeLink(text);
      if (picked != null) {
        url = _normalizeLink(picked.group(0)!);
        _urlCtrl.text = url;
        text = text
            .replaceRange(picked.start, picked.end, ' ')
            .replaceAll(RegExp(r'[ \t]+'), ' ')
            .trim();
        _textCtrl.text = text;
        await sink('链接修正',
            '「原始内容」里发现了视频链接，已自动挪到「来源链接」框：$url');
        if (mounted) setState(() {});
      }
    }

    // v1.12 修正：以前是「文字像配方就不读链接」，结果小红书分享文案
    // （标题 + 几个话题 + 一句「软烂入味」）被误判成配方，链接一次都没被打开，
    // 86 个字硬跑四步 AI，用料 0 项 / 步骤 0 步，白花钱还报「素材不可用」。
    //
    // 现在的规则：**有链接就去读**。理由很实在 —— 分享文案再像配方，也只是
    // 作者写的一句话简介，真正的用料和步骤在视频里 / 图文正文里。
    // 读到的内容和用户手打的文字会合并送给 AI，手打的部分一个字都不丢。
    var textLooksLikeRecipe = _looksLikeRecipeText(text);
    // 用户自己加了图，说明他要以图为准，就不去爬链接了（避免把他选的图冲掉）。
    final wantReadLink = url.isNotEmpty && _photos.isEmpty;

    // v1.11：小红书也能自动读了（图文 + 视频）。两条链路取料方式完全不同，
    // 先认平台，后面所有分支都按它走 —— 别再拿小红书链接去当抖音请求。
    final isXhs = url.isNotEmpty && _isXhsLink(url);
    if (isXhs) {
      await sink('平台', '识别到小红书链接，走小红书通道（图文 / 视频都支持）');
    }

    bool detailed = true;
    bool loggedIn = false;
    try {
      detailed = await _settings.isChefReviewEnabled();
      // 小红书公开笔记不需要登录，只有抖音要看登录态
      if (!isXhs) loggedIn = await DouyinReader().hasLogin();
    } catch (_) {}

    await logs.startSession('贴链接 / 输内容 → 本地整理成菜谱', <String, String>{
      'App 版本': AppInfo.version,
      '系统': LogService.platformInfo,
      '整理引擎': '纯本地（零 API、离线、不花钱）',
      '整理方式': detailed ? '精细整理（切步骤+抽料+核对）' : '快速整理（只切步骤+抽料）',
      '来源链接': url.isEmpty ? '（空）' : url,
      '链接平台': url.isEmpty ? '（无链接）' : (isXhs ? '小红书' : '抖音'),
      '原始文字': '${text.length} 字',
      '文字像配方吗': textLooksLikeRecipe ? '像（会和链接内容合并）' : '不像（只有标题/话题）',
      '手动加图': '${_photos.length} 张',
      '抖音登录状态':
          isXhs ? '（小红书不需要登录）' : (loggedIn ? '已登录（作品页会返回数据）' : '未登录（平台不给作品数据）'),
      '走自动读链接': wantReadLink ? '是' : '否',
    });
    await sink('输入',
        '链接 ${url.length} 字｜文字 ${text.length} 字｜已选图 ${_photos.length} 张');

    // 【V1.4 提前提醒】既没链接、又没图、文字里也看不到用料和做法时，
    // 先问一句再花钱跑 AI —— 日志里那次就是拿 107 个字标题+话题硬跑四步，
    // 26 秒后得到「3 项用料 / 0 步」的残次品。问一句比白跑强，但不硬拦（用户可能就想试试）。
    if (url.isEmpty &&
        _photos.isEmpty &&
        !textLooksLikeRecipe &&
        text.trim().length >= 6) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('这段文字里没有做法步骤'),
          content: const Text(
            '你贴的这段只有菜名和话题，没有用料、用量和做法。\n'
            '直接整理只能得到菜名，得不到能照着做的步骤。\n\n'
            '更省事的做法：把这条作品的**链接**贴进上面的框，'
            'App 会自己去视频里找用料、找步骤、找画面。\n\n'
            '也可以照样整理试试。',
            style: TextStyle(height: 1.55),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('我去贴链接'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('照样整理'),
            ),
          ],
        ),
      );
      if (go != true) {
        await sink('终止', '用户选择先补内容，未发起整理');
        await logs.end('⚠️ 文字里无做法，用户选择返回补充');
        return;
      }
      await sink('继续', '用户选择照样整理（文字里可能没有做法步骤）');
    }

    // 【V1.5.1】没登录就去读，平台一定不给内容，白等 20 秒。
    // 所以先问一句要不要登录（一次就够），点「先试试」照样往下走。
    // v1.11：小红书公开笔记不需要登录，这条只对抖音弹。
    if (wantReadLink &&
        !isXhs &&
        !_loggedIn) {
      final want = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('先登录一次抖音？'),
          content: const Text(
            '抖音现在只对「已登录」的网页返回作品内容，不登录基本读不出来。\n'
            '在 App 里登录一次就行，以后贴链接不用再登。',
            style: TextStyle(height: 1.55),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('先试试'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('登录一次'),
            ),
          ],
        ),
      );
      if (want == true) {
        await _doLogin();
        await sink('登录', _loggedIn ? '已登录，继续读链接' : '仍未登录，继续尝试（多半读不到）');
      } else {
        await sink('登录', '用户选择先不登录，直接尝试读取');
      }
    }

    // v1.25：这份链接是视频、但语音包还没下载 —— 就在「要用」的这一刻引导下载，
    // 下完这次立即能听视频讲解，以后永久免下。用户拒绝就用画面字幕兜底，不打断。
    if (wantReadLink && !_asrPromptedThisSession) {
      _asrPromptedThisSession = true; // 一次会话只问一次，别每道菜都弹
      try {
        final asr = AsrModelService();
        if (!await asr.isReady()) {
          final onWifi = await asr.isOnWifi();
          final want = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('下载语音包？'),
              content: Text(
                onWifi
                    ? '这段视频可以「听讲解」：用量、火候、下锅顺序常只说不写，'
                        '比画面字幕更全。\n语音包约 79MB，你现在连着 WiFi，'
                        '下完这次就能用，且以后永久免下。'
                    : '这段视频可以「听讲解」（用量、火候常只说不写）。\n'
                        '语音包约 79MB，你现在用的是流量，建议连 WiFi 再下。'
                        '现在下会消耗约 79MB 流量；不选也能整理，只是仅用画面字幕。',
                style: const TextStyle(height: 1.55),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('先不用（用字幕）'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(onWifi ? '现在下载' : '仍要下载'),
                ),
              ],
            ),
          );
          if (want == true) {
            _setStage('正在下载语音包（约 79MB）…');
            try {
              await asr.download(
                onProgress: (p) {
                  if (!mounted) return;
                  // v1.26：显示「已下 / 共多少 MB · 速度」，下 79MB 得几十秒，
                  // 只给一个百分比容易让人以为卡住了。
                  _setStage('下载语音包 ${p.human}…');
                },
              );
              await sink('语音包', '下载完成，这次整理能听视频讲解了；以后永久免下');
            } catch (e) {
              await sink('语音包', '这次没下成（$e），先用画面字幕整理，不影响出菜谱；下次可重试');
              if (mounted) _snack('语音包没下成，先用字幕整理，不影响出菜谱');
            }
          } else {
            await sink('语音包', '用户选择跳过，这次仅用画面字幕整理');
          }
        }
      } catch (e) {
        await sink('语音包', '检查语音包状态出错（$e），不影响整理');
      }
    }

    // ── 从这里开始，交给后台作业 ───────────────────────────────────────────
    // 上面那些弹窗（没做法 / 要不要登录 / 下不下语音包）必须由页面问，
    // 因为要用 BuildContext。问完就开跑；跑起来以后页面随时能退出 ——
    // 作业活在 IngestJob 里，退出只掉一个「显示器」，活不会断。
    final outcome = await _job.run(
      url: url,
      text: text,
      titleHint: titleHint,
      tag: _tag,
      photos: List<Uint8List>.from(_photos),
      isXhs: isXhs,
      readLink: wantReadLink,
      sink: sink,
    );

    // 页面已经退掉了：成果留在 job.pending 里，首页那条「菜谱做好了」会接住它。
    if (!mounted) return;

    if (outcome == null) {
      final err = _job.takeError();
      if (err != null) await _showJobError(err, isXhs: isXhs);
      return;
    }
    await _openReview(outcome);
  }

  /// 把作业的成果送到校对页。
  Future<void> _openReview(IngestOutcome o) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          recipe: o.recipe,
          rawText: o.rawText,
          sourceUrl: o.sourceUrl,
          titleHint: o.titleHint,
          imageBytes: null,
          subtitleLines: o.subtitleLines,
          photos: o.photos,
          report: o.report,
          auditNotes: o.auditNotes,
        ),
      ),
    );
    await LogService.instance.log('返回',
        '从校对页返回（若日志里没有「出图」记录，说明没走到保存长图那一步）');
  }

  /// 页面重新出现时：作业已经做完了就直接接到校对页；还在跑就什么都不做
  /// （进度面板自己会显示）。这是「返回去逛一圈再回来」能续上的关键。
  Future<void> _handoffIfReady() async {
    if (!mounted || _job.busy) return;
    final p = _job.takePending();
    if (p == null) return;
    await _openReview(p);
  }

  /// 统一的失败提示。三种情况给的出口不一样：
  ///  · 链接没读出来 —— 重试 / 登录 / 打开网页验证（平台侧的问题，用户能自救）
  ///  · 内容不完整 —— 解释为什么不硬凑，让他换一条
  ///  · 其它 —— 给一条日志入口
  Future<void> _showJobError(IngestError err, {bool isXhs = false}) async {
    if (!mounted) return;
    if (err.kind == 'read') {
      await _showAutoReadFailDialog(err.detail, isXhs: isXhs);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(err.title),
        content: Text(err.detail, style: const TextStyle(height: 1.55)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogScreen()),
              );
            },
            child: const Text('看运行日志'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasLink = _urlCtrl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        // 文案跟着首页走：入口叫「收一道新菜」，进来别突然变成「新建菜谱」
        title: const Text('收一道新菜'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogScreen()),
            ),
            icon: const Icon(Icons.article_outlined),
            tooltip: '运行日志 / 导出给开发者',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.fromShare) _shareBanner(),
            // 上架版（kInternal == false）整块链接 UI 不渲染。
            // 这不是「藏起来」，而是编译期常量分支 —— AOT 会把它当死代码消掉，
            // 连带解析链接的那些类一起从产物里消失。
            if (kInternal) ...[
              if (hasLink) _linkNotice(),
              TextField(
                controller: _urlCtrl,
                maxLines: 3,
                minLines: 1,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 15, height: 1.5),
                decoration: const InputDecoration(
                  labelText: '粘贴抖音 / 小红书链接 / 整段分享文案',
                  hintText: '抖音、小红书都行：整段分享文案直接贴，App 自己去读',
                  alignLabelWithHint: true,
                  helperText: '只贴这一条就够了：菜名、用料、步骤、实拍图都由 App 自己去视频里找',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 10),
              _onlyLinkHint(),
              _loginRow(),
            ] else
              _localVideoPanel(),
            const SizedBox(height: 14),
            _advancedPanel(),
          ],
        ),
      ),
      bottomSheet: _bottomButton(),
    );
  }

  /// 上架版的素材入口：从相册选一段自己的视频。
  ///
  /// 文案刻意不提任何平台名字。商店审核看的就是这几行字，
  /// 「导入你自己的视频」和「下载别人的视频」是两件完全不同的事，
  /// 前者不需要任何解释，后者解释不清。
  Widget _localVideoPanel() {
    final picked = _localVideoPath.isNotEmpty;
    final name =
        picked ? _localVideoPath.split(Platform.pathSeparator).last : '';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(Icons.video_library_outlined,
              size: 40, color: AppColors.primary),
          const SizedBox(height: 10),
          Text(
            picked ? '选好了这一段' : '选一段做菜视频',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: AppColors.ink),
          ),
          const SizedBox(height: 6),
          Text(
            picked
                ? name
                : '从手机相册里挑一段你自己拍的、或者已经存在本机的视频，\n'
                    'App 会把里面的做法整理成能照着做的菜谱。',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: AppColors.ink),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed:
                _busy ? null : () => _pickVideo(autoStart: false),
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: Text(picked ? '换一段' : '从相册选视频'),
          ),
        ],
      ),
    );
  }

  /// 一句话把「你什么都不用准备」讲清楚。
  /// 以前这里写的是「读不到时你再补文字 / 再加截图」，等于把活推给用户，
  /// 用户原话是「我更想要傻瓜操作，只给你链接」——所以这段必须改成承诺。
  Widget _onlyLinkHint() => Container(
        padding:  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:  <Widget>[
            Icon(Icons.auto_awesome, size: 16, color: AppColors.primary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '不用写配方、不用自己截图。App 会自己打开链接、读视频里的文字、'
                '从视频里抓画面当实拍图。',
                style: TextStyle(
                    fontSize: 12.5, height: 1.5, color: AppColors.ink),
              ),
            ),
          ],
        ),
      );

  /// 可选补充区：配方文字 / 菜名 / 分类 / 自己加图。
  /// 这些都是「用户的选择」，不是完成菜谱的前提，所以默认收起。
  Widget _advancedPanel() => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _advancedOpen = !_advancedOpen),
              child: Padding(
                padding:
                     EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.tune, size: 16, color: AppColors.primary),
                     SizedBox(width: 8),
                     Expanded(
                      child: Text(
                        '想自己补点东西再点开（可选）',
                        style: TextStyle(fontSize: 13, color: AppColors.ink),
                      ),
                    ),
                    Icon(
                      _advancedOpen ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ),
            if (_advancedOpen) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextField(
                      controller: _textCtrl,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '手上有现成配方？贴这儿（选填）',
                        hintText: '比如包装袋上的配料表、别处抄来的做法',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _imagePicker(),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _titleCtrl,
                      maxLines: 1,
                      decoration: const InputDecoration(
                        labelText: '菜名（选填，留空自动起）',
                      ),
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
                  ],
                ),
              ),
            ],
          ],
        ),
      );

  /// 抖音登录状态 + 一键登录。
  /// 平台现在只对「已登录」的网页给作品内容，所以这一行不是可选项，
  /// 但也不能做成拦路虎：没登录也允许点整理，失败时再引导。
  Widget _loginRow() => Padding(
        padding:  EdgeInsets.only(top: 6, left: 2),
        child: Row(
          children: <Widget>[
            Icon(
              _loggedIn ? Icons.check_circle_outline : Icons.info_outline,
              size: 15,
              color: AppColors.primary,
            ),
             SizedBox(width: 6),
            Expanded(
              child: Text(
                _loggedIn
                    ? '抖音已登录，贴链接就能读'
                    : '抖音还没登录：平台不给内容，先登录一次',
                style:  TextStyle(
                    fontSize: 12, color: AppColors.ink, height: 1.4),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _doLogin,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _loggedIn ? '重新登录' : '登录一次',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
      );

  /// 带链接进来时的说明条（不再教用户「读不到就自己补」）。
  Widget _linkNotice() => Padding(
        padding:  EdgeInsets.only(bottom: 14),
        child: Container(
          padding:  EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children:  <Widget>[
                  Icon(Icons.info_outline, color: AppColors.primary, size: 19),
                  SizedBox(width: 8),
                  Text(
                    '贴链接会自动读视频里的字幕',
                    style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                '点下面「一键做成菜谱」，App 会自己：打开作品页 → 读出文案 → 下载视频 → '
                '抽帧认画面上的字 → 挑 6 张画面当实拍图。\n'
                '你不用写配方、不用截图、不用加图。\n'
                '万一某条作品平台不放行（要登录 / 已删除 / 只在 App 内可见），'
                'App 会直接告诉你，并记进运行日志，你点右上角图标导出发我就行。',
                style: TextStyle(
                    color: AppColors.ink, fontSize: 13, height: 1.55),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogScreen()),
                  ),
                  icon: const Icon(Icons.article_outlined, size: 16),
                  label: const Text('看运行日志 / 导出', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _shareBanner() => Padding(
        padding:  EdgeInsets.only(bottom: 14),
        child: Container(
          padding:  EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children:  <Widget>[
              Icon(Icons.input_rounded, color: AppColors.primary, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '已从分享带入文案和链接。分享文案通常只有标题和话题，'
                  '记得补上用料/做法文字或视频截图再整理。',
                  style: TextStyle(color: AppColors.primary, fontSize: 13, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _imagePicker() {
    return Container(
      padding:  EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.photo_library_outlined,
                color: _photos.isEmpty ? AppColors.subInk : AppColors.primary,
                size: 20,
              ),
               SizedBox(width: 10),
              Expanded(
                child: Text(
                  _photos.isEmpty
                      ? '加几张视频截图 / 图文原图，会成组排进菜谱'
                      : '已选 ${_photos.length} 张实拍图（最多 $maxPhotos 张）',
                  style: AppText.bodySub,
                ),
              ),
              if (_photos.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined, size: 19),
                  tooltip: '清空已选',
                  onPressed: () => setState(() => _photos.clear()),
                ),
              TextButton(onPressed: _pickImage, child: const Text('加图')),
            ],
          ),
          if (_photos.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 66,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _photos[i],
                    width: 66,
                    height: 66,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _bottomButton() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: _busy
            ? _progressPanel()
            : SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: kInternal
                      ? _organize
                      : (_localVideoPath.isEmpty
                          ? () => _pickVideo()
                          : () => _organizeLocal(_localVideoPath)),
                  child: Text(
                    kInternal
                        ? '一键做成菜谱'
                        : (_localVideoPath.isEmpty ? '选一段视频开始' : '开始整理'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
      ),
    );
  }

  /// 干活时的进度面板（v1.31 重做）。
  ///
  /// 老版本只有一个转圈 + 一行「别退出，退出会从头再来」——用户既帮不上忙，
  /// 也不敢走，只能盯着屏幕等 40 秒。这一版：
  ///   · 左边一个自己换场景的小动画（锅→番茄→打蛋碗→菜板）陪着，不刷屏但一直在动；
  ///   · 右边阶段、百分比、进度条照旧（这个必须准，不能为了好看含糊）；
  ///   · 中间轮换一句关心话，按进度分段挑句子，不会在下载时说什么「在切菜」；
  ///   · 末尾明说「不用守着，返回也行」——因为作业确实不依赖这个页面。
  Widget _progressPanel() {
    final pct = (_progress * 100).clamp(0, 100).round();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          WaitingBuddy(size: 78, stage: _stage),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _stage.isEmpty ? '正在开始…' : _stage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$pct%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                WaitingCopy(progress: _progress),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: _progress),
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOut,
                    builder: (_, v, __) => LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      backgroundColor: Colors.white24,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _etaText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // v1.46：取消入口。给足 40px 高（≈48dp 视觉热区），
                    // 描边样式在蓝底上够清楚，又不像主按钮那样诱人误点。
                    SizedBox(
                      height: 40,
                      child: TextButton(
                        onPressed: _confirmCancel,
                        style: TextButton.styleFrom(
                          foregroundColor: WidgetStateProperty.all(Colors.white),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: BorderSide(
                                color: Colors.white.withOpacity(0.55)),
                          ),
                        ),
                        child: const Text(
                          '取消整理',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

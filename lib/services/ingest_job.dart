// 一次「把链接做成菜谱」的全程作业（v1.31）。
//
// 为什么抽成单例：用户的实际操作是「贴链接 → 等 → 嫌慢，返回去刷别的」。
// 老实现整条流水线跑在页面 State 里，退出页面后 `mounted` 变 false，
// 后半段那些 `if (!mounted) return;` 直接把**已经下载好的视频、抽好的帧、
// 读好的字幕、拼好的菜谱**全丢掉 —— 十几秒的活白干，用户回来看到输入框
// 还是原样，自然就说「一返回就断了」。
//
// 现在：作业活在单例里，页面只是「显示器」。
//   · 进来就 subscribe，退出就 unsubscribe，作业照跑；
//   · 跑完把成果留在 pending 里，首页和新建页都能认领；
//   · 进度、阶段、ETA 也放在这里，所以重进页面能接着看到 40% 而不是从 0 开始。
//
// 一句话原则：**UI 可以死，活不能断。**
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/chef_review.dart';
import '../models/recipe.dart';
import 'douyin_reader.dart';
import 'frame_matcher.dart';
import 'local_recipe_builder.dart';
import 'local_video_reader.dart';
import 'log_service.dart';
import 'recipe_audit.dart';
import 'settings_service.dart';
import 'stage_progress.dart';
import 'storage_service.dart';
import 'work_guard.dart';
import 'xhs_reader.dart';

/// 作业跑完之后交给 UI 的一整包东西：够开校对页，也够判断要不要提示。
class IngestOutcome {
  final Recipe recipe;
  final String rawText;
  final String sourceUrl;
  final String? titleHint;
  final List<SubLine> subtitleLines;
  final List<Uint8List> photos;
  final ChefReviewReport report;
  final List<String> auditNotes;

  const IngestOutcome({
    required this.recipe,
    required this.rawText,
    required this.sourceUrl,
    required this.titleHint,
    required this.subtitleLines,
    required this.photos,
    required this.report,
    required this.auditNotes,
  });
}

/// 失败说明。`title` 当弹窗标题，`detail` 是给人看的整段话。
class IngestError {
  final String title;

  /// 人话说明。读链接失败的场景里这里只放「原因」，补救办法由页面弹窗补上。
  final String detail;

  /// 'read' = 链接没读出来（页面会给重试/登录/开网页三个出口）
  /// 'empty' = 读出来了但内容不完整（页面会解释为什么不硬凑）
  /// 'other' = 其它意外
  final String kind;

  const IngestError(this.title, this.detail, this.kind);
}

/// 后台跑着的那一件活。
class IngestJob extends ChangeNotifier {
  IngestJob._();
  static final IngestJob instance = IngestJob._();

  bool _busy = false;
  String _stage = '';
  String _label = '';
  double _progress = 0;
  DateTime? _startAt;
  Timer? _tick;
  Timer? _watchdog;

  /// v1.46：作业「代次」。每次 begin 或 cancel 都会 +1。
  ///
  /// 为什么要这个：底层那些 await（下载、抽帧、压视频）没法从外部中断。
  /// 用户点取消 / 立刻发起下一单时，旧那趟还在 await 里睡着。等它醒来，
  /// 如果只靠一个 bool 判断，会把它己经过期的字幕、视频、成果写进 pending，
  /// 覆盖掉新的一单。用代次号才能认出「这不是我这一趟了，结果直接丢弃」。
  int _generation = 0;

  IngestOutcome? _pending;
  String _errorTitle = '';
  String _errorDetail = '';
  String _errorKind = 'other';
  int _finishedCount = 0;

  /// 正在跑
  bool get busy => _busy;

  /// 当前阶段文案（和 StageProgress 的关键字对得上）
  String get stage => _stage;

  /// 这一单叫什么（菜名或链接域名），给首页那个小条用
  String get label => _label;

  double get progress => _progress;

  /// 做好了、等着看的那一份。UI 认领时调 [takePending]。
  IngestOutcome? get pending => _pending;

  /// 失败原因（人话）。UI 认领时调 [takeError]。
  String get errorTitle => _errorTitle;
  String get errorDetail => _errorDetail;

  /// 成功了几次。首页靠它变化去刷新列表 —— 作业在后台跑完，
  /// 首页并不知道，得有个能监听的东西。
  int get finishedCount => _finishedCount;

  IngestOutcome? takePending() {
    final p = _pending;
    _pending = null;
    if (p != null) notifyListeners();
    return p;
  }

  /// 认领失败信息；没有失败就返回 null。
  /// （用一个小类而不是 record —— 这个项目锁在 Dart 2.17，record 是 3.0 才有的。）
  IngestError? takeError() {
    if (_errorTitle.isEmpty) return null;
    final e = IngestError(_errorTitle, _errorDetail, _errorKind);
    _errorTitle = '';
    _errorDetail = '';
    notifyListeners();
    return e;
  }

  /// 还差多久。前 8% 不算 —— 那时候样本太小，估出来常常是「还要 12 分钟」，吓人。
  String get etaText {
    final t0 = _startAt;
    if (t0 == null || !_busy) return '';
    final el = DateTime.now().difference(t0).inMilliseconds / 1000.0;
    if (_progress <= 0.08 || el < 3) return '正在估算还要多久…';
    final total = el / _progress.clamp(0.01, 1.0);
    final left = total - el;
    if (left <= 4) return '马上就好';
    if (left < 60) return '预计还要 ${left.round()} 秒';
    return '预计还要 ${(left / 60).ceil()} 分钟';
  }

  /// 只许前进不许后退：小红书图文会跳过下载和抽帧，
  /// 按文案硬套就会从 40% 掉回 10%，看起来像出错。
  void setStage(String label, {double? forced}) {
    final p = forced ?? StageProgress.lookup(label);
    _stage = label;
    if (p != null && p > _progress) _progress = p;
    notifyListeners();
  }

  /// 当前这一趟的代次号。取消后旧作业靠比对它自我作废。
  int get generation => _generation;

  /// 用户主动取消正在跑的这一单。
  ///
  /// 不能真正掐断底层 await（原生下载/抽帧不受 Dart 控制），所以做的是：
  /// 代次 +1 让旧作业作废，立刻收掉看门狗与常驻通知，界面马上回到可再点的状态；
  /// 旧作业在每个阶段边界比对代次，发现自己过期就静默丢弃，绝不产出、绝不弹错。
  void cancel() {
    if (!_busy) return;
    _generation++;
    _finish();
  }

  /// 开始一单。返回 true 表示真的开始了（已有一单在跑就返回 false）。
  bool begin(String label) {
    if (_busy) return false;
    _generation++;
    _busy = true;
    _label = label;
    _stage = '正在准备…';
    _progress = 0;
    _startAt = DateTime.now();
    _tick?.cancel();
    // 每秒刷一次，让「预计还要 N 秒」真的在倒数 —— 页面退出后也要继续数，
    // 所以这个 Timer 归作业所有，不归页面。
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_busy) notifyListeners();
    });
    // 兜底：真卡死（比如原生下载毫无响应）时不能让用户看一个永远 8% 的条。
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(minutes: 6), () {
      if (!_busy) return;
      _fail('等太久了，这次先停下',
          '上次这条跑了 6 分钟还没走完，多半是平台那边没响应或者网太慢。'
          '菜谱没生成，输入的东西都还在，可以直接再点一次。');
    });
    // v1.45：挂常驻通知。真机日志里有两条记录只写到「开始读链接」就断了，
    // 看门狗都没来得及触发 —— 进程被系统回收，Timer 一起死。
    WorkGuard.start();
    notifyListeners();
    return true;
  }

  void _finish() {
    _busy = false;
    // 无论成功、失败还是看门狗超时，通知都必须收掉，别留个关不掉的图标。
    WorkGuard.stop();
    _tick?.cancel();
    _tick = null;
    _watchdog?.cancel();
    _watchdog = null;
    _startAt = null;
    _progress = 0;
    _stage = '';
    notifyListeners();
  }

  void _fail(String title, String detail, {String kind = 'other'}) {
    _errorTitle = title;
    _errorDetail = detail;
    _errorKind = kind;
    _finish();
  }

  /// 跑完一整单。成功返回成果并留在 [pending]，失败返回 null（原因进 [errorTitle]）。
  ///
  /// 注意：这个方法**不碰任何 Widget / BuildContext** —— 页面随时可以退出，
  /// 它必须能自己跑到底。所有「给用户看的提示」都通过返回值 + notifyListeners 交付。
  ///
  /// [localVideoPath] 非空时走「本机视频」那条路（上架版唯一的入口），
  /// 此时 [readLink] 应为 false；两条路产出的素材结构完全一致，
  /// 所以后面「整理 → 配图 → 自检 → 存视频」一大段代码一行都不用分叉。
  Future<IngestOutcome?> run({
    required String url,
    required String text,
    required String? titleHint,
    required String tag,
    required List<Uint8List> photos,
    required bool isXhs,
    required bool readLink,
    required Future<void> Function(String tag, String msg) sink,
    String localVideoPath = '',
  }) async {
    if (_busy) return null;
    if (localVideoPath.isNotEmpty) {
      begin(localVideoPath.split(Platform.pathSeparator).last);
    } else {
      begin(url.isEmpty ? '你贴的内容' : url);
    }
    // 记下这一趟的代次。用户中途取消（或开了新的一单）会让 _generation 变化，
    // 下面每个阶段边界都会比对；一旦不符就清理临时文件、静默 return null。
    final myGeneration = _generation;

    // onStage 是读料器在后台线程里回调的。取消之后、新的一单开始之后，
    // 旧读料器可能还在吐阶段文案——直接 setStage 会盖掉新单子的进度文字。
    // 这里加一道代次闸：过期的回调一律不落到界面。
    void stage(String label, {double? forced}) {
      if (_generation != myGeneration) return;
      setStage(label, forced: forced);
    }

    final logs = LogService.instance;
    var workText = text;
    var workTitle = titleHint;
    final workPhotos = List<Uint8List>.from(photos);

    List<VideoFrame> frames = const <VideoFrame>[];
    List<SubLine> subtitleLines = const <SubLine>[];
    var videoTemp = '';
    // 素材是不是「用户自己本机上的原件」。是的话收尾时绝不能删。
    var localSource = false;

    // 被取消时的统一收尾：清掉临时视频（本机原件除外）。
    // 取消不是失败 —— 不碰 pending / finishedCount / error，静默退出。
    Future<void> cleanupTemp() async {
      if (videoTemp.isNotEmpty && !localSource) {
        try {
          final f = File(videoTemp);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    // 每个阶段边界自查：代次变了说明被取消/被新单取代。
    bool canceled() => _generation != myGeneration;

    var detailed = true;
    try {
      detailed = await SettingsService().isChefReviewEnabled();
    } catch (_) {}

    // ── 一、拿到素材 ─────────────────────────────────────────────────────
    var readFailed = false;
    String readFailReason = '';
    if (localVideoPath.isNotEmpty) {
      // 本机视频：不联网、不解析任何链接，只是把用户选的这个文件读一遍。
      setStage('正在读本地视频…');
      try {
        final r = await LocalVideoReader().readLocal(
          localVideoPath,
          titleHint: workTitle,
          onStage: (label) => stage(label),
          onLog: sink,
          skipAudio: !detailed,
        );

        final parts = <String>[];
        if (r.audioText.trim().isNotEmpty) {
          parts.add('【视频里说的话】\n${r.audioText.trim()}');
        }
        if (r.subtitleLines.isNotEmpty) {
          final b = StringBuffer();
          b.writeln('【画面上烧录的字（机器识别，可能有错字）】');
          b.writeln('每行开头方括号里的数字，是这句话出现在视频的第几秒。');
          for (final l in r.subtitleLines) {
            b.writeln('[${l.sec}] ${l.text}');
          }
          parts.add(b.toString().trim());
        } else if (r.subtitleText.trim().isNotEmpty) {
          parts.add('【画面上烧录的字（机器识别，可能有错字）】\n${r.subtitleText.trim()}');
        }
        if (workText.trim().isNotEmpty) {
          parts.insert(0, '【用户自己补充的内容】\n${workText.trim()}');
        }
        workText = parts.join('\n\n').trim();
        if (workTitle == null && r.title.isNotEmpty) workTitle = r.title;
        if (r.photos.isNotEmpty) {
          workPhotos
            ..clear()
            ..addAll(r.photos);
        }
        frames = r.frames;
        subtitleLines = r.subtitleLines;
        videoTemp = r.videoPath;
        localSource = true;
        _label = (workTitle ?? '').isNotEmpty ? workTitle! : _label;
        setStage('正在整理成菜谱…');
        await sink(
            '本地视频',
            '送进整理器的文字 ${workText.length} 字'
            '（语音 ${r.audioText.length} + 字幕 ${r.subtitleText.length}）'
            '｜带进来的实拍图 ${workPhotos.length} 张'
            '${workText.isEmpty ? ' ←← 一个字没读到，整理器没有配方可用' : ''}');
      } on LocalVideoReadException catch (e) {
        await sink('失败', '本地视频读取中断：${e.message}');
        readFailed = true;
        readFailReason = e.message;
      } catch (e, st) {
        await sink('失败',
            '本地视频未预期异常：${e.runtimeType} $e｜堆栈 ${st.toString().split('\n').first}');
        readFailed = true;
        readFailReason = '出了点意外：$e';
      }
    } else if (readLink) {
      setStage('正在解析链接…');
      try {
        final ReadRecipeResult r = isXhs
            ? await XhsReader().read(
                url,
                onStage: (label) => stage(label),
                onLog: sink,
                skipAudio: !detailed,
              )
            : await DouyinReader().read(
                url,
                onStage: (label) => stage(label),
                onLog: sink,
                skipAudio: !detailed,
              );

        // v1.8：把「听来的」和「看来的」分开标注，两份一起给整理器互相校对。
        final parts = <String>[];
        if (r.desc.trim().isNotEmpty) {
          parts.add('【作品文案 / 作者写的介绍】\n${r.desc.trim()}');
        }
        if (r.audioText.trim().isNotEmpty) {
          parts.add('【视频里说的话】\n${r.audioText.trim()}');
        }
        if (r.subtitleLines.isNotEmpty) {
          final b = StringBuffer();
          b.writeln('【画面上烧录的字（机器识别，可能有错字）】');
          b.writeln('每行开头方括号里的数字，是这句话出现在视频的第几秒。');
          for (final l in r.subtitleLines) {
            b.writeln('[${l.sec}] ${l.text}');
          }
          parts.add(b.toString().trim());
        } else if (r.subtitleText.trim().isNotEmpty) {
          parts.add('【画面上烧录的字（机器识别，可能有错字）】\n${r.subtitleText.trim()}');
        }
        // 用户手打的放最前面：那是他自己最想说的
        if (workText.trim().isNotEmpty) {
          parts.insert(0, '【用户自己补充的内容】\n${workText.trim()}');
        }
        workText = parts.join('\n\n').trim();
        if (workText.isEmpty) workText = r.desc;
        if (workTitle == null && r.title.isNotEmpty) workTitle = r.title;
        if (r.photos.isNotEmpty) {
          workPhotos
            ..clear()
            ..addAll(r.photos);
        }
        frames = r.frames;
        subtitleLines = r.subtitleLines;
        videoTemp = r.videoPath;
        _label = (workTitle ?? '').isNotEmpty ? workTitle! : (r.title.isNotEmpty ? r.title : _label);
        setStage('正在整理成菜谱…');
        await sink('自动读结果',
            '送进整理器的文字 ${workText.length} 字（文案 ${r.desc.length} + 语音 ${r.audioText.length} + 字幕 ${r.subtitleText.length}）'
            '｜带进来的实拍图 ${workPhotos.length} 张'
            '${workText.isEmpty ? ' ←← 一个字没读到，整理器没有配方可用' : ''}');
      } on XhsReadException catch (e) {
        await sink('失败', '小红书读取中断：${e.message}');
        readFailed = true;
        readFailReason = e.message;
      } on DouyinReadException catch (e) {
        await sink('失败', '自动读取中断：${e.message}');
        readFailed = true;
        readFailReason = e.message;
      } catch (e, st) {
        await sink('失败',
            '自动读取未预期异常：${e.runtimeType} $e｜堆栈 ${st.toString().split('\n').first}');
        readFailed = true;
        readFailReason = '出了点意外：$e';
      }
    }

    // 读素材这一段最慢。它一返回就先自查：若期间被取消，连下面的
    // 「读失败 → _fail 弹框」都不能走，否则用户取消后会冒出一个错误框。
    if (canceled()) {
      await cleanupTemp();
      return null;
    }

    // 读失败不再一律中断：用户手打的文字本身够像配方时，降级用它继续。
    if (readFailed) {
      if (_looksLikeRecipeText(workText) && workText.trim().length >= 20) {
        await sink('降级',
            '素材没读成（$readFailReason），改用你自己贴的 ${workText.length} 字继续整理');
      } else {
        await logs.end('❌ 读素材失败：$readFailReason（未进入整理、未出图）');
        _fail(
          localVideoPath.isNotEmpty
              ? '这个视频没读出来'
              : (isXhs ? '这条小红书没读出来' : '这条链接这次没读出来'),
          readFailReason,
          kind: 'read',
        );
        return null;
      }
    }

    if (workText.trim().isEmpty && workPhotos.isEmpty) {
      await sink('终止', '既没文字也没图片，不发起整理');
      await logs.end('⚠️ 输入框是空的，没发起整理');
      _fail('没有内容可整理',
          '链接没读到东西，你也没贴文字或图片。换一条作品，或者把作者的配方文字贴进来。');
      return null;
    }

    // ── 二、本地整理 ─────────────────────────────────────────────────────
    await sink('本地整理',
        '用画面字幕（${subtitleLines.length} 行带秒数）本地拼菜谱'
        '｜文字 ${workText.length} 字｜实拍图 ${workPhotos.length} 张｜零 API');

    List<FrameMatch>? stepMatches;
    try {
      setStage('本地正在切步骤、抽用料…', forced: StageProgress.aiStep(1));
      final result = LocalRecipeBuilder.build(
        rawText: workText,
        titleHint: workTitle ?? '',
        sourceUrl: url,
        subtitleLines: subtitleLines,
        onLog: sink,
      );
      setStage('本地正在核对用料…', forced: StageProgress.aiStep(3));
      final Recipe recipe = result.recipe;
      final ChefReviewReport report = result.report;
      if (!detailed) {
        report.note = '快速整理：本地切步骤 + 抽用料，未听口播（用量、火候可能缺），未逐条合并补充描述。';
      }

      await sink('整理结果',
          '用料 ${recipe.ingredients.length} 项｜步骤 ${recipe.steps.length} 步｜标题「${recipe.title}」'
          '（纯本地，无 AI）');

      // 硬拦截：用料和步骤缺任何一样，都不许进校对页、不许落盘。
      if (!_hasRealContent(recipe)) {
        final what = _missingWhat(recipe);
        await sink('硬拦截', '判定不完整：$what → 不进校对页、不落盘。');
        await logs.end('❌ 已拦截：$what，未生成图片');
        _fail(
          localVideoPath.isNotEmpty ? '这个视频里没读到完整做法' : '这条作品里没读到完整做法',
          '$what。\n\n'
              '为了不编造克数和步骤，App 没硬凑一份给你。这通常是素材本身的问题：'
              '全程靠手势讲解、没有字幕，或者画面太糊认不出字。\n\n'
              '${localVideoPath.isNotEmpty ? '可以换一个讲解更清楚的视频再试' : '可以直接换一条讲得清楚的作品链接再试'}；'
              '如果你手上正好有现成配方，也可以点开「想自己补点东西」贴进去。',
          kind: 'empty',
        );
        return null;
      }

      recipe.tag = tag;

      // 整理（切步骤）通常很快，但用户可能在读素材结束后就点了取消，
      // 到配图前再查一次，别让已作废的一趟继续写图片文件。
      if (canceled()) {
        await cleanupTemp();
        return null;
      }

      // ── 三、给每一步配图 ───────────────────────────────────────────────
      if (frames.isNotEmpty) {
        await sink('配图', '正在给 ${recipe.steps.length} 个步骤各配一张画面…');
        try {
          final matches = FrameMatcher.assign(recipe.steps, frames);
          stepMatches = matches;
          final accurate = matches.where((m) => m.accurate).length;
          final offBy =
              matches.where((m) => m.byTime && !m.accurate && m.atDiff > 15).length;
          final nearMiss =
              matches.where((m) => m.byTime && !m.accurate && m.atDiff <= 15).length;
          final byText = matches.where((m) => !m.byTime && m.score >= 0.06).length;
          final byFallback = matches.where((m) => !m.byTime && m.score < 0.06).length;
          final blobs = matches.map((m) => m.frame?.jpeg ?? Uint8List(0)).toList();
          final paths =
              await StorageService().savePhotos(recipe.id, blobs, tag: 'step');
          for (var i = 0; i < recipe.steps.length && i < paths.length; i++) {
            recipe.steps[i].photoPath = paths[i];
          }
          final cover = FrameMatcher.cover(frames);
          if (cover != null) {
            final p = await StorageService()
                .savePhotos(recipe.id, <Uint8List>[cover.jpeg], tag: 'cover');
            if (p.isNotEmpty) recipe.coverPath = p.first;
          }
          await sink('配图',
              '${recipe.steps.length} 步配好了 ${paths.length} 张画面'
              '（5 秒内对准 $accurate 步 / 偏了 $nearMiss 步 / 太偏 $offBy 步 / '
              '按画面文字对上 $byText 步 / 兜底 $byFallback 步）');
          for (var i = 0; i < matches.length; i++) {
            final m = matches[i];
            if (m.frame == null) continue;
            final at = recipe.steps[i].atSec;
            final tagNote = m.accurate
                ? ' ✓准'
                : m.byTime
                    ? (m.atDiff > 15 ? ' ⚠偏 ${m.atDiff}s（那个时间点前后没有可用画面）' : ' ≈偏 ${m.atDiff}s')
                    : (m.score >= 0.06 ? ' ～按画面文字 ${m.score.toStringAsFixed(2)}' : ' ⚠兜底');
            await sink('配图',
                '第 ${i + 1} 步 → 第 ${m.frame!.sec}s 的画面'
                '${at >= 0 ? '（本地标注 ${at}s）' : '（没标到时间）'}$tagNote');
          }
        } catch (e) {
          await sink('配图', '配图出了点问题，不影响出图：$e');
        }
      }

      final auditNotes = RecipeAudit.check(recipe, matches: stepMatches);
      await sink('自检', RecipeAudit.summary(auditNotes));
      for (final n in auditNotes) {
        await sink('自检', n);
      }

      // ── 四、把原视频压一遍存进菜谱 ─────────────────────────────────────
      if (canceled()) {
        await cleanupTemp();
        return null;
      }
      if (videoTemp.isNotEmpty) {
        setStage('正在把原视频压一遍存进菜谱…（10~60 秒）', forced: 0.99);
        final dstFile = await StorageService().videoFile(recipe.id);
        try {
          final res = await DouyinReader().saveVideo(videoTemp, dstFile.path, sink);
          final bytes = (res['bytes'] as num?)?.toInt() ?? 0;
          final realLen = await dstFile.exists() ? await dstFile.length() : 0;
          if (bytes > 0 && realLen > 10240) {
            recipe.videoPath = dstFile.path;
          } else {
            try {
              await dstFile.delete();
            } catch (_) {}
            await sink('存视频',
                '这次没存成（原生写回 ${bytes}B / 落盘 ${realLen}B），已丢弃半截文件；'
                '菜谱照常出，只是这道菜暂时没有视频');
          }
        } catch (e) {
          try {
            await dstFile.delete();
          } catch (_) {}
          await sink('存视频', '没存上，菜谱照常出，只是没有视频：$e');
        }
        // 临时文件已经没用了，立刻删 —— 原视频几十兆，留着白占地方。
        // 但本机导入的是用户自己的原件，删了就是删用户的东西，坚决不动。
        if (!localSource) {
          try {
            final f = File(videoTemp);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        videoTemp = '';
      }

      // 最后一道闸：哪怕上面每一关都过了，只要这一趟已被取消，
      // 也绝不把成果写进 pending、绝不 +1 成功数——否则用户取消后
      // 会莫名其妙多出一道菜，或新的一单被旧结果覆盖。
      if (canceled()) {
        await cleanupTemp();
        return null;
      }

      setStage('快好了…', forced: 1.0);

      final outcome = IngestOutcome(
        recipe: recipe,
        rawText: workText,
        sourceUrl: url,
        titleHint: workTitle,
        subtitleLines: subtitleLines,
        photos: List<Uint8List>.from(workPhotos),
        report: report,
        auditNotes: auditNotes,
      );
      _pending = outcome;
      _finishedCount++;
      // 注意：这里故意不 end()，让后面「保存长图」继续写进同一次会话；
      // 用户没走到保存就被标成「没走完」，导出时一眼可见。
      await sink('校对页', '整理通过，成果已交给界面（将带 ${outcome.photos.length} 张实拍图进长图）');
      _finish();
      return outcome;
    } catch (e, st) {
      await sink('失败',
          '整理流程异常：${e.runtimeType} $e｜堆栈 ${st.toString().split('\n').first}');
      await logs.end('❌ 整理异常：$e（未出图）');
      if (videoTemp.isNotEmpty && !localSource) {
        try {
          final f = File(videoTemp);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      _fail('这次没做成', '出了点意外：$e\n\n可以再点一次试试；要是每次都卡在同一个地方，把运行日志导出给我看。');
      return null;
    }
  }

  // ── 小工具 ─────────────────────────────────────────────────────────────

  static bool _hasRealContent(Recipe r) {
    final hasIng = r.ingredients.any(
      (i) => i.name.trim().isNotEmpty || i.amount.trim().isNotEmpty,
    );
    final hasStep =
        r.steps.any((s) => s.text.trim().length >= 2) || r.ingredients.length >= 3;
    return hasIng && hasStep;
  }

  static String _missingWhat(Recipe r) {
    final hasIng = r.ingredients.any(
      (i) => i.name.trim().isNotEmpty || i.amount.trim().isNotEmpty,
    );
    final hasStep =
        r.steps.any((s) => s.text.trim().length >= 2) || r.ingredients.length >= 3;
    if (!hasIng && !hasStep) return '用料和步骤都没读到';
    if (!hasIng) return '读到了步骤，但一份用料都没读到';
    return '读到了用料，但没有能照着做的步骤';
  }

  /// 和页面里那份判断保持一致：有明确用量或动作词才算「像配方」。
  static bool _looksLikeRecipeText(String t) {
    final s = t.trim();
    if (s.length < 15) return false;
    final hasAmount = RegExp(
      r'\d+(?:\.\d+)?\s*(?:g|G|克|ml|ML|毫升|勺|个|根|只|片|粒|瓣|颗|斤|两|把|杯)',
    ).hasMatch(s) ||
        RegExp(r'[一二三四五六七八九十半两]+\s*(?:个|根|只|片|勺|瓣|颗|粒|把|杯)').hasMatch(s);
    final hasAction = RegExp(
      r'切|炒|煮|焖|蒸|炸|煎|拌|腌|焯|炖|烤|下锅|出锅|翻|淋|撒|倒入|加入|搅',
    ).hasMatch(s);
    return hasAmount || hasAction;
  }
}

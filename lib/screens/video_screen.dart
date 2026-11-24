// 页面 7 · 看原视频（v1.16 新增，v1.18 重做显示层）。
//
// 用户的原话（v1.16）：「能不能直接把这个视频也放到我这个菜谱里？最好是能来回拖动长度、
// 能播放、还能自动循环播放。这样我做饭的时候能看到原样。」
// 用户的原话（v1.18）：「下载视频能正常下载下来能播放，但是格式不对，
// 我就能看到屏幕左上角 1/4 大概这个区域。能旋转、能大小缩放。」
//
// ── v1.18 修的到底是什么 ────────────────────────────────────────────────
// 旧版把 VideoPlayer 塞进 AspectRatio(aspectRatio: c.value.aspectRatio)。
// 但 aspectRatio 只算「编码像素尺寸」，不含 rotationCorrection；而 video_player 2.6.1
// 内部是 _VideoPlayerWithRotation → Transform.rotate(rotationCorrection)，那是
// **绘制阶段旋转，布局框尺寸不变**。竖屏视频带 90° 元数据时，外层按 16:9 给了一个
// 横框，纹理在里面转了 90°，宽高没跟着换 —— 画面就只落在左上角一小块（用户说「1/4」）。
// 另外 MainActivity 转码时把原片的 setOrientationHint 又写回新文件，元数据可能和
// 实际画面方向对不上，光靠自动判断不够。
//
// 所以这一版不再套 AspectRatio，改成自己算「旋转之后的视觉尺寸」再缩放：
// 插件负责按文件元数据自动转，我们只在外层叠加用户手动转的那几下；
// 比例 / 缩放 / 平移也全部交给用户。不管元数据是对是错，总能把画面调正、调满。
// v1.19 再进一步：让原生直接读文件里的真实编码宽高与 rotation 元数据，
// 自己摆 Texture、自己转全部角度 —— 插件那个「size 换了却不给角度」的行为
// 不能再当依据。文件里压根没写角度的（像素本身就是横躺的），
// 就给用户一个「转正」按钮，点一次记住这个视频，以后打开自动正。
// ────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, SystemUiOverlayStyle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../services/alarm_service.dart';
import '../services/douyin_reader.dart';
import '../services/log_service.dart';
import '../services/storage_service.dart';
import '../services/video_file.dart';

class VideoScreen extends StatefulWidget {
  final String path;
  final String title;

  /// v1.17：补视频用。旧版本存视频会失败，用户不想为了一个视频重做整道菜，
  /// 所以留一条后路：拿来源链接再下一次，压好写回这道菜。
  final String recipeId;
  final String sourceUrl;
  final VoidCallback? onFixed;

  /// v1.27：从做菜页「看这一步的视频」进来时，直接跳到这一步对应的秒数。
  /// 负数/空 = 从头播。
  final int initialSec;

  /// 这一步在做菜页是第几步（从 1 开始，0 = 不知道），只用于界面上那句提示。
  final int stepNo;

  const VideoScreen({
    super.key,
    required this.path,
    this.title = '',
    this.recipeId = '',
    this.sourceUrl = '',
    this.onFixed,
    this.initialSec = -1,
    this.stepNo = 0,
  });

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  VideoPlayerController? _c;
  bool _ready = false;
  String _err = '';
  bool _loop = true;
  bool _showBar = true;
  // v1.50.2：点画面任意处暂停/继续，并短暂闪一个中央图标当反馈。
  // 做饭时手湿，底部那个小按钮太难点——整个画面都是热区。
  bool _flashPause = false; // true 显示暂停符（刚点了暂停），false 显示播放符
  bool _flashVisible = false;
  Timer? _flashTimer;
  Timer? _barTimer; // 播放时 3 秒后自动收起控制条，全屏更干净
  int _lastSec = -1;
  bool _lastPlaying = false;
  // 补过视频之后路径会变，所以不能用 widget.path 写死
  late String _path = widget.path;
  bool _fixing = false;

  // ── v1.18：显示层的手动控制 ──────────────────────────────────────────
  int _userTurns = 0; // 用户在自动校正之外，额外转了几个 90°
  int _ratioMode = 0; // 0 自动 / 1 竖屏 9:16 / 2 横屏 16:9 / 3 方形
  int _fitMode = 0; // 0 适应（整帧不裁） / 1 铺满（裁边） / 2 拉伸（铺满但变形）
  double _zoom = 1.0; // 用户捏合或按钮缩放的倍率
  Offset _pan = Offset.zero; // 放大之后把画面拖到想看的位置
  double _baseZoom = 1.0;
  Offset _basePan = Offset.zero;
  Offset _startFocal = Offset.zero;

  // v1.23：播放倍速。做饭时想快进过掉搅拌、慢慢看关键手法，自己调。
  double _speed = 1.0;
  static const List<double> _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  // v1.19：原生从文件轨道格式里读出来的真实参数
  int _rawW = 0;
  int _rawH = 0;
  int _rawRotation = 0;
  bool _probed = false;

  static const List<String> _ratioLabels = ['自动', '9:16', '16:9', '1:1'];
  static const List<String> _fitLabels = ['适应·整帧', '铺满·裁边', '拉伸'];

  /// 自动转正的角度：优先用文件里真实写着的 rotation，
  /// 读不到才退回插件给的 rotationCorrection（它常常报 0）。
  int get _autoTurns {
    final deg = _probed && _rawRotation != 0
        ? _rawRotation
        : (_c?.value.rotationCorrection ?? 0);
    return ((deg ~/ 90) % 4 + 4) % 4;
  }

  /// 实际绘制角度 = 自动校正 + 用户手动补的那几下
  int get _turns => (_autoTurns + _userTurns) % 4;

  @override
  void initState() {
    super.initState();
    _open();
    // 做饭时手上是油，别让屏幕在最高潮的地方灭掉
    AlarmService.keepScreenOn(true);
  }

  Future<void> _open() async {
    try {
      if (_path.trim().isEmpty) {
        if (mounted) setState(() => _err = '这道菜还没存视频。');
        return;
      }
      final old = _c;
      _c = null;
      if (mounted) {
        setState(() {
          _ready = false;
          _err = '';
        });
      }
      try { await old?.pause(); await old?.dispose(); } catch (_) {}
      final f = File(_path);
      if (!await f.exists()) {
        if (mounted) setState(() => _err = '视频文件不见了，可能被清理掉了');
        await _note('文件不存在：$_path');
        return;
      }
      // v1.17：先看一眼体积。转码被超时掐断时留下的半截文件只有几百字节，
      // 拿它去初始化播放器只会抛一句英文异常，用户看不懂。
      final len = await f.length();
      if (len < 10240) {
        if (mounted) {
          setState(() => _err = '这个视频当初没存完整（只有 ${len}B），放不出来。');
        }
        await _note('文件太小，判定为坏文件：${len}B｜$_path');
        return;
      }
      final c = VideoPlayerController.file(f);
      _c = c;
      await c.initialize();
      await c.setLooping(_loop);
      // 恢复这道菜上次调的倍速（和旋转角一样按视频路径记忆）
      await _loadSpeed();
      await c.setPlaybackSpeed(_speed);
      // 「看这一步的视频」进来的：先定位到那一步的秒数，再播。
      // 夹一下范围，避免配图秒数比视频还长的脏数据把播放器 seek 到越界位置。
      if (widget.initialSec > 0) {
        final dur = c.value.duration.inSeconds;
        final target = dur > 0 ? widget.initialSec.clamp(0, dur - 1) : widget.initialSec;
        try {
          await c.seekTo(Duration(seconds: target));
        } catch (_) {}
        await _note('从第 ${widget.stepNo > 0 ? widget.stepNo : '?'} 步跳进来｜定位到 ${target}s');
      }
      await c.play();
      await _probeVideo();
      // 尺寸和旋转元数据写进日志：万一还是不对，用户导一份日志就能定位
      await _note('开始播放｜${(len / 1048576).toStringAsFixed(1)}MB'
          '｜${c.value.size.width.toInt()}x${c.value.size.height.toInt()}'
          '｜旋转校正 ${c.value.rotationCorrection}°'
          '｜${c.value.duration.inSeconds} 秒');
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ready = true);
      // 监听器每帧都会回调（30fps 就是每秒 30 次），在这个回调里直接 setState
      // 会让整页每秒重建 30 次，手机上看着就是卡。只按「秒」和「播放状态」变化刷新，
      // 反正界面上要显示的也就是这两个；进度条自己会重绘。
      c.addListener(() {
        if (!mounted) return;
        final sec = c.value.position.inSeconds;
        if (sec == _lastSec && c.value.isPlaying == _lastPlaying) return;
        _lastSec = sec;
        _lastPlaying = c.value.isPlaying;
        setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '这个视频打不开：$e');
      await _note('播放失败：${e.runtimeType} $e');
    }
  }

  /// v1.17：照来源链接把视频再取一次。
  ///
  /// v1.16 的转码有 bug（编码器收不到 EOS），存视频那一步被 3 分钟超时掐断，
  /// 留下的半截文件放不出来。用户不想为了一个视频把整道菜重做一遍 ——
  /// 那 13 步、6 张实拍图都是他认过的，重做反而多一道重复的菜。
  /// 这里只补视频：取直链 → 下载 → 压一遍 → 写回这道菜。
  Future<void> _refetch() async {
    if (_fixing) return;
    Future<void> sink(String tag, String msg) => LogService.instance.log(tag, msg);

    // v1.25：老菜谱可能没存来源链接。没有就问用户要一条，别让按钮变成摆设。
    String link = widget.sourceUrl.trim();
    if (link.isEmpty) {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重新取这条视频'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '这道菜当初没存来源链接。把抖音 / 小红书的分享链接粘进来，'
                'App 重新下一条完整原片（只换视频，菜谱、步骤、实拍图都不动）。',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '粘贴分享链接',
                  hintText: '长按 → 粘贴',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新取')),
          ],
        ),
      );
      if (ok != true || ctrl.text.trim().isEmpty) return;
      link = ctrl.text.trim();
      // 把用户补的链接存回这道菜，下次就不用再贴了
      try {
        final all = await StorageService().loadRecipes();
        for (final r in all) {
          if (r.id == widget.recipeId) {
            r.sourceUrl = link;
            await StorageService().saveRecipe(r);
            break;
          }
        }
      } catch (_) {}
    }

    setState(() {
      _fixing = true;
      _err = '';
    });
    String tmp = '';
    try {
      await sink('补视频', '照链接重新取一次视频：$link');
      final reader = DouyinReader();
      final vurl = await reader.fetchVideoUrl(link, sink);
      tmp = await reader.downloadVideo(vurl, sink);
      final dst = await StorageService().videoFile(widget.recipeId);
      final res = await reader.saveVideo(tmp, dst.path, sink);
      final bytes = (res['bytes'] as num?)?.toInt() ?? 0;
      if (bytes <= 0 || !VideoFile.usable(dst.path)) {
        throw Exception('视频没存成（写回 ${bytes}B）');
      }
      // 写回这道菜，下次从任何入口点进来都能播
      final all = await StorageService().loadRecipes();
      for (final r in all) {
        if (r.id == widget.recipeId) {
          r.videoPath = dst.path;
          await StorageService().saveRecipe(r);
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _path = dst.path;
        _fixing = false;
      });
      widget.onFixed?.call();
      await _open();
    } catch (e) {
      await sink('补视频', '失败的：$e');
      if (!mounted) return;
      setState(() {
        _fixing = false;
        _err = '还是没取到：$e';
      });
    } finally {
      if (tmp.isNotEmpty) {
        try {
          final f = File(tmp);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// 播放成功/失败都往运行日志里留一行 —— 下次出问题不用猜。
  Future<void> _note(String msg) async {
    try {
      await LogService.instance.log('看视频', msg);
    } catch (_) {}
  }

  @override
  void dispose() {
    AlarmService.keepScreenOn(false);
    _flashTimer?.cancel();
    _barTimer?.cancel();
    _c?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _toggle() {
    final c = _c;
    if (c == null || !_ready) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  /// v1.50.2：点画面任意处 = 播放/暂停，同时闪一个中央图标告知状态。
  /// 控制条也一并显示出来——点画面的人多半下一步要拖进度或调工具。
  void _tapPlayPause() {
    final c = _c;
    if (c == null || !_ready) return;
    final willPause = c.value.isPlaying;
    if (willPause) {
      c.pause();
    } else {
      c.play();
    }
    _flashPause = willPause;
    _flashTimer?.cancel();
    setState(() {
      _showBar = true;
      _flashVisible = true;
    });
    _flashTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _flashVisible = false);
    });
    // 继续播放后 3 秒收起控制条——全屏看画面时不被控件挡着。
    // 暂停时保持显示，方便调倍速/转正/进度。
    _barTimer?.cancel();
    if (!willPause) {
      _barTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showBar = false);
      });
    }
  }

  // ── v1.19：读文件真实方向 + 记住这个视频调好的角度 ──────────────────

  static const MethodChannel _platform =
      MethodChannel('com.xiaobo.recipe/share');

  String get _turnsKey => 'video_turns_${_path.hashCode}';
  String get _speedKey => 'video_speed_${_path.hashCode}';

  Future<void> _probeVideo() async {
    try {
      final r = await _platform.invokeMapMethod<String, dynamic>(
          'probeVideo', <String, dynamic>{'path': _path});
      _rawW = (r?['width'] as num?)?.toInt() ?? 0;
      _rawH = (r?['height'] as num?)?.toInt() ?? 0;
      _rawRotation = (r?['rotation'] as num?)?.toInt() ?? 0;
      _probed = _rawW > 0 && _rawH > 0;
      await _note('文件真实参数｜$_rawW x $_rawH｜rotation $_rawRotation°'
          '｜插件报 ${_c?.value.size.width.toInt()}x${_c?.value.size.height.toInt()}'
          ' / 校正${_c?.value.rotationCorrection}°');
    } catch (e) {
      await _note('读文件方向失败（不影响播放）：$e');
    }
    // 上次给这个视频调好的角度，下次进来直接生效
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getInt(_turnsKey);
      if (saved != null) _userTurns = saved % 4;
    } catch (_) {}
  }

  Future<void> _persistTurns() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_turnsKey, _userTurns);
    } catch (_) {}
  }

  /// 恢复这道菜上次调的倍速；存的是档位下标，夹一下防脏值。
  Future<void> _loadSpeed() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final idx = sp.getInt(_speedKey);
      if (idx != null && idx >= 0 && idx < _speedOptions.length) {
        _speed = _speedOptions[idx];
      }
    } catch (_) {}
  }

  Future<void> _persistSpeed() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_speedKey, _speedOptions.indexOf(_speed));
    } catch (_) {}
  }

  /// 点一下切到下一档，到头回到 0.5x。播放不中断，只改速率。
  Future<void> _cycleSpeed() async {
    final i = _speedOptions.indexOf(_speed);
    final next = _speedOptions[(i + 1) % _speedOptions.length];
    setState(() => _speed = next);
    await _c?.setPlaybackSpeed(next);
    await _persistSpeed();
    await _note('播放倍速切到 ${_speedLabel(next)}');
  }

  String _speedLabel(double s) => s == 1.0 ? '1x（正常）' : '${s}x';

  /// 转正 / 左转 / 右转都走这里：转完强制回到「适应·整帧」，
  /// 别让「铺满」把刚转正的画面又裁掉 —— 用户要的是看全。
  void _turnBy(int delta) {
    setState(() {
      _userTurns = (_userTurns + delta) % 4;
      _fitMode = 0;
      _zoom = 1.0;
      _pan = Offset.zero;
    });
    _persistTurns();
  }

  void _turnUpright() => _turnBy(1);

  // ── v1.18：缩放 / 平移 / 复位 ─────────────────────────────────────────

  void _scaleStart(ScaleStartDetails d) {
    _baseZoom = _zoom;
    _basePan = _pan;
    _startFocal = d.localFocalPoint;
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    // 没放大之前，单指划动留给「点画面显隐控制条」，别误拖画面
    if (d.pointerCount < 2 && _zoom <= 1.02) return;
    setState(() {
      if (d.pointerCount >= 2) {
        _zoom = (_baseZoom * d.scale).clamp(0.6, 6.0).toDouble();
      }
      final delta = d.localFocalPoint - _startFocal;
      _pan = _basePan + delta;
    });
  }

  /// 双击：只把大小拖回原位，旋转和比例先留着
  void _resetTransform() {
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
    });
  }

  /// 「复位」按钮：所有显示设置回到自动
  void _resetAll() {
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
      _userTurns = 0;
      _ratioMode = 0;
      _fitMode = 0;
    });
    _persistTurns();
  }

  void _zoomBy(double k) {
    setState(() {
      // 下限 0.6：再小就只剩中间一小条，看着跟「显示不全」一样
      _zoom = (_zoom * k).clamp(0.6, 6.0).toDouble();
      if (_zoom <= 1.001) _pan = Offset.zero;
    });
  }

  /// 纹理框的比例。自动模式用文件报的尺寸；报得离谱时用户可手动指定。
  Size _frameSize(VideoPlayerController c) {
    switch (_ratioMode) {
      case 1:
        return const Size(9, 16);
      case 2:
        return const Size(16, 9);
      case 3:
        return const Size(1, 1);
      default:
        // 原生读到的编码宽高最可信；插件的 value.size 有时已被交换过
        if (_probed) return Size(_rawW.toDouble(), _rawH.toDouble());
        final s = c.value.size;
        if (s.width <= 0 || s.height <= 0) return const Size(9, 16);
        return s;
    }
  }

  /// 画面层：纹理自己摆，缩放 / 平移 / 旋转全在这里一次合成。
  ///
  /// 关键是先按「旋转之后的视觉尺寸」算缩放比 —— 转 90/270 时宽高要交换，
  /// 这正是旧版漏掉的一步。总角度 _turns = 文件真实角度 + 用户手动补的，
  /// 一次转到位，不再叠加插件内部那个不靠谱的自动旋转。
  Widget _buildStage(VideoPlayerController c, BoxConstraints cons) {
    final turns = _turns;
    final raw = _frameSize(c);
    // 旋转之后真正要显示的宽高：转 90/270 时宽高交换
    final visual = turns.isOdd ? Size(raw.height, raw.width) : raw;

    // 拉伸模式：直接把纹理铺满可用区，允许变形
    if (_fitMode == 2) {
      final fill = turns.isOdd
          ? Size(cons.maxHeight, cons.maxWidth)
          : Size(cons.maxWidth, cons.maxHeight);
      return ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tapPlayPause,
          onDoubleTap: _resetTransform,
          onScaleStart: _scaleStart,
          onScaleUpdate: _scaleUpdate,
          child: SizedBox.expand(
            child: Transform.rotate(
              angle: turns * math.pi / 2,
              alignment: Alignment.center,
              child: SizedBox(
                width: fill.width,
                height: fill.height,
                // ignore: invalid_use_of_visible_for_testing_member
                child: Texture(textureId: c.textureId),
              ),
            ),
          ),
        ),
      );
    }

    // 适应 / 铺满：交给 Flutter 标准的 FittedBox 按比例缩放整帧。
    // 之前自己算 base 再套 Transform.scale，尺寸推导出错，画面被缩成
    // 中间一小条、四周黑边，用户以为「没全部显示」，复位和 100% 都救不回来。
    return ClipRect(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tapPlayPause,
        onDoubleTap: _resetTransform,
        onScaleStart: _scaleStart,
        onScaleUpdate: _scaleUpdate,
        child: SizedBox.expand(
          child: Transform.translate(
            offset: _pan,
            child: Transform.scale(
              scale: _zoom,
              child: FittedBox(
                fit: _fitMode == 1 ? BoxFit.cover : BoxFit.contain,
                alignment: Alignment.center,
                child: SizedBox(
                  width: visual.width,
                  height: visual.height,
                  child: Transform.rotate(
                    angle: turns * math.pi / 2,
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: raw.width,
                      height: raw.height,
                      // ignore: invalid_use_of_visible_for_testing_member
                      child: Texture(textureId: c.textureId),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 右上角那行小字：把当前视频的真实参数摊开给用户看。
  /// 万一还是不对，截个图发过来就知道该往哪调。
  Widget _statusChip(VideoPlayerController c) {
    final s = c.value.size;
    final txt = '${s.width.toInt()}×${s.height.toInt()}'
        ' · 校正${c.value.rotationCorrection}°'
        ' · 当前${_turns * 90}°'
        ' · ${_ratioLabels[_ratioMode]}'
        ' · ${_fitLabels[_fitMode]}'
        ' · ${_zoom.toStringAsFixed(1)}x'
        ' · ${_speedOptions.indexOf(_speed) == 2 ? '1x' : '${_speed}x'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        txt,
        style: const TextStyle(color: Colors.white70, fontSize: 10.5),
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部控制条：进度 + 播放/循环（v1.16 原有）+ v1.18 的显示工具
  Widget _buildBar(VideoPlayerController c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VideoProgressIndicator(
            c,
            allowScrubbing: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            colors: const VideoProgressColors(
              playedColor: Color(0xFFE8663C),
              bufferedColor: Colors.white30,
              backgroundColor: Colors.white12,
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  c.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
                tooltip: c.value.isPlaying ? '暂停' : '继续',
                onPressed: _toggle,
              ),
              Text(
                '${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              // 循环是默认开的：做饭时看一段就低头干活，
              // 抬头时常常已经播完了，还得腾出手重播一次
              TextButton.icon(
                onPressed: () async {
                  final v = !_loop;
                  setState(() => _loop = v);
                  await c.setLooping(v);
                },
                icon: Icon(
                  _loop ? Icons.repeat_on : Icons.repeat,
                  size: 18,
                  color: _loop ? const Color(0xFFE8663C) : Colors.white54,
                ),
                label: Text(
                  _loop ? '循环中' : '循环',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _loop ? const Color(0xFFE8663C) : Colors.white54,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            children: [
              _tool(Icons.screen_rotation, '转正', _turnUpright),
              _tool(Icons.rotate_left, '左转', () => _turnBy(-1)),
              _tool(Icons.rotate_right, '右转', () => _turnBy(1)),
              _tool(Icons.aspect_ratio, _ratioLabels[_ratioMode],
                  () => setState(() {
                        _ratioMode = (_ratioMode + 1) % 4;
                        _resetTransformStateOnly();
                      })),
              _tool(Icons.fit_screen, _fitLabels[_fitMode], () {
                setState(() {
                  _fitMode = (_fitMode + 1) % 3;
                  // 切模式时把缩放/平移归位 —— 误按「缩小」后倍率还停在 0.8x，
                  // 画面小小一块，用户会以为「显示不全」。点这个按钮直接恢复满屏。
                  _zoom = 1.0;
                  _pan = Offset.zero;
                });
              }),
              _tool(Icons.zoom_out, '缩小', () => _zoomBy(1 / 1.25)),
              _tool(Icons.zoom_in, '放大', () => _zoomBy(1.25)),
              // v1.23：倍速。做饭时快进过搅拌、慢放看手法，点一下循环切档。
              _tool(Icons.speed, _speed == 1.0 ? '倍速 1x' : '倍速 ${_speed}x', _cycleSpeed),
              _tool(Icons.restart_alt, '复位', _resetAll),
              // v1.25：始终给「重取原片」入口。老版本被转码裁过的视频画面回不来，
              // 只能重新下一条完整原片；没存来源链接时点它会现场问用户要，不再是摆设。
              _tool(Icons.download_rounded, '重取原片', _refetch),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 2),
            child: Text(
              '点画面暂停/继续 · 双击复位 · 双指缩放 · 点「倍速」快进慢放',
              style: TextStyle(color: Colors.white38, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 换了旋转/比例之后，之前手动缩放的位置多半不适用了，清掉更省心。
  /// 注意：只在 setState 里直接改字段，不能在这里再调一次 setState。
  void _resetTransformStateOnly() {
    _zoom = 1.0;
    _pan = Offset.zero;
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _err,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.6),
          ),
          // 有来源链接就给一条活路：不用重做整道菜，只把视频补回来。
          if (widget.sourceUrl.trim().isNotEmpty &&
              widget.recipeId.trim().isNotEmpty) ...[
            const SizedBox(height: 22),
            if (_fixing)
              Column(
                children: const [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white70),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '正在照原链接重新取视频…\n（要下几十兆，大概半分钟）',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white54, fontSize: 12.5, height: 1.6),
                  ),
                ],
              )
            else
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: _refetch,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white38),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  icon: const Icon(Icons.download_rounded,
                      size: 18, color: Colors.white),
                  label: const Text(
                    '照原链接重新取一次视频',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ok = _ready && c != null && c.value.isInitialized;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 全屏黑底页：状态栏与底部导航条一起转黑、图标转浅色。
      // 不这么做的话，从详情页点「看原视频」进来会顶着一条白状态栏，
      // 那感觉就像没真正全屏 —— 跟用户抱怨的那条灰线是同一个毛病。
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.black,
        systemNavigationBarColor: Colors.black,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: ok
                    ? LayoutBuilder(
                        builder: (ctx, cons) => _buildStage(c, cons),
                      )
                    : _err.isNotEmpty
                        ? Center(child: _buildError())
                        : const Center(
                            child: CircularProgressIndicator(
                                color: Colors.white),
                          ),
              ),

              // v1.50.2：点画面后的中央反馈，0.65 秒淡出。
              // IgnorePointer 保证它不挡住画面本身的点按手势。
              if (ok && _flashVisible)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _flashVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 180),
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.42),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _flashPause
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 44,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // 顶部返回：控制条收起时降到半透明，不抢画面但有轮廓可点。
              Positioned(
                top: 4,
                left: 4,
                child: AnimatedOpacity(
                  opacity: _showBar ? 1.0 : 0.45,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.28),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: '回去做菜',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),

              // v1.50.2：那行技术参数跟着控制条一起收起——全屏播放时
              // 画面上只留一个淡淡的返回键，不再堆一排小字。
              if (ok && _showBar)
                Positioned(top: 10, right: 10, child: _statusChip(c)),

              if (ok && _showBar)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildBar(c),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

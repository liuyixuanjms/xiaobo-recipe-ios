// 这一步的「动图」（v1.30 新增）。
//
// 用户的设想原话：「有的图片变成动图，会不会增加负担，但是会不会更方便做饭」。
//
// 结论先写在代码里：
//   · 真做成 GIF 是笔坏账 —— 一步一张，十步就是十张 3~5MB，流量翻倍、内存翻倍，
//     而且做出来的还是「压缩到 12fps 的糊图」，看不清手法。
//   · 但「动起来比定格更有用」这件事是真的：切菜的刀往哪边落、翻面的手怎么抬，
//     静止一帧看不出来。
//
// 所以这里不去生成任何新文件，而是**就地复用一个已经存在的东西**：菜谱里本来就
// 存着原视频。点一下，就把这一步那几秒静音循环播出来 —— 零额外流量、零额外存储。
//
// 几条克制：
//   1) 默认不播。三个步骤同时自动播放，手机发烫、电掉得快，用户会关掉整个功能。
//   2) 静音。做菜时手机常搁在台面上，突然出声很吓人；要听原声就点「看原视频」。
//   3) 同一时刻只允许一个在播（_active）。解码器是稀缺资源，叠两个就卡。
//   4) 停下就 dispose，不留在内存里等下次。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/video_file.dart';
import '../theme/app_theme.dart';

class StepClip extends StatefulWidget {
  /// 这一步底下那张静态图（没图就传空字符串）
  final Widget child;

  /// 菜谱里的原视频路径
  final String videoPath;

  /// 这一步从第几秒开始
  final int startSec;

  /// 播到第几秒回卷。-1 / 0 表示不知道下一步在哪，播一个默认长度
  final int endSec;

  /// 默认循环长度（秒）
  final int defaultSpan;

  const StepClip({
    Key? key,
    required this.child,
    required this.videoPath,
    this.startSec = -1,
    this.endSec = -1,
    this.defaultSpan = 8,
  }) : super(key: key);

  @override
  State<StepClip> createState() => _StepClipState();
}

class _StepClipState extends State<StepClip> {
  VideoPlayerController? _c;
  bool _busy = false;
  bool _playing = false;
  String? _err;

  /// 全局只留一个在播的
  static _StepClipState? _active;

  bool get _hasVideo => VideoFile.usable(widget.videoPath);

  @override
  void dispose() {
    _stop(notify: false);
    super.dispose();
  }

  int get _from {
    final s = widget.startSec;
    return s > 0 ? s : 0;
  }

  int get _to {
    final e = widget.endSec;
    if (e > _from + 1) return e;
    return _from + widget.defaultSpan;
  }

  Future<void> _toggle() async {
    if (_playing) {
      _stop();
      return;
    }
    if (_busy) return;
    _busy = true;
    if (mounted) setState(() => _err = null);

    // 先把别人停掉，免得两个解码器抢资源
    final prev = _active;
    if (prev != null && prev != this) prev._stop();

    try {
      final f = File(widget.videoPath);
      final c = VideoPlayerController.file(f);
      _c = c;
      await c.initialize();
      await c.setVolume(0); // 静音：做饭时手机就搁在台面上
      await c.setLooping(false);

      final dur = c.value.duration.inSeconds;
      final from = dur > 0 ? _from.clamp(0, dur > 1 ? dur - 1 : 0) : _from;
      try {
        await c.seekTo(Duration(seconds: from));
      } catch (_) {}

      // 边界回卷：播到 _to 就跳回 from，做出「循环动图」的观感
      final stopAt = _to;
      c.addListener(() {
        if (!mounted) return;
        final v = c.value;
        if (!v.isInitialized) return;
        if (v.position.inSeconds >= stopAt) {
          if (mounted) {
            try {
              c.seekTo(Duration(seconds: from));
              c.play();
            } catch (_) {}
          }
        }
      });

      await c.play();
      _active = this;
      if (!mounted) {
        await c.dispose();
        _c = null;
        return;
      }
      setState(() => _playing = true);
    } catch (e) {
      _err = '这一步的视频放不出来：$e';
      await _c?.dispose();
      _c = null;
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  void _stop({bool notify = true}) {
    final c = _c;
    _c = null;
    _playing = false;
    if (_active == this) _active = null;
    if (c != null) {
      try {
        c.pause();
      } catch (_) {}
      c.dispose();
    }
    if (notify && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasVideo) return widget.child;

    return Stack(
      children: [
        widget.child,
        if (_playing && _c != null && _c!.value.isInitialized)
          Positioned.fill(
            child: GestureDetector(
              onTap: _stop,
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _c!.value.aspectRatio == 0
                        ? 9 / 16
                        : _c!.value.aspectRatio,
                    child: VideoPlayer(_c!),
                  ),
                ),
              ),
            ),
          ),
        // 角标：不播的时候是「动图」入口，播的时候是「停住」
        Positioned(
          right: 10,
          bottom: 10,
          child: GestureDetector(
            onTap: _playing ? _stop : _toggle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _playing
                    ? Colors.black.withOpacity(0.55)
                    : AppColors.primary.withOpacity(0.92),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_busy)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: Colors.white),
                    )
                  else
                    Icon(
                      _playing ? Icons.pause : Icons.play_arrow_rounded,
                      size: 15,
                      color: Colors.white,
                    ),
                  const SizedBox(width: 4),
                  Text(
                    _busy
                        ? '准备中'
                        : (_playing ? '停住' : '动起来 ${_to - _from}s'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_err != null)
          Positioned(
            left: 10,
            bottom: 10,
            right: 92,
            child: Text(
              _err!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
      ],
    );
  }
}

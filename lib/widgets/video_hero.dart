// 菜谱详情页顶部的「视频封面」（v1.32）。
//
// 用户原话：「我图片画圈这个位置，如果有视频的话能不能播放菜的视频，这样更灵活」。
// 他圈的其实是长图最上面那张封面照 —— 那是抽帧截下来的静帧，而原视频
// 明明就存在手机里（下载、抽帧、压存都做过了）。既然有，就该让它动起来。
//
// 几个刻意的决定：
//  1. **不自动播放**。自动播会出声、会耗电，而且用户可能只是想扫一眼菜谱。
//     第一帧静着挂在那里，看得出来是什么菜，点一下才播。
//  2. **出声播**。用户是主动点的，做菜视频的讲解（「这时候转小火」）比画面更值钱，
//     跟做菜页那个静音小窗的定位不一样。
//  3. **完整显示画面，不裁切**。用 contain + 深色底。
//     竖屏视频裁成横条会切掉半个人，之前配图那次已经因为「留边难看」返工过 ——
//     但这次宁可留边：做菜视频里手在哪个位置、锅里什么状态，裁掉就看不见了。
//     深色底看着像播放器本身，不像"没铺满"。
//  4. **失败就当没有**。解码器起不来（文件半截、编码不认）就整块隐藏，
//     不在详情页正中间摆一个红叉。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';

class VideoHero extends StatefulWidget {
  /// 本机视频文件路径（Recipe.videoPath）
  final String path;

  /// 菜名，给无障碍朗读用
  final String title;

  /// 右下角「全屏」：跳到 VideoScreen，那里能倍速、拖进度、转正
  final VoidCallback onOpenFull;

  const VideoHero({
    super.key,
    required this.path,
    required this.title,
    required this.onOpenFull,
  });

  @override
  State<VideoHero> createState() => _VideoHeroState();
}

class _VideoHeroState extends State<VideoHero> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _playing = false;
  bool _broken = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final f = File(widget.path);
    if (!f.existsSync()) {
      if (mounted) setState(() => _broken = true);
      return;
    }
    final c = VideoPlayerController.file(f);
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(1); // 有原声：讲解比画面更重要
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _ready = true;
      });
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _broken = true);
    }
  }

  Future<void> _toggle() async {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      // 播完了再点要回到开头，否则会停在最后一帧不动
      if (c.value.position >= c.value.duration) {
        await c.seekTo(Duration.zero);
      }
      await c.play();
      if (mounted) setState(() => _playing = true);
    }
  }

  @override
  void dispose() {
    // 离开页面就释放解码器。视频是整段 25MB 的菜谱原片，
    // 挂着一个不用的播放器会一直占着内存和解码通道。
    _c?.dispose();
    super.dispose();
  }

  /// 高度跟着真实比例走，但两头都夹住：
  /// 太矮（横屏视频）看着像条胶带，太高（极端竖屏）会把长图挤出屏幕。
  double _height(double width) {
    final v = _c?.value;
    if (v == null || v.size.width <= 0 || v.size.height <= 0) return 210;
    final ratio = v.size.height / v.size.width;
    return (width * ratio).clamp(190.0, 330.0);
  }

  @override
  Widget build(BuildContext context) {
    if (_broken) return const SizedBox.shrink();

    final w = MediaQuery.of(context).size.width;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: _height(w - 28),
          width: double.infinity,
          child: GestureDetector(
            onTap: _ready ? _toggle : null,
            behavior: HitTestBehavior.opaque,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 深色底（播放器质感），不是"没铺满"的留白
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF241E1F), Color(0xFF3B2C2E)],
                    ),
                  ),
                ),
                if (_ready && _c != null)
                  Center(
                    child: AspectRatio(
                      aspectRatio: _c!.value.aspectRatio,
                      child: VideoPlayer(_c!),
                    ),
                  ),
                // 没播的时候压一层暗罩，让中间那个播放键读得清
                if (!_playing)
                  Container(color: Colors.black.withOpacity(0.12)),
                if (!_playing) _playBadge(),
                if (_playing) _playingChrome(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 未播放态：中央大播放键 + 下方一行说明
  Widget _playBadge() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.92),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.22),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              _ready ? Icons.play_arrow_rounded : Icons.hourglass_top_rounded,
              size: 32,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.34),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _ready ? '点一下放原视频' : '视频准备中…',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 播放态：左上角「原视频」标、右下角暂停与全屏。
  /// 播放时不遮画面，所以按钮都做成小圆片贴在角上。
  Widget _playingChrome() {
    return Stack(
      children: [
        Positioned(
          left: 10,
          top: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.volume_up_rounded, size: 12, color: Colors.white),
                SizedBox(width: 3),
                Text('原视频',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Row(
            children: [
              _roundBtn(
                icon: Icons.pause_rounded,
                onTap: _toggle,
                tip: '暂停',
              ),
              const SizedBox(width: 8),
              _roundBtn(
                icon: Icons.fullscreen_rounded,
                onTap: widget.onOpenFull,
                tip: '全屏看',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _roundBtn({
    required IconData icon,
    required VoidCallback onTap,
    required String tip,
  }) {
    return Semantics(
      label: tip,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.42),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 19, color: Colors.white),
        ),
      ),
    );
  }
}

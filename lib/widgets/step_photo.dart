// 步骤配图：按图片真实比例自适应，去掉难看的留边。
//
// 背景（用户原话）：「截下来那个图与做饭那个边框，我觉得应该自适应一下子，
// 要不有留边的很难看。又不能把有用的给截掉。」
//
// 这是一个死结：抖音/小红书的做菜视频全是竖屏 9:16，
// 而步骤卡片的宽度是整屏宽（约 345pt）。
//   · 用 cover：横向撑满，纵向砍掉一半 —— 锅里的动作被裁掉，误导；
//   · 用 contain + 固定高度 260：整帧在，但左右各留一大条米色空白 —— 难看。
//
// 解法是两条一起用：
//   ① 高度不再是死数，按图片真实宽高比算：高 = 宽 / 比例（夹在 min~max 之间）。
//      多数情况下比例刚好，图正好铺满，一点边都不留、也一点不裁。
//   ② 只有当比例极端（比如超长竖图被 max 高度卡住）时才会有缝，
//      这时用**同一张图**高斯模糊铺底，看着是自然的暗色描边，不再是"没铺满"。
//
// 为什么不在长图里也用异步测量：长图是 RepaintBoundary 实时截屏，
// 图还没解码完就截会截成空白。所以长图走 adaptive:false（固定高度 + 模糊铺底）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class StepPhoto extends StatefulWidget {
  final String path;

  /// 固定高度（长图用；为 null 时按比例自适应）
  final double? fixedHeight;

  /// 自适应高度的上下限
  final double minHeight;
  final double maxHeight;

  final double radius;
  final BoxFit fit;

  /// 点一下看大图（做菜页用；长图里不要）
  final VoidCallback? onTap;

  /// 图挂了也不让整页崩 —— 做饭时看到空白比看到报错强
  final bool softFail;

  const StepPhoto({
    Key? key,
    required this.path,
    this.fixedHeight,
    this.minHeight = 150,
    this.maxHeight = 340,
    this.radius = 16,
    this.fit = BoxFit.contain,
    this.onTap,
    this.softFail = true,
  }) : super(key: key);

  @override
  State<StepPhoto> createState() => _StepPhotoState();
}

class _StepPhotoState extends State<StepPhoto> {
  /// 宽/高。0 = 还没量出来，按 4:3 先占位（和多数横屏帧接近，不会跳得太厉害）
  double _aspect = 0;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  bool get _adaptive => widget.fixedHeight == null;

  @override
  void initState() {
    super.initState();
    if (_adaptive) _resolve();
  }

  @override
  void didUpdateWidget(StepPhoto old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path && _adaptive) {
      _detach();
      _aspect = 0;
      _resolve();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  /// 只读图片头拿到宽高就够，token 数限制到 1，不把整张位图拽进内存。
  void _resolve() {
    final f = File(widget.path);
    if (!f.existsSync()) return;
    final stream = FileImage(f).resolve(ImageConfiguration.empty);
    _stream = stream;
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final w = info.image.width;
        final h = info.image.height;
        if (w > 0 && h > 0) setState(() => _aspect = w / h);
      },
      onError: (_, __) {},
    );
    stream.addListener(_listener!);
  }

  @override
  Widget build(BuildContext context) {
    if (!File(widget.path).existsSync()) {
      return widget.softFail ? const SizedBox.shrink() : const SizedBox(height: 0);
    }
    return LayoutBuilder(
      builder: (ctx, box) {
        final width = box.maxWidth.isFinite ? box.maxWidth : 0.0;
        // 比例未知时给个 4:3 的占位高度，量出来再收紧 —— 只跳一次，不抖
        final ratio = _aspect > 0.05 ? _aspect : 4 / 3;
        final wanted = width > 0 ? width / ratio : widget.minHeight;
        final height = _adaptive
            ? wanted.clamp(widget.minHeight, widget.maxHeight).toDouble()
            : widget.fixedHeight!;
        // 图的比例和框的比例差多少（>1.02 说明一定有缝）。
        // 固定高度模式（长图）量不到比例，就直接铺模糊底 —— 反正正图会盖住它，没副作用。
        final boxRatio = width > 0 ? width / height : ratio;
        final hasGap = !_adaptive || (boxRatio / ratio) > 1.02;

        // 【v1.27 内存】按显示宽度解码，而不是按原图 720×1280 全解码。
        // 一道 37 步的菜谱在长图里同时挂着 37 张图，
        // 原尺寸解码约 37×3.6MB ≈ 134MB，正是「出长图时闪退」最典型的死法；
        // 按显示尺寸解码约 23MB，画面看不出差别。
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final decodeW = (width * dpr).clamp(200.0, 1080.0).round();

        final photo = Image.file(
          File(widget.path),
          fit: widget.fit,
          cacheWidth: decodeW,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );

        Widget content = photo;
        if (hasGap) {
          // 有缝：同一张图放大模糊铺底，缝里也还是这道菜的颜色，不刺眼
          content = Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Image.file(
                  File(widget.path),
                  fit: BoxFit.cover,
                  cacheWidth: decodeW,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              // 压一层，避免模糊底比正图还抢眼
              Container(color: Colors.black.withOpacity(0.18)),
              Center(child: photo),
            ],
          );
        }

        final card = ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: ColoredBox(
              color: AppColors.cream,
              child: content,
            ),
          ),
        );
        if (widget.onTap == null) return card;
        return GestureDetector(
          onTap: widget.onTap,
          child: card,
        );
      },
    );
  }
}

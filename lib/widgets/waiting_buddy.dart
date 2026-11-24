// 等待时陪着你的一小块动画（v1.31）。
//
// 起因：用户的原话是「在这个结果多点女性喜欢的等待图标来回切换，让使用者
// 不那么无聊，增加粘性」。等 40 秒的进度条，只有一个转圈是很折磨人的。
//
// 做法取巧的地方：不做图、不引资源包、不加体积 —— 四个小场景全用 Canvas 画，
// 颜色直接吃当前主题（换成抹茶绿它就变绿），一个 AnimationController 同时驱动
// 冒泡、弹跳、旋转和刀起刀落。切换场景用 AnimatedSwitcher 淡入淡出，不闪。
//
// 场景顺序也照做饭的流程排：锅 → 番茄 → 打蛋碗 → 菜板，看着像在「做饭」，
// 而不是随机卖萌。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class WaitingBuddy extends StatefulWidget {
  final double size;

  /// 当前阶段文案。换阶段时顺手切一个更贴合的场景，别让「切菜板」跑到「下载」阶段。
  final String stage;

  const WaitingBuddy({super.key, this.size = 76, this.stage = ''});

  @override
  State<WaitingBuddy> createState() => _WaitingBuddyState();
}

class _WaitingBuddyState extends State<WaitingBuddy>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;
  late final Timer _switch;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    // 2.8 秒换一个场景：比动画本身稍慢，切换时不会打架。
    _switch = Timer.periodic(const Duration(milliseconds: 2800), (_) {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % 4);
    });
  }

  @override
  void dispose() {
    _switch.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1).animate(anim),
            child: child,
          ),
        ),
        child: CustomPaint(
          key: ValueKey<int>(_index),
          painter: _BuddyPainter(
            motion: _motion,
            index: _index,
            primary: AppColors.primary,
            soft: AppColors.primarySoft,
            accent: const Color(0xFFE4736A),
            leaf: const Color(0xFF8CAE8C),
            wood: const Color(0xFFE4C9A9),
          ),
        ),
      ),
    );
  }
}

class _BuddyPainter extends CustomPainter {
  _BuddyPainter({
    required this.motion,
    required this.index,
    required this.primary,
    required this.soft,
    required this.accent,
    required this.leaf,
    required this.wood,
  }) : super(repaint: motion);

  final Animation<double> motion;
  final int index;
  final Color primary;
  final Color soft;
  final Color accent;
  final Color leaf;
  final Color wood;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = motion.value;

    // 背后一圈柔光，让图案不孤零零地浮在卡片上
    final center = Offset(w * 0.5, h * 0.54);
    final halo = Paint()
      ..shader = RadialGradient(
        colors: <Color>[soft, soft.withOpacity(0.0)],
        stops: const <double>[0.1, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: w * 0.52));
    canvas.drawCircle(center, w * 0.52, halo);

    switch (index) {
      case 0:
        _pot(canvas, w, h, t);
        break;
      case 1:
        _tomato(canvas, w, h, t);
        break;
      case 2:
        _bowl(canvas, w, h, t);
        break;
      default:
        _board(canvas, w, h, t);
        break;
    }
  }

  /// 场景一：小锅咕嘟冒泡
  void _pot(Canvas canvas, double w, double h, double t) {
    final body = Paint()..color = Color.lerp(primary, Colors.white, 0.10)!;
    final rim = Paint()..color = Color.lerp(primary, Colors.white, 0.42)!;
    final pot = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.20, h * 0.42, w * 0.60, h * 0.36),
      Radius.circular(w * 0.12),
    );
    // 锅耳
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.13, h * 0.50, w * 0.09, h * 0.09),
        Radius.circular(w * 0.04),
      ),
      body,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.78, h * 0.50, w * 0.09, h * 0.09),
        Radius.circular(w * 0.04),
      ),
      body,
    );
    canvas.drawRRect(pot, body);
    // 锅沿高光
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.20, h * 0.42, w * 0.60, h * 0.07),
        Radius.circular(w * 0.035),
      ),
      rim,
    );

    // 三个气泡，各自不同相位
    final bubble = Paint()..color = Colors.white.withOpacity(0.85);
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final y = h * (0.40 - phase * 0.26);
      final x = w * (0.34 + i * 0.16) + math.sin(phase * math.pi * 2) * w * 0.012;
      final r = w * (0.030 + 0.020 * (1 - phase)) * (i == 1 ? 1.15 : 1.0);
      bubble.color = Colors.white.withOpacity(0.85 * (1 - phase * 0.9));
      canvas.drawCircle(Offset(x, y), r, bubble);
    }
  }

  /// 场景二：番茄轻轻弹
  void _tomato(Canvas canvas, double w, double h, double t) {
    final bob = math.sin(t * math.pi * 2) * h * 0.022;
    final c = Offset(w * 0.5, h * 0.58 + bob);
    final r = w * 0.21;
    canvas.drawCircle(c, r, Paint()..color = accent);
    // 高光
    canvas.drawCircle(
      Offset(c.dx - r * 0.34, c.dy - r * 0.36),
      r * 0.20,
      Paint()..color = Colors.white.withOpacity(0.45),
    );
    // 蒂：两片小叶子
    final leafPaint = Paint()..color = leaf;
    for (final dir in <double>[-1, 1]) {
      final p = Path()
        ..moveTo(c.dx, c.dy - r * 0.92)
        ..quadraticBezierTo(c.dx + dir * r * 0.86, c.dy - r * 1.22,
            c.dx + dir * r * 0.34, c.dy - r * 1.02)
        ..close();
      canvas.drawPath(p, leafPaint);
    }
    // 两颗闪光，跟着秒针亮灭
    for (var i = 0; i < 2; i++) {
      final ph = (t + i * 0.5) % 1.0;
      final a = (math.sin(ph * math.pi * 2) + 1) / 2;
      final p = Offset(w * (i == 0 ? 0.79 : 0.24), h * (i == 0 ? 0.35 : 0.44));
      _star(canvas, p, w * 0.035, Colors.white.withOpacity(0.35 + 0.5 * a));
    }
  }

  /// 场景三：碗里打圈搅拌
  void _bowl(Canvas canvas, double w, double h, double t) {
    final bowlPaint = Paint()..color = Color.lerp(primary, Colors.white, 0.30)!;
    final liquid = Paint()..color = Color.lerp(soft, primary, 0.18)!;
    final box = Rect.fromLTWH(w * 0.18, h * 0.42, w * 0.64, h * 0.40);
    // 碗：下半圆
    final bowl = Path()
      ..moveTo(box.left, box.top)
      ..lineTo(box.right, box.top)
      ..arcToPoint(Offset(box.left, box.top), radius: Radius.circular(w * 0.32));
    canvas.drawPath(bowl, bowlPaint);
    canvas.drawOval(
      Rect.fromLTWH(box.left + w * 0.05, box.top + h * 0.02, box.width - w * 0.10, h * 0.09),
      liquid,
    );

    // 打蛋器：绕碗心转
    final angle = t * math.pi * 2;
    final cx = w * 0.5;
    final cy = box.top + h * 0.10;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(angle);
    final wire = Paint()
      ..color = primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.028
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final dx = (i - 1) * w * 0.055;
      final p = Path()
        ..moveTo(dx, 0)
        ..quadraticBezierTo(dx * 1.5, -h * 0.14, dx, -h * 0.22);
      canvas.drawPath(p, wire);
    }
    canvas.drawLine(Offset(0, 0), Offset(0, h * 0.12), wire);
    canvas.restore();

    // 溅起的小点
    final dot = Paint()..color = primary.withOpacity(0.55);
    for (var i = 0; i < 3; i++) {
      final ph = (t + i / 3) % 1.0;
      canvas.drawCircle(
        Offset(cx + math.cos(angle + i * 2.1) * w * 0.20,
            cy + math.sin(angle + i * 2.1) * h * 0.05 - ph * h * 0.05),
        w * 0.014,
        dot,
      );
    }
  }

  /// 场景四：菜板切菜，刀起刀落
  void _board(Canvas canvas, double w, double h, double t) {
    final board = Paint()..color = wood;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.12, h * 0.60, w * 0.76, h * 0.20),
        Radius.circular(w * 0.06),
      ),
      board,
    );
    // 切好的两段
    final veg = Paint()..color = leaf;
    for (var i = 0; i < 2; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * (0.30 + i * 0.14), h * 0.545, w * 0.10, h * 0.055),
          Radius.circular(w * 0.03),
        ),
        veg,
      );
    }
    // 刀：绕刀背端点上下切
    final swing = (math.sin(t * math.pi * 2) + 1) / 2; // 0..1
    final angle = -0.55 + swing * 0.75;
    canvas.save();
    canvas.translate(w * 0.62, h * 0.56);
    canvas.rotate(angle);
    final blade = Path()
      ..moveTo(0, 0)
      ..lineTo(-w * 0.30, h * 0.02)
      ..lineTo(-w * 0.30, h * 0.10)
      ..lineTo(0, h * 0.06)
      ..close();
    canvas.drawPath(blade, Paint()..color = const Color(0xFFB9C0C6));
    canvas.drawLine(
      Offset(-w * 0.02, h * 0.02),
      Offset(-w * 0.02, h * 0.075),
      Paint()
        ..color = const Color(0xFF7E878E)
        ..strokeWidth = w * 0.03
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  void _star(Canvas canvas, Offset c, double r, Color color) {
    final p = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + r * 0.2, c.dy - r * 0.2, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + r * 0.2, c.dy + r * 0.2, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - r * 0.2, c.dy + r * 0.2, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - r * 0.2, c.dy - r * 0.2, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BuddyPainter old) =>
      old.index != index || old.primary != primary;
}

/// 等着的时候轮着说的一句话。
///
/// 为什么不复用进度条那句阶段文案：那句必须准（「正在抽帧读字幕」），
/// 而这里要的是**有温度**。所以按进度分段挑句子 —— 下载时不说「在切菜」，
/// 整理时才说「马上就好」。每 3.4 秒换一句，配淡入上滑。
class WaitingCopy extends StatefulWidget {
  final double progress;
  const WaitingCopy({super.key, required this.progress});

  @override
  State<WaitingCopy> createState() => _WaitingCopyState();
}

class _WaitingCopyState extends State<WaitingCopy> {
  static const List<String> _early = <String>[
    '去作品里翻一遍，把画面和声音都捞回来…',
    '链接有点长，等我一小会儿',
    '先把视频存到本机，后面就不卡了',
  ];
  static const List<String> _middle = <String>[
    '一帧一帧看，把字幕上的字抄下来',
    '糊掉的画面我挑掉，留最清楚的几张',
    '同一句话读错好几次也没事，我对着投票',
  ];
  static const List<String> _late = <String>[
    '在排先后顺序了：先炒什么、后放什么',
    '盐和糖分开算，别腌成咸菜哈',
    '用料按原文抄，我不瞎编克数',
  ];
  static const List<String> _final = <String>[
    '马上就好，就差最后一步了',
    '正在把图配到对应的那一步上',
    '好了我给你看，你点头我再存',
  ];

  late List<String> _pool;
  int _i = 0;
  Timer? _timer;

  List<String> _pick(double p) {
    if (p < 0.22) return _early;
    if (p < 0.62) return _middle;
    if (p < 0.9) return _late;
    return _final;
  }

  @override
  void initState() {
    super.initState();
    _pool = _pick(widget.progress);
    _timer = Timer.periodic(const Duration(milliseconds: 3400), (_) {
      if (!mounted) return;
      setState(() => _i++);
    });
  }

  @override
  void didUpdateWidget(covariant WaitingCopy old) {
    super.didUpdateWidget(old);
    final next = _pick(widget.progress);
    // 换段了才重排句子，别每涨 1% 就把句子打断重来
    if (!identical(next, _pool)) {
      setState(() {
        _pool = next;
        _i = 0;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _pool[_i % _pool.length];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 520),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.35),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: Text(
        text,
        key: ValueKey<String>(text),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.35,
          color: Colors.white.withOpacity(0.92),
        ),
      ),
    );
  }
}

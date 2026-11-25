// 页面 5 · 大图查看：做饭时打开这一页照着做。图片来自本机，断网也能看。
//
// v1.30 重做了一次工具栏，起因是用户的一句话：
// 「两个播放按钮不好区分，用户不能快速理解这个按钮的用意」。
// 原来顶上挤了 5 个没有文字的图标（看视频 / 一步一步做 / 放大 / 编辑 / 删除），
// 其中两个都是「播放」形状，谁也分不清哪个是放视频、哪个是进做菜流程。
//
// 现在的做法是「把动作放在手指够得着的地方，并且写清楚它是什么」：
//   底部两个并排的大按钮 —— 「看原视频」「开始做菜」，一个都跑不掉；
//   其他低频动作（分享、加入本周菜单、放大、编辑、删除）收进右上角「···」。
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/recipe.dart';
import '../services/log_service.dart';
import '../services/plan_service.dart';
import '../services/share_channel.dart';
import '../services/storage_service.dart';
import '../services/video_file.dart';
import '../theme/app_theme.dart';
import '../widgets/video_hero.dart';
import 'cook_screen.dart';
import 'review_screen.dart';
import 'shopping_screen.dart';
import 'video_screen.dart';

class ViewerScreen extends StatefulWidget {
  final Recipe recipe;

  const ViewerScreen({super.key, required this.recipe});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late Recipe _recipe;
  bool _zoom = false;
  bool _inMenu = false;

  /// 每次从编辑页回来 +1，用来强制 Image.file 重新解码。
  /// 长图是覆盖写同一个文件路径的，Flutter 的图片缓存只认路径，
  /// 路径没变就一直拿旧图 —— 用户改完用量回来看到的还是老菜谱。
  int _stamp = 0;

  @override
  void initState() {
    super.initState();
    _recipe = widget.recipe;
    _refreshMenuState();
    PlanService.instance.revision.addListener(_refreshMenuState);
  }

  @override
  void dispose() {
    PlanService.instance.revision.removeListener(_refreshMenuState);
    super.dispose();
  }

  Future<void> _refreshMenuState() async {
    final v = await PlanService.instance.inMenu(_recipe.id);
    if (mounted && v != _inMenu) setState(() => _inMenu = v);
  }

  bool get _hasImage =>
      _recipe.imagePath != null && File(_recipe.imagePath!).existsSync();

  // 不再只看「文件在不在」。半截的 mp4 也在，但放不出来，
  // 挂个播放键给用户等于骗他一次。VideoFile.usable 连体积一起看。
  bool get _hasVideo => VideoFile.usable(_recipe.videoPath);

  /// 有视频，或者至少有原链接可以补下载 —— 两种情况都给入口
  bool get _canVideo => _hasVideo || _recipe.sourceUrl.trim().isNotEmpty;

  Future<void> _reload() async {
    try {
      final all = await StorageService().loadRecipes();
      Recipe? fresh;
      for (final r in all) {
        if (r.id == _recipe.id) {
          fresh = r;
          break;
        }
      }
      if (fresh == null) return;
      final p = fresh.imagePath;
      if (p != null && p.isNotEmpty) {
        await FileImage(File(p)).evict();
      }
      if (!mounted) return;
      setState(() {
        _recipe = fresh!;
        _stamp++;
      });
    } catch (_) {
      // 读失败就保持原样，不影响用户已经看到的内容
    }
  }

  Future<void> _openVideo() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoScreen(
          path: _recipe.videoPath,
          title: _recipe.title,
          recipeId: _recipe.id,
          sourceUrl: _recipe.sourceUrl,
          onFixed: _reload,
        ),
      ),
    );
  }

  Future<void> _openCook() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CookScreen(recipe: _recipe)),
    );
  }

  Future<void> _edit() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          recipe: _recipe,
          rawText: '',
          sourceUrl: _recipe.sourceUrl,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这道菜？'),
        content: Text('「${_recipe.title}」和它的长图会一起删掉，找不回来。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await StorageService()
          .deleteRecipe(_recipe.id, imagePath: _recipe.imagePath);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _toggleMenu() async {
    final now = await PlanService.instance.toggleMenu(_recipe.id);
    if (!mounted) return;
    setState(() => _inMenu = now);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(now ? '已加入这周菜单，去买菜清单看看' : '已从这周菜单移除'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        action: now
            ? SnackBarAction(
                label: '去看清单',
                onPressed: () {
                  if (!mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ShoppingScreen()),
                  );
                },
              )
            : null,
      ),
    );
  }

  // ───────────── 分享 ─────────────

  Future<void> _shareSheet() async {
    final hasImg = _hasImage;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('分享给朋友', style: AppText.section),
              const SizedBox(height: 4),
              Text('发给微信好友、家人群都行，选完人再决定发什么',
                  style: AppText.caption),
              const SizedBox(height: 14),
              _shareTile(
                icon: Icons.image_outlined,
                title: '发长图',
                sub: hasImg
                    ? '一张竖版菜谱图，朋友圈、群里都好看'
                    : '这道菜还没有长图，去「编辑」里存一张',
                enabled: hasImg,
                onTap: () async {
                  Navigator.pop(ctx);
                  await _shareImage();
                },
              ),
              const SizedBox(height: 10),
              _shareTile(
                icon: Icons.notes_outlined,
                title: '发文字',
                sub: '菜名 + 用料 + 做法，对方可以直接复制',
                enabled: true,
                onTap: () async {
                  Navigator.pop(ctx);
                  await _shareText();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shareTile({
    required IconData icon,
    required String title,
    required String sub,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.cream,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink)),
                    const SizedBox(height: 2),
                    Text(sub, style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareImage() async {
    final p = _recipe.imagePath;
    if (!ShareChannel.fileReady(p ?? '')) {
      await LogService.instance.log('分享', '长图文件不存在或读不到：${p ?? '(路径为空)'}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('长图文件不在了，点右上角「···」→「改一下再重存」会重新生成一张'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    try {
      await ShareChannel.shareFile(p!, subject: _recipe.title);
      await LogService.instance.log('分享', '已调起系统分享面板｜长图 $p');
    } catch (e) {
      await LogService.instance.log('分享', '长图分享失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('分享面板没打开：$e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _shareText() async {
    final text = ShareChannel.recipeAsText(
      title: _recipe.title.isEmpty ? '一道菜' : _recipe.title,
      ingredients: _recipe.ingredients
          .map((i) {
            final n = i.name.trim();
            final a = i.amount.trim();
            if (n.isEmpty) return a;
            return a.isEmpty ? n : '$n  $a';
          })
          .where((s) => s.trim().isNotEmpty)
          .toList(),
      steps: _recipe.steps.map((s) => s.text.trim()).toList(),
      sourceUrl: _recipe.sourceUrl,
    );
    try {
      await ShareChannel.shareText(text, subject: _recipe.title);
    } catch (e) {
      // 分享面板调不起来时，退回复制，至少别让用户白点
      final ok = await ClipboardChannel.copy(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '分享面板没打开，已复制到剪贴板' : '没调起分享：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _recipe.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '分享给朋友',
            onPressed: _shareSheet,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'menu':
                  _toggleMenu();
                  break;
                case 'zoom':
                  setState(() => _zoom = !_zoom);
                  break;
                case 'edit':
                  _edit();
                  break;
                case 'delete':
                  _delete();
                  break;
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'menu',
                child: Row(
                  children: [
                    Icon(
                      _inMenu
                          ? Icons.remove_shopping_cart_outlined
                          : Icons.add_shopping_cart_outlined,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(_inMenu ? '从这周菜单移除' : '这周想做这道菜'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'zoom',
                child: Row(
                  children: [
                    Icon(_zoom ? Icons.zoom_out_map : Icons.zoom_in,
                        size: 20, color: AppColors.subInk),
                    const SizedBox(width: 10),
                    Text(_zoom ? '恢复正常大小' : '放大看细节'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined,
                        size: 20, color: AppColors.subInk),
                    const SizedBox(width: 10),
                    const Text('改一下再重存'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline,
                        size: 20, color: AppColors.danger),
                    const SizedBox(width: 10),
                    Text('删除', style: TextStyle(color: AppColors.danger)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: !_hasImage
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '长图文件不见了，点右上角「···」选「改一下再重存」，重新生成一张。',
                  textAlign: TextAlign.center,
                  style: AppText.bodySub,
                ),
              ),
            )
          : _zoom
              ? InteractiveViewer(
                  // 长图比屏幕高很多，constrained:false 才允许拖动看完整张图
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(40),
                  minScale: 0.8,
                  maxScale: 4.0,
                  child: Image.file(
                    File(_recipe.imagePath!),
                    key: ValueKey('zoom$_stamp'),
                    width: screenW,
                    fit: BoxFit.fitWidth,
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      // v1.32：用户的原话「我图片画圈这个位置，如果有视频的话
                      // 能不能播放菜的视频，这样更灵活」—— 圈的就是长图最上面
                      // 那张封面照。既然原视频就在手机里，第一眼就该让它动起来。
                      //
                      // 刻意做成「跟着长图一起滚动」而不是钉在顶上：这一页的主
                      // 内容是那张完整长图，视频钉住会吃掉两百多像素，长图永远
                      // 看不全。
                      if (_hasVideo)
                        VideoHero(
                          path: _recipe.videoPath,
                          title: _recipe.title,
                          onOpenFull: _openVideo,
                        ),
                      Image.file(
                        File(_recipe.imagePath!),
                        key: ValueKey('scroll$_stamp'),
                        width: screenW,
                        fit: BoxFit.fitWidth,
                      ),
                    ],
                  ),
                ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                if (_canVideo)
                  Expanded(
                    flex: 4,
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WidgetStateProperty.all(AppColors.primary),
                          side: BorderSide(color: AppColors.primary),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: _openVideo,
                        icon: const Icon(Icons.play_circle_outline, size: 20),
                        label: Text(
                          _hasVideo ? '看原视频' : '补上视频',
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                if (_canVideo) const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _recipe.steps.isEmpty ? null : _openCook,
                      icon: const Icon(Icons.local_fire_department, size: 20),
                      label: const Text(
                        '开始做菜',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800),
                      ),
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
}

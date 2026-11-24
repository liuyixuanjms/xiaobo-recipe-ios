// 页面 1 · 小波菜谱（首页）：网格看已生成的长图、搜索、分类、从系统分享直接带进内容。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/build_flavor.dart';
import '../models/recipe.dart';
import '../services/app_info.dart';
import '../services/asr_model_service.dart';
import '../services/ingest_job.dart';
import '../services/plan_service.dart';
import '../services/settings_service.dart';
import '../services/share_bridge.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/home_card_layout.dart';
import '../widgets/waiting_buddy.dart';
import 'new_recipe_screen.dart';
import 'review_screen.dart';
import 'settings_screen.dart';
import 'shopping_screen.dart';
import 'viewer_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const List<String> tags = ['全部', '家常菜', '汤羹', '烘焙', '凉菜', '早餐', '其他'];

  final StorageService _storage = StorageService();
  final TextEditingController _searchCtrl = TextEditingController();
  // v1.50.2：分类栏的横向滚动由它驱动——手指滑 + 右侧箭头点一下前进一屏，
  // 两种方式都保留「左右滑动」的体验，箭头只是滑不动时的兜底。
  final ScrollController _tagCtrl = ScrollController();

  List<Recipe> _all = [];
  String _keyword = '';
  String _tag = '全部';
  bool _loading = true;
  bool _navigating = false;
  StreamSubscription<String>? _shareSub;

  /// 这周菜单里有几道菜 —— 购物袋上挂个数字，才知道里面有没有东西
  int _menuCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMenuCount();
    PlanService.instance.revision.addListener(_loadMenuCount);
    // v1.31：后台作业的进度和成果都在这儿。首页订阅它，才能在用户
    // 「点返回、去刷别的」之后，仍然把「正在做 / 做好了」摆在他眼前。
    IngestJob.instance.addListener(_onJobChanged);

    // App 已在前台时又收到分享
    _shareSub = ShareBridge.instance.onSharedText.listen(_onShared);

    // App 本来没开、由分享动作拉起（冷启动）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = ShareBridge.instance.consumePending();
      if (pending != null) _onShared(pending);
    });

    // v1.24：语音包改为按需下载后在 WiFi 下后台静默备好，省得用户用到时干等。
    // 延迟 8 秒、避开启动高峰；流量下 / 用户关了自动下载 / 已就绪 都不碰网络。
    _maybeAutoDownloadAsr();
  }

  Future<void> _maybeAutoDownloadAsr() async {
    try {
      await Future<void>.delayed(const Duration(seconds: 8));
      if (!mounted) return;
      final settings = SettingsService();
      final auto = await settings.isAsrAutoDownloadEnabled();
      if (!auto) return;
      final svc = AsrModelService();
      if (await svc.isReady() || svc.isDownloading) return;
      if (!await svc.isOnWifi()) return; // 只认 WiFi，绝不偷跑流量
      // 后台下载，失败静默（下次启动再试），不打断用户当前操作
      try {
        await svc.download();
      } catch (_) {}
    } catch (_) {
      // 自动下载是可有可无的便利，任何异常都吞掉
    }
  }

  Future<void> _loadMenuCount() async {
    final ids = await PlanService.instance.loadMenu();
    if (!mounted) return;
    if (ids.length != _menuCount) setState(() => _menuCount = ids.length);
  }

  void _onJobChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    IngestJob.instance.removeListener(_onJobChanged);
    PlanService.instance.revision.removeListener(_loadMenuCount);
    _shareSub?.cancel();
    _searchCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await _storage.loadRecipes();
    // V1.4：旧版把「缺步骤」的残次菜谱也存了下来（日志里那条 3 项用料 / 0 步），
    // 装新版后还挂在首页会让人以为修复没生效。这里启动时自动清掉，只留完整记录。
    final hasReal = list.where((r) {
      final hasIng = r.ingredients.any(
        (i) => i.name.trim().isNotEmpty || i.amount.trim().isNotEmpty,
      );
      final hasStep = r.steps.any((s) => s.text.trim().isNotEmpty);
      return hasIng && hasStep;
    }).toList();
    final broken = list.where((r) => !hasReal.contains(r)).toList();
    for (final r in broken) {
      await _storage.deleteRecipe(r.id, imagePath: r.imagePath);
    }
    final shown = hasReal;
    if (!mounted) return;
    setState(() {
      _all = shown;
      _loading = false;
    });
  }

  List<Recipe> get _shown {
    final kw = _keyword.trim().toLowerCase();
    return _all.where((r) {
      final tagOk = _tag == '全部' || r.tag == _tag;
      final kwOk = kw.isEmpty ||
          r.title.toLowerCase().contains(kw) ||
          r.ingredients.any((i) => i.name.toLowerCase().contains(kw));
      return tagOk && kwOk;
    }).toList();
  }

  void _onShared(String raw) {
    if (_navigating || !mounted) return;
    _navigating = true;
    final p = ShareParser.parse(raw);
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => NewRecipeScreen(
            initialText: p.text,
            initialUrl: p.url,
            fromShare: true,
          ),
        ))
        .then((_) {
          _navigating = false;
          _load();
        });
  }

  Future<void> _openNew() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NewRecipeScreen()),
    );
    _load();
  }

  /// 作业做完了，但用户当时已经退出新建页 —— 成果在这儿等着他去核对。
  Future<void> _openPendingReview() async {
    final o = IngestJob.instance.takePending();
    if (o == null || !mounted) return;
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
    _load();
  }

  Future<void> _openViewer(Recipe r) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ViewerScreen(recipe: r)),
    );
    _load();
  }

  Future<void> _openSettings() async {
    // 设置页里「从备份恢复」成功后会 pop(true)，这时首页要把数据重新拉一遍，
    // 否则用户恢复完回来看到的还是空列表，会以为白恢复了。
    final restored = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (restored == true) _load();
  }

  /// 长按卡片：不再直接弹「删除」，而是先给两个常见意图。
  /// 以前长按就删，手滑一次菜谱就没了，这个风险不该留。
  Future<void> _confirmDelete(Recipe r) async {
    final inMenu = await PlanService.instance.inMenu(r.id);
    if (!mounted) return;
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(
                inMenu
                    ? Icons.remove_shopping_cart_outlined
                    : Icons.add_shopping_cart_outlined,
                color: AppColors.primary,
              ),
              title: Text(inMenu ? '从这周菜单移除' : '这周想做'),
              subtitle: Text(
                inMenu ? '买菜清单里就不需要它的料了' : '加进买菜清单，一起算用料',
                style: AppText.caption,
              ),
              onTap: () => Navigator.pop(ctx, 'menu'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text('删除这道菜', style: TextStyle(color: AppColors.danger)),
              subtitle: Text('菜谱和长图一起删掉，找不回来', style: AppText.caption),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
            ListTile(
              title: const Center(child: Text('取消')),
              onTap: () => Navigator.pop(ctx, 'cancel'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (act == 'menu') {
      await PlanService.instance.toggleMenu(r.id);
      await _loadMenuCount();
      return;
    }
    if (act != 'delete') return;

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('真的要删掉吗？'),
        content: Text('「${r.title}」和它的长图会一起消失，删了找不回来。'),
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
      await _storage.deleteRecipe(r.id, imagePath: r.imagePath);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // v1.50.1：版本号挪到首页标题下面，打开就能看到。
        // 之前藏在「设置→数据与关于」一大段文字里，用户装了旧版都不知道，
        // 反复反馈的问题其实修复早发了却没到手机 —— 必须一眼能核对。
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kAppName),
            Text(
              'v${AppInfo.version}',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.subInk,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          // 买菜清单：这周要做几道菜，袋子上挂个数字
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShoppingScreen()),
                  );
                  _loadMenuCount();
                },
                icon: const Icon(Icons.shopping_bag_outlined),
                tooltip: '买菜清单',
              ),
              if (_menuCount > 0)
                Positioned(
                  right: 6,
                  top: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '$_menuCount',
                      style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 「正在做 / 做好了」永远摆在最上面 —— 用户从新建页退出来，
                // 第一眼就得看见活还在跑、或者已经好了。
                _buildJobBanner(),
                _buildSearch(),
                _buildTags(),
                Expanded(
                  child: _shown.isEmpty ? _buildEmpty() : _buildGrid(),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openNew,
        icon: const Icon(Icons.add),
        label: const Text('收一道新菜'),
      ),
    );
  }

  /// 首页顶部那条「正在做菜谱 40% / 菜谱做好了」。
  ///
  /// 有了它，「返回也不影响」才是一个用户能看见的事实，而不是我在代码里
  /// 答应他的一句话。作业在后台跑，这条就是唯一的线索。
  Widget _buildJobBanner() {
    final job = IngestJob.instance;

    if (job.busy) {
      final pct = (job.progress * 100).clamp(0, 100).round();
      return GestureDetector(
        onTap: _openNew,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              WaitingBuddy(size: 40, stage: job.stage),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '正在做菜谱 · $pct%',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      job.stage.isEmpty ? '准备中…' : job.stage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '看进度',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 失败了也要说一声。最怕的是「点返回 → 后台跑完但没成 → 什么提示都没有」，
    // 用户会以为 App 把活吞了。
    if (job.errorTitle.isNotEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 2),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warn.withOpacity(0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: AppColors.warn, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                job.errorTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
            TextButton(
              onPressed: _showJobError,
              child: const Text('看原因'),
            ),
          ],
        ),
      );
    }

    final p = job.pending;
    if (p != null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 2),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: AppColors.done, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '「${p.recipe.title}」做好了',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${p.recipe.ingredients.length} 项用料 · ${p.recipe.steps.length} 步，核对一下再存',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _openPendingReview,
              child: const Text('去核对'),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Future<void> _showJobError() async {
    final err = IngestJob.instance.takeError();
    if (err == null || !mounted) return;
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

  Widget _buildSearch() {
    return Padding(
      padding:  EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _keyword = v),
        decoration: InputDecoration(
          hintText: '搜菜名或食材…',
          prefixIcon: Icon(Icons.search, color: AppColors.subInk),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _keyword = '');
                  },
                ),
        ),
      ),
    );
  }

  /// 分类标签（v1.50.2）：按用户要求恢复「左右滑动」的交互。
  /// 三条同时做到：
  ///  1) 横向 ListView 手指能滑，且用自绘标签（不用会抢手势的 FilterChip）；
  ///  2) 右缘渐变 + 箭头按钮，点一下前进一屏——手指滑不顺时也有确定性的出口；
  ///  3) 切换分类自动把该标签滚到可见区，选中项永远看得见。
  Widget _tagChip(String t) {
    final selected = t == _tag;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _tag = t);
        final i = tags.indexOf(t);
        if (i >= 0) {
          _tagCtrl.animateTo(
            i * 78.0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.check, size: 15, color: AppColors.primary),
              ),
            Text(
              t,
              style: TextStyle(
                color: selected ? AppColors.primary : AppColors.subInk,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTags() {
    return Stack(
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            controller: _tagCtrl,
            padding: const EdgeInsets.fromLTRB(16, 0, 52, 0),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            itemCount: tags.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) => _tagChip(tags[i]),
          ),
        ),
        // 右缘：半透明白遮罩提示「后面还有」，箭头点一下前进一段。
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: false,
            child: GestureDetector(
              onTap: () {
                final max = _tagCtrl.position.maxScrollExtent;
                final next = (_tagCtrl.offset + 160).clamp(0.0, max);
                _tagCtrl.animateTo(
                  next,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOut,
                );
              },
              child: Container(
                width: 52,
                alignment: Alignment.centerRight,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      AppColors.bg.withOpacity(0),
                      AppColors.bg,
                    ],
                  ),
                ),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Icon(Icons.chevron_right,
                      size: 18, color: AppColors.primary),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGrid() {
    // v1.43.2：格子高不再拍死 0.72，而是按「封面比例 + 文字区」动态算。
    // 图片区锁成 360:200，缩略图就只露封面，不会把长图里的菜名和
    // 「用料」再带一遍 —— 卡片下方本来就有菜名和元信息了。
    return LayoutBuilder(
      builder: (ctx, c) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          HomeCardLayout.pagePadding, 8, HomeCardLayout.pagePadding, 110,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: HomeCardLayout.columns,
          crossAxisSpacing: HomeCardLayout.spacing,
          mainAxisSpacing: 12,
          childAspectRatio: HomeCardLayout.aspectRatio(c.maxWidth),
        ),
        itemCount: _shown.length,
        itemBuilder: (ctx, i) {
          final r = _shown[i];
          return GestureDetector(
            onTap: () => _openViewer(r),
            onLongPress: () => _confirmDelete(r),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: HomeCardLayout.coverAspect,
                    child: _thumb(r),
                  ),
                  SizedBox(
                    height: HomeCardLayout.textHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${r.tag} · ${r.steps.length} 步',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _thumb(Recipe r) {
    // v1.43.2：优先用单独存下来的实拍封面 —— 它是纯照片，没有长图里
    // 那套「菜名 / 分类标签 / 用料」叠字。以前首页缩略图直接用长图 PNG，
    // 等于把长图里的标题又抄了一遍进卡片，而卡片下方本来就有菜名。
    final cover = r.coverPath.trim();
    if (cover.isNotEmpty && File(cover).existsSync()) {
      return Image.file(File(cover), fit: BoxFit.cover);
    }
    // 老菜谱可能没存独立封面，只能退回长图。图片区已锁成 360:200，
    // BoxFit.cover 按宽度缩放后，容器高度对应源图正好是顶部 200px 的封面段，
    // 长图下面的文字自然被裁掉。
    final path = r.imagePath;
    if (path == null || !File(path).existsSync()) return _placeholder();
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
    );
  }

  Widget _placeholder() => Container(
        color: AppColors.cream,
        alignment: Alignment.center,
        child:  Icon(Icons.image_not_supported_outlined,
            color: AppColors.subInk, size: 32),
      );

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding:  EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children:  [
            Icon(Icons.menu_book_outlined, size: 56, color: AppColors.line),
            SizedBox(height: 16),
            Text(
              '这里还空着，把刷到的第一道菜收进来吧',
              textAlign: TextAlign.center,
              style: AppText.bodySub,
            ),
            SizedBox(height: 10),
            Text(
              '在抖音或小红书点「分享 → 小波菜谱」，链接和文案会自动带过来；\n也可以点右下角，自己贴一条链接或几张截图。',
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}

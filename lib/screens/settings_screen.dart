// 页面 6 · 设置：外观（配色/字号）、语音包、离线整理说明、备份、清空数据。
// v1.25 起 App 完全离线：不再有任何 AI 服务商 / 密钥 / 接口配置。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/brand.dart';
import '../services/app_info.dart';
import '../services/asr_model_service.dart';
import '../services/backup_service.dart';
import '../services/log_service.dart';
import '../services/plan_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'log_screen.dart';
import 'privacy_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settings = SettingsService();
  bool _loading = true;
  bool _detailed = true;

  /// v1.23 外观：当前配色 key 与字号倍率。切了立刻全局生效并记住。
  String _paletteKey = ThemeController.palette.key;
  double _fontScale = FontScale.value;

  /// v1.24 语音包：模型已移出安装包，按需下载到私有目录。
  final AsrModelService _asr = AsrModelService();
  bool _asrReady = false;
  bool _asrBundled = false; // v1.37：模型是否随安装包内置（决定文案说「已内置」还是「已下载」）
  int _asrSize = 0;
  double _asrProgress = 0;
  String _asrMsg = '';
  bool _asrAuto = true;

  /// 上次没下完留下的断点字节数（v1.26）。>0 时提示「点一下接着下」。
  int _asrPending = 0;

  /// 备份 / 恢复进行中。两个按钮在跑的时候都要禁用，避免重复点出两个包。
  bool _busy = false;
  String _busyKind = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    final detailed = await _settings.isChefReviewEnabled();
    final asrReady = await _asr.isReady();
    final asrSize = await _asr.localSize();
    // v1.37：模型内置进安装包后，「就绪」是装完即成立的。
    // 单独问一次是不是内置的，好把文案从「已下载」改成「已内置」——
    // 否则用户会以为还有一步没做，一直找下载按钮。
    final asrBundled = asrReady ? await _asr.isBundled() : false;
    final asrAuto = await _settings.isAsrAutoDownloadEnabled();
    final asrPending = asrReady ? 0 : await _asr.pendingBytes();
    // 万一冷启动预热没拿到，进设置页时再问一次，别让用户看着「未知」
    await AppInfo.load();
    if (!mounted) return;
    setState(() {
      _detailed = detailed;
      _asrReady = asrReady;
      _asrBundled = asrBundled;
      _asrSize = asrSize;
      _asrAuto = asrAuto;
      _asrPending = asrPending;
      _loading = false;
    });
  }

  /// 手动下载语音包（用户点按钮）。实时刷新进度，失败给人话提示。
  Future<void> _downloadAsr() async {
    if (_asr.isDownloading) return;
    setState(() {
      _asrProgress = 0;
      _asrMsg = _asrPending > 0
          ? '接着上次的进度下（已存 ${(_asrPending / 1048576).toStringAsFixed(1)} MB）…'
          : '正在下载语音包，别关掉这个页面…';
    });
    try {
      final size = await _asr.download(
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _asrProgress = p.percent;
            _asrPending = p.received;
            _asrMsg = '已下载 ${p.human}';
          });
        },
      );
      await _load();
      _snack('语音包下载好了（${(size / 1048576).toStringAsFixed(0)} MB），以后永久免下');
    } catch (e) {
      if (mounted) {
        final left = await _asr.pendingBytes();
        setState(() {
          _asrPending = left;
          _asrMsg = '下载没成：${e is Exception ? e.toString().replaceFirst('Exception: ', '') : e}';
        });
      }
    }
  }

  /// App 内怎么都下不动时的兜底：把直链复制出来，用户丢进浏览器/迅雷照样能拿。
  Future<void> _copyAsrUrl() async {
    await Clipboard.setData(
        ClipboardData(text: AsrModelService.modelDownloadUrl));
    _snack('下载链接已复制，可以丢进手机浏览器下载');
  }

  Future<void> _toggleAsrAuto(bool v) async {
    await _settings.setAsrAutoDownload(v);
    setState(() => _asrAuto = v);
    _snack(v ? '已允许 WiFi 下自动下载语音包' : '已关闭自动下载，只在手动点时下载');
  }

  /// 切换配色：改 notifier 让顶层 ValueListenableBuilder 重建全 App，再记住选择。
  Future<void> _switchPalette(AppPalette p) async {
    if (p.key == _paletteKey) return;
    ThemeController.setPalette(p);
    await _settings.setPaletteKey(p.key);
    setState(() => _paletteKey = p.key);
    _snack('已换成「${p.label}」');
  }

  /// 切字号倍率：改 notifier 让顶层 MediaQuery.textScaleFactor 生效。
  Future<void> _setFontScale(double v) async {
    final step = FontScale.clampToStep(v);
    FontScale.scale.value = step;
    await _settings.setFontScale(step);
    setState(() => _fontScale = step);
    _snack('字号已设为「${FontScale.labelOf(step)}」');
  }

  Future<void> _toggleDetailed(bool v) async {
    await _settings.setChefReviewEnabled(v);
    setState(() => _detailed = v);
    _snack(v ? '已开启精细整理（逐行合并补充、完整核对）' : '已切回快速整理（只切步骤+抽料）');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 导出备份：打包 → 记日志 → 弹系统分享面板。
  ///
  /// 为什么要走分享面板而不是「存到手机」：Android 10 以后往公共目录写文件
  /// 要申请存储权限，小米还会弹一堆「允许访问照片和媒体」。走分享面板
  /// 用户自己选微信/网盘，一个权限都不用给。
  Future<void> _exportBackup() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyKind = 'export';
    });
    final logs = LogService.instance;
    await logs.startSession('设置页 · 导出备份', <String, String>{
      '操作': '把菜谱 + 长图 + 步骤图打成一个 zip',
    });
    try {
      final r = await BackupService().export();
      await logs.log('备份', '已生成｜${r.recipeCount} 道菜｜${r.fileCount} 个图片文件｜${r.sizeText}');
      await logs.end('✅ 备份成功：${r.recipeCount} 道菜、${r.sizeText}');
      await BackupService.shareBackup(r.path);
      _snack('备份好了：${r.recipeCount} 道菜、${r.sizeText}。选微信发给自己或存网盘');
    } catch (e) {
      await logs.end('❌ 备份失败：$e');
      _snack(backupErrorText(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyKind = '';
        });
      }
    }
  }

  /// 从备份恢复：选包 → 解包 → 合并（同 id 覆盖）。
  Future<void> _importBackup() async {
    if (_busy) return;
    String? path;
    try {
      path = await BackupService.pickBackupFile();
    } catch (e) {
      _snack('打不开文件选择器：$e');
      return;
    }
    if (path == null) return; // 用户取消了

    setState(() {
      _busy = true;
      _busyKind = 'import';
    });
    final logs = LogService.instance;
    await logs.startSession('设置页 · 从备份恢复', <String, String>{
      '操作': '解开 zip，把菜谱和图片写回本机',
    });
    try {
      final r = await BackupService().restoreFrom(path);
      await logs.log('恢复',
          '新增 ${r.added} 道｜覆盖 ${r.updated} 道｜图片 ${r.fileCount} 张｜坏数据 ${r.broken} 条');
      await logs.end('✅ 恢复完成：共 ${r.total} 道菜');
      _snack('恢复完成：新增 ${r.added} 道，覆盖 ${r.updated} 道'
          '${r.broken > 0 ? '（${r.broken} 条读不了，已跳过）' : ''}');
      // 恢复完让首页重新拉一遍数据
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      await logs.end('❌ 恢复失败：$e');
      _snack(backupErrorText(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyKind = '';
        });
      }
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部菜谱？'),
        content: const Text('所有菜谱和生成的长图都会删掉，找不回来。这一周菜单和买菜清单也会一起清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:  Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确认清空', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await StorageService().clearAll();
      // 菜都没了，菜单和清单里的 id 全是悬空的，一起清干净
      await PlanService.instance.clearMenu();
      _snack('已清空，回首页看看');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding:  EdgeInsets.all(16),
              children: [
                _sectionTitle('外观'),
                 SizedBox(height: 8),
                 Text(
                  '背景颜色和字体大小，随时调、立刻生效，关掉 App 也记得住。',
                  style: AppText.bodySub,
                ),
                 SizedBox(height: 12),
                Text('背景颜色', style: AppText.body),
                 SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: kPalettes.map((p) {
                    final selected = p.key == _paletteKey;
                    return _paletteSwatch(p, selected);
                  }).toList(),
                ),
                 SizedBox(height: 18),
                Text('字体大小', style: AppText.body),
                 SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Row(
                    children: FontScale.options.asMap().entries.map((e) {
                      final i = e.key;
                      final v = e.value;
                      final selected = (v - _fontScale).abs() < 0.01;
                      return Expanded(
                        child: InkWell(
                          onTap: () => _setFontScale(v),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: selected ? AppColors.primarySoft : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border(
                                right: i < FontScale.options.length - 1
                                    ? BorderSide(color: AppColors.line)
                                    : BorderSide.none,
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  FontScale.labels[i],
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                                    color: selected ? AppColors.primary : AppColors.subInk,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${v.toStringAsFixed(2)}x',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: selected ? AppColors.primary : AppColors.subInk,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                 SizedBox(height: 6),
                Text(
                  '字太小看不清、或想做大字给家里老人看，选「偏大 / 特大」。',
                  style: AppText.caption,
                ),
                 SizedBox(height: 24),
                _sectionTitle('语音包（听视频讲解）'),
                 SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
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
                            _asrReady ? Icons.check_circle : Icons.graphic_eq,
                            color: _asrReady ? AppColors.done : AppColors.subInk,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _asrReady
                                  ? (_asrBundled
                                      ? '已内置 · ${(_asrSize / 1048576).toStringAsFixed(0)} MB（随安装包，不用下载）'
                                      : '已下载 · ${(_asrSize / 1048576).toStringAsFixed(0)} MB')
                                  : (_asrPending > 0
                                      ? '没下完 · 已存 ${(_asrPending / 1048576).toStringAsFixed(1)} MB（可接着下）'
                                      : '还没下载（约 79 MB）'),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _asrReady ? AppColors.done : AppColors.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _asrReady
                            ? (_asrBundled
                                ? '语音识别已就绪：模型已经打包在安装包里，装完就能用，'
                                    '不联网、不上传、不花流量。听视频讲解全程在本机完成。'
                                : '语音识别已就绪，听视频讲解全离线、不上传、不要钱。'
                                    '这个包下过一次就永久留在手机，以后升级 App 都不用再下。')
                            : '安装包已瘦身，语音模型改为按需下载。没下载也能正常整理菜谱（用画面字幕兜底），下载后识别更准（用量、火候常只说不写）。',
                        style: AppText.caption,
                      ),
                      if (!_asrReady) ...[
                        const SizedBox(height: 10),
                        if (_asrMsg.isNotEmpty) ...[
                          Text(_asrMsg, style: AppText.tip),
                          if (_asr.isDownloading) ...[
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: _asrProgress),
                          ],
                          const SizedBox(height: 8),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _asr.isDownloading ? null : _downloadAsr,
                            icon: _asr.isDownloading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.download_rounded, size: 18),
                            label: Text(
                              _asr.isDownloading
                                  ? '下载中…'
                                  : (_asrPending > 0
                                      ? '接着下（已存 ${(_asrPending / 1048576).toStringAsFixed(1)} MB）'
                                      : '下载语音包'),
                            ),
                            style: ElevatedButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        // 兜底出口：App 内网络一直断的话，复制直链用浏览器下照样能拿到。
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _asr.isDownloading ? null : _copyAsrUrl,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('下不动？复制下载链接', style: TextStyle(fontSize: 12.5)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SwitchListTile(
                          value: _asrAuto,
                          onChanged: _toggleAsrAuto,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('WiFi 下自动下载', style: TextStyle(fontSize: 13)),
                          subtitle: Text(
                            '开着的话，连 WiFi 时 App 启动会自己在后台下好，流量下绝不下。',
                            style: AppText.caption,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                 SizedBox(height: 24),
                _sectionTitle('整理方式'),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Text(
                    '从 v1.25 起，整理菜谱完全在手机本地完成：画面字幕自带秒数，'
                    'App 直接切成分步做法、用词表抽出用料，不调用任何 AI 接口。\n'
                    '不用注册、不用密钥、不花一分钱、断网也能整理。',
                    style: AppText.bodySub,
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: _detailed,
                  onChanged: _toggleDetailed,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('精细整理（推荐）',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    '开启：带秒数字幕逐行切成步骤，合并补充描述，再扫漏料、抽关键点。\n'
                    '关闭：只切步骤 + 抽用料，更快但描述更简。',
                    style: AppText.caption,
                  ),
                ),
                 SizedBox(height: 20),
                _sectionTitle('结果不对？导出运行日志'),
                 SizedBox(height: 8),
                 Text(
                  'App 会把「读链接 → 打开页面 → 下视频 → 抽帧 → 认字幕 → 本地整理 → 出图」'
                  '每一步成没成记下来。跑不通时不用口述，导出一份发过来就能定位。',
                  style: AppText.bodySub,
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogScreen()),
                  ),
                  icon: const Icon(Icons.article_outlined, size: 18),
                  label: const Text('查看 / 导出运行日志'),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                 SizedBox(height: 24),
                _sectionTitle('备份与恢复'),
                 SizedBox(height: 8),
                 Text(
                  '整理一道菜要花几十秒和一点额度，做过的菜谱是攒下来的东西。'
                  '备份会把它打成一个压缩包（含长图和步骤图），发到微信 / 网盘存着；'
                  '换手机、重装 App 之后选这个包就能整包搬回来。',
                  style: AppText.bodySub,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : _exportBackup,
                        icon: _busy && _busyKind == 'export'
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.backup_outlined, size: 18),
                        label: const Text('导出备份'),
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _importBackup,
                        icon: _busy && _busyKind == 'import'
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.restore_outlined, size: 18),
                        label: const Text('从备份恢复'),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
                 SizedBox(height: 8),
                 Text(
                  '导出后选「微信」发给自己（文件传输助手），或者选网盘。'
                  '恢复时同名的菜谱会覆盖成备份里的版本，不会重复。',
                  style: AppText.caption,
                ),
                const SizedBox(height: 24),
                _sectionTitle('数据与关于'),
                 SizedBox(height: 10),
                Text(
                  '整理引擎：纯本地（离线、零 API、不花钱）\n'
                  '菜谱和长图只存在本机。换手机前记得用上面的「导出备份」存一份。\n'
                  '版本 ${AppInfo.version} · 仅安卓\n\n'
                  '$copyrightLine\n'
                  '构建标记 $kBuildMark',
                  style: AppText.bodySub,
                ),
                const SizedBox(height: 20),
                // 【v1.37】隐私政策入口。小米审核会核对「App 内能读到政策全文」，
                // 只有启动弹窗里的链接是不够的 —— 用户同意之后就再没有别的入口了。
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                  ),
                  icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                  label: const Text('查看隐私政策'),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.line),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _clearAll,
                  icon: Icon(Icons.delete_forever_outlined, size: 18, color: AppColors.danger),
                  label: Text('清空全部菜谱', style: TextStyle(color: AppColors.danger)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.danger),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
    );
  }

  /// 配色色块：上方是这套方案的迷你预览（背景+主色+文字色），下方是名字。
  Widget _paletteSwatch(AppPalette p, bool selected) {
    return InkWell(
      onTap: () => _switchPalette(p),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 78,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.line,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              height: 34,
              decoration: BoxDecoration(
                color: p.bg,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: p.line),
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 5,
                    top: 5,
                    right: 5,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: p.card,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 5,
                    bottom: 5,
                    child: Container(
                      width: 26,
                      height: 6,
                      decoration: BoxDecoration(
                        color: p.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: Container(
                      width: 16,
                      height: 6,
                      decoration: BoxDecoration(
                        color: p.ink,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Text(
              p.label.replaceAll('（默认）', ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected ? AppColors.primary : AppColors.subInk,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text, style: AppText.section);
}

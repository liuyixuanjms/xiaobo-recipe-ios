// 页面 7 · 运行日志（V0.14）
//
// 用户真机上「不出图 / 不出步骤」时，不用自己口述。这个页面把整条链路
// 每一步的记录摆出来，一键复制或分享，发过来就能精确定位断在哪一步。
// 面向不懂技术的用户：按钮写大白话，操作只有「点一下 → 选微信 → 发」。
import 'package:flutter/material.dart';

import '../services/log_exporter.dart';
import '../services/log_service.dart';
import '../theme/app_theme.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final LogService _logs = LogService.instance;

  bool _loading = true;
  bool _busy = false;
  bool _all = false; // 默认只导最近一次，文本短、好发
  String _text = '';
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final list = await _logs.sessions();
    final text = await _logs.exportText(all: _all);
    if (!mounted) return;
    setState(() {
      _count = list.length;
      _text = text;
      _loading = false;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _run(Future<void> Function() action, String okMsg) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _snack(okMsg);
    } catch (e) {
      _snack('没发出去：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doCopy() => _run(
        () => LogExporter.copy(_text),
        '已复制 ✅ 打开微信，长按输入框粘贴发我就行',
      );

  Future<void> _doShareText() => _run(
        () => LogExporter.shareText(_text),
        '已拉起分享，选微信 / QQ 发我',
      );

  Future<void> _doShareFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final full = await _logs.exportText(all: true);
      final path = await LogExporter.writeFile(full);
      await LogExporter.shareFile(path);
      _snack('已生成日志文件，选微信 / QQ 发我');
    } catch (e) {
      _snack('发文件没成功，改用「复制日志」也行：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部日志？'),
        content:  Text('只是删掉这些记录，不影响你已经存好的菜谱和图片。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:  Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清空', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _logs.clear();
      await _reload();
      _snack('日志已清空');
    }
  }

  Future<void> _setAll(bool v) async {
    setState(() => _all = v);
    final text = await _logs.exportText(all: _all);
    if (!mounted) return;
    setState(() => _text = text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _hint(),
                        const SizedBox(height: 12),
                        _scopeSwitch(),
                        const SizedBox(height: 14),
                        _actions(),
                        const SizedBox(height: 16),
                        _logBox(),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _doClear,
                            icon: const Icon(Icons.delete_outline, size: 16),
                            label: const Text('清空日志',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
      bottomSheet: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _busy ? null : _doShareFile,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_outlined),
              label: const Text(
                '导出日志文件 · 发给我',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hint() => Container(
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
                Icon(Icons.article_outlined, color: AppColors.primary, size: 20),
                SizedBox(width: 8),
                Text(
                  '哪不对，不用你自己描述',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
             SizedBox(height: 8),
             Text(
              'App 把每一步（读链接、打开页面、下视频、抽帧、认字幕、'
              '本地整理、出图）成没成、拿到多少东西，都记在下面了。\n'
              '复现一次不对的，再点右下角「导出日志文件」选微信发过来，'
              '我照着日志就能看出断在哪儿，比你口述准得多。',
              style: TextStyle(
                  color: AppColors.ink, fontSize: 13, height: 1.6),
            ),
          ],
        ),
      );

  Widget _scopeSwitch() => Row(
        children: <Widget>[
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                backgroundColor: _all ? AppColors.card : AppColors.primarySoft,
                side: BorderSide(
                  color: _all ? AppColors.line : AppColors.primary,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => _setAll(false),
              child: Text(
                '只看最近一次',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _all ? AppColors.subInk : AppColors.primary,
                ),
              ),
            ),
          ),
           SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                backgroundColor: _all ? AppColors.primarySoft : AppColors.card,
                side: BorderSide(
                  color: _all ? AppColors.primary : AppColors.line,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => _setAll(true),
              child: Text(
                '看全部（$_count 次）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _all ? AppColors.primary : AppColors.subInk,
                ),
              ),
            ),
          ),
        ],
      );

  Widget _actions() => Row(
        children: <Widget>[
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _busy ? null : _doCopy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制日志', style: TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _busy ? null : _doShareText,
              icon: const Icon(Icons.text_snippet_outlined, size: 18),
              label:  Text('发文字', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      );

  Widget _logBox() => Container(
        width: double.infinity,
        padding:  EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.line),
        ),
        child: SelectableText(
          _text.isEmpty ? '（还没有日志）' : _text,
          style:  TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.55,
            color: AppColors.ink,
          ),
        ),
      );
}

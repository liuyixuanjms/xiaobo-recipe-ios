// 启动时的隐私政策闸门（v1.37 新增）。
//
// 为什么做成独立的 StatefulWidget 而不是塞进 main()：
// 弹窗必须挂在 MaterialApp 的 Navigator 上才能拿到主题和返回栈，
// 而 MaterialApp 是在 build 里才有的。所以放在 home 外面包一层，
// 由它在首帧之后去弹 —— 既拿得到 context，又不用把整个 App 改成 Stateful。
//
// 合规上必须做到的三件事（小米审核会真机验）：
//   ① 弹窗不可点外部关闭、不可按返回键关闭 —— 必须明确选择
//   ② 必须能读到全文（「查看完整政策」进 PrivacyScreen）
//   ③ 不同意就不能用 —— 不能出现「不同意但照样进首页」
import 'dart:io';

import 'package:flutter/material.dart';

import '../screens/privacy_screen.dart';
import '../services/privacy_consent.dart';
import '../theme/app_theme.dart';

class PrivacyGate extends StatefulWidget {
  const PrivacyGate({super.key, required this.child});

  final Widget child;

  @override
  State<PrivacyGate> createState() => _PrivacyGateState();
}

class _PrivacyGateState extends State<PrivacyGate> {
  /// null = 还在读本地状态（首帧不闪弹窗，避免老用户每次启动看到一下白框）
  bool? _agreed;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok = await PrivacyConsent.isAgreed(PrivacyScreen.policyVersion);
    if (!mounted) return;
    setState(() => _agreed = ok);
    if (!ok) _showDialog();
  }

  Future<void> _showDialog() async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    final agreedNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ConsentDialog(),
    );
    _dialogOpen = false;
    if (!mounted) return;
    if (agreedNow == true) {
      await PrivacyConsent.agree(PrivacyScreen.policyVersion);
      if (!mounted) return;
      setState(() => _agreed = true);
    } else {
      // 用户明确选了「不同意」→ 退出。
      // 不能用 SystemNavigator.pop() 之外的温和做法，否则等于默许无同意使用。
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 读状态期间先给个空白底，别让首页先露出来再被弹窗盖住
    if (_agreed == null || _agreed == false) {
      return Scaffold(backgroundColor: AppColors.bg);
    }
    return widget.child;
  }
}

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog();

  @override
  Widget build(BuildContext context) {
    // 拦掉返回键：这一屏必须由用户主动点按钮才能离开
    return WillPopScope(
      onWillPop: () async => false,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('隐私政策', style: AppText.section),
              const SizedBox(height: 14),
              Text(
                '欢迎使用小波菜谱。开始前，请花一分钟了解我们怎么处理你的数据：',
                style: AppText.body,
              ),
              const SizedBox(height: 12),
              _line('不收集任何个人信息。没有账号、没有服务器、不需要注册。'),
              _line('你的菜谱、照片、买菜清单只存在这台手机里，我们看不到。'),
              _line('只申请三个权限：网络（取视频、下载语音模型）、网络状态（判断当前能否联网）、震动（倒计时提醒）。'),
              _line('不申请相机、麦克风、通讯录、定位等任何敏感权限。'),
              _line('没有接入任何第三方统计、广告或推送 SDK。'),
              const SizedBox(height: 14),
              Text(
                '完整条款请点下方「查看完整政策」。',
                style: AppText.caption,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                  ),
                  child: const Text('查看完整政策'),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('同意并继续',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => _confirmExit(context),
                  child: Text('不同意',
                      style: TextStyle(color: AppColors.subInk)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 不同意时的二次确认 —— 不是挽留，是把后果说清楚，避免误触。
  Future<void> _confirmExit(BuildContext context) async {
    // 提前把 NavigatorState 取出来。
    // 这里是 StatelessWidget，拿不到 State.mounted，而 Flutter 3.0 也没有
    // BuildContext.mounted（3.7 才加）—— 所以不能像常规写法那样在 await 之后
    // 再判断 context 还活着。先抓住 NavigatorState 就绕开了这个问题：
    // 它不依赖那个可能已经失效的 element。
    final nav = Navigator.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确定不同意吗？'),
        content: const Text(
            '不同意的话，小波菜谱无法使用，App 会关闭。\n\n'
            '我们不会在你不同意的情况下收集或处理任何数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('我再看看'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('退出', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (sure == true) {
      // false 表示「没同意」，上层会 exit(0)。
      nav.pop(false);
    }
  }

  Widget _line(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 8),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                    color: AppColors.primary, shape: BoxShape.circle),
              ),
            ),
            Expanded(
                child: Text(t,
                    style: TextStyle(
                        fontSize: 14, height: 1.55, color: AppColors.ink))),
          ],
        ),
      );
}

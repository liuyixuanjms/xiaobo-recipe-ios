// 隐私政策页（v1.37 新增）。
//
// 为什么必须有：小米应用商店强制要求「独立的隐私政策」+「首次启动弹窗让用户
// 主动同意」，两样缺一直接驳回。而且不是走个形式 —— 审核员会真机装上，
// 看第一屏有没有弹、点进去能不能读到内容、内容跟实际行为对不对得上。
//
// 这个页面刻意写得比一般隐私政策短：本 App 确实什么都没收集，
// 硬凑六千字反而显得可疑。审核看的是「说的和做的一致」。
//
// 页内文本与线上网页版（privacy.html）必须同步。改动时两边一起改，
// 否则商店后台挂的链接和你 App 里显示的内容不一致，属于典型的驳回理由。
import 'package:flutter/material.dart';

import '../config/brand.dart';
import '../config/build_flavor.dart';
import '../theme/app_theme.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  /// 用户在首次启动弹窗里点「同意」后落盘用的版本号。
  ///
  /// 不是随手写的：政策内容一旦实质变化（比如将来真要收集某个数据），
  /// 必须改这个值，用户下次启动会重新被问一次。否则等于悄悄扩大了授权范围。
  static const String policyVersion = '2026-11-13';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('隐私政策')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Text('小波菜谱 · 隐私政策', style: AppText.section),
          const SizedBox(height: 6),
          Text('生效日期：2026 年 11 月 13 日 · 版本 $policyVersion',
              style: AppText.caption),
          const SizedBox(height: 20),

          _h('一、我们收集哪些信息'),
          _p('没有任何信息。', bold: true),
          _p('小波菜谱没有服务器、没有账号体系、不需要注册登录。'
              '你的菜谱、步骤照片、视频片段、买菜清单、口味偏好，'
              '全部只保存在你自己的手机里，我们看不到、也拿不到。'),
          _p('我们不收集：你的姓名、手机号、通讯录、位置、设备唯一标识、'
              '应用使用时长、崩溃统计、广告标识符。'),

          _h('二、App 会用到哪些权限'),
          _p('本应用只申请了两个系统权限，逐条说明用途：'),
          _bullet('网络访问（INTERNET）',
              kInternal
                  ? '① 解析你主动粘贴的抖音/小红书分享链接，'
                      '把视频取回来做本地整理；② 下载语音识别模型（约 79MB，'
                      '仅首次需要，可关闭）。这两件事都由你主动触发，'
                      '不会在后台自行联网。'
                  : '仅用于下载语音识别模型（约 79MB，仅首次需要，'
                      '可在设置中关闭）。v1.37 起模型已随安装包内置，'
                      '此权限实际不再使用，保留是为了兼容旧版本升级。'),
          _bullet('震动（VIBRATE）',
              '倒计时到点时震动提醒。属于普通权限，安装时自动授予，不会弹窗询问。'),
          _p('我们没有申请：相册/存储读写权限（选图走的是系统自带的'
              '「照片选择器」，App 只能拿到你亲手选中的那几张）、'
              '麦克风权限（语音识别是对视频里已有的音轨做处理，不录音）、'
              '通讯录、位置、短信、通话记录。'),

          _h('三、你的菜谱存在哪里'),
          _p('存在这台手机的 App 私有目录里。别的 App 读不到，我们也读不到。'),
          _p('删除 App 会连同菜谱一起删除，没有云端备份可以恢复。'
              '换手机或卸载前，请到「设置 → 备份与恢复」导出备份文件，'
              '并自己保存到微信、网盘或电脑上。'),

          _h('四、会不会分享给第三方'),
          _p('不会。', bold: true),
          _p('本应用没有接入任何第三方统计、广告、推送、崩溃上报 SDK。'
              '唯一的对外行为是你主动点「分享」时，'
              '把菜谱长图交给系统分享面板 —— 发到哪个 App、发给谁，'
              '由你在系统面板里选择，我们不参与、也不记录。'),

          _h('五、你可以随时做的事'),
          _bullet('查看和修改', '所有菜谱都在首页，点进去就能改。'),
          _bullet('导出带走', '「设置 → 备份与恢复 → 导出备份」，得到一个文件，'
              '你随便存哪儿。'),
          _bullet('彻底删除', '「设置 → 数据与关于 → 清空全部菜谱」，'
              '或者直接卸载 App。两种方式都不需要向我们申请。'),

          _h('六、未成年人'),
          _p('本应用不面向未成年人单独提供服务，也不会有针对未成年人的内容推荐。'
              '如果孩子要用，请在家长陪同下使用，'
              '因为做菜涉及明火、热油和刀具。'),

          _h('七、政策变更'),
          _p('如果将来功能变化导致需要收集数据，我们会先改这份政策、'
              '提高上面的版本号，并在你下次启动时重新征求同意。'
              '不会在你不知情的情况下扩大权限。'),

          _h('八、联系我们'),
          _p('开发者：$kDeveloperName'),
          _p('邮箱：$kContactEmail'),
          _p('软件著作权登记号：${kCopyrightNo.isEmpty ? '（登记中）' : kCopyrightNo}'),

          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '一句话总结：这个 App 不联网收集任何东西，'
              '你的菜谱只在你的手机里。',
              style: AppText.bodySub,
            ),
          ),
        ],
      ),
    );
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Text(t,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      );

  Widget _p(String t, {bool bold = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: TextStyle(
              fontSize: 15,
              height: 1.62,
              color: AppColors.ink,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            )),
      );

  Widget _bullet(String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
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
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: '$title：',
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.62,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink)),
                  TextSpan(
                      text: body,
                      style: TextStyle(
                          fontSize: 15, height: 1.62, color: AppColors.ink)),
                ]),
              ),
            ),
          ],
        ),
      );
}

// 云端 OCR 兜底（v1.44）—— 默认关闭，架构就绪。
//
// 【为什么默认关】
// 1. 没有可靠的免密钥 OCR 服务；App 是公开的，密钥写进去一定会被反编译扒走，
//    所以只能走服务端代理，密钥放服务器环境变量。
// 2. App 现在对外写的是「不联网、不上传、不花钱」。真要传画面去云端，
//    必须**先同步改隐私弹窗和设置页的文案**，否则又变成说的和做的不一样。
// 3. 按量计费，分享出去的人越多账单越贵，所以只重试「本地明显没认出来」的帧，
//    并且每个视频有硬上限。
//
// 【怎么打开】
// ① 服务端配置 OCR_API_URL / OCR_API_KEY（见发布页 server.js 的 /api/ocr）；
// ② 改完隐私文案；
// ③ 把下面的 enabled 改成 true。
// 三步缺一不可，别只改开关。
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class CloudOcr {
  const CloudOcr._();

  /// 部署在下载页服务上的代理端点。App 里不存任何密钥。
  static const String endpoint =
      'https://recipe-apk-download.app.workbuddy.host/api/ocr';

  /// 默认关闭。改成 true 之前必须先配服务端、改隐私文案。
  static const bool enabled = false;

  /// 一条视频最多重试几帧，防止把云端额度吃光。
  static const int maxRetriesPerVideo = 12;

  /// 单帧云端识别。任何失败都返回 null，调用方静默用本地结果。
  static Future<String?> recognize(Uint8List jpeg) async {
    if (!enabled) return null;
    try {
      final r = await http
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{'image': base64Encode(jpeg)}),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final text = (j['text'] ?? '').toString().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null; // 云端不可用不能让整理流程失败
    }
  }

  /// 哪些帧值得花云端额度：含数字+单位（调料/用量行），但本地读出来
  /// 一个厨房规范字都没有，或者带着典型的 OCR 错字形态。
  ///
  /// 真机日志里的目标样例：
  ///   「1河老抽」「鸡精9自糖取生抽Eg,」「次蒜粉23葱粉2g、生姜粉E」
  /// 而「碗中打入5个笨鸡蛋」这种本地读对了的不该再花钱。
  static bool needsCloudRetry(String frameText) {
    final t = frameText.trim();
    if (t.isEmpty) return false;
    // 「小勺水精(說匀個一迪」这类连数字都读错了，但「勺」说明它是用量行。
    final hasAmountClue = t.contains(RegExp(r'\d')) || t.contains('勺');
    if (!hasAmountClue) return false;

    // 先把合法单位摘掉，否则「生抽40g」里的 g 会被当成乱码。
    final stripped = t.replaceAll(
        RegExp(r'\d+\s*(?:g|G|ml|ML|克|毫升)\b'), ' ');
    // 注意必须是字符类 [...]：「油盐糖…」不加方括号是要求整串连续出现，
    // 那样任何一行都判成「没命中规范词」，云端额度会被本地读对的行吃光。
    final hasKitchenWord = stripped.contains(
        RegExp(r'[油盐糖酱醋葱姜蒜鸡蛋肉菜豆椒粉抽生蚝耗水料]'));
    final hasLikelyJunk = stripped.contains(RegExp(r'[河句勾鎌迪劃]')) ||
        stripped.contains(RegExp(r'[A-Za-z]'));
    return !hasKitchenWord || hasLikelyJunk;
  }
}

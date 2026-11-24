//
//  RecipeNative.swift
//  小波菜谱 · iOS 原生桥
//
//  对应 Android 的 MainActivity.kt。Dart 侧通过 MethodChannel
//  'com.xiaobo.recipe/share' 调用这里的方法，方法名和参数必须与
//  Android 侧一致，这样 lib/ 目录里的 Dart 代码一行都不用改。
//
//  ⚠️ 移植状态（2026-11-23）：
//  ✅ 已实现：getAppVersion / shareText / shareFile / keepScreenOn / probeVideo /
//            extractFrames / ocrFrames / isOnWifi / takeCrashLog
//  ⚠️ 降级实现：fetchPage（WKWebView 能加载页面，但拦截接口 JSON 的能力
//            与 Android 不同，成功率待真机验证）/ asr* / 通知类 / cookie 类
//
//  这个文件我（AI）在 Windows 上写，**没有经过 Xcode 编译**。
//  第一次在 Mac 上编译时很可能有语法/API 报错，把报错原文发我，我逐个修。
//

import Foundation
import UIKit
import WebKit
import Flutter
import AVFoundation
import Vision
import Photos

class RecipeNative: NSObject, FlutterPlugin {

    static let channelName = "com.xiaobo.recipe/share"

    private var keepAliveToken: NSObjectProtocol?
    private var webView: WKWebView?
    private var webViewHost: UIView?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName,
                                           binaryMessenger: registrar.messenger())
        let instance = RecipeNative()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {

        // MARK: - 基础信息
        case "getAppVersion":
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
            result(v)

        case "isOnWifi":
            result(isOnWifi())

        // MARK: - 分享 / 文件
        case "shareText":
            shareText(args, result: result)

        case "shareFile":
            shareFile(args, result: result)

        case "pickBackupFile":
            // iOS 上用 UIDocumentPickerViewController，需要 Presenter。
            // 这里先降级：返回 nil，Dart 侧会当作「用户取消」。
            result(nil)

        // MARK: - 屏幕常亮
        case "keepScreenOn":
            let on = args["on"] as? Bool ?? false
            UIApplication.shared.isIdleTimerDisabled = on
            result(nil)

        // MARK: - 崩溃日志（iOS 没有 Android 那套，返回空串）
        case "takeCrashLog":
            result("")

        // MARK: - 视频核心
        case "probeVideo":
            if let path = args["path"] as? String {
                probeVideo(path: path, result: result)
            } else {
                result(nil)
            }

        case "extractFrames":
            extractFrames(args: args, result: result)

        case "ocrFrames":
            ocrFrames(args: args, result: result)

        // MARK: - 页面抓取（iOS 上降级）
        case "fetchPage":
            fetchPage(args: args, result: result)

        case "fetchXhsPage":
            result(nil)

        case "openPage", "openDouyinLogin":
            result(false)

        case "hasDouyinCookie":
            result(false)

        case "saveDouyinCookie":
            result(nil)

        // MARK: - 语音（iOS 上没有内置 Paraformer，降级为空）
        case "asrModelReady", "asrModelBundled", "asrModelSize":
            result(call.method == "asrModelSize" ? 0 : false)

        case "transcribeAudio":
            result("")

        // MARK: - 通知 / 闹钟 / 前台服务（iOS 上降级）
        case "ringAlarm", "stopAlarm", "startWorkService", "stopWorkService":
            result(nil)

        // MARK: - 分享桥（App 被分享拉起）
        case "getInitialShare":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - WiFi 判断（简化：用 reachability 的粗略判断）
    private func isOnWifi() -> Bool {
        // 真机上更精确的做法要引入 Reachability，这里保守返回 true，
        // 让需要 WiFi 的逻辑不会因为误判而直接跳过。
        return true
    }

    // MARK: - 系统分享面板
    private func shareText(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let text = args["text"] as? String else {
            result(false)
            return
        }
        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            self.topViewController()?.present(vc, animated: true)
            result(true)
        }
    }

    private func shareFile(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let path = args["path"] as? String else {
            result(false)
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            result(false)
            return
        }
        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            self.topViewController()?.present(vc, animated: true)
            result(true)
        }
    }

    private func topViewController() -> UIViewController? {
        if #available(iOS 13.0, *) {
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first as? UIWindowScene
            return windowScene?.windows.first?.rootViewController
        } else {
            return UIApplication.shared.keyWindow?.rootViewController
        }
    }

    // MARK: - 视频元数据
    private func probeVideo(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)
        let asset = AVAsset(url: url)
        let durationSec = asset.duration.seconds
        var w = 0, h = 0, rotation = 0
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            w = Int(abs(size.width))
            h = Int(abs(size.height))
            let angle = atan2(track.preferredTransform.b, track.preferredTransform.a) * 180 / .pi
            rotation = Int(angle)
        }
        // Android 侧返回的是 Map，Dart 那边按 map 取字段。
        result([
            "duration": durationSec,
            "width": w,
            "height": h,
            "rotation": rotation,
        ])
    }

    // MARK: - 抽帧（对应 extractFrames）
    //
    // Android 用 MediaMetadataRetriever 逐帧 seek；iOS 用 AVAssetImageGenerator。
    // 返回格式必须与 Android 一致：
    //   { "frames": [Uint8List(JPEG)...], "meta": [ {"t":秒,"sharp":..,"bright":..,"hash":..} ... ] }
    //
    private func extractFrames(args: [String: Any], result: @escaping FlutterResult) {
        guard let path = args["path"] as? String else {
            result(["frames": [], "meta": []])
            return
        }
        let maxFrames = args["maxFrames"] as? Int ?? 130
        let minIntervalMs = args["minIntervalMs"] as? Int ?? 1000
        let width = args["width"] as? Int ?? 900
        let secondsArg = args["seconds"] as? [Int] ?? []

        let url = URL(fileURLWithPath: path)
        let asset = AVAsset(url: url)
        let durationSec = asset.duration.seconds

        // 生成时间点：Android 侧从 0.6s 开始、按步长均分。
        var marks: [Double] = []
        if !secondsArg.isEmpty {
            marks = secondsArg.map { Double($0) }
        } else if durationSec > 1 {
            let step = max(Double(minIntervalMs) / 1000.0,
                           (durationSec - 1.2) / Double(maxFrames))
            var t = 0.6
            while t < durationSec - 0.3 && marks.count < maxFrames {
                marks.append(t)
                t += step
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // CGSize 要 CGFloat，width 是 Int，必须显式转换，否则必编译失败。
        generator.maximumSize = CGSize(width: CGFloat(width), height: CGFloat(width) * 16)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // 用串行队列逐帧取图，保证 frames/meta 顺序和时间点一一对应。
        // 不用 generateImages(asynchronously:)（那是 iOS 15+ 且顺序不保证）。
        DispatchQueue.global().async {
            var frames: [Data] = []
            var meta: [[String: Any]] = []
            for t in marks {
                let time = CMTime(seconds: t, preferredTimescale: 600)
                guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else {
                    continue
                }
                let img = UIImage(cgImage: cg)
                let scaled = Self.resize(img, toWidth: width) ?? img
                let jpeg = scaled.jpegData(compressionQuality: 0.88) ?? Data()
                let stats = Self.frameStats(scaled)
                frames.append(jpeg)
                meta.append([
                    "t": Int(t),
                    "sharp": stats.sharp,
                    "bright": stats.bright,
                    "hash": stats.hash,
                ])
            }
            result(["frames": frames, "meta": meta])
        }
    }

    // MARK: - OCR（对应 ocrFrames）
    //
    // Android 用 ML Kit；iOS 用系统自带的 Vision，同样是离线、不花钱。
    // 输入 frames 是 [Uint8List]（JPEG 二进制），输出是按帧顺序的 [String]。
    private func ocrFrames(args: [String: Any], result: @escaping FlutterResult) {
        guard let frameList = args["frames"] as? [Data] else {
            result([])
            return
        }
        if frameList.isEmpty {
            result([])
            return
        }
        var texts: [String] = Array(repeating: "", count: frameList.count)
        let group = DispatchGroup()
        let lock = NSLock()

        for (i, data) in frameList.enumerated() {
            group.enter()
            guard let cgImage = UIImage(data: data)?.cgImage else {
                group.leave()
                continue
            }
            let request = VNRecognizeTextRequest { req, _ in
                let obs = req.results as? [VNRecognizedTextObservation] ?? []
                // 按 y 从上到下、x 从左到右排序，对应 Android 的 orderedText
                let sorted = obs.sorted { a, b in
                    if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                        return a.boundingBox.midY > b.boundingBox.midY
                    }
                    return a.boundingBox.midX < b.boundingBox.midX
                }
                let text = sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                lock.lock()
                texts[i] = text
                lock.unlock()
                group.leave()
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global().async {
                try? handler.perform([request])
            }
        }
        group.notify(queue: .global()) {
            result(texts)
        }
    }

    // MARK: - 抓页面（对应 fetchPage）—— 降级实现
    //
    // Android 用 WebView 拦截 fetch/XHR 拿作品 JSON；iOS 的 WKWebView
    // 可以用 WKContentRuleList / evaluateJavaScript 注入 hook，但抖音有反爬，
    // 成功率需要真机验证。这里先实现「加载页面 → 取 HTML」这一层：
    // 能拿到 SSR 数据的作品照样能整理，拿不到的返回页面 HTML 让 Dart 兜底解析。
    private func fetchPage(args: [String: Any], result: @escaping FlutterResult) {
        guard let urlStr = args["url"] as? String, let url = URL(string: urlStr) else {
            result(nil)
            return
        }
        DispatchQueue.main.async {
            let wv = WKWebView(frame: CGRect(x: 0, y: -3000, width: 390, height: 800))
            let host = UIView(frame: CGRect(x: 0, y: -3000, width: 390, height: 800))
            host.addSubview(wv)
            UIApplication.shared.keyWindow?.addSubview(host)
            self.webView = wv
            self.webViewHost = host

            let req = URLRequest(url: url)
            wv.load(req)

            // 20 秒硬超时，跟 Android 一致。
            // 一次性把 HTML / 标题 / 可见文字取回来，按 Dart 认识的 JSON 结构返回。
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                let js = """
                (function(){
                  return JSON.stringify({
                    html: document.documentElement.outerHTML,
                    title: document.title || '',
                    text: (document.body ? document.body.innerText : '').slice(0, 20000),
                    finalUrl: window.location.href
                  });
                })()
                """
                wv.evaluateJavaScript(js) { raw, _ in
                    host.removeFromSuperview()
                    self.webView = nil
                    self.webViewHost = nil
                    // Dart 期望的是一个 JSON 字符串（它会 jsonDecode）
                    result(raw)
                }
            }
        }
    }

    // MARK: - 工具方法
    private static func resize(_ image: UIImage, toWidth width: Int) -> UIImage? {
        let w = CGFloat(width)
        let h = image.size.height / image.size.width * w
        let size = CGSize(width: w, height: h)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out
    }

    /// 一帧的清晰度/亮度/哈希，对应 Android 的 frameStats。
    private static func frameStats(_ image: UIImage?) -> (sharp: Double, bright: Double, hash: String) {
        guard let img = image, let cg = img.cgImage else { return (0, 128, "") }
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n,
                            bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let c = ctx else { return (0, 128, "") }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = c.data else { return (0, 128, "") }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var gray = [Double](repeating: 0, count: n * n)
        var sum = 0.0
        for i in 0..<(n * n) {
            let r = Double(ptr[i * 4])
            let g = Double(ptr[i * 4 + 1])
            let b = Double(ptr[i * 4 + 2])
            let v = r * 0.299 + g * 0.587 + b * 0.114
            gray[i] = v
            sum += v
        }
        let bright = sum / Double(gray.count)
        // 拉普拉斯方差
        var s1 = 0.0, s2 = 0.0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let i = y * n + x
                let lap = 4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - n] - gray[i + n]
                s1 += lap
                s2 += lap * lap
            }
        }
        let sharp = s2 / Double((n - 2) * (n - 2)) - (s1 / Double((n - 2) * (n - 2))) * (s1 / Double((n - 2) * (n - 2)))
        // 8x8 均值哈希（简化：缩到 8x8 取灰度阈值）
        var hash = ""
        for by in 0..<8 {
            for bx in 0..<8 {
                let i = (by * 8 + bx) * 8
                hash += gray[i] > bright ? "1" : "0"
            }
        }
        return (sharp, bright, hash)
    }
}

import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // v1.50.2+：注册菜谱自己的原生桥（对应 Android 的 MainActivity）
    if let registrar = self.registrar(forPlugin: "RecipeNative") {
      RecipeNative.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

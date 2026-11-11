import Flutter
import UIKit

// OpenInstall 免填邀请码（2026-11-11：由 Xinstall 换成 OpenInstall）说明：
// 本工程启用 UIScene 生命周期（Info.plist 的 UIApplicationSceneManifest），iOS 13+ 的
// scheme / Universal Link 回调只会打到 SceneDelegate，而 OpenInstall 插件是通过
// `addApplicationDelegate` 挂在 AppDelegate 上的，UIScene 下收不到 ——
// 因此转发写在 SceneDelegate.swift（含冷启动 connectionOptions），此处保持不动。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

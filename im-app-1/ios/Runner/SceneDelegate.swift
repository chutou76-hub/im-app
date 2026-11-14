import Flutter
import UIKit
// 免填邀请码（2026-11-14：Opo → **Xinstall**，xinstall_flutter_plugin 官方插件）：
// 插件 iOS 侧（XinstallFlutterPlugin.h）暴露两个 Objective-C 类方法供这里转发：
//   +[XinstallFlutterPlugin continueUserActivity:]  → Universal Link 唤起
//   +[XinstallFlutterPlugin handleSchemeURL:]       → 自定义 scheme 唤起
// pod 名即 module 名（插件自带 podspec），Podfile 已 use_frameworks!，可直接 import。
// （2026-11-11~11-12 期间曾用本地插件 plugins/opo_install，已随 Opo 一并移除。）
import xinstall_flutter_plugin

/// UIScene 生命周期下的 URL / Universal Link 入口。
///
/// Xinstall 免填邀请码（2026-11-14）关键说明：
/// 1. 本工程 Info.plist 已启用 UIApplicationSceneManifest（UIScene 生命周期），iOS 13+ 只会把
///    「scheme 拉起」投递到 scene(_:openURLContexts:)、把「Universal Link 拉起」投递到
///    scene(_:continue:)（冷启动则在 scene(_:willConnectTo:options:) 的 connectionOptions 里）。
///    插件是通过 `[registrar addApplicationDelegate:instance]` 挂在 **AppDelegate** 上的
///    （XinstallFlutterPlugin 的 application:openURL:options: / continueUserActivity:），
///    在 UIScene 下这些 AppDelegate 方法不会被系统调用 —— 所以必须在本文件转发，
///    否则表现是「App 能打开，但拿不到邀请码」。
///
/// 2. （2026-11-12 确立、本版沿用）标准 override 写法：
///    - override 让 Swift 自动把方法挂到 UIKit 回调的**正确 ObjC 选择器**上
///      （scene(_:willConnectTo:options:) 映射 scene:willConnectToSession:options:）；
///    - 处理完 Xinstall 后调 super，由 FlutterSceneDelegate 原生实现完成引擎-scene 关联
///      与插件 scene 生命周期转发（fluwx 微信 / tobias 支付宝等插件的 scene 回调不受影响）。
class SceneDelegate: FlutterSceneDelegate {

  // MARK: - 冷启动（App 未运行，被 scheme / Universal Link 拉起）

  // 2026-11-14：Opo → Xinstall，转发方法换成 XinstallFlutterPlugin 类方法。
  override func scene(_ scene: UIScene,
                      willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    // Xinstall：冷启动时 Universal Link 在 userActivities 里。
    for userActivity in connectionOptions.userActivities where userActivity.webpageURL != nil {
      _ = XinstallFlutterPlugin.continueUserActivity(userActivity)
    }
    // Xinstall：冷启动时自定义 scheme 在 urlContexts 里。
    for urlContext in connectionOptions.urlContexts {
      _ = XinstallFlutterPlugin.handleSchemeURL(urlContext.url)
    }
    // 保留 Flutter 原有 scene 连接处理（引擎与 scene 关联、插件 scene 生命周期回调）。
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // MARK: - 运行中 / 后台被拉起：自定义 scheme

  // 2026-11-14：Opo → Xinstall，转发方法换成 XinstallFlutterPlugin 类方法。
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for urlContext in URLContexts {
      // Xinstall：交给插件解析 scheme 携带的动态参数。
      _ = XinstallFlutterPlugin.handleSchemeURL(urlContext.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  // MARK: - 运行中 / 后台被拉起：Universal Link

  // 2026-11-14：Opo → Xinstall，转发方法换成 XinstallFlutterPlugin 类方法。
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    // Xinstall：Universal Link 唤起，交给插件解析动态参数。
    _ = XinstallFlutterPlugin.continueUserActivity(userActivity)
    super.scene(scene, continue: userActivity)  // 2026-11-12：同名 SDK 改名，转发给插件层
  }
}

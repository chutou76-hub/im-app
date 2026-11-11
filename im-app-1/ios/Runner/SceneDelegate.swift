import Flutter
import UIKit
// 免填邀请码（2026-11-11：Xinstall → openinstall 老版 → **Opo**）：
// 本项目的本地插件 plugins/opo_install 把 Opo 原生 SDK 包了一层，
// iOS 侧暴露两个 Objective-C 类方法供这里转发：
//   +[OpoInstallPlugin continueUserActivity:]  → Opo: +[OpoInstallSDK continueUserActivity:]
//   +[OpoInstallPlugin handLinkURL:]           → Opo: +[OpoInstallSDK handLinkURL:]
// pod 名即 module 名（plugins/opo_install/ios/opo_install.podspec），
// Podfile 已 use_frameworks!，故可直接 import。
import opo_install

/// UIScene 生命周期下的 URL / Universal Link 入口。
///
/// OpenInstall 免填邀请码（2026-11-11）关键说明：
/// 1. 本工程 Info.plist 已启用 UIApplicationSceneManifest（UIScene 生命周期），iOS 13+ 只会把
///    「scheme 拉起」投递到 scene(_:openURLContexts:)、把「Universal Link 拉起」投递到
///    scene(_:continue:)（冷启动则在 scene(_:willConnectTo:options:) 的 connectionOptions 里）。
///    插件是通过 `[registrar addApplicationDelegate:instance]` 挂在 **AppDelegate** 上的
///    （见 OpoInstallPlugin.m 里的 application:openURL:options: / continueUserActivity:），
///    在 UIScene 下这些 AppDelegate 方法不会被系统调用 —— 所以必须在本文件手动转发，
///    否则表现是「App 能打开，但拿不到邀请码」。
/// 2. Flutter 3.44 的 FlutterSceneDelegate 只在头文件声明了 window 属性，scene 回调都实现在
///    .mm 里、Swift 侧不可见，所以这里不能写 override / super，改用 @objc 声明同选择器方法，
///    UIKit 按选择器回调即可生效。
/// 3. 为了不吞掉其它插件（fluwx 微信、tobias 支付宝等）的 scene 回调，处理完 OpenInstall 后
///    手动把事件转发给 FlutterSceneLifeCycleProvider.sceneLifeCycleDelegate，等价于原
///    FlutterSceneDelegate 的默认转发行为。
class SceneDelegate: FlutterSceneDelegate {

  // MARK: - 冷启动（App 未运行，被 scheme / Universal Link 拉起）

  @objc func scene(_ scene: UIScene,
                   willConnectTo session: UISceneSession,
                   options connectionOptions: UIScene.ConnectionOptions) {
    // OpenInstall（2026-11-11）：冷启动时 Universal Link 在 userActivities 里。
    for userActivity in connectionOptions.userActivities where userActivity.webpageURL != nil {
      _ = OpoInstallPlugin.continueUserActivity(userActivity)
    }
    // OpenInstall（2026-11-11）：冷启动时自定义 scheme 在 urlContexts 里。
    for urlContext in connectionOptions.urlContexts {
      _ = OpoInstallPlugin.handLinkURL(urlContext.url)
    }
    // 保留 Flutter 原有 scene 连接处理（引擎与 scene 关联、插件 scene 生命周期回调）。
    (self as? FlutterSceneLifeCycleProvider)?
      .sceneLifeCycleDelegate
      .scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // MARK: - 运行中 / 后台被拉起：自定义 scheme

  // 用 NSSet 而非 Set<UIOpenURLContext>：Flutter 头文件里该参数是未泛型的 NSSet，
  // 用 NSSet 声明可规避 Swift 泛型桥接差异，选择器仍是 scene:openURLContexts:。
  @objc func scene(_ scene: UIScene, openURLContexts URLContexts: NSSet) {
    for case let urlContext as UIOpenURLContext in URLContexts {
      // OpenInstall（2026-11-11）：交给插件解析 scheme 携带的动态参数。
      _ = OpoInstallPlugin.handLinkURL(urlContext.url)
    }
    // 转发给 Flutter 插件层（选择器 scene:openURLContexts:，按 id 传 NSSet）。
    let selector = NSSelectorFromString("scene:openURLContexts:")
    if let lifeCycleDelegate = (self as? FlutterSceneLifeCycleProvider)?.sceneLifeCycleDelegate,
       lifeCycleDelegate.responds(to: selector) {
      _ = lifeCycleDelegate.perform(selector, with: scene, with: URLContexts)
    }
  }

  // MARK: - 运行中 / 后台被拉起：Universal Link

  @objc func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    // OpenInstall（2026-11-11）：Universal Link 唤起，交给插件解析动态参数。
    _ = OpoInstallPlugin.continueUserActivity(userActivity)
    (self as? FlutterSceneLifeCycleProvider)?
      .sceneLifeCycleDelegate
      .scene(scene, continueUserActivity: userActivity)
  }
}

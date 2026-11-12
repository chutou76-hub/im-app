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
///    在 UIScene 下这些 AppDelegate 方法不会被系统调用 —— 所以必须在本文件转发，
///    否则表现是「App 能打开，但拿不到邀请码」。
///
/// 2. （2026-11-12 重写）旧版用 @objc 声明「同选择器方法」的方式在新 SDK（iOS 26 /
///    Swift 6 模式）下编译失败：UIKit 已把 scene 回调做了 Swift 改名（continueUserActivity
///    → continue），且 FlutterSceneDelegate 的 scene 实现对 Swift 可见，子类不写 override
///    直接报「Overriding declaration requires 'override' keyword / selector conflict」。
///    本版改为标准 override 写法：
///    - override 让 Swift 自动把方法挂到 UIKit 回调的**正确 ObjC 选择器**上
///      （旧版 scene(_:willConnectTo:options:) 生成的是 scene:willConnectTo:options:，
///      系统回调的是 scene:willConnectToSession:options:，旧版方法实际从未被调用）；
///    - 处理完 Opo 后调 super，由 FlutterSceneDelegate 原生实现完成引擎-scene 关联与
///      插件 scene 生命周期转发（等价且优于旧版手动 FlutterSceneLifeCycleProvider 转发，
///      fluwx 微信 / tobias 支付宝等插件的 scene 回调也不会被吞）；
///    - OpoInstallPlugin.continueUserActivity 在新 SDK 导入后改名为 continue(_:)，
///      按编译器提示调用新名。
class SceneDelegate: FlutterSceneDelegate {

  // MARK: - 冷启动（App 未运行，被 scheme / Universal Link 拉起）

  // 2026-11-12 修复：标准 override（自动映射到 scene:willConnectToSession:options:），
  // 处理完 Opo 后 super 转发给 Flutter 引擎与插件层。
  override func scene(_ scene: UIScene,
                      willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    // OpenInstall（2026-11-11）：冷启动时 Universal Link 在 userActivities 里。
    for userActivity in connectionOptions.userActivities where userActivity.webpageURL != nil {
      _ = OpoInstallPlugin.continue(userActivity) // 2026-11-12：SDK 改名 continueUserActivity → continue(_:)
    }
    // OpenInstall（2026-11-11）：冷启动时自定义 scheme 在 urlContexts 里。
    for urlContext in connectionOptions.urlContexts {
      _ = OpoInstallPlugin.handLinkURL(urlContext.url)
    }
    // 保留 Flutter 原有 scene 连接处理（引擎与 scene 关联、插件 scene 生命周期回调）。
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // MARK: - 运行中 / 后台被拉起：自定义 scheme

  // 2026-11-12 修复：参数类型改回 SDK 标准的 Set<UIOpenURLContext>（旧版为绕泛型桥接
  // 用的 NSSet 与父类方法选择器冲突）；override + super 转发给插件层。
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for urlContext in URLContexts {
      // OpenInstall（2026-11-11）：交给插件解析 scheme 携带的动态参数。
      _ = OpoInstallPlugin.handLinkURL(urlContext.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  // MARK: - 运行中 / 后台被拉起：Universal Link

  // 2026-11-12 修复：标准 override（自动映射到 scene:continueUserActivity:）。
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    // OpenInstall（2026-11-11）：Universal Link 唤起，交给插件解析动态参数。
    _ = OpoInstallPlugin.continue(userActivity) // 2026-11-12：SDK 改名 continueUserActivity → continue(_:)
    super.scene(scene, continue: userActivity)  // 2026-11-12：同名 SDK 改名，转发给插件层
  }
}

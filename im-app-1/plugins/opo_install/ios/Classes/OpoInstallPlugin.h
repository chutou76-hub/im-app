//
//  OpoInstallPlugin.h
//  Opo（opoinstall.com）iOS 端桥接（本项目内部本地插件，2026-11-11 新建）
//
//  官方没有 Flutter 插件，这里按原生 SDK 的 Objective-C 接口包一层。
//
//  为什么要暴露两个类方法给 SceneDelegate：
//  本工程启用 UIScene 生命周期（Info.plist 的 UIApplicationSceneManifest），
//  iOS 13+ 的 scheme / Universal Link 回调只会投递给 SceneDelegate，
//  用 addApplicationDelegate 挂在 AppDelegate 上收不到 —— 必须由
//  SceneDelegate.swift 手动转发到这两个方法，否则「App 能打开但拿不到邀请码」。
//

#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpoInstallPlugin : NSObject <FlutterPlugin>

/// 处理自定义 scheme 拉起（对应 Opo: +[OpoInstallSDK handLinkURL:]）
+ (BOOL)handLinkURL:(NSURL *)url;

/// 处理 Universal Link 拉起（对应 Opo: +[OpoInstallSDK continueUserActivity:]）
+ (BOOL)continueUserActivity:(NSUserActivity *)userActivity;

@end

NS_ASSUME_NONNULL_END

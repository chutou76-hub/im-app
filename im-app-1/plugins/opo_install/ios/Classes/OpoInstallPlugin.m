//
//  OpoInstallPlugin.m
//  Opo（opoinstall.com）iOS 端桥接（本项目内部本地插件，2026-11-11 新建）
//
//  与 Android 侧（OpoInstallPlugin.java）保持**完全相同**的通道名与数据结构，
//  Dart 侧只面对一套 map：ok / bindData / channelCode / opid / errorCode /
//  errorMsg / shouldRetry。
//
//  注意：iOS 原生的 OpoInstallData.data 是 NSDictionary，而 Android 返回的是
//  JSON 字符串。这里统一序列化成 JSON 字符串（Dart 的 _pick 已按 JSON 解析），
//  两端行为才一致。
//

#import "OpoInstallPlugin.h"

#if __has_include(<OpoInstallSDK/OpoInstallSDK.h>)
#import <OpoInstallSDK/OpoInstallSDK.h>
#else
#import "OpoInstallSDK.h"
#endif

static NSString *const kMethodChannel = @"im_app/opoinstall";
static NSString *const kEventChannel = @"im_app/opoinstall/wakeup";

@interface OpoInstallPlugin () <FlutterStreamHandler, OpoInstallDelegate>
@property(nonatomic, strong, nullable) FlutterEventSink sink;
/// 冷启动的拉起参数可能早于 Dart 订阅到达，先缓存，订阅时补发
@property(nonatomic, strong, nullable) NSDictionary *pendingWakeup;
@end

@implementation OpoInstallPlugin

/// SDK 只初始化一次（initWithDelegate: 重复调用会重置内部状态）
static BOOL sdkInited = NO;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  OpoInstallPlugin *instance = [[OpoInstallPlugin alloc] init];

  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:kMethodChannel
                                  binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:channel];

  FlutterEventChannel *events =
      [FlutterEventChannel eventChannelWithName:kEventChannel
                                binaryMessenger:[registrar messenger]];
  [events setStreamHandler:instance];

  // 兜底：万一工程改回非 UIScene 生命周期，AppDelegate 回调也能收到
  [registrar addApplicationDelegate:instance];

  // 尽早初始化（h5 归因只需要 delegate，不需要 IDFA）
  if (!sdkInited) {
    sdkInited = YES;
    [OpoInstallSDK initWithDelegate:instance];
  }
}

#pragma mark - 给 SceneDelegate 的静态转发入口

+ (BOOL)handLinkURL:(NSURL *)url {
  if (url == nil) return NO;
  return [OpoInstallSDK handLinkURL:url];
}

+ (BOOL)continueUserActivity:(NSUserActivity *)userActivity {
  if (userActivity == nil) return NO;
  return [OpoInstallSDK continueUserActivity:userActivity];
}

#pragma mark - AppDelegate 兜底（非 UIScene 工程才会被调用）

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
  return [OpoInstallPlugin handLinkURL:url];
}

- (BOOL)application:(UIApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *_Nullable))restorationHandler {
  return [OpoInstallPlugin continueUserActivity:userActivity];
}

#pragma mark - FlutterPlugin

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;

  if ([@"initialize" isEqualToString:call.method]) {
    BOOL debug = [args[@"debug"] boolValue];
    [OpoInstallSDK setDebug:debug];
    if (!sdkInited) {
      sdkInited = YES;
      [OpoInstallSDK initWithDelegate:self];
    }
    result([OpoInstallSDK sdkVersion] ?: @"");

  } else if ([@"getVersion" isEqualToString:call.method]) {
    result([OpoInstallSDK sdkVersion] ?: @"");

  } else if ([@"getOpId" isEqualToString:call.method]) {
    NSString *opid = [[OpoInstallSDK defaultManager] getOpId];
    result(opid ?: @"");

  } else if ([@"start" isEqualToString:call.method] ||
             [@"handleDeepLink" isEqualToString:call.method]) {
    // iOS 没有 Activity/Intent 概念，采集在首次 getInstallParms 时触发；
    // 拉起由 SceneDelegate 转发，这里无需动作（保持与 Dart 接口一致）
    result(nil);

  } else if ([@"register" isEqualToString:call.method]) {
    [OpoInstallSDK reportRegister];
    result(nil);

  } else if ([@"getInstallParam" isEqualToString:call.method]) {
    NSTimeInterval timeout = 10;
    id t = args[@"timeout"];
    if ([t isKindOfClass:[NSNumber class]]) timeout = [t doubleValue];

    __block BOOL replied = NO;
    [[OpoInstallSDK defaultManager]
        getInstallParmsWithTimeoutInterval:timeout
                                 completed:^(OpoInstallData *_Nullable data) {
                                   if (replied) return;
                                   replied = YES;
                                   NSDictionary *m = [OpoInstallPlugin mapFromData:data];
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     result(m);
                                   });
                                 }];

  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - OpoInstallDelegate（拉起参数）

- (void)getWakeUpParams:(OpoInstallData *)appData {
  NSDictionary *m = [OpoInstallPlugin mapFromData:appData];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.sink) {
      self.sink(m);
    } else {
      self.pendingWakeup = m;
    }
  });
}

#pragma mark - FlutterStreamHandler

- (FlutterError *_Nullable)onListenWithArguments:(id)arguments
                                       eventSink:(FlutterEventSink)events {
  self.sink = events;
  if (self.pendingWakeup) {
    events(self.pendingWakeup);
    self.pendingWakeup = nil;
  }
  return nil;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id)arguments {
  self.sink = nil;
  return nil;
}

#pragma mark - 数据结构统一

+ (NSDictionary *)mapFromData:(OpoInstallData *_Nullable)data {
  NSMutableDictionary *m = [NSMutableDictionary dictionary];
  NSString *bindJSON = @"";
  NSString *channel = @"";
  BOOL ok = (data != nil);
  NSString *errMsg = @"";

  if (data != nil) {
    channel = data.channelCode ?: @"";
    if ([data.data isKindOfClass:[NSDictionary class]] && data.data.count > 0) {
      bindJSON = [OpoInstallPlugin jsonStringFromDictionary:data.data];
    }
    // opCode == OPOCode_timeout(1) 表示没等到结果，属于「可重试」而非硬失败
    if (data.opCode == OPOCode_timeout) {
      ok = NO;
      errMsg = @"getInstallParms 超时（未匹配到安装来源）";
    }
  } else {
    ok = NO;
    errMsg = @"getInstallParms 回调为空对象";
  }

  m[@"ok"] = @(ok);
  m[@"bindData"] = bindJSON;
  m[@"channelCode"] = channel;
  NSString *opid = [[OpoInstallSDK defaultManager] getOpId];
  m[@"opid"] = opid ?: @"";
  m[@"errorCode"] = ok ? @0 : @(-1);
  m[@"errorMsg"] = errMsg;
  m[@"shouldRetry"] = @(data != nil && data.opCode == OPOCode_timeout);
  return m;
}

+ (NSString *)jsonStringFromDictionary:(NSDictionary *)dict {
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
  if (data == nil || err != nil) return @"";
  NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return s ?: @"";
}

@end

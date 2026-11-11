#
# Opo（opoinstall.com）iOS 端桥接（本项目内部本地插件，2026-11-11 新建）。
#
# 官方只发 OpoInstallSDK（静态库 xcframework），没有 Flutter 插件，所以这里
# 用 CocoaPods 的 vendored_frameworks 把二进制随插件一起带走。
#
# 为什么 static_framework = true：
#   xcframework 里是 libOpoInstallSDK.a（静态库），若让 CocoaPods 再包一层
#   动态 framework，链接时常出现符号未被载入（-undefined symbol），
#   声明为静态 framework 可直接并进主二进制，行为与官方原生集成一致。
#
Pod::Spec.new do |s|
  s.name             = 'opo_install'
  s.version          = '1.0.0'
  s.summary          = 'Opo (opoinstall) install params / deeplink bridge for Flutter'
  s.description      = <<-DESC
Opo 官方没有 Flutter 插件，本插件按原生 SDK 包一层 MethodChannel：
  initialize / getInstallParam / register / getOpId / handLinkURL / continueUserActivity
  DESC
  s.homepage         = 'https://www.opoinstall.com'
  s.license          = { :type => 'MIT', :text => 'Copyright (c) 2026 im-app' }
  s.author           = { 'im-app' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.static_framework = true
  s.requires_arc     = true
  s.vendored_frameworks = 'OpoInstallSDK.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # 静态库里有 category / class 注册，缺 -ObjC 会导致运行时找不到类
    'OTHER_LDFLAGS' => '-ObjC',
  }
end

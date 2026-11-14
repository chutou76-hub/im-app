# mobile_scanner / ML Kit 条码识别：R8 full mode 会裁掉 ML Kit 通过反射
# 注册的组件，导致 release 包扫码崩溃（混淆名 NPE，如 r5.c r5.b.a(n5.b)）。
# 上游 issue: juliansteenbakker/mobile_scanner#1722 #1725
# 注意：必须用双星 ** （插件自带的单星 keep 规则是已知 bug，覆盖不到子包）
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }

# ===== 极光推送 JPush（jpush_flutter 3.5.6 不自带 proguard 规则）=====
# R8 会裁剪/混淆 cn.jpush / cn.jiguang 的类，导致 release 包
# 初始化或 setAlias 时 JVM 层崩溃（NoClassDefFoundError / NoSuchMethodError），
# Dart 的 try/catch 无法捕获。以下为极光官方 keep 规则。
-dontwarn cn.jpush.**
-keep class cn.jpush.** { *; }
-keep class * extends cn.jpush.android.service.JPushMessageReceiver { *; }
-dontwarn cn.jiguang.**
-keep class cn.jiguang.** { *; }

# ===== 个推 gtsdk 3.3.7.0（getuiflut 插件要求的 app 侧依赖）=====
# 与极光同理：R8 裁剪/混淆 com.igexin（gtsdk 核心包名）会导致反射初始化失败。
# Android 侧当前不启用个推（不调 startSdk），规则仅保底防构建/裁剪问题。
-dontwarn com.igexin.**
-keep class com.igexin.** { *; }
-dontwarn com.getui.**
-keep class com.getui.** { *; }

# ===== Xinstall 免填邀请码 SDK（xinstall_flutter_plugin 内置，2026-11-14 起）=====
# 2026-11-11（Opo 时代）起要求加 keep；2026-11-14 换 Xinstall 后同样需要
# （SDK 内部大量反射/JSON 反序列化，被裁剪的表现是激活失败但**不报错**）。
# 不开 minify 时这里是空转，一旦以后开启 minifyEnabled 就靠它兜住。
-keep class com.xinstall.** { *; }

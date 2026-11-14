plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.siqu.chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 要求开启 core library desugaring（java.time 等 API 在低版本上的脱糖）
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.siqu.chat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 极光推送 SDK 必需占位符（jpush_flutter 插件 manifest 合并时读取）：
        // TODO: 替换成极光控制台（包名必须与本 applicationId 一致）创建应用的 AppKey
        // 注意：AGP 9 的 Kotlin DSL 里 applicationId 是 String?，必须 toString() 转 Any
        manifestPlaceholders["JPUSH_PKGNAME"] = applicationId.toString()
        manifestPlaceholders["JPUSH_APPKEY"] = "b1ba48f444fae6c40da73549"
        manifestPlaceholders["JPUSH_CHANNEL"] = "default"
        // getuiflut 插件 manifest 合并必需占位符（Android 侧当前不启用个推，留空即可；
        // 仅 iOS 运行时由服务端下发 appId 启动 SDK）
        manifestPlaceholders["GETUI_APPID"] = ""
        // Xinstall 免填邀请码（2026-11-14：Opo → Xinstall，官方 Flutter 插件）：
        // AndroidManifest 里的 <meta-data com.xinstall.APP_KEY> 与拉起 intent-filter
        // 的 android:scheme（xi${XINSTALL_APPKEY}）都读这个占位符，真正取值来自
        // android/gradle.properties 的 XINSTALL_APPKEY。
        // 用 providers.gradleProperty 而不是硬编码，CI / 本地可用 -PXINSTALL_APPKEY=xxx 覆盖。
        // 留空 = 未配置：SDK 不会初始化成功，但**不阻塞构建**（功能开关默认关）。
        manifestPlaceholders["XINSTALL_APPKEY"] =
            providers.gradleProperty("XINSTALL_APPKEY").getOrElse("")
        // 瘦身说明：不要在这里写 ndk.abiFilters —— Flutter Gradle 插件会设置 splits abi，
        // 两者并存会报 "Conflicting configuration"。用打包命令控制架构：
        //   flutter build apk --release --split-per-abi  （arm64 单包约 45M，上架推荐）
        //   flutter build apk --release --target-platform android-arm64,android-arm （通用包瘦身）
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // 挂载自定义 R8 keep 规则（mobile_scanner/ML Kit 条码识别崩溃修复）
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 配合 isCoreLibraryDesugaringEnabled（flutter_local_notifications 必需）
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // getuiflut 0.2.41 把个推 gtsdk 声明为 compileOnly（编译插件自身可见、不进最终包），
    // 官方预期由 App 侧补 implementation；不补的话 R8 报缺类
    //（com.igexin.sdk.PushManager/GTIntentService/...，assembleRelease 失败）。
    // 版本必须与插件 android/build.gradle 里的 compileOnly 完全一致。
    // Android 侧仍走极光推送（运行时不调 getuiflut.startSdk，gtsdk 不会初始化）。
    implementation("com.getui:gtsdk:3.3.7.0")
}

flutter {
    source = "../.."
}

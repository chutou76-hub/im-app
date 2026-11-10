pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 版本取 Flutter 官方给出的「最低建议值」，三个都仍在 8.x / 2.2.x 系列内，
    // 既满足依赖要求又避开 AGP 9：
    //   - AGP 必须 >= 8.9.1：androidx.core 1.18.0 / activity 1.13.0 / browser 1.9.0 /
    //     navigationevent 1.0.0 的 AAR metadata 强要求，低于它会在
    //     :app:checkReleaseAarMetadata 直接失败（此前用 8.7.3 就栽在这里）。
    //   - 必须 < 9：AGP 9 的「内置 Kotlin」过渡期里，file_picker（AGP9 就不自己挂 Kotlin）
    //     与 audioplayers_android（无条件自己挂 Kotlin）对 android.builtInKotlin 的要求
    //     正好相反，该 flag 无论 true/false 都会有一个插件编译失败。
    //     8.x 没有内置 Kotlin 概念，Kotlin 一律由插件自己 apply，两边回到同一条路。
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

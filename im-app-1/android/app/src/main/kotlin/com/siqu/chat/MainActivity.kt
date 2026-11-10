package com.siqu.chat
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 禁用 Flutter 自动 deep link 处理：
    // Flutter 3.29+ 默认开启 flutter_deeplinking_enabled，App 进程被杀后点击
    // 厂商通道（华为/小米等）离线推送拉起 App 时，intent.data 会被误当成
    // Flutter 路由解析，路由表无对应页面导致打开后白屏。
    override fun shouldHandleDeeplinking(): Boolean {
        return false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "im_app/rom")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRomInfo" -> result.success(
                        mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "brand" to Build.BRAND,
                            "model" to Build.MODEL
                        )
                    )
                    // 跳厂商自启动/后台设置页：返回 true=跳到了厂商页，false=退回应用详情页
                    "openAutoStartSettings" -> result.success(openAutoStartSettings())
                    // 电池优化白名单：返回 1=直接授权弹窗 2=电池优化列表页 3=应用详情页
                    "openBatterySettings" -> result.success(openBatterySettings())
                    "openAppDetails" -> {
                        openAppDetails()
                        result.success(true)
                    }
                    // 桌面图标角标（未读红点数字）：各厂商逐一尝试、静默失败
                    "setBadge" -> {
                        val count = (call.arguments as? Number)?.toInt() ?: 0
                        BadgeManager.setBadge(applicationContext, count)
                        result.success(true)
                    }
                    // 静音循环保活：后台循环 -60dB 极低音量音频，让厂商省电策略
                    // 把本应用当「正在播放媒体」而豁免后台冻结（防 WS 心跳被冻结）
                    "startSilentAudio" -> {
                        SilentAudioPlayer.start(applicationContext)
                        result.success(true)
                    }
                    "stopSilentAudio" -> {
                        SilentAudioPlayer.stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 各厂商 ROM 的自启动/后台管理页组件（逐个尝试，命中即跳） */
    private fun autoStartCandidates(manufacturer: String): List<Pair<String, String>> = when {
        listOf("xiaomi", "redmi", "poco").any { manufacturer.contains(it) } -> listOf(
            "com.miui.securitycenter" to
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
        )
        manufacturer.contains("honor") -> listOf(
            "com.hihonor.systemmanager" to
                "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.hihonor.systemmanager" to
                "com.hihonor.systemmanager.appcontrol.activity.StartupAppControlActivity"
        )
        manufacturer.contains("huawei") -> listOf(
            "com.huawei.systemmanager" to
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to
                "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"
        )
        listOf("oppo", "realme", "oneplus").any { manufacturer.contains(it) } -> listOf(
            "com.coloros.safecenter" to
                "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to
                "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to
                "com.oppo.safe.permission.startup.StartupAppListActivity"
        )
        listOf("vivo", "iqoo").any { manufacturer.contains(it) } -> listOf(
            "com.vivo.permissionmanager" to
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to
                "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
            "com.iqoo.secure" to
                "com.iqoo.secure.safeguard.PurviewTabActivity"
        )
        manufacturer.contains("samsung") -> listOf(
            "com.samsung.android.lool" to
                "com.samsung.android.sm.battery.ui.BatteryActivity"
        )
        else -> emptyList()
    }

    private fun openAutoStartSettings(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        for ((pkg, cls) in autoStartCandidates(manufacturer)) {
            try {
                val intent = Intent().setComponent(ComponentName(pkg, cls))
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // 组件不存在/被禁：试下一个
            }
        }
        openAppDetails()
        return false
    }

    private fun openAppDetails() {
        try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null)
                )
            )
        } catch (_: Exception) {
        }
    }

    /**
     * 打开电池优化白名单设置，三级 fallback：
     *   1. ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS：直接弹"允许忽略电池优化？"授权框
     *      （需要 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限；部分 ROM 如 MIUI 可能禁用）
     *   2. ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS：系统"电池优化"列表页，
     *      用户需切「所有应用」→ 找到本应用 → 选「不允许」
     *   3. 应用详情页兜底
     * 返回实际打开的层级：1=授权弹窗 2=列表页 3=应用详情
     */
    private fun openBatterySettings(): Int {
        // 层级 1：直接授权弹窗（需要 manifest 权限，缺权限会 SecurityException）
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
            return 1
        } catch (_: Exception) {
        }
        // 层级 2：电池优化列表页（全部应用列表，手动选"不允许"）
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            return 2
        } catch (_: Exception) {
        }
        // 层级 3：应用详情页
        openAppDetails()
        return 3
    }
}

package com.siqu.chat
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri

/**
 * 桌面图标角标（未读红点数字）—— 各厂商逐一尝试，全部静默失败。
 *
 * 现实约束（2026 年国产 ROM）：
 *  - 三星/索尼/HTC/部分 AOSP：broadcast 接口仍然开放（本文件实现）。
 *  - 华为/荣耀：老 EMUI broadcast 大概率被新系统忽略，仍保留尝试（命中即赚）。
 *    新系统（HarmonyOS/MagicOS）的角标主要跟「通知」走——App 发通知角标自动 +1，
 *    由 jpush 厂商通道的离线推送天然覆盖，本类是对 App 内主动设置场景的补充。
 *  - 小米 MIUI/HyperOS：无公开角标 API，角标=通知数（走通知即可）；
 *    保留 MiuiNotification 反射老接口兜底尝试。
 *  - OPPO ColorOS：角标需厂商白名单授权，第三方设置无效，不尝试。
 *  - VIVO OriginOS：需 vivo push SDK 内部接口，不尝试。
 * 所有调用包 try/catch：接口不存在/被禁时静默跳过，绝不能崩 App。
 */
object BadgeManager {

    fun setBadge(context: Context, count: Int) {
        val n = count.coerceAtLeast(0)
        setSamsung(n, context)
        setSony(n, context)
        setHtc(n, context)
        setHuaweiLegacy(context, n)
        setHonorLegacy(context, n)
        setMiuiLegacy(n)
    }

    /** 三星：android.intent.action.BADGE_COUNT_UPDATE（OneUI 仍兼容） */
    private fun setSamsung(count: Int, context: Context) {
        try {
            val intent = Intent("android.intent.action.BADGE_COUNT_UPDATE")
            intent.putExtra("badge_count", count)
            intent.putExtra("badge_count_package_name", context.packageName)
            intent.putExtra(
                "badge_count_class_name",
                launchActivityClassName(context)
            )
            context.sendBroadcast(intent)
        } catch (_: Exception) {
        }
    }

    /** 索尼：com.sonyericsson.home.action.UPDATE_BADGE */
    private fun setSony(count: Int, context: Context) {
        try {
            val intent = Intent("com.sonyericsson.home.action.UPDATE_BADGE")
            intent.putExtra(
                "com.sonyericsson.home.intent.extra.badge.ACTIVITY_NAME",
                launchActivityClassName(context)
            )
            intent.putExtra(
                "com.sonyericsson.home.intent.extra.badge.SHOW_MESSAGE",
                count > 0
            )
            intent.putExtra(
                "com.sonyericsson.home.intent.extra.badge.MESSAGE",
                count.toString()
            )
            context.sendBroadcast(intent)
        } catch (_: Exception) {
        }
    }

    /** HTC：com.htc.launcher.action.UPDATE_SHORTCUT + SET_NOTIFICATION */
    private fun setHtc(count: Int, context: Context) {
        try {
            val i1 = Intent("com.htc.launcher.action.SET_NOTIFICATION")
            i1.putExtra("com.htc.launcher.extra.COMPONENT",
                ComponentName(context, launchActivityClassName(context)).flattenToString())
            i1.putExtra("com.htc.launcher.extra.COUNT", count.toString())
            context.sendBroadcast(i1)
            val i2 = Intent("com.htc.launcher.action.UPDATE_SHORTCUT")
            i2.putExtra("packagename", context.packageName)
            i2.putExtra("count", count)
            context.sendBroadcast(i2)
        } catch (_: Exception) {
        }
    }

    /** 华为 EMUI 老 broadcast（新系统大概率忽略，静默） */
    private fun setHuaweiLegacy(context: Context, count: Int) {
        try {
            val bundle = android.os.Bundle()
            bundle.putString("package", context.packageName)
            bundle.putString("class", launchActivityClassName(context))
            bundle.putInt("badgenumber", count)
            context.sendBroadcast(
                Intent("com.huawei.android.launcher.action.CHANGE_NOTIFICATION")
                    .putExtras(bundle)
            )
        } catch (_: Exception) {
        }
    }

    /** 荣耀 MagicOS 老 broadcast（同华为思路，静默） */
    private fun setHonorLegacy(context: Context, count: Int) {
        try {
            val bundle = android.os.Bundle()
            bundle.putString("package", context.packageName)
            bundle.putString("class", launchActivityClassName(context))
            bundle.putInt("badgenumber", count)
            context.sendBroadcast(
                Intent("com.hihonor.android.launcher.action.CHANGE_NOTIFICATION")
                    .putExtras(bundle)
            )
        } catch (_: Exception) {
        }
    }

    /** 小米 MIUI 反射老接口（MiuiNotification.extraNotification，新系统无效则静默） */
    private fun setMiuiLegacy(count: Int) {
        try {
            val notification = android.app.Notification()
            val field = notification.javaClass.getDeclaredField("extraNotification")
            val extraNotification = field.get(notification)
            extraNotification.javaClass
                .getDeclaredMethod("setMessageCount", Int::class.javaPrimitiveType)
                .invoke(extraNotification, count)
        } catch (_: Throwable) {
        }
    }

    /** 取 launcher 入口 Activity 类名（Manifest 里 MAIN/LAUNCHER 的 Activity） */
    private fun launchActivityClassName(context: Context): String {
        return try {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .setPackage(context.packageName)
            val ri = context.packageManager.queryIntentActivities(intent, 0).firstOrNull()
            ri?.activityInfo?.name ?: "${context.packageName}.MainActivity"
        } catch (_: Exception) {
            "${context.packageName}.MainActivity"
        }
    }
}

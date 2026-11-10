package com.siqu.chat
import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer

/**
 * 静音循环保活：后台循环播放一段 -60dB（振幅 30/32767）的极低音量正弦波，
 * 让系统检测到「真实音频输出活动」→ 厂商省电策略（MIUI/ColorOS/OriginOS 等）
 * 把本应用当「正在播放媒体」而豁免后台冻结，避免 WS 心跳被冻结后掉线。
 *
 * 设计要点：
 *  - 不用纯静音轨/音量 0：部分 ROM 会识别静音并照样冻结；极低振幅正弦任何
 *    检测都算真实音频，人耳不可闻（-60dB 在正常环境音之下）。
 *  - 单例防重复：start 幂等（已在播则忽略），stop 可重复调用。
 *  - 全程 try/catch 静默：播放失败（无音频设备等）不影响任何主流程。
 *  - 代价：电池统计里 Audio 常驻（后台耗电略增）——用户已知情选择默认开启。
 */
object SilentAudioPlayer {
    private var player: MediaPlayer? = null

    @Synchronized
    fun start(context: Context) {
        if (player != null) return
        try {
            val p = MediaPlayer()
            p.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            val afd = context.resources.openRawResourceFd(R.raw.silence)
            p.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            afd.close()
            p.isLooping = true
            p.setVolume(0.05f, 0.05f)
            p.prepare()
            p.start()
            player = p
        } catch (_: Exception) {
            player = null
        }
    }

    @Synchronized
    fun stop() {
        try {
            player?.let {
                try { it.stop() } catch (_: Exception) {}
                try { it.release() } catch (_: Exception) {}
            }
        } finally {
            player = null
        }
    }
}

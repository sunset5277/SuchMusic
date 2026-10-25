package com.such.music.such_music

import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        // 悬浮歌词 MethodChannel：Service 销毁时反向通知 Flutter 用
        @JvmStatic
        var floatingLyricChannel: MethodChannel? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 原生兜底：窗口系统栏全透明。release 下 Flutter SystemChrome 的
        // 导航栏透明设置不可靠（debug 正常、release 白底），故在此强制设置
        window.apply {
            addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            statusBarColor = Color.TRANSPARENT
            navigationBarColor = Color.TRANSPARENT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        KaraokeDecoder.register(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FloatingLyricService.CHANNEL,
        )
        floatingLyricChannel = channel
        channel.setMethodCallHandler { call, result ->
            if (call.method != "syncPosition") {
                android.util.Log.d(
                    "悬浮歌词",
                    "channel<-${call.method} instance=${FloatingLyricService.instance != null}",
                )
            }
            when (call.method) {
                "canDrawOverlays" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "requestOverlayPermission" -> {
                    if (!Settings.canDrawOverlays(this)) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        )
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                    }
                    result.success(null)
                }
                "showFloatingLyric" -> {
                    val text = call.argument<String>("text") ?: ""
                    FloatingLyricService.start(this, text)
                    // startService 异步创建，初始文本统一走 dispatch：
                    // 服务未就绪时暂存，onCreate 后按序回放，避免首屏歌词丢失
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.updateText(text)
                    }
                    result.success(null)
                }
                "updateFloatingLyric" -> {
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.updateText(call.argument<String>("text") ?: "")
                    }
                    result.success(null)
                }
                "setKaraokeLine" -> {
                    @Suppress("UNCHECKED_CAST")
                    val tokens = call.argument<List<Map<*, *>>>("tokens")
                        ?: emptyList()
                    val text = call.argument<String>("text") ?: ""
                    val lineEndMs =
                        (call.argument<Any>("lineEndMs") as? Number)?.toLong() ?: -1L
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.setKaraokeLine(tokens, text, lineEndMs)
                    }
                    result.success(null)
                }
                "syncPosition" -> {
                    val positionMs =
                        (call.argument<Any>("positionMs") as? Number)?.toLong() ?: 0L
                    val playing = call.argument<Boolean>("playing") == true
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.syncPosition(positionMs, playing)
                    }
                    result.success(null)
                }
                "clearKaraoke" -> {
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.clearKaraoke()
                    }
                    result.success(null)
                }
                "setFloatingLyricLocked" -> {
                    val locked = call.argument<Boolean>("locked") == true
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.setLocked(locked)
                    }
                    result.success(null)
                }
                "setFloatingLyricAlign" -> {
                    val align = call.argument<String>("align") ?: "center"
                    FloatingLyricService.dispatch(FloatingLyricService.instance) {
                        it.setAlign(align)
                    }
                    result.success(null)
                }
                "hideFloatingLyric" -> {
                    stopService(Intent(this, FloatingLyricService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

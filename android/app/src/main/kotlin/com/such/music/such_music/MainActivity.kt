package com.such.music.such_music

import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import com.such.music.such_music.band.BandChannelBridge
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {

    // 小米手环桥接通道（可插拔：AAR 缺席时自动 Noop，不影响其它功能）
    private val bandBridge by lazy { BandChannelBridge(applicationContext) }

    // 注册手环 MethodChannel / EventChannel。此为新增集成点，不改变既有行为。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bandBridge.attach(flutterEngine.dartExecutor.binaryMessenger)
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
}

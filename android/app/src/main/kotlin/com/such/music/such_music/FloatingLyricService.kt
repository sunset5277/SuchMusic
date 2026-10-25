package com.such.music.such_music

import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import io.flutter.plugin.common.MethodChannel

/**
 * 桌面悬浮歌词服务：TYPE_APPLICATION_OVERLAY 悬浮窗。
 * - 卡拉OK逐字填充（FloatingLyricView 自绘）或整句回退文本
 * - 触摸歌词拖动位置；点击歌词回到 App；锁定后不可拖动/点击
 */
class FloatingLyricService : Service() {

    companion object {
        const val CHANNEL = "com.such.music.such_music/floating_lyric"
        const val EXTRA_TEXT = "text"
        const val TAG = "悬浮歌词"
        const val PREFS_NAME = "floating_lyric"
        const val KEY_LAST_X = "last_x"
        const val KEY_LAST_Y = "last_y"
        const val KEY_LAST_W = "last_w"
        const val KEY_LAST_H = "last_h"
        const val KEY_ALIGN = "align"

        // 当前运行实例（悬浮窗显示中才有值），供 MainActivity 更新文本/关闭
        @JvmStatic
        var instance: FloatingLyricService? = null
            private set

        // startService 是异步的：onCreate 前 instance 为 null，期间到达的
        // 文本/卡拉OK/位置/锁定消息先暂存，onCreate 后按序回放，
        // 避免首帧歌词被静默丢弃导致悬浮窗卡在初始一句
        private val pending = ArrayDeque<(FloatingLyricService) -> Unit>()

        /** instance 就绪则直接执行，否则暂存待 onCreate 回放 */
        @JvmStatic
        fun dispatch(service: FloatingLyricService?, action: (FloatingLyricService) -> Unit) {
            if (service != null) {
                action(service)
            } else {
                synchronized(pending) {
                    if (pending.size >= 64) pending.removeFirst() // 兜底防堆积
                    pending.addLast(action)
                }
            }
        }

        @JvmStatic
        fun start(context: android.content.Context, text: String) {
            val intent = Intent(context, FloatingLyricService::class.java)
            intent.putExtra(EXTRA_TEXT, text)
            context.startService(intent)
        }
    }

    private var windowManager: WindowManager? = null
    private var rootView: View? = null
    private var lyricView: FloatingLyricView? = null
    private lateinit var params: WindowManager.LayoutParams

    /** 歌词锁定：锁定后悬浮窗触摸穿透（不挡下层可点击内容），不可拖动/点击 */
    @Volatile
    var locked: Boolean = false
        private set

    /** 锁定切换：锁定时加 FLAG_NOT_TOUCHABLE 让触摸穿透到下层应用 */
    fun setLocked(value: Boolean) {
        locked = value
        applyTouchableFlags()
    }

    private fun applyTouchableFlags() {
        val view = rootView ?: return
        params.flags = if (locked) {
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        } else {
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        }
        windowManager?.updateViewLayout(view, params)
    }

    /** 对齐方式：left / center / right（屏幕水平锚定，决定 gravity） */
    var align: String = "center"
        private set

    private fun gravityFor(a: String): Int = when (a) {
        "left" -> Gravity.TOP or Gravity.START
        "right" -> Gravity.TOP or Gravity.END
        else -> Gravity.TOP or Gravity.CENTER_HORIZONTAL
    }

    /** 对齐切换：重设水平锚点（垂直位置保留），持久化并立即应用 */
    fun setAlign(value: String) {
        if (value == align) return
        align = value
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putString(KEY_ALIGN, value).apply()
        if (rootView == null) return
        val density = resources.displayMetrics.density
        params.gravity = gravityFor(value)
        // 切换对齐时水平重置到对应锚点
        params.x = if (value == "center") 0 else (40 * density).toInt()
        windowManager?.updateViewLayout(rootView, params)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        showOverlay()
        // 回放服务创建完成前暂存的消息（初始文本/卡拉OK行/位置/锁定）
        val replayed = synchronized(pending) {
            val n = pending.size
            while (pending.isNotEmpty()) pending.removeFirst()(this)
            n
        }
        android.util.Log.d(TAG, "onCreate 回放${replayed}条暂存消息")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 初始文本已由 showFloatingLyric 经 dispatch 推送（onCreate 前暂存、
        // 创建后回放），这里不再 setText，以免覆盖刚回放的卡拉OK行
        android.util.Log.d(TAG, "onStartCommand（服务复用，无需创建）")
        return START_NOT_STICKY
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun showOverlay() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        val density = resources.displayMetrics.density

        // 歌词自绘 View（逐字填充/整句文本，点击回 App，可拖动）
        lyricView = FloatingLyricView(this).apply {
            setText("等待播放歌词...")
        }

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(lyricView)
        }
        rootView = row

        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            // 默认水平居中、垂直上部偏中；有历史位置则按存档对齐恢复
            y = resources.displayMetrics.heightPixels / 4
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            align = prefs.getString(KEY_ALIGN, "center") ?: "center"
            gravity = gravityFor(align)
            x = if (align == "center") 0 else (40 * density).toInt()
            if (prefs.contains(KEY_LAST_X)) {
                // 原样还原用户上次拖放的位置：贴边时坐标可为负（窗口部分
                // 在屏幕外/状态栏后），显示裁剪行为与保存时一致，无需回推。
                // 仅做"至少留 40dp 可见"的兜底 clamp（旋转/换机时防完全看不见）
                val w = prefs.getInt(KEY_LAST_W, (120 * density).toInt())
                    .coerceAtLeast((120 * density).toInt())
                val h = prefs.getInt(KEY_LAST_H, (120 * density).toInt())
                    .coerceAtLeast((120 * density).toInt())
                x = prefs.getInt(KEY_LAST_X, x).coerceIn(
                    (40 * density - w).toInt(),
                    (resources.displayMetrics.widthPixels - 40 * density).toInt(),
                )
                y = prefs.getInt(KEY_LAST_Y, y).coerceIn(
                    (40 * density - h).toInt(),
                    (resources.displayMetrics.heightPixels - 40 * density).toInt(),
                )
            }
        }

        // 拖动：按下记录起点，移动更新悬浮窗位置；点击（位移很小）回 App。
        // 锁定时禁拖动/点击。
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        lyricView!!.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (moved || dx * dx + dy * dy > 25 * 25) {
                        moved = true
                        if (!locked) {
                            // gravity END 时 x 轴向左为正，拖动方向需取反。
                            // 注意必须严格相等判断：START(0x800003) 与
                            // END(0x800005) 位与为 0x800001 非零，
                            // 用 "!= 0" 会导致所有模式下都误判为 END
                            val isEnd = params.gravity and Gravity.END == Gravity.END
                            params.x = startX + (if (isEnd) -1 else 1) * dx.toInt()
                            params.y = startY + dy.toInt()
                            windowManager?.updateViewLayout(rootView, params)
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (event.action == MotionEvent.ACTION_UP && !moved && !locked) {
                        launchApp()
                    }
                    // 拖动结束：记住位置、窗口尺寸与对齐方式，下次打开时恢复。
                    // 坐标允许为负（贴顶时窗口顶进状态栏后），恢复时原样还原
                    if (event.action == MotionEvent.ACTION_UP && moved && !locked) {
                        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
                            .putInt(KEY_LAST_X, params.x)
                            .putInt(KEY_LAST_Y, params.y)
                            .putInt(KEY_LAST_W, rootView?.width ?: 0)
                            .putInt(KEY_LAST_H, rootView?.height ?: 0)
                            .putString(KEY_ALIGN, align)
                            .apply()
                    }
                    true
                }
                else -> false
            }
        }
        windowManager?.addView(row, params)
    }

    fun updateText(text: String) {
        lyricView?.setText(text)
    }

    // ------------------------------------------------------- 卡拉OK接口

    fun setKaraokeLine(tokenList: List<Map<*, *>>, text: String, lineEndMs: Long) {
        lyricView?.setKaraokeLine(tokenList, text, lineEndMs)
    }

    fun syncPosition(positionMs: Long, playing: Boolean) {
        lyricView?.sync(positionMs, playing)
    }

    fun clearKaraoke() {
        lyricView?.clearKaraoke()
    }

    private fun launchApp() {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        startActivity(intent)
    }

    override fun onDestroy() {
        android.util.Log.d(TAG, "onDestroy")
        instance = null
        rootView?.let { windowManager?.removeView(it) }
        rootView = null
        // 通知 Flutter 侧悬浮窗已关闭（用户点了 ✕）
        MainActivity.floatingLyricChannel
            ?.invokeMethod("onFloatingLyricClosed", null)
        super.onDestroy()
    }
}

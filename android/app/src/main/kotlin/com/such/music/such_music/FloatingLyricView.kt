package com.such.music.such_music

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.view.View

/**
 * 悬浮歌词自绘 View：卡拉OK逐字填充（已唱白 / 未唱半透白）。
 * 时间驱动：Flutter 侧每次位置 tick 推 syncPosition，本地按时钟外推，
 * 每帧重绘直到行结束；暂停即停。无逐字数据时回退显示整句静态文本。
 */
class FloatingLyricView(context: Context) : View(context) {

    private data class Tok(
        val text: String,
        val startMs: Long,
        val endMs: Long,
        val startX: Float,
        val endX: Float,
    )

    private val basePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x99FFFFFF.toInt()
        typeface = Typeface.DEFAULT_BOLD
        setShadowLayer(6f, 0f, 0f, 0xCC000000.toInt())
    }
    private val playedPaint = Paint(basePaint)

    private var textSizePx = 15f * resources.displayMetrics.scaledDensity
    private val padH = 14f * resources.displayMetrics.density
    private val padV = 8f * resources.displayMetrics.density

    // 回退整句文本
    private var plainText: String = ""

    // 卡拉OK状态
    private var tokens: List<Tok> = emptyList()
    private var fullText = ""
    private var textW = 0f
    private var lineEndMs = -1L
    private var basePosMs = 0L
    private var baseUptimeMs = 0L
    private var playing = false

    init {
        playedPaint.color = Color.WHITE
        applyTextSize()
    }

    private fun applyTextSize() {
        basePaint.textSize = textSizePx
        playedPaint.textSize = textSizePx
        basePaint.typeface = Typeface.DEFAULT_BOLD
        playedPaint.typeface = Typeface.DEFAULT_BOLD
    }

    // ------------------------------------------------------------- 对外接口

    /** 回退模式：显示整句静态文本 */
    fun setText(text: String) {
        tokens = emptyList()
        plainText = if (text.isEmpty()) "  ♪  " else text
        fitTextSize()
        requestLayout()
        invalidate()
    }

    /** 进入卡拉OK行：token 时间表 + 整句文本 + 行结束时间 */
    fun setKaraokeLine(tokenList: List<Map<*, *>>, text: String, lineEndMs: Long) {
        fullText = text
        this.lineEndMs = lineEndMs
        fitTextSize()
        // 前缀宽度测量：每个 token 在整句中的 x 区间
        val toks = ArrayList<Tok>(tokenList.size)
        var cursor = 0
        var x = 0f
        for (t in tokenList) {
            val s = (t["s"] as? Number)?.toLong() ?: 0L
            val e = (t["e"] as? Number)?.toLong() ?: 0L
            val txt = t["t"] as? String ?: ""
            val charCount = txt.length
            val endX = if (cursor + charCount <= fullText.length) {
                x + basePaint.measureText(fullText, cursor, cursor + charCount)
            } else {
                x
            }
            toks.add(Tok(txt, s, e, x, endX))
            cursor += charCount
            x = endX
        }
        tokens = toks
        textW = x
        requestLayout()
        invalidate()
    }

    /** 播放位置同步（Flutter 每 tick 一次，本地外推） */
    fun sync(positionMs: Long, playing: Boolean) {
        val jump = kotlin.math.abs(positionMs - audioNow()) > 1000
        this.playing = playing
        basePosMs = positionMs
        baseUptimeMs = SystemClock.uptimeMillis()
        if (tokens.isNotEmpty()) {
            if (playing) postInvalidateOnAnimation() else invalidate()
        } else if (jump) invalidate()
    }

    /** 清空卡拉OK回到回退模式 */
    fun clearKaraoke() {
        if (tokens.isEmpty()) return
        tokens = emptyList()
        lineEndMs = -1
        requestLayout()
        invalidate()
    }

    // ------------------------------------------------------------- 绘制

    private fun audioNow(): Long =
        basePosMs + if (playing) SystemClock.uptimeMillis() - baseUptimeMs else 0L

    /** 当前已唱填充的 x 宽度 */
    private fun fillXAt(now: Long): Float {
        if (tokens.isEmpty()) return 0f
        if (now <= tokens.first().startMs) return 0f
        if (now >= tokens.last().endMs) return textW
        for (i in tokens.indices) {
            val tk = tokens[i]
            if (now < tk.startMs) {
                // 处于 token 间隙：填到上一 token 末尾（即本 token 起点）
                return tk.startX
            }
            if (now < tk.endMs) {
                val p = (now - tk.startMs).toDouble() / (tk.endMs - tk.startMs).coerceAtLeast(1)
                return tk.startX + p.toFloat() * (tk.endX - tk.startX)
            }
        }
        return textW
    }

    /** 超宽自动缩字号，限制在屏幕宽度 86% 内 */
    private fun fitTextSize() {
        val raw = plainText.ifEmpty { fullText }
        val maxW = resources.displayMetrics.widthPixels * 0.86f - padH * 2
        basePaint.textSize = textSizePx
        val w = basePaint.measureText(raw)
        if (w > maxW && w > 0) {
            val scaled = textSizePx * (maxW / w)
            basePaint.textSize = scaled
        }
        playedPaint.textSize = basePaint.textSize
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val text = if (tokens.isEmpty()) plainText else fullText
        if (text.isEmpty()) return
        val baseline = padV - basePaint.ascent()

        if (tokens.isEmpty()) {
            // 无逐字数据：整句直接用高亮色（纯白），与逐字模式已唱填充一致
            canvas.drawText(text, padH, baseline, playedPaint)
            return
        }

        val now = audioNow()
        // 未唱底色
        canvas.drawText(fullText, padH, baseline, basePaint)
        // 已唱部分裁剪绘制
        val fillX = fillXAt(now)
        if (fillX > 0f) {
            val save = canvas.save()
            canvas.clipRect(0f, 0f, padH + fillX, height.toFloat())
            canvas.drawText(fullText, padH, baseline, playedPaint)
            canvas.restoreToCount(save)
        }
        if (playing && now < lineEndMs) {
            postInvalidateOnAnimation()
        }
    }

    // ------------------------------------------------------------- 布局

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val text = if (tokens.isEmpty()) plainText else fullText
        val w = if (text.isEmpty()) 0f else basePaint.measureText(text)
        val width = (w + padH * 2).toInt().coerceAtLeast((padH * 2).toInt())
        val fontH = (basePaint.descent() - basePaint.ascent()).toInt()
        val height = fontH + padV.toInt() * 2
        setMeasuredDimension(width, height)
    }
}

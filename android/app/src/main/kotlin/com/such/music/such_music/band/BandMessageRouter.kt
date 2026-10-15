package com.such.music.such_music.band

import android.util.Log
import java.nio.charset.StandardCharsets
import org.json.JSONObject

/**
 * 信封路由器（原生侧极薄）。
 *
 * 职责边界：
 * - **入站**：把手环发来的原始字节解码为 UTF-8 JSON 字符串，做最小合法性校验
 *   （必须是含 `type` 字段的 JSON 对象），然后**原样交给 Dart**（`toDart`）。
 * - **出站**：把 Dart 生成好的信封 JSON 字符串交给 [BandConnection] 发送（`toBand`）。
 *
 * 所有协议语义（版本/能力协商、幂等去重、分片组装、命令落地）都在 **Dart 侧**
 * （`lib/services/band/`）实现，Kotlin 只做「解码 + 透传 + 发送」，避免双份逻辑。
 * 信封字段为 `{v,id,type,method|event,payload,ts}`，与设计文档冻结值一致。
 */
class BandMessageRouter(
    private val toBand: (String) -> Boolean,
    private val toDart: (String) -> Unit,
) {

    companion object {
        private const val TAG = "BandMessageRouter"
    }

    /** 手环 → 手机：入站字节。 */
    fun onInboundBytes(bytes: ByteArray) {
        onInboundText(String(bytes, StandardCharsets.UTF_8))
    }

    /** 手环 → 手机：入站文本（已解码）。 */
    fun onInboundText(text: String) {
        if (text.isEmpty()) return
        val valid = try {
            val obj = JSONObject(text)
            obj.has("type")
        } catch (_: Exception) {
            false
        }
        if (!valid) {
            // 非法信封：丢弃 + 记录，不重试（对应协议 E_BADREQ）
            Log.w(TAG, "丢弃非法信封: ${text.take(120)}")
            return
        }
        toDart(text)
    }

    /** 手机 → 手环：Dart 侧生成的信封。 */
    fun fromDart(json: String): Boolean {
        return toBand(json)
    }
}

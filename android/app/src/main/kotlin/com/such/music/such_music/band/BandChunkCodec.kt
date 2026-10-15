package com.such.music.such_music.band

import android.util.Base64
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.CRC32
import org.json.JSONArray
import org.json.JSONObject

/**
 * 跨设备分片（header → data → end）编解码与校验。
 *
 * 该文件为**纯工具类**，不依赖小米 SDK，可安全地随仓库分发与单测。
 * 帧格式与 Dart 端 `lib/services/band/band_chunk.dart` 严格一致（字段名已冻结）：
 *
 * - header: { tid, phase:"header", kind, total, bytes, crc32, meta }
 * - data  : { tid, phase:"data", seq, txt }            // 文本用 "txt"
 * - data  : { tid, phase:"data", seq, b64 }            // 二进制用 "b64"
 * - end   : { tid, phase:"end", total, crc32 }
 *
 * 说明：本类由 Dart 端调用亦可（当前手机端主逻辑在 Dart），Kotlin 侧保留一份
 * 等价实现用于「封面二进制」等原生侧数据的分片，以及为将来下沉做准备。
 */
object BandChunkCodec {

    /** 单包字节上限（保守值，真实上限待验证）。与 Dart 端一致。 */
    const val CHUNK_MAX_BYTES: Int = 900

    /** 组装缓存上限，超限即回落增量模式。与 Dart 端一致。 */
    const val ASSEMBLE_MAX_BYTES: Int = 8192

    /** 计算 IEEE CRC32（与 zlib / Dart `crc32` 同款），返回无符号 32 位值。 */
    fun crc32(bytes: ByteArray): Long {
        val crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    /** CRC32 的 8 位十六进制小写字符串（协议字段 `crc32` 的形式）。 */
    fun crc32Hex(bytes: ByteArray): String = "%08x".format(crc32(bytes))

    /**
     * 把一段文本切成 header → data → end 三段帧（JSON 字符串列表）。
     *
     * @param tid   传输 id，同一链路同一时刻仅允许 1 个
     * @param kind  "lyric_window" / "search_result" / "cover"
     * @param text  待发送文本（UTF-8）
     * @param meta  附加元信息（可选）
     */
    fun splitText(
        tid: String,
        kind: String,
        text: String,
        meta: JSONObject? = null,
    ): List<String> {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        val crc = crc32Hex(bytes)
        val pieces = splitOnCharBoundary(text, CHUNK_MAX_BYTES)

        val frames = ArrayList<String>(pieces.size + 2)

        val headerPayload = JSONObject().apply {
            put("tid", tid)
            put("phase", "header")
            put("kind", kind)
            put("total", pieces.size)
            put("bytes", bytes.size)
            put("crc32", crc)
            if (meta != null) put("meta", meta)
        }
        frames.add(headerPayload.toString())

        pieces.forEachIndexed { index, piece ->
            val dataPayload = JSONObject().apply {
                put("tid", tid)
                put("phase", "data")
                put("seq", index)
                put("txt", piece)
            }
            frames.add(dataPayload.toString())
        }

        val endPayload = JSONObject().apply {
            put("tid", tid)
            put("phase", "end")
            put("total", pieces.size)
            put("crc32", crc)
        }
        frames.add(endPayload.toString())

        return frames
    }

    /** 把一段二进制切成 header → data → end 三段帧（二进制用 base64 承载）。 */
    fun splitBytes(
        tid: String,
        kind: String,
        data: ByteArray,
        meta: JSONObject? = null,
    ): List<String> {
        val crc = crc32Hex(data)
        val chunkSize = CHUNK_MAX_BYTES
        val total = if (data.isEmpty()) 0 else (data.size + chunkSize - 1) / chunkSize

        val frames = ArrayList<String>(total + 2)
        frames.add(JSONObject().apply {
            put("tid", tid)
            put("phase", "header")
            put("kind", kind)
            put("total", total)
            put("bytes", data.size)
            put("crc32", crc)
            if (meta != null) put("meta", meta)
        }.toString())

        for (i in 0 until total) {
            val from = i * chunkSize
            val to = minOf(from + chunkSize, data.size)
            val slice = data.copyOfRange(from, to)
            frames.add(JSONObject().apply {
                put("tid", tid)
                put("phase", "data")
                put("seq", i)
                put("b64", Base64.encodeToString(slice, Base64.NO_WRAP))
            }.toString())
        }

        frames.add(JSONObject().apply {
            put("tid", tid)
            put("phase", "end")
            put("total", total)
            put("crc32", crc)
        }.toString())

        return frames
    }

    /** 按 UTF-8 字节上限切分，且保证不切断多字节字符。 */
    private fun splitOnCharBoundary(text: String, maxBytes: Int): List<String> {
        val result = ArrayList<String>()
        val buffer = StringBuilder()
        var bufferedBytes = 0
        for (ch in text) {
            val chBytes = ch.toString().toByteArray(StandardCharsets.UTF_8).size
            if (bufferedBytes + chBytes > maxBytes && buffer.isNotEmpty()) {
                result.add(buffer.toString())
                buffer.setLength(0)
                bufferedBytes = 0
            }
            buffer.append(ch)
            bufferedBytes += chBytes
        }
        if (buffer.isNotEmpty()) result.add(buffer.toString())
        return result
    }

    /** 组装结果。 */
    sealed class AssembleResult {
        /** 尚未收齐。 */
        object Pending : AssembleResult()

        /** 组装成功，[text] 为还原文本。 */
        data class Complete(val text: String) : AssembleResult()

        /** 校验失败 / 超限，携带缺失分片序号（可为空，表示整体失败）。 */
        data class Failed(val missing: List<Int>, val reason: String) : AssembleResult()
    }

    /**
     * 按 seq 组装分片，`end` 时校验总数与 CRC32。
     * 与 Dart 端 `BandChunkAssembler` 行为一致。
     */
    class Assembler {
        private var tid: String = ""
        private var total: Int = 0
        private var expectedCrc: String = ""
        private var expectedBytes: Int = 0
        private var started = false
        private val parts = HashMap<Int, String>()
        private var oversize = false

        fun onHeader(payload: JSONObject): AssembleResult {
            tid = payload.optString("tid")
            total = payload.optInt("total")
            expectedCrc = payload.optString("crc32")
            expectedBytes = payload.optInt("bytes")
            parts.clear()
            started = true
            oversize = expectedBytes > ASSEMBLE_MAX_BYTES
            return AssembleResult.Pending
        }

        fun onData(payload: JSONObject): AssembleResult {
            if (!started) return AssembleResult.Pending
            val seq = payload.optInt("seq", -1)
            if (seq < 0) return AssembleResult.Pending
            val text = payload.optString("txt", "")
            parts[seq] = text
            return AssembleResult.Pending
        }

        fun onEnd(payload: JSONObject): AssembleResult {
            if (!started) return AssembleResult.Failed(emptyList(), "end before header")
            if (oversize) {
                val missing = (0 until total).filter { !parts.containsKey(it) }
                reset()
                return AssembleResult.Failed(missing, "E_TOOLARGE")
            }
            val missing = (0 until total).filter { !parts.containsKey(it) }
            if (missing.isNotEmpty()) {
                reset()
                return AssembleResult.Failed(missing, "E_CRC")
            }
            val sb = StringBuilder()
            for (i in 0 until total) sb.append(parts[i])
            val text = sb.toString()
            val got = crc32Hex(text.toByteArray(StandardCharsets.UTF_8))
            reset()
            return if (got == expectedCrc) {
                AssembleResult.Complete(text)
            } else {
                AssembleResult.Failed(emptyList(), "E_CRC")
            }
        }

        private fun reset() {
            parts.clear()
            started = false
        }
    }

    /** 将 JSON 数组串解析为字符串列表（用于 base64 之外的小工具，无副作用）。 */
    fun parseStringArray(raw: String): List<String> {
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.optString(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** 拼接字节数组的小工具（保留给原生侧组装使用）。 */
    fun concat(chunks: List<ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        for (c in chunks) out.write(c)
        return out.toByteArray()
    }
}

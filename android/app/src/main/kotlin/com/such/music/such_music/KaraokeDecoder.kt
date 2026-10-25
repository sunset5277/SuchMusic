package com.such.music.such_music

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// 逐字歌词音频解码：MediaCodec 解码任意容器 → 单声道 f32le PCM 缓存文件。
/// 返回 { "path": String, "sampleRate": Int }，由 Dart 侧重采样到 22050Hz。
object KaraokeDecoder {

    private const val TIMEOUT_US = 10000L

    fun decode(path: String): Map<String, Any> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var out: FileOutputStream? = null
        var outFile: File? = null
        try {
            extractor.setDataSource(path)
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            require(trackIndex >= 0) { "no audio track" }
            extractor.selectTrack(trackIndex)
            val mime = format!!.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var sawInputEOS = false
            var sawOutputEOS = false

            outFile = File.createTempFile("karaoke_", ".pcm")
            out = FileOutputStream(outFile)
            val info = MediaCodec.BufferInfo()
            // 16bit PCM 交织缓冲，按声道下混为 f32 追加写入
            var pcm16 = ByteArray(1 shl 16)

            while (!sawOutputEOS) {
                if (!sawInputEOS) {
                    val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIdx >= 0) {
                        val ib = codec.getInputBuffer(inIdx)!!
                        val sz = extractor.readSampleData(ib, 0)
                        if (sz < 0) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEOS = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, sz, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIdx >= 0 -> {
                        val ob = codec.getOutputBuffer(outIdx)!!
                        if (info.size > 0) {
                            if (pcm16.size < info.size) pcm16 = ByteArray(info.size)
                            ob.position(info.offset)
                            ob.limit(info.offset + info.size)
                            ob.get(pcm16, 0, info.size)
                            val frames = info.size / 2 / channels
                            val f32 = ByteArray(frames * 4)
                            val bb = ByteBuffer.wrap(f32).order(ByteOrder.LITTLE_ENDIAN)
                            var p = 0
                            for (f in 0 until frames) {
                                var acc = 0
                                for (c in 0 until channels) {
                                    val s =
                                        ((pcm16[p + 2 * c].toInt() and 0xFF) shl 8) or
                                            (pcm16[p + 2 * c + 1].toInt() and 0xFF)
                                    acc += s.toShort().toInt()
                                }
                                bb.putFloat(acc.toFloat() / channels / 32768.0f)
                                p += 2 * channels
                            }
                            out.write(f32)
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            sawOutputEOS = true
                        }
                    }
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val of = codec.outputFormat
                        sampleRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                }
            }
            out.flush()

            // 输出帧数校验（过小视为解码失败）
            val frames = (outFile.length() / 4).toInt()
            if (frames < sampleRate) {
                outFile.delete()
                throw IllegalStateException("decoded too few frames: $frames")
            }
            return mapOf("path" to outFile.absolutePath, "sampleRate" to sampleRate)
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
            runCatching { out?.close() }
        }
    }

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "such_music/karaoke")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decodeAudio" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("args", "path required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                result.success(decode(path))
                            } catch (e: Exception) {
                                result.error("decode", e.message, null)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

package com.such.music.such_music.band

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 打通 Flutter(Dart) ↔ 原生 ↔ 手环 的通道桥。
 *
 * 与概念版不同，上游原版 `MainActivity` 此前**没有任何 MethodChannel**，
 * 本桥接为**全新独立新增**，在 `MainActivity.configureFlutterEngine` 中注册，
 * 不触碰任何既有原生逻辑。
 *
 * 通道约定（与 Dart 端 `lib/services/band/band_channel.dart` 一致）：
 * - MethodChannel `com.such.music.such_music/band`
 *     - `start`     -> Int   启动连接，返回连接状态
 *     - `stop`      -> null  停止连接
 *     - `send`(String json) -> Boolean  发送一封手机→手环信封
 *     - `status`    -> Int   当前连接状态
 *     - `available` -> Boolean  SDK 是否可用（是否放置了 AAR）
 * - EventChannel `com.such.music.such_music/band_events`
 *     - `{"type":"available","available":Bool}`
 *     - `{"type":"state","state":Int}`
 *     - `{"type":"message","data":String}`  手环→手机信封（JSON 字符串）
 *     - `{"type":"error","message":String}`
 */
class BandChannelBridge(private val context: Context) {

    companion object {
        const val METHOD_CHANNEL = "com.such.music.such_music/band"
        const val EVENT_CHANNEL = "com.such.music.such_music/band_events"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null

    private lateinit var connection: BandConnection
    private lateinit var router: BandMessageRouter

    init {
        connection = BandConnection(context, object : BandConnection.Listener {
            override fun onStateChanged(state: Int) {
                postEvent(mapOf("type" to "state", "state" to state))
            }

            override fun onMessageReceived(bytes: ByteArray) {
                router.onInboundBytes(bytes)
            }

            override fun onError(message: String) {
                postEvent(mapOf("type" to "error", "message" to message))
            }
        })

        router = BandMessageRouter(
            toBand = { json -> connection.send(json.toByteArray(Charsets.UTF_8)) },
            toDart = { json -> postEvent(mapOf("type" to "message", "data" to json)) },
        )
    }

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            handleMethodCall(call, result)
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    sink?.success(mapOf("type" to "available", "available" to connection.isAvailable))
                    sink?.success(mapOf("type" to "state", "state" to connection.status()))
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                connection.start()
                result.success(connection.status())
            }
            "stop" -> {
                connection.stop()
                result.success(null)
            }
            "send" -> {
                val json = call.arguments as? String
                if (json == null) {
                    result.error("E_BADREQ", "send 需要 String 参数", null)
                } else {
                    result.success(router.fromDart(json))
                }
            }
            "status" -> result.success(connection.status())
            "available" -> result.success(connection.isAvailable)
            else -> result.notImplemented()
        }
    }

    private fun postEvent(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }
}

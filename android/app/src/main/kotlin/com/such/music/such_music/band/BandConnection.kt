package com.such.music.such_music.band

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * 手机 ↔ 小米手环 的连接封装（**薄适配层**）。
 *
 * 设计约束：
 * - 小米官方 `xms-wearable-lib`（`com.xiaomi.xms.wearable.*`）带专有许可，**不随仓库分发**。
 *   因此本类**不做编译期硬依赖**，全部通过**反射**访问；当 `android/app/libs/` 下不存在
 *   `xms-wearable-lib*.aar` 时，`build.gradle.kts` 不会引入该 SDK，本类自动进入
 *   **Noop 兜底**（状态恒为 UNAVAILABLE），App 其余功能完全不受影响。
 * - 反射所需的具体类名 / 方法名（如 `OnMessageReceivedListener` 的注册方法）受 SDK 版本
 *   影响，属于**待真机验证项**；所有反射调用均包在 try/catch 内，任何失败都降级为 Noop，
 *   绝不抛异常导致 App 崩溃。
 *
 * 包名/签名约束（重要）：interconnect 通道仅对「包名 + 签名与手环快应用完全一致」的手机 App
 * 开放。本 App 的包名为 `com.such.music.such_music`，手环快应用必须使用**同一包名**
 * （详见 `docs/手环通讯.md`）。
 */
class BandConnection(
    context: Context,
    private val listener: Listener,
) {

    /** 连接回调，均在主线程派发。 */
    interface Listener {
        fun onStateChanged(state: Int)
        fun onMessageReceived(bytes: ByteArray)
        fun onError(message: String)
    }

    companion object {
        private const val TAG = "BandConnection"

        /** SDK 缺席 / 反射失败：能力不可用。 */
        const val STATE_UNAVAILABLE = -2

        /** 通道已就绪但未发现已连接节点。 */
        const val STATE_DISCONNECTED = 0

        /** 已发现手环节点且监听已注册。 */
        const val STATE_CONNECTED = 1

        private const val LIB_CLASS = "com.xiaomi.xms.wearable.Wearable"
        private const val PERMISSION_CLASS = "com.xiaomi.xms.wearable.Permission"
    }

    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    /** SDK 主入口类是否加载成功。 */
    private var sdkLoaded: Boolean = false

    private var nodeApi: Any? = null
    private var messageApi: Any? = null
    private var authApi: Any? = null

    /** 已发现的手环节点 id。 */
    private var nodeId: String? = null

    private var currentState: Int = STATE_UNAVAILABLE

    /** 消息监听代理（保持强引用，避免被 GC 回收）。 */
    private var messageListenerProxy: Any? = null

    val isAvailable: Boolean get() = sdkLoaded

    fun status(): Int = currentState

    /**
     * 启动连接：加载 SDK → 获取各 Api → 请求权限 → 发现节点 → 注册监听。
     * 任一步骤失败即降级为 UNAVAILABLE/DISCONNECTED，不抛出异常。
     */
    fun start() {
        if (sdkLoaded) return
        try {
            val wearableCls = Class.forName(LIB_CLASS)
            sdkLoaded = true

            nodeApi = invokeStatic(wearableCls, "getNodeApi", appContext)
            messageApi = invokeStatic(wearableCls, "getMessageApi", appContext)
            authApi = invokeStatic(wearableCls, "getAuthApi", appContext)

            if (nodeApi == null || messageApi == null) {
                Log.w(TAG, "xms SDK 已加载但 Api 获取失败，进入 Noop")
                sdkLoaded = false
                publishState(STATE_UNAVAILABLE)
                return
            }

            discoverNodes()
            registerMessageListener()
        } catch (t: Throwable) {
            // 未放置 AAR（ClassNotFound）或反射契约不符：静默降级
            Log.i(TAG, "小米手环 SDK 不可用，进入 Noop 模式: ${t.message}")
            sdkLoaded = false
            publishState(STATE_UNAVAILABLE)
        }
    }

    /** 停止连接并释放监听。 */
    fun stop() {
        try {
            val api = messageApi
            val proxy = messageListenerProxy
            if (api != null && proxy != null) {
                findMethod(api.javaClass, "unregisterListener", proxy.javaClass)?.let {
                    it.isAccessible = true
                    it.invoke(api, proxy)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "unregisterListener 失败：${t.message}")
        }
        messageListenerProxy = null
        nodeId = null
        publishState(STATE_UNAVAILABLE)
    }

    /** 发送一帧字节到手环。返回是否成功派发（不代表送达）。 */
    fun send(bytes: ByteArray): Boolean {
        val api = messageApi ?: return false
        val node = nodeId ?: return false
        return try {
            val m = findMethod(api.javaClass, "sendMessage", String::class.java, ByteArray::class.java)
                ?: return false
            m.isAccessible = true
            m.invoke(api, node, bytes)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "sendMessage 失败：${t.message}")
            listener.onError("E_LINK")
            false
        }
    }

    // ----- 内部实现 -----

    private fun discoverNodes() {
        val api = nodeApi ?: return
        try {
            val raw = findMethod(api.javaClass, "getConnectedNodes")?.let {
                it.isAccessible = true
                it.invoke(api)
            }
            val nodes = normalizeNodes(raw)
            if (nodes.isEmpty()) {
                publishState(STATE_DISCONNECTED)
                return
            }
            // 约定：取第一个已连接节点
            nodeId = extractNodeId(nodes.first())
            if (nodeId == null) {
                publishState(STATE_DISCONNECTED)
                return
            }
            requestPermissionIfNeeded(nodeId!!)
            publishState(STATE_CONNECTED)
        } catch (t: Throwable) {
            Log.w(TAG, "getConnectedNodes 失败：${t.message}")
            publishState(STATE_DISCONNECTED)
        }
    }

    /** getConnectedNodes 可能直接返回 List，或返回一个 Task（带 getResult()）。 */
    @Suppress("UNCHECKED_CAST")
    private fun normalizeNodes(raw: Any?): List<Any> {
        if (raw == null) return emptyList()
        if (raw is List<*>) return raw.filterNotNull()
        // 兼容 Task/RemoteFuture：尝试 getResult()
        findMethod(raw.javaClass, "getResult")?.let {
            it.isAccessible = true
            val result = it.invoke(raw)
            if (result is List<*>) return result.filterNotNull()
        }
        return emptyList()
    }

    private fun extractNodeId(node: Any): String? {
        for (name in listOf("getId", "getNodeId", "getDeviceId")) {
            findMethod(node.javaClass, name)?.let {
                it.isAccessible = true
                val v = it.invoke(node)
                if (v is String && v.isNotEmpty()) return v
            }
        }
        return null
    }

    private fun requestPermissionIfNeeded(nodeId: String) {
        val api = authApi ?: return
        try {
            val permission = permissionDeviceManager() ?: return
            val check = findMethod(
                api.javaClass, "checkPermission", String::class.java, String::class.java,
            ) ?: return
            check.isAccessible = true
            val granted = check.invoke(api, nodeId, permission)
            val ok = granted is Boolean && granted
            if (!ok) {
                val request = findMethod(
                    api.javaClass, "requestPermission", String::class.java, String::class.java,
                )
                if (request != null) {
                    request.isAccessible = true
                    request.invoke(api, nodeId, permission)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "权限检查失败（可由 SDK 在注册监听时自动处理）：${t.message}")
        }
    }

    private fun permissionDeviceManager(): String? {
        return try {
            val cls = Class.forName(PERMISSION_CLASS)
            val field = cls.getField("DEVICE_MANAGER")
            field.get(null) as? String
        } catch (t: Throwable) {
            "DEVICE_MANAGER"
        }
    }

    private fun registerMessageListener() {
        val api = messageApi ?: return
        try {
            // 找到「参数为某个回调接口」的注册方法（registerListener / addListener 等）
            val register = api.javaClass.methods.firstOrNull { m ->
                m.parameterTypes.size == 1 &&
                    m.parameterTypes[0].isInterface &&
                    (m.name.contains("register", ignoreCase = true) ||
                        m.name.contains("addListener", ignoreCase = true) ||
                        m.name.contains("subscribe", ignoreCase = true))
            } ?: run {
                Log.w(TAG, "未找到消息监听注册方法（待真机验证 SDK 契约）")
                return
            }

            val listenerInterface = register.parameterTypes[0]
            val proxy = Proxy.newProxyInstance(
                listenerInterface.classLoader,
                arrayOf(listenerInterface),
            ) { _, method, args ->
                when {
                    method.name == "onMessageReceived" -> {
                        val bytes = (args?.lastOrNull { it is ByteArray }) as? ByteArray
                        if (bytes != null) dispatchMessage(bytes)
                        null
                    }
                    else -> null
                }
            }
            register.isAccessible = true
            register.invoke(api, proxy)
            messageListenerProxy = proxy
        } catch (t: Throwable) {
            Log.w(TAG, "注册消息监听失败：${t.message}")
        }
    }

    private fun dispatchMessage(bytes: ByteArray) {
        mainHandler.post { listener.onMessageReceived(bytes) }
    }

    private fun publishState(state: Int) {
        if (currentState == state) return
        currentState = state
        mainHandler.post { listener.onStateChanged(state) }
    }

    private fun findMethod(
        clazz: Class<*>,
        name: String,
        vararg params: Class<*>,
    ): Method? {
        // 精确签名
        try {
            return clazz.getMethod(name, *params)
        } catch (_: Throwable) {
            // 忽略
        }
        // 宽松匹配（参数个数一致即可）
        return clazz.methods.firstOrNull { it.name == name && it.parameterTypes.size == params.size }
    }

    private fun invokeStatic(clazz: Class<*>, name: String, arg: Any): Any? {
        val method = clazz.methods.firstOrNull {
            it.name == name && it.parameterTypes.size == 1 && it.parameterTypes[0].isInstance(arg)
        } ?: clazz.methods.firstOrNull { it.name == name }
        method?.isAccessible = true
        return method?.invoke(null, arg)
    }
}

package com.example.app

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private val vpnRequestCode = 1001

    private lateinit var methodChannel: MethodChannel
    private var waitingForUsageAccess = false
    private var pendingDeviceId: String? = null
    private var pendingPublicKey: String? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as XorVpnApplication).flutterEngine

    override fun onResume() {
        super.onResume()
        if (!waitingForUsageAccess) return

        waitingForUsageAccess = false
        if (hasUsageAccess()) {
            requestVpnPermission()
        } else if (::methodChannel.isInitialized) {
            methodChannel.invokeMethod("onStatusChange", "error: Usage Access is required")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            XorVpnApplication.CHANNEL_NAME,
        )
        XorVpnService.flutterChannel = methodChannel

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> {
                    parseIdentity(call.arguments)?.let {
                        continueConnect(it.first, it.second)
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    VpnActions.cachedIdentity(this)?.let {
                        continueConnect(it.first, it.second)
                        result.success(null)
                        return@setMethodCallHandler
                    }

                    methodChannel.invokeMethod(
                        "getDeviceIdentity",
                        null,
                        object : MethodChannel.Result {
                            override fun success(identityPayload: Any?) {
                                val identity = parseIdentity(identityPayload)
                                if (identity == null) {
                                    VpnActions.cachedIdentity(this@MainActivity)?.let {
                                        continueConnect(it.first, it.second)
                                        result.success(null)
                                        return
                                    }
                                    result.error(
                                        "invalid_identity",
                                        "Device identity is missing",
                                        null,
                                    )
                                    return
                                }
                                continueConnect(identity.first, identity.second)
                                result.success(null)
                            }

                            override fun error(code: String, message: String?, details: Any?) {
                                result.error(code, message, details)
                            }

                            override fun notImplemented() {
                                result.error(
                                    "invalid_identity",
                                    "Device identity provider is unavailable",
                                    null,
                                )
                            }
                        },
                    )
                }

                "disconnect" -> {
                    VpnActions.stopVpn(this)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == vpnRequestCode && resultCode == RESULT_OK) {
            launchVpnService()
        } else if (requestCode == vpnRequestCode) {
            methodChannel.invokeMethod("onStatusChange", "error: VPN permission denied")
        }
    }

    private fun requestConnect() {
        if (!hasUsageAccess()) {
            waitingForUsageAccess = true
            startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            return
        }
        requestVpnPermission()
    }

    private fun continueConnect(deviceId: String, publicKey: String) {
        pendingDeviceId = deviceId
        pendingPublicKey = publicKey
        requestConnect()
    }

    private fun parseIdentity(arguments: Any?): Pair<String, String>? {
        val identity = when (arguments) {
            is String -> runCatching {
                val json = JSONObject(arguments)
                Pair(
                    json.optString("deviceId").takeIf { it.isNotBlank() },
                    json.optString("publicKey").takeIf { it.isNotBlank() },
                )
            }.getOrElse { Pair(null, null) }
            is List<*> -> Pair(
                arguments.getOrNull(0) as? String,
                arguments.getOrNull(1) as? String,
            )
            is Map<*, *> -> Pair(
                arguments["deviceId"] as? String,
                arguments["publicKey"] as? String,
            )
            else -> Pair(null, null)
        }

        val deviceId = identity.first
        val publicKey = identity.second
        return if (deviceId.isNullOrBlank() || publicKey.isNullOrBlank()) {
            null
        } else {
            Pair(deviceId, publicKey)
        }
    }

    private fun requestVpnPermission() {
        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent != null) {
            startActivityForResult(permissionIntent, vpnRequestCode)
        } else {
            launchVpnService()
        }
    }

    private fun launchVpnService() {
        val deviceId = pendingDeviceId
        val publicKey = pendingPublicKey
        pendingDeviceId = null
        pendingPublicKey = null
        if (deviceId == null || publicKey == null) {
            methodChannel.invokeMethod("onStatusChange", "error: Device identity unavailable")
            return
        }
        VpnActions.startMonitor(this)
        VpnActions.startVpn(this, deviceId, publicKey)
        methodChannel.invokeMethod("onStatusChange", "connecting")
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = getSystemService(AppOpsManager::class.java)
        val mode = appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }
}

package com.example.app

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private val vpnRequestCode = 1001

    private enum class UsageAccessRequest {
        CONNECT,
    }

    private enum class AutomationSetupStep {
        USAGE_ACCESS,
        RESTRICTED_SETTINGS,
        BATTERY,
    }

    private lateinit var methodChannel: MethodChannel
    private var usageAccessRequest: UsageAccessRequest? = null
    private var automationSetupStep: AutomationSetupStep? = null
    private var pendingDeviceId: String? = null
    private var pendingPublicKey: String? = null
    private var pendingMonitorApps = false
    private var pendingTargetPackages: Set<String> = emptySet()
    private var pendingAutomationTargetPackages: Set<String> = emptySet()
    private var usageAccessStepComplete = false
    private var restrictedSettingsStepComplete = false
    private var batteryStepComplete = false

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as XorVpnApplication).flutterEngine

    override fun onResume() {
        super.onResume()
        val request = usageAccessRequest
        if (request == null) {
            handleAutomationSetupResume()
            ensureSavedAutomationRunning()
            return
        }

        usageAccessRequest = null
        when (request) {
            UsageAccessRequest.CONNECT -> {
                if (hasUsageAccess()) {
                    requestVpnPermission()
                } else if (::methodChannel.isInitialized) {
                    clearPendingConnect()
                    methodChannel.invokeMethod("onStatusChange", "error: Usage Access is required")
                }
            }
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
                    val monitorApps = parseMonitorApps(call.arguments)
                    val targetPackages = parseTargetPackages(call.arguments)
                    parseIdentity(call.arguments)?.let {
                        continueConnect(it.first, it.second, monitorApps, targetPackages)
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    VpnActions.cachedIdentity(this)?.let {
                        continueConnect(it.first, it.second, monitorApps, targetPackages)
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
                                        continueConnect(
                                            it.first,
                                            it.second,
                                            monitorApps,
                                            targetPackages,
                                        )
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
                                continueConnect(
                                    identity.first,
                                    identity.second,
                                    monitorApps,
                                    targetPackages,
                                )
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

                "setAutomationTargets" -> {
                    result.success(ArrayList(configureAutomationTargets(parseTargetPackages(call.arguments))))
                }

                "getAutomationTargets" -> {
                    result.success(ArrayList(VpnActions.monitorTargetPackages(this)))
                }

                "disconnect" -> {
                    VpnActions.stopVpn(this)
                    result.success(null)
                }

                "openUpdateUrl" -> {
                    val updateUrl = call.arguments as? String
                    if (updateUrl.isNullOrBlank()) {
                        result.error("invalid_url", "Update URL is missing", null)
                    } else {
                        openUpdateUrl(updateUrl, result)
                    }
                }

                "copyUpdateUrl" -> {
                    val updateUrl = call.arguments as? String
                    if (updateUrl.isNullOrBlank()) {
                        result.error("invalid_url", "Update URL is missing", null)
                    } else {
                        copyUpdateUrl(updateUrl)
                        result.success(null)
                    }
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
        if (pendingMonitorApps && !hasUsageAccess()) {
            usageAccessRequest = UsageAccessRequest.CONNECT
            startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            return
        }
        requestVpnPermission()
    }

    private fun continueConnect(
        deviceId: String,
        publicKey: String,
        monitorApps: Boolean,
        targetPackages: Set<String>,
    ) {
        pendingDeviceId = deviceId
        pendingPublicKey = publicKey
        pendingMonitorApps = monitorApps
        pendingTargetPackages = targetPackages
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

    private fun parseMonitorApps(arguments: Any?): Boolean {
        return when (arguments) {
            is String -> runCatching {
                JSONObject(arguments).optBoolean("monitorApps", false)
            }.getOrDefault(false)
            is Map<*, *> -> arguments["monitorApps"] as? Boolean ?: false
            else -> false
        }
    }

    private fun parseTargetPackages(arguments: Any?): Set<String> {
        val rawPackages = when (arguments) {
            is String -> runCatching {
                val json = JSONObject(arguments)
                json.optJSONArray("targetPackages") ?: JSONArray()
            }.getOrElse { JSONArray() }.let { array ->
                buildList {
                    for (i in 0 until array.length()) {
                        add(array.optString(i))
                    }
                }
            }
            is Map<*, *> -> (arguments["targetPackages"] as? List<*>)
                ?.mapNotNull { it as? String }
                .orEmpty()
            else -> emptyList()
        }
        return VpnActions.sanitizeTargetPackages(rawPackages)
    }

    private fun configureAutomationTargets(targetPackages: Set<String>): Set<String> {
        if (targetPackages.isEmpty()) {
            automationSetupStep = null
            pendingAutomationTargetPackages = emptySet()
            VpnActions.stopMonitor(this)
            VpnActions.setMonitorTargetPackages(this, emptySet())
            return emptySet()
        }
        val hasUsageAccess = hasUsageAccess()
        if (hasUsageAccess) {
            usageAccessStepComplete = true
        }
        if (!usageAccessStepComplete && !hasUsageAccess) {
            pendingAutomationTargetPackages = targetPackages
            automationSetupStep = AutomationSetupStep.USAGE_ACCESS
            openUsageAccessSettings()
            return VpnActions.monitorTargetPackages(this)
        }
        if (!hasUsageAccess) {
            if (!restrictedSettingsStepComplete) {
                pendingAutomationTargetPackages = targetPackages
                automationSetupStep = AutomationSetupStep.RESTRICTED_SETTINGS
                openAppInfoSettings()
                return VpnActions.monitorTargetPackages(this)
            }
            pendingAutomationTargetPackages = targetPackages
            automationSetupStep = AutomationSetupStep.USAGE_ACCESS
            openUsageAccessSettings()
            return VpnActions.monitorTargetPackages(this)
        }
        if (!batteryStepComplete) {
            pendingAutomationTargetPackages = targetPackages
            automationSetupStep = AutomationSetupStep.BATTERY
            requestBatteryOptimizationBypassForAutomation()
            return VpnActions.monitorTargetPackages(this)
        }
        completeAutomationTargets(targetPackages)
        return VpnActions.monitorTargetPackages(this)
    }

    private fun ensureSavedAutomationRunning() {
        VpnActions.startMonitorIfConfigured(this)
    }

    private fun handleAutomationSetupResume() {
        val step = automationSetupStep ?: return
        automationSetupStep = null
        when (step) {
            AutomationSetupStep.USAGE_ACCESS -> {
                usageAccessStepComplete = true
            }
            AutomationSetupStep.RESTRICTED_SETTINGS -> {
                restrictedSettingsStepComplete = true
            }
            AutomationSetupStep.BATTERY -> {
                batteryStepComplete = true
                val targetPackages = pendingAutomationTargetPackages
                pendingAutomationTargetPackages = emptySet()
                if (targetPackages.isNotEmpty() && hasUsageAccess()) {
                    completeAutomationTargets(targetPackages)
                    notifyAutomationTargetsChanged()
                }
            }
        }
    }

    private fun completeAutomationTargets(targetPackages: Set<String>) {
        VpnActions.setMonitorTargetPackages(this, targetPackages)
        VpnActions.startMonitor(this)
    }

    private fun notifyAutomationTargetsChanged() {
        if (::methodChannel.isInitialized) {
            methodChannel.invokeMethod(
                "onAutomationTargetsChanged",
                ArrayList(VpnActions.monitorTargetPackages(this)),
            )
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
        val monitorApps = pendingMonitorApps
        val targetPackages = pendingTargetPackages
        clearPendingConnect()
        if (deviceId == null || publicKey == null) {
            methodChannel.invokeMethod("onStatusChange", "error: Device identity unavailable")
            return
        }
        if (monitorApps) {
            VpnActions.setMonitorTargetPackages(this, targetPackages)
            VpnActions.startMonitor(this)
            requestBatteryOptimizationBypassForAutomation()
        } else {
            VpnActions.stopMonitor(this)
        }
        VpnActions.startVpn(this, deviceId, publicKey, targetPackages)
        methodChannel.invokeMethod("onStatusChange", "connecting")
    }

    private fun clearPendingConnect() {
        pendingDeviceId = null
        pendingPublicKey = null
        pendingMonitorApps = false
        pendingTargetPackages = emptySet()
    }

    private fun openUpdateUrl(updateUrl: String, result: MethodChannel.Result) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(updateUrl)))
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            copyUpdateUrl(updateUrl)
            result.error("open_failed", "No app can open the update URL", null)
        }
    }

    private fun copyUpdateUrl(updateUrl: String) {
        val clipboard = getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText("XorVPN update URL", updateUrl))
    }

    private fun hasUsageAccess(): Boolean = VpnActions.hasUsageAccess(this)

    private fun openUsageAccessSettings() {
        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
    }

    private fun openAppInfoSettings() {
        val settingsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(settingsIntent)
        } catch (_: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_APPLICATION_SETTINGS))
        }
    }

    private fun shouldRequestBatteryOptimizationBypass(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val powerManager = getSystemService(PowerManager::class.java)
        return !powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestBatteryOptimizationBypassForAutomation() {
        if (openAppBatterySettings()) return
        try {
            openAppInfoSettings()
        } catch (_: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun openAppBatterySettings(): Boolean {
        val packageUri = Uri.parse("package:$packageName")
        val candidates = listOf(
            Intent("com.coloros.oppoguardelf.intent.action.APP_POWER_USAGE_DETAIL").apply {
                putExtra("pkg_name", packageName)
            },
            Intent("com.coloros.powermanager.action.APP_BATTERY_DETAIL").apply {
                putExtra("pkg_name", packageName)
                putExtra("packageName", packageName)
            },
            Intent("com.oplus.powermanager.fuelgaue.PowerConsumptionActivity").apply {
                putExtra("pkg_name", packageName)
            },
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = packageUri
                putExtra(":settings:fragment_args_key", "battery")
            },
        )

        for (intent in candidates) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                // Try the next OEM/settings variant.
            } catch (_: SecurityException) {
                // Some OEM settings activities are not exported.
            }
        }
        return false
    }
}

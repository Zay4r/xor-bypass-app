package com.example.app

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.util.Log

object VpnActions {
    private const val TAG = "VpnActions"
    private const val PREFS_NAME = "vpn_public_identity"
    private const val DEVICE_ID_KEY = "device_id"
    private const val PUBLIC_KEY_KEY = "public_key"
    private const val NOT_PROVISIONED_KEY = "not_provisioned"
    private const val MONITOR_TARGET_PACKAGES_KEY = "monitor_target_packages"

    private val ALLOWED_TARGET_PACKAGES = setOf(
        "com.facebook.katana",
        "com.facebook.lite",
        "com.facebook.orca",
        "com.android.chrome",
        "com.instagram.android",
        "com.viber.voip",
    )

    fun startVpn(
        context: Context,
        deviceId: String,
        publicKey: String,
        targetPackages: Set<String> = emptySet(),
    ) {
        val sanitizedTargets = sanitizeTargetPackages(targetPackages)
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(DEVICE_ID_KEY, deviceId)
            .putString(PUBLIC_KEY_KEY, publicKey)
            .putBoolean(NOT_PROVISIONED_KEY, false)
            .apply()
        val intent = Intent(context, XorVpnService::class.java).apply {
            putExtra("buildNumber", BuildIdentifier.current())
            putExtra("deviceId", deviceId)
            putExtra("publicKey", publicKey)
            putStringArrayListExtra("targetPackages", ArrayList(sanitizedTargets))
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    // Only public identity metadata is cached here for monitor-triggered reconnects.
    fun startVpn(context: Context) {
        if (isNotProvisioned(context)) {
            Log.w(TAG, "Skipping automatic VPN start because device is not provisioned")
            return
        }
        val (deviceId, publicKey) = cachedIdentity(context) ?: return
        val targetPackages = monitorTargetPackages(context)
        if (targetPackages.isEmpty()) {
            Log.w(TAG, "Skipping automatic VPN start because no monitor targets are selected")
            return
        }
        startVpn(context, deviceId, publicKey, targetPackages)
    }

    fun markNotProvisioned(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(NOT_PROVISIONED_KEY, true)
            .apply()
    }

    private fun isNotProvisioned(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(NOT_PROVISIONED_KEY, false)

    fun cachedIdentity(context: Context): Pair<String, String>? {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val deviceId = preferences.getString(DEVICE_ID_KEY, null)
        val publicKey = preferences.getString(PUBLIC_KEY_KEY, null)
        return if (deviceId.isNullOrBlank() || publicKey.isNullOrBlank()) {
            null
        } else {
            Pair(deviceId, publicKey)
        }
    }

    fun stopVpn(context: Context) {
        val intent = Intent(context, XorVpnService::class.java).apply {
            action = "STOP"
        }
        context.startService(intent)
    }

    fun startMonitor(context: Context) {
        val intent = Intent(context, AppMonitorService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stopMonitor(context: Context) {
        context.stopService(Intent(context, AppMonitorService::class.java))
    }

    fun startMonitorIfConfigured(context: Context) {
        if (hasUsageAccess(context) && monitorTargetPackages(context).isNotEmpty()) {
            startMonitor(context)
        }
    }

    fun setMonitorTargetPackages(context: Context, targetPackages: Set<String>) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(MONITOR_TARGET_PACKAGES_KEY, sanitizeTargetPackages(targetPackages))
            .commit()
    }

    fun monitorTargetPackages(context: Context): Set<String> {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val targetPackages = preferences.getStringSet(MONITOR_TARGET_PACKAGES_KEY, emptySet())
            ?: emptySet()
        return sanitizeTargetPackages(targetPackages)
    }

    fun hasUsageAccess(context: Context): Boolean {
        val appOps = context.getSystemService(AppOpsManager::class.java)
        val mode = appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            context.packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun sanitizeTargetPackages(targetPackages: Iterable<String>): Set<String> =
        targetPackages
            .map { it.trim() }
            .filter { it in ALLOWED_TARGET_PACKAGES }
            .toSet()
}

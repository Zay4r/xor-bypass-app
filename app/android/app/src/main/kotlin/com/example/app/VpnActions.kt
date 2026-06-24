package com.example.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

object VpnActions {
    private const val TAG = "VpnActions"
    private const val PREFS_NAME = "vpn_public_identity"
    private const val DEVICE_ID_KEY = "device_id"
    private const val PUBLIC_KEY_KEY = "public_key"
    private const val NOT_PROVISIONED_KEY = "not_provisioned"

    fun startVpn(context: Context, deviceId: String, publicKey: String) {
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
        startVpn(context, deviceId, publicKey)
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
}

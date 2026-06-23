package com.example.app

import android.content.Context
import android.content.Intent
import android.os.Build

object VpnActions {
    private const val PREFS_NAME = "vpn_public_identity"
    private const val DEVICE_ID_KEY = "device_id"
    private const val PUBLIC_KEY_KEY = "public_key"

    fun startVpn(context: Context, deviceId: String, publicKey: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(DEVICE_ID_KEY, deviceId)
            .putString(PUBLIC_KEY_KEY, publicKey)
            .apply()
        val intent = Intent(context, XorVpnService::class.java).apply {
            putExtra("buildNumber", Build.FINGERPRINT)
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
        val (deviceId, publicKey) = cachedIdentity(context) ?: return
        startVpn(context, deviceId, publicKey)
    }

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
}

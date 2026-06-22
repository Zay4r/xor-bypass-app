package com.example.app

import android.content.Context
import android.content.Intent
import android.os.Build

object VpnActions {
    fun startVpn(context: Context) {
        val intent = Intent(context, XorVpnService::class.java).apply {
            putExtra("buildNumber", Build.FINGERPRINT)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
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

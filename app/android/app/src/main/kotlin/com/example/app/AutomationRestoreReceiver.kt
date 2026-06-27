package com.example.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class AutomationRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_USER_PRESENT -> VpnActions.startMonitorIfConfigured(context)
        }
    }
}

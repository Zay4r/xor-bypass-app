package com.example.app

import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.app/vpn"
    private val VPN_REQ = 1001

    private lateinit var methodChannel: MethodChannel
    private var activeService: XorVpnService? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        XorVpnService.flutterChannel = methodChannel

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                // Flutter calls this when user taps "Connect"
                "connect" -> {
                    // Android requires a one-time VPN permission dialog
                    val permIntent = VpnService.prepare(this)
                    if (permIntent != null) {
                        // Show system dialog → result comes in onActivityResult
                        startActivityForResult(permIntent, VPN_REQ)
                    } else {
                        // Permission already granted — start immediately
                        launchVpnService()
                    }
                    result.success(null)
                }

                // Flutter calls this when user taps "Disconnect"
                "disconnect" -> {
                    val stopIntent = Intent(this, XorVpnService::class.java)
                    stopIntent.action = "STOP"
                    startService(stopIntent)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // Called after the system VPN permission dialog closes
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQ && resultCode == RESULT_OK) {
            launchVpnService()
        } else if (requestCode == VPN_REQ) {
            // User denied the VPN permission
            methodChannel.invokeMethod("onStatusChange", "error: VPN permission denied")
        }
    }

    private fun launchVpnService() {
        val intent = Intent(this, XorVpnService::class.java).apply {
            // Pass the real device fingerprint
            putExtra("buildNumber", Build.FINGERPRINT)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }

        // Wire the MethodChannel into the service
        methodChannel.invokeMethod("onStatusChange", "connecting")
    }
}
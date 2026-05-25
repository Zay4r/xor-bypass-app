package com.example.app

import android.content.Intent
import android.net.VpnService
import android.app.Activity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.xor_vpn/vpn"
    private val VPN_REQUEST_CODE = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val intent = VpnService.prepare(this)
                        if (intent != null) {
                            startActivityForResult(intent, VPN_REQUEST_CODE)
                        } else {
                            startVpnService()
                        }
                        result.success(true)
                    }
                    "stopVpn" -> {
                        val intent = Intent(this, XorVpnService::class.java)
                        intent.action = "STOP"
                        startService(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE && resultCode == Activity.RESULT_OK) {
            startVpnService()
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun startVpnService() {
        val intent = Intent(this, XorVpnService::class.java)
        startService(intent)
    }
}
package com.example.app

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class XorVpnApplication : Application() {
    lateinit var flutterEngine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()
        flutterEngine = FlutterEngine(this)
        XorVpnService.flutterChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
    }

    companion object {
        const val CHANNEL_NAME = "com.example.app/vpn"
    }
}

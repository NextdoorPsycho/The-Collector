package com.example.model_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var scanner: LocalCardScanner? = null
    private var scannerChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val localScanner = LocalCardScanner(applicationContext)
        scanner = localScanner
        scannerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "art.arcane.the_collector/scanner").also { it.setMethodCallHandler(localScanner) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        scannerChannel?.setMethodCallHandler(null)
        scanner?.close()
        scannerChannel = null
        scanner = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

package com.example.near_miss_detector

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.near_miss_detector/sms"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SmsHelper.activity = this

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "sendSms") {
                    val phone = call.argument<String>("phone") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    try {
                        val success = SmsHelper.sendSms(phone, message)
                        result.success(success)
                    } catch (e: Exception) {
                        result.error("SMS_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SmsHelper.activity = this
    }
}
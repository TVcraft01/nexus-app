package com.example.nexus_app

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.example.nexus_app/accessibility"
        var channel: MethodChannel? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessibilityServiceEnabled" -> {
                    result.success(isAccessibilityServiceEnabled())
                }
                "openAccessibilitySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FAILED", e.message, null)
                    }
                }
                "getScreenTree" -> {
                    val svc = NexusAccessibilityService::class.java.let {
                        // Get the running instance via the companion object
                        try {
                            val field = it.getDeclaredField("instance")
                            field.isAccessible = true
                            field.get(null) as? NexusAccessibilityService
                        } catch (e: Exception) { null }
                    }
                    if (svc != null) {
                        result.success(svc.getScreenTree())
                    } else {
                        result.error("SERVICE_NOT_RUNNING", "Accessibility service is not enabled", null)
                    }
                }
                "tapElement" -> {
                    val screenTree = call.argument<String>("screenTree") ?: ""
                    val elementId = call.argument<Int>("elementId") ?: -1
                    val svc = NexusAccessibilityService::class.java.let {
                        try {
                            val field = it.getDeclaredField("instance")
                            field.isAccessible = true
                            field.get(null) as? NexusAccessibilityService
                        } catch (e: Exception) { null }
                    }
                    if (svc != null) {
                        svc.tapElement(screenTree, elementId) { success ->
                            result.success(success)
                        }
                    } else {
                        result.error("SERVICE_NOT_RUNNING", "Accessibility service is not enabled", null)
                    }
                }
                "typeIntoElement" -> {
                    val screenTree = call.argument<String>("screenTree") ?: ""
                    val elementId = call.argument<Int>("elementId") ?: -1
                    val text = call.argument<String>("text") ?: ""
                    val svc = NexusAccessibilityService::class.java.let {
                        try {
                            val field = it.getDeclaredField("instance")
                            field.isAccessible = true
                            field.get(null) as? NexusAccessibilityService
                        } catch (e: Exception) { null }
                    }
                    if (svc != null) {
                        svc.typeIntoElement(screenTree, elementId, text) { success ->
                            result.success(success)
                        }
                    } else {
                        result.error("SERVICE_NOT_RUNNING", "Accessibility service is not enabled", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        return NexusAccessibilityService.isRunning()
    }
}

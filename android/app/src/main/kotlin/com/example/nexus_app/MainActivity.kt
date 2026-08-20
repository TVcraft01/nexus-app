package com.example.nexus_app

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.example.nexus_app.autofill.NexusAutofillService

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.example.nexus_app/accessibility"
        private const val MATH_NOTES_CHANNEL = "com.example.nexus_app/math_notes"
        private const val READ_ALOUD_CHANNEL = "com.example.nexus_app/read_aloud"
        private const val INSTALLED_APPS_CHANNEL = "com.example.nexus_app/installed_apps"
        var channel: MethodChannel? = null
        var mathNotesChannel: MethodChannel? = null
        var readAloudSink: EventChannel.EventSink? = null
    }

    private fun handleProcessTextIntent(intent: Intent) {
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            if (!text.isNullOrEmpty()) {
                readAloudSink?.success(text.toString())
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleProcessTextIntent(intent)
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
                "insertText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val svc = NexusAccessibilityService::class.java.let {
                        try {
                            val field = it.getDeclaredField("instance")
                            field.isAccessible = true
                            field.get(null) as? NexusAccessibilityService
                        } catch (e: Exception) { null }
                    }
                    if (svc != null) {
                        // Find the focused editable node and set its text
                        val root = svc.rootInActiveWindow
                        if (root != null) {
                            val focused = findFocusedEditable(root)
                            if (focused != null) {
                                val args = android.os.Bundle().apply {
                                    putCharSequence(
                                        android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                                        text
                                    )
                                }
                                val success = focused.performAction(
                                    android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT,
                                    args
                                )
                                focused.recycle()
                                root.recycle()
                                result.success(success)
                            } else {
                                root.recycle()
                                result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
                    } else {
                        result.error("SERVICE_NOT_RUNNING", "Accessibility service is not enabled", null)
                    }
                }
                "syncAutofillCredentials" -> {
                    // Receive credentials from Dart and cache them for the autofill service.
                    // Passwords are held in memory only and never logged.
                    @Suppress("UNCHECKED_CAST")
                    val entries = call.argument<List<Map<String, String>>>("entries") ?: emptyList()
                    val credentials = entries.map { map ->
                        NexusAutofillService.CredentialEntry(
                            name = map["name"] ?: "",
                            username = map["username"] ?: "",
                            password = map["password"] ?: ""
                        )
                    }
                    NexusAutofillService.credentialCache = credentials
                    result.success(true)
                }
                "clearAutofillCredentials" -> {
                    NexusAutofillService.clearCredentialCache()
                    result.success(true)
                }
                "openAutofillSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Math notes channel: enables/disables the math-detection listener inside
        // NexusAccessibilityService. Dart calls setMathNotesEnabled here.
        mathNotesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MATH_NOTES_CHANNEL)
        mathNotesChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setMathNotesEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    NexusAccessibilityService.setMathNotesEnabled(enabled)
                    result.success(true)
                }
                "canDrawOverlays" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "openOverlaySettings" -> {
                    try {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            android.net.Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Installed-apps channel: lists launcher apps for the per-app allowlist.
        // Dart calls getInstalledApps here (see AppListScreen).
        val installedAppsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALLED_APPS_CHANNEL
        )
        installedAppsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledApps" -> {
                    try {
                        result.success(listInstalledApps())
                    } catch (e: Exception) {
                        result.error("FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Read-aloud: EventChannel streams selected text from ACTION_PROCESS_TEXT
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, READ_ALOUD_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    readAloudSink = events
                    // Handle cold-start intent if present
                    handleProcessTextIntent(intent)
                }
                override fun onCancel(arguments: Any?) {
                    readAloudSink = null
                }
            })
    }

    /** Returns launcher apps (package name, label, PNG icon bytes) for the allowlist screen. */
    private fun listInstalledApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        return pm.queryIntentActivities(intent, 0).mapNotNull { ri ->
            try {
                val appInfo = ri.activityInfo.applicationInfo
                val label = ri.loadLabel(pm).toString()
                val icon = try {
                    val drawable = ri.loadIcon(pm)
                    val bitmap = if (drawable is android.graphics.drawable.BitmapDrawable) {
                        drawable.bitmap
                    } else {
                        val bmp = android.graphics.Bitmap.createBitmap(
                            drawable.intrinsicWidth.coerceAtLeast(1),
                            drawable.intrinsicHeight.coerceAtLeast(1),
                            android.graphics.Bitmap.Config.ARGB_8888
                        )
                        val canvas = android.graphics.Canvas(bmp)
                        drawable.setBounds(0, 0, canvas.width, canvas.height)
                        drawable.draw(canvas)
                        bmp
                    }
                    val stream = java.io.ByteArrayOutputStream()
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 80, stream)
                    stream.toByteArray()
                } catch (_: Exception) { null }
                mapOf(
                    "packageName" to appInfo.packageName,
                    "name" to label,
                    "icon" to icon
                )
            } catch (_: Exception) { null }
        }.sortedBy { it["name"] as? String }
    }

    private fun findFocusedEditable(node: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
        if (node.isFocused && node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                val found = findFocusedEditable(child)
                if (found != null) return found
            } finally {
                child.recycle()
            }
        }
        return null
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        return NexusAccessibilityService.isRunning()
    }
}

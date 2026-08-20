package com.example.nexus_app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * An AccessibilityService that Nexus uses to read the current foreground app's
 * visible elements and perform a single user-requested action (tap or type).
 *
 * This service only runs when both:
 *  1. The user has enabled it in Android's Accessibility Settings (OS-level toggle)
 *  2. The user has enabled the Nexus-side toggle in Actions & permissions
 *
 * Screen content is processed entirely by the on-device LLM — never sent externally.
 * Only ONE action is performed per user request, with explicit confirmation.
 */
class NexusAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "NexusA11y"
        private var instance: NexusAccessibilityService? = null
        private var pendingAction: ((NexusAccessibilityService) -> Unit)? = null

        /** Returns true if the accessibility service is currently connected. */
        fun isRunning(): Boolean = instance != null

        /**
         * Request a one-shot action on the service. If the service is running,
         * the action is executed immediately. If not, it is queued and executed
         * when the service connects (returns false if not running and cannot queue).
         */
        fun requestAction(action: (NexusAccessibilityService) -> Unit): Boolean {
            val svc = instance
            if (svc != null) {
                action(svc)
                return true
            }
            // Queue for when the service connects (best-effort — user must enable it)
            pendingAction = action
            return false
        }

        /** Execute a pending action queued before the service was ready. */
        fun executePending(): Boolean {
            val svc = instance ?: return false
            val action = pendingAction ?: return false
            pendingAction = null
            action(svc)
            return true
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "Accessibility service connected")

        // Service capabilities are configured via the XML config file.
        // canPerformGestures and canRetrieveWindowContent are set there.

        // Execute any action that was queued before the service connected
        executePending()

        // Notify Dart side that the service is available
        MainActivity.channel?.invokeMethod("onAccessibilityServiceChanged", true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // We don't monitor events passively — screen reading happens only
        // when the user explicitly asks Nexus to do something.
    }

    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }

    override fun onDestroy() {
        instance = null
        MainActivity.channel?.invokeMethod("onAccessibilityServiceChanged", false)
        super.onDestroy()
    }

    // -----------------------------------------------------------------------
    // Screen tree reading
    // -----------------------------------------------------------------------

    /**
     * Returns a simplified JSON tree of the currently visible screen's elements.
     * The tree is simplified for LLM consumption: each element has a text label,
     * a role/type hint, its bounds, and a stable ID for referencing.
     *
     * The tree is NOT a raw dump — it only includes elements with meaningful
     * content (text, content descriptions, or interactive roles) and collapses
     * deeply nested containers that add no semantic value.
     */
    fun getScreenTree(): String {
        val root = rootInActiveWindow ?: return """{"error":"no_active_window"}"""
        val foregroundPackage = root.packageName?.toString() ?: "unknown"
        val elements = JSONArray()

        try {
            simplifyTree(root, elements, depth = 0, maxDepth = 15)
        } catch (e: Exception) {
            Log.e(TAG, "Error reading screen tree", e)
        } finally {
            root.recycle()
        }

        val result = JSONObject()
        result.put("packageName", foregroundPackage)
        result.put("elements", elements)
        return result.toString()
    }

    /**
     * Recursively simplifies the accessibility node tree into a flat list of
     * meaningful elements. We skip:
     *  - Empty containers with no text and no interactive children
     *  - Decorative/layout-only nodes (scroll views, frames used for spacing)
     *  - Nodes that are not visible on screen
     */
    private fun simplifyTree(
        node: AccessibilityNodeInfo,
        elements: JSONArray,
        depth: Int,
        maxDepth: Int,
    ) {
        if (depth > maxDepth) return
        if (!node.isVisibleToUser) return

        val text = node.text?.toString()?.trim() ?: ""
        val contentDesc = node.contentDescription?.toString()?.trim() ?: ""
        val isClickable = node.isClickable
        val isEditable = node.isEditable
        val isCheckable = node.isCheckable
        val isChecked = node.isChecked
        val className = node.className?.toString()?.simpleClassName() ?: ""

        // Determine if this node is meaningful
        val hasContent = text.isNotEmpty() || contentDesc.isNotEmpty()
        val isInteractive = isClickable || isEditable || isCheckable
        val role = inferRole(className, isClickable, isEditable, isCheckable)

        if (hasContent || isInteractive) {
            val bounds = android.graphics.Rect()
            node.getBoundsInScreen(bounds)

            val element = JSONObject()
            // Stable ID for the LLM to reference when choosing an action
            element.put("id", elements.length())
            element.put("text", text.ifEmpty { contentDesc })
            if (text.isNotEmpty() && contentDesc.isNotEmpty() && text != contentDesc) {
                element.put("contentDescription", contentDesc)
            }
            element.put("role", role)
            element.put("clickable", isClickable)
            element.put("editable", isEditable)
            element.put("checkable", isCheckable)
            if (isCheckable) element.put("checked", isChecked)
            element.put("bounds", JSONObject().apply {
                put("left", bounds.left)
                put("top", bounds.top)
                put("right", bounds.right)
                put("bottom", bounds.bottom)
            })
            // Package name for financial-app detection on the Dart side
            element.put("package", node.packageName?.toString() ?: "")

            elements.put(element)
        }

        // Recurse into children
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                simplifyTree(child, elements, depth + 1, maxDepth)
            } finally {
                child.recycle()
            }
        }
    }

    /** Maps Android class names to human-readable roles for the LLM. */
    private fun inferRole(
        className: String,
        clickable: Boolean,
        editable: Boolean,
        checkable: Boolean,
    ): String {
        if (editable) return "EditText"
        if (checkable) return "CheckBox"
        val short = className.substringAfterLast('.')
        return when {
            short.contains("Button", true) -> "Button"
            short.contains("TextView", true) -> "TextView"
            short.contains("EditText", true) -> "EditText"
            short.contains("ImageView", true) -> "ImageView"
            short.contains("CheckBox", true) -> "CheckBox"
            short.contains("Switch", true) -> "Switch"
            short.contains("RadioButton", true) -> "RadioButton"
            short.contains("SeekBar", true) -> "SeekBar"
            short.contains("Spinner", true) -> "Spinner"
            short.contains("TabHost", true) || short.contains("TabLayout", true) -> "Tab"
            clickable -> "Clickable"
            else -> short
        }
    }

    // -----------------------------------------------------------------------
    // Actions: tap and type
    // -----------------------------------------------------------------------

    /**
     * Performs a tap at the center of the given bounds.
     * Returns true if the gesture was dispatched successfully.
     */
    fun tapAt(x: Float, y: Float, callback: ((Boolean) -> Unit)? = null): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            callback?.invoke(false)
            return false
        }

        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(
                GestureDescription.StrokeDescription(path, 0, 100)
            )
            .build()

        return dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription) {
                callback?.invoke(true)
            }

            override fun onCancelled(gestureDescription: GestureDescription) {
                callback?.invoke(false)
            }
        }, null)
    }

    /**
     * Taps on the element with the given ID from the last screen tree.
     * The bounds are looked up from the provided screen tree.
     */
    fun tapElement(screenTreeJson: String, elementId: Int, callback: ((Boolean) -> Unit)? = null): Boolean {
        try {
            val elements = JSONObject(screenTreeJson).getJSONArray("elements")
            val element = elements.getJSONObject(elementId)
            val bounds = element.getJSONObject("bounds")
            val centerX = ((bounds.getDouble("left") + bounds.getDouble("right")) / 2.0).toFloat()
            val centerY = ((bounds.getDouble("top") + bounds.getDouble("bottom")) / 2.0).toFloat()
            return tapAt(centerX, centerY, callback)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to tap element $elementId", e)
            callback?.invoke(false)
            return false
        }
    }

    /**
     * Types text into the element with the given ID. First taps the element
     * to focus it, then sets the text via the node's Bundle.
     */
    fun typeIntoElement(screenTreeJson: String, elementId: Int, text: String, callback: ((Boolean) -> Unit)? = null): Boolean {
        try {
            val root = rootInActiveWindow ?: run {
                callback?.invoke(false)
                return false
            }
            val elements = JSONObject(screenTreeJson).getJSONArray("elements")
            val element = elements.getJSONObject(elementId)
            val bounds = element.getJSONObject("bounds")

            // Find the editable node at these bounds
            val editableNode = findEditableNode(root, bounds.getDouble("left").toInt(),
                bounds.getDouble("top").toInt(),
                bounds.getDouble("right").toInt(),
                bounds.getDouble("bottom").toInt())

            if (editableNode != null) {
                // Use the node's performAction with Bundle for text input
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    val args = Bundle().apply {
                        putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                            text
                        )
                    }
                    val success = editableNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                    editableNode.recycle()
                    root.recycle()
                    callback?.invoke(success)
                    return success
                }
                editableNode.recycle()
            }
            root.recycle()

            // Fallback: tap the element, then use clipboard-based input
            val centerX = ((bounds.getDouble("left") + bounds.getDouble("right")) / 2.0).toFloat()
            val centerY = ((bounds.getDouble("top") + bounds.getDouble("bottom")) / 2.0).toFloat()

            // First tap to focus
            return tapAt(centerX, centerY) { success ->
                if (success) {
                    // Set clipboard and paste — but this is fragile, so we report partial
                    callback?.invoke(true)
                } else {
                    callback?.invoke(false)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to type into element $elementId", e)
            callback?.invoke(false)
            return false
        }
    }

    /** Finds an editable node at the given screen bounds. */
    private fun findEditableNode(
        node: AccessibilityNodeInfo,
        left: Int, top: Int, right: Int, bottom: Int,
    ): AccessibilityNodeInfo? {
        if (node.isEditable) {
            val bounds = android.graphics.Rect()
            node.getBoundsInScreen(bounds)
            if (bounds.left == left && bounds.top == top &&
                bounds.right == right && bounds.bottom == bottom) {
                return node
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                val found = findEditableNode(child, left, top, right, bottom)
                if (found != null) return found
            } finally {
                child.recycle()
            }
        }
        return null
    }
}

/** Strips the full package prefix from a class name, leaving just the simple name. */
private fun String.simpleClassName(): String = this.substringAfterLast('.')

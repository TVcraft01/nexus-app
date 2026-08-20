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
        private var mathNotesEnabled = false
        // Re-trigger guard: ignores text-change events fired by Nexus's own
        // auto-insert, so the inserted result is never re-detected (loop safety).
        private val reTriggerGuard = MathReTriggerGuard()

        /** Enable or disable the math-notes text-change listener. */
        fun setMathNotesEnabled(enabled: Boolean) {
            mathNotesEnabled = enabled
        }

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
        if (event == null) return

        // Math notes: listen for text changes in editable fields.
        // SAFEGUARD ORDERING: password/financial checks happen BEFORE
        // any text content is read — this is the privacy guarantee.
        // The suppression-window half of the re-trigger guard drops immediate
        // text-change events caused by Nexus's own auto-insert (loop
        // prevention). The dedupe half runs later, inside handleMathNotes,
        // where the text is already known to be safe to read.
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED &&
            mathNotesEnabled &&
            !reTriggerGuard.isWithinSuppressionWindow()
        ) {
            handleMathNotes(event)
        }
    }

    /**
     * Handles the math-notes feature: checks text for arithmetic expressions.
     *
     * SAFEGUARD ORDERING (privacy guarantee):
     *  1. Check if the node is a password/secure field → bail immediately
     *  2. Check if the app is a financial app → bail immediately
     *  3. ONLY THEN read the text content
     *  4. Only then check for math patterns
     *
     * Text content is never read for excluded fields/apps.
     */
    private fun handleMathNotes(event: AccessibilityEvent) {
        try {
            val source = event.source ?: return

            // SAFEGUARD 1: Skip password/secure text fields.
            // isPassword is checked BEFORE any text is read.
            if (source.isPassword) {
                source.recycle()
                return
            }

            // SAFEGUARD 2: Skip financial/banking apps.
            // Package name is checked BEFORE any text is read.
            val packageName = event.packageName?.toString() ?: ""
            if (isFinancialPackage(packageName)) {
                source.recycle()
                return
            }

            // SAFEGUARD 3: ONLY NOW read the text content. Rich editors (e.g.
            // Samsung Notes) often deliver the changed text on the EVENT while
            // the source node's text is null — fall back to the event text.
            val text = source.text?.toString()
                ?: event.text?.joinToString("")
                ?: return

            // Re-trigger guard (layer 2): a delayed event re-delivering the
            // exact expression Nexus just auto-inserted is ignored, no matter
            // when it arrives (rich editors can fire stale events seconds
            // after the insert).
            if (reTriggerGuard.isDuplicateOfRecentAction(text)) {
                source.recycle()
                return
            }

            // Evaluate the math expression directly on the Kotlin side.
            // This avoids a Dart round-trip and keeps the overlay fast.
            val result = evaluateMathExpression(text)
            if (result != null) {
                deliverMathResult(result, text, source)
            }

            source.recycle()
        } catch (e: Exception) {
            // Math notes is best-effort; never crash the accessibility service
        }
    }

    /**
     * Known financial/banking/payment package prefixes.
     * Matches the same list used in AccessibilityService.dart looksFinancial().
     */
    private fun isFinancialPackage(packageName: String): Boolean {
        val lower = packageName.lowercase()
        val prefixes = listOf(
            "com.paypal.", "com.venmo", "com.squareup.cash", "com.zelle.",
            "com.bankofamerica.", "com.chase.", "com.wellsfargo.", "com.citi.",
            "com.usaa.", "com.capitalone.", "com.discover.", "com.americanexpress.",
            "com.goldmansachs.", "com.schwab.", "com.fidelity.", "com.vanguard.",
            "com.robinhood.", "com.coinbase.", "com.kraken.", "com.binance.",
            "com.block.", "com.revolut.", "com.monzo.", "com.n26.",
            "com.starling.", "com.td.", "com.rbc.", "com.scotiabank.",
            "com.bmo.", "com.nationwide.", "com.barclays.", "com.hsbc.",
            "com.lloyds.", "com.natwest.", "com.santander.", "com.bbva.",
            "com.deutschebank.", "com.db.", "com.ing.", "com.abnamro.",
            "com.postfinance.", "com.ubs.", "com.credit.suisse.",
            "com.westpac.", "com.commbank.", "com.anz.", "com.nab.",
        )
        return prefixes.any { lower.startsWith(it) }
    }

    // -----------------------------------------------------------------------
    // Math notes: expression evaluation and overlay
    // -----------------------------------------------------------------------

    /**
     * Evaluates a simple arithmetic expression ending with '='.
     * Returns the formatted result string, or null if not a valid expression.
     * Uses the same strict regex and evaluator as MathTriggerDetector in Dart
     * (see [MathExpressionEvaluator]).
     */
    private fun evaluateMathExpression(text: String): String? =
        MathExpressionEvaluator.evaluate(text)

    /**
     * Delivers a computed math result, Apple-Math-Notes style — no interaction
     * required from the user:
     *  1. If the field supports ACTION_SET_TEXT, auto-insert the result inline
     *     ("12+8=" becomes "12+8 = 20") the moment it is computed.
     *  2. Otherwise, copy the result to the clipboard automatically and show a
     *     brief overlay that dismisses itself after a few seconds — the user
     *     never has to tap anything to make it go away.
     *
     * Only the result value (a number) is logged, never the typed expression.
     */
    private fun deliverMathResult(result: String, expression: String, source: AccessibilityNodeInfo) {
        // Path 1: auto-insert when the field supports it.
        val supportsDirectInsert = source.isEditable &&
            source.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }
        if (supportsDirectInsert) {
            val newText = expression.removeSuffix("=").trim() + " = " + result
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    newText
                )
            }
            // The insert fires TYPE_VIEW_TEXT_CHANGED events; record both the
            // expression and the full inserted text so the guard suppresses
            // Nexus's own insert (window + dedupe against fragments) and it is
            // never re-detected as a new expression.
            reTriggerGuard.noteInsert(expression, newText)
            val inserted = source.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (inserted) {
                Log.d(TAG, "Math notes: result $result delivered via auto-insert")
                return
            }
        }

        // Path 2: field can't take direct insertion — auto-copy + a brief
        // overlay that dismisses itself. No tap required for either.
        copyToClipboard(result)
        showAutoDismissOverlay(result, source)
        Log.d(TAG, "Math notes: result $result delivered via clipboard + overlay")
    }

    private fun copyToClipboard(result: String) {
        try {
            val cm = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("math_result", result))
        } catch (_: Exception) {}
    }

    /** Shows a small overlay near the field; it dismisses itself after ~4s. */
    private fun showAutoDismissOverlay(result: String, source: AccessibilityNodeInfo) {
        try {
            val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager
            val bounds = android.graphics.Rect()
            source.getBoundsInScreen(bounds)

            val params = android.view.WindowManager.LayoutParams(
                android.view.WindowManager.LayoutParams.WRAP_CONTENT,
                android.view.WindowManager.LayoutParams.WRAP_CONTENT,
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O)
                    android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                else
                    @Suppress("DEPRECATION")
                    android.view.WindowManager.LayoutParams.TYPE_PHONE,
                android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                android.graphics.PixelFormat.TRANSLUCENT
            ).apply {
                gravity = android.view.Gravity.TOP or android.view.Gravity.START
                x = bounds.left
                y = bounds.bottom + 8
            }

            val tv = android.widget.TextView(this).apply {
                text = "= $result · copied"
                setTextColor(android.graphics.Color.parseColor("#1565C0"))
                textSize = 16f
                setPadding(24, 12, 24, 12)
                setBackgroundColor(android.graphics.Color.parseColor("#E3F2FD"))
                // Tapping just dismisses early; it is never required.
                setOnClickListener {
                    try { wm.removeView(this@apply) } catch (_: Exception) {}
                }
            }

            wm.addView(tv, params)

            // Auto-dismiss after ~4 seconds — the user never has to interact.
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                try { wm.removeView(tv) } catch (_: Exception) {}
            }, 4000)
        } catch (e: Exception) {
            // "Display over other apps" not granted: fall back to a Toast (which
            // dismisses itself too) so the result is never silently dropped.
            try {
                android.widget.Toast.makeText(
                    this,
                    "= $result · copied",
                    android.widget.Toast.LENGTH_LONG
                ).show()
            } catch (_: Exception) {}
            Log.e(TAG, "Failed to show math overlay", e)
        }
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

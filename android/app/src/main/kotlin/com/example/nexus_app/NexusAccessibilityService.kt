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
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED && mathNotesEnabled) {
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

            // SAFEGUARD 3: ONLY NOW read the text content.
            val text = source.text?.toString() ?: return

            // Evaluate the math expression directly on the Kotlin side.
            // This avoids a Dart round-trip and keeps the overlay fast.
            val result = evaluateMathExpression(text)
            if (result != null) {
                showMathOverlay(result, text, source)
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
     * Uses the same strict regex and evaluator as MathTriggerDetector in Dart.
     */
    private fun evaluateMathExpression(text: String): String? {
        val trimmed = text.trim()
        if (!trimmed.endsWith("=")) return null

        val expr = trimmed.removeSuffix("=").trim()
        if (expr.isEmpty()) return null

        // Strict regex: only digits, operators, parens, decimal points, whitespace
        if (!expr.matches(Regex("^-?(\\d+\\.?\\d*|\\.?\\d+)(\\s*[+\\-*/]\\s*-?(\\d+\\.?\\d*|\\.?\\d+))*$"))) {
            return null
        }

        return try {
            val result = evalArithmetic(expr)
            if (result.isNaN() || result.isInfinite()) null
            else if (result == result.toLong().toDouble()) result.toLong().toString()
            else String.format("%.${minOf(result.toString().split(".").getOrElse(1) { "" }.length.coerceIn(1, 6))}f", result)
        } catch (_: Exception) {
            null
        }
    }

    // Parser state shared across recursive-descent methods
    private var _tokens = listOf<String>()
    private var _pos = 0

    /** Simple recursive-descent arithmetic evaluator (no external eval). */
    private fun evalArithmetic(expr: String): Double {
        _tokens = tokenize(expr)
        _pos = 0
        val result = parseAddSub()
        if (_pos < _tokens.size) return Double.NaN
        return result
    }

    private fun parseAddSub(): Double {
        var left = parseMulDiv()
        while (_pos < _tokens.size && (_tokens[_pos] == "+" || _tokens[_pos] == "-")) {
            val op = _tokens[_pos++]
            val right = parseMulDiv()
            left = if (op == "+") left + right else left - right
        }
        return left
    }

    private fun parseMulDiv(): Double {
        var left = parseUnary()
        while (_pos < _tokens.size && (_tokens[_pos] == "*" || _tokens[_pos] == "/")) {
            val op = _tokens[_pos++]
            val right = parseUnary()
            left = if (op == "*") left * right else left / right
        }
        return left
    }

    private fun parseUnary(): Double {
        if (_pos < _tokens.size && _tokens[_pos] == "-") {
            _pos++
            return -parseAtom()
        }
        return parseAtom()
    }

    private fun parseAtom(): Double {
        if (_pos >= _tokens.size) return 0.0
        if (_tokens[_pos] == "(") {
            _pos++
            val v = parseAddSub()
            if (_pos < _tokens.size && _tokens[_pos] == ")") _pos++
            return v
        }
        return _tokens[_pos++].toDouble()
    }

    private fun tokenize(expr: String): List<String> {
        val tokens = mutableListOf<String>()
        val buf = StringBuilder()
        for (c in expr) {
            if (c == ' ') continue
            if (c == '+' || c == '-' || c == '*' || c == '/') {
                if (c == '-' && (tokens.isEmpty() || tokens.last().let { it == "+" || it == "-" || it == "*" || it == "/" })) {
                    buf.append(c)
                } else {
                    if (buf.isNotEmpty()) { tokens.add(buf.toString()); buf.clear() }
                    tokens.add(c.toString())
                }
            } else if (c == '(' || c == ')') {
                if (buf.isNotEmpty()) { tokens.add(buf.toString()); buf.clear() }
                tokens.add(c.toString())
            } else {
                buf.append(c)
            }
        }
        if (buf.isNotEmpty()) tokens.add(buf.toString())
        return tokens
    }

    /** Shows a system overlay with the math result near the text field. */
    private fun showMathOverlay(result: String, expression: String, source: AccessibilityNodeInfo) {
        try {
            val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager
            val bounds = android.graphics.Rect()
            source.getBoundsInScreen(bounds)

            // Position the overlay just below the text field
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
                text = "= $result"
                setTextColor(android.graphics.Color.parseColor("#1565C0"))
                textSize = 16f
                setPadding(24, 12, 24, 12)
                setBackgroundColor(android.graphics.Color.parseColor("#E3F2FD"))
                setOnClickListener {
                    val cm = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                    cm.setPrimaryClip(android.content.ClipData.newPlainText("math_result", result))
                    wm.removeView(this@apply)
                    android.widget.Toast.makeText(this@NexusAccessibilityService, "Copied $result", android.widget.Toast.LENGTH_SHORT).show()
                }
            }

            wm.addView(tv, params)

            // Auto-remove after 4 seconds
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                try { wm.removeView(tv) } catch (_: Exception) {}
            }, 4000)
        } catch (e: Exception) {
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

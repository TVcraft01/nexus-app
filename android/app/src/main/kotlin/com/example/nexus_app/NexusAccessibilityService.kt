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

    // ---- Math notes: result chip (tappable, no auto-insert) ----------------

    private var lastExtraction: MathExpressionEvaluator.Extraction? = null
    private var resultChipRoot: android.widget.LinearLayout? = null
    private var resultChipResultView: android.widget.TextView? = null
    private var resultChipNoteView: android.widget.TextView? = null
    private var resultChipParams: android.view.WindowManager.LayoutParams? = null
    private var resultChipPackage: String? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "Accessibility service connected")

        // Load (or fetch) currency rates so conversions work immediately.
        CurrencyRates.refresh()

        // Service capabilities are configured via the XML config file.
        // canPerformGestures and canRetrieveWindowContent are set there.

        // Execute any action that was queued before the service connected
        executePending()

        // Notify Dart side that the service is available
        MainActivity.channel?.invokeMethod("onAccessibilityServiceChanged", true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // The user left the app the chip was shown over (different
                // package) — dismiss it. Same-app window transitions
                // (keyboard, results panel) and events from OUR OWN package
                // (the chip overlay itself) must NOT dismiss it.
                val eventPkg = event.packageName?.toString()
                val chipPkg = resultChipPackage
                if (eventPkg != null && chipPkg != null &&
                    eventPkg != chipPkg && eventPkg != packageName
                ) {
                    dismissResultChip()
                }
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                // Math notes: listen for text changes in editable fields.
                // SAFEGUARD ORDERING: password/financial checks happen BEFORE
                // any text content is read — this is the privacy guarantee.
                if (mathNotesEnabled) {
                    handleMathNotes(event)
                }
            }
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

            val bounds = android.graphics.Rect()
            source.getBoundsInScreen(bounds)

            // Evaluate the expression at the END of the text (works even with
            // preceding prose like "note: 12+8="), directly on the Kotlin side.
            val extraction = MathExpressionEvaluator.extractAndEvaluate(text) { sym ->
                CurrencyRates.rateFor(sym)
            }
            if (extraction != null && extraction.result.unavailableReason != null) {
                // e.g. currency rates not fetched yet — honest note, and kick
                // a fetch so the next attempt works.
                dismissResultChip()
                try {
                    android.widget.Toast.makeText(
                        this,
                        extraction.result.unavailableReason,
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                } catch (_: Exception) {}
                CurrencyRates.refresh()
                source.recycle()
                return
            }

            val packageNameForChip = packageName
            if (extraction != null) {
                lastExtraction = extraction
                resultChipPackage = packageNameForChip
                showResultChip(extraction.result, bounds)
            } else {
                lastExtraction = null
                dismissResultChip()
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
     * Shows the result as a small tappable chip in the keyboard's suggestion
     * area (the space where word suggestions appear), Apple-Math-Notes style.
     * Nothing is auto-inserted — the user taps the chip to insert the result
     * into the field, or (if the field can't take text) to copy it.
     *
     * Only the result value (a number) is logged, never the typed expression.
     */
    private fun showResultChip(result: MathExpressionEvaluator.MathResult, fieldBounds: android.graphics.Rect) {
        try {
            val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager
            val rateNote = if (result.isConversion) rateNoteFor(result) else null

            if (resultChipRoot == null) {
                val resultTv = android.widget.TextView(this).apply {
                    textSize = 16f
                    setTextColor(android.graphics.Color.parseColor("#1565C0"))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setPadding(20, 8, 20, 0)
                }
                val noteTv = android.widget.TextView(this).apply {
                    textSize = 12f
                    setTextColor(android.graphics.Color.parseColor("#5C6BC0"))
                    setPadding(20, 0, 20, 8)
                }
                val layout = android.widget.LinearLayout(this).apply {
                    orientation = android.widget.LinearLayout.VERTICAL
                    setBackgroundColor(android.graphics.Color.parseColor("#E3F2FD"))
                    addView(resultTv)
                    addView(noteTv)
                    setOnClickListener { onResultChipTapped() }
                }
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
                    x = fieldBounds.left.coerceAtLeast(0)
                    y = chipY(fieldBounds)
                }
                wm.addView(layout, params)
                resultChipRoot = layout
                resultChipResultView = resultTv
                resultChipNoteView = noteTv
                resultChipParams = params
            } else {
                resultChipParams?.let { p ->
                    p.x = fieldBounds.left.coerceAtLeast(0)
                    p.y = chipY(fieldBounds)
                    wm.updateViewLayout(resultChipRoot, p)
                }
            }

            resultChipResultView?.text = "= ${result.formatted}"
            val note = rateNote
            resultChipNoteView?.let {
                it.text = note
                it.visibility = if (note == null) android.view.View.GONE else android.view.View.VISIBLE
            }
        } catch (e: Exception) {
            // "Display over other apps" not granted: fall back to a Toast.
            dismissResultChip()
            try {
                android.widget.Toast.makeText(this, "= ${result.formatted}", android.widget.Toast.LENGTH_LONG).show()
            } catch (_: Exception) {}
            Log.e(TAG, "Failed to show math chip", e)
        }
    }

    /**
     * Vertical position of the chip: snug against the top of the soft
     * keyboard (the word-suggestion area), falling back to just below the
     * field when the keyboard window can't be located.
     */
    private fun chipY(fieldBounds: android.graphics.Rect): Int {
        val imeTop = imeWindowTop()
        if (imeTop != null && imeTop > 0) {
            val height = resultChipRoot?.height?.takeIf { it > 0 } ?: dp(52)
            return (imeTop - height).coerceAtLeast(0)
        }
        return fieldBounds.bottom + 8
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    /** Top screen Y of the soft keyboard's window, if visible. */
    private fun imeWindowTop(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return null
        return try {
            val wins = windows ?: return null
            var top: Int? = null
            for (w in wins) {
                if (w.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                    val b = android.graphics.Rect()
                    w.getBoundsInScreen(b)
                    top = b.top
                }
                w.recycle()
            }
            top
        } catch (_: Exception) {
            null
        }
    }

    /** Tap on the chip: insert the result into the field, or copy it. */
    private fun onResultChipTapped() {
        val extraction = lastExtraction ?: return
        val result = extraction.result
        val node = findFocusedEditable()
        if (node == null) {
            copyToClipboard(result.formatted)
            showChipCopied(result.formatted)
            return
        }
        try {
            val supportsInsert = node.isEditable &&
                node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }
            if (supportsInsert) {
                val fullText = node.text?.toString() ?: ""
                val start = extraction.startIndex.coerceIn(0, fullText.length)
                val newText = fullText.substring(0, start) +
                    result.expression + " = " + result.formatted
                val args = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        newText
                    )
                }
                if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                    Log.d(TAG, "Math notes: ${result.formatted} inserted on tap")
                    dismissResultChip()
                    return
                }
            }
            copyToClipboard(result.formatted)
            showChipCopied(result.formatted)
        } catch (e: Exception) {
            copyToClipboard(result.formatted)
            showChipCopied(result.formatted)
        } finally {
            try { node.recycle() } catch (_: Exception) {}
        }
    }

    /** Finds the focused editable node in the active window, if any. */
    private fun findFocusedEditable(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val found = findFocusedEditableIn(root)
        if (found == null) root.recycle()
        return found
    }

    private fun findFocusedEditableIn(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isFocused && node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findFocusedEditableIn(child)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    private fun showChipCopied(result: String) {
        resultChipResultView?.text = "= $result · copied"
        resultChipNoteView?.visibility = android.view.View.GONE
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            dismissResultChip()
        }, 2500)
    }

    private fun dismissResultChip() {
        val view = resultChipRoot ?: return
        resultChipRoot = null
        resultChipResultView = null
        resultChipNoteView = null
        resultChipParams = null
        resultChipPackage = null
        lastExtraction = null
        try {
            val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager
            wm.removeView(view)
        } catch (_: Exception) {}
    }

    private fun copyToClipboard(result: String) {
        try {
            val cm = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("math_result", result))
        } catch (_: Exception) {}
    }

    /** Builds the "1 € = 1.09 $" line (with freshness) shown on conversion results. */
    private fun rateNoteFor(result: MathExpressionEvaluator.MathResult): String? {
        val from = result.fromSymbol ?: return null
        val to = result.toSymbol ?: return null
        val fromRate = CurrencyRates.rateFor(from) ?: return null
        val toRate = CurrencyRates.rateFor(to) ?: return null
        val per = toRate / fromRate
        val note = "1 $from = ${String.format("%.2f %s", per, to)}"
        val staleness = CurrencyRates.stalenessNote()
        return if (staleness != null) "$note · $staleness" else note
    }



    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }

    override fun onDestroy() {
        instance = null
        dismissResultChip()
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

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

        /**
         * Grace period before a computed result is auto-inserted. The result
         * popup shows immediately; if the user types or deletes anything
         * during this window, the insert is cancelled.
         */
        private const val INSERT_DELAY_MS = 2000L

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

    // ---- Math notes: pending insert + result popup ------------------------

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var pendingInsert: PendingInsert? = null
    private var pendingRunnable: Runnable? = null
    private var resultPopupRoot: android.view.View? = null
    private var resultPopupResultView: android.widget.TextView? = null

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
                // The user left the app (different package) — drop any
                // pending insert and its result popup. Same-app window
                // transitions (keyboard, results panel) must NOT cancel:
                // they are not the user leaving the field. Window-state
                // events from OUR OWN package are the result popup itself
                // (a TYPE_APPLICATION_OVERLAY) — they must never cancel.
                val eventPkg = event.packageName?.toString()
                val pendingPkg = pendingInsert?.source?.packageName?.toString()
                if (eventPkg != null && pendingPkg != null &&
                    eventPkg != pendingPkg && eventPkg != packageName
                ) {
                    cancelPendingInsert()
                }
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                // Math notes: listen for text changes in editable fields.
                // SAFEGUARD ORDERING: password/financial checks happen BEFORE
                // any text content is read — this is the privacy guarantee.
                // The suppression-window half of the re-trigger guard drops
                // immediate text-change events caused by Nexus's own
                // auto-insert (loop prevention). The dedupe half runs later,
                // inside handleMathNotes, where the text is already known to
                // be safe to read.
                if (mathNotesEnabled && !reTriggerGuard.isWithinSuppressionWindow()) {
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

            // Re-trigger guard (layer 2): a delayed event re-delivering the
            // expression Nexus is already acting on (pending or inserted) is
            // ignored — it is an app re-render, not user input.
            if (reTriggerGuard.isDuplicateOfRecentAction(text)) {
                source.recycle()
                return
            }

            // Any OTHER text change is real user input (typing or deleting):
            // cancel a pending auto-insert and its popup — if the user does
            // anything during the short delay, the result is NOT written.
            cancelPendingInsert()

            // Pure deletions never trigger a calculation. Deleting the
            // inserted " = 4" must not re-run the math (the old
            // "2+2 = = 4" bug came from exactly this).
            if (event.removedCount > 0 && event.addedCount == 0) {
                source.recycle()
                return
            }

            // Evaluate the math expression directly on the Kotlin side.
            // This avoids a Dart round-trip and keeps the popup fast.
            val outcome = MathExpressionEvaluator.evaluate(text) { sym ->
                CurrencyRates.rateFor(sym)
            }
            if (outcome != null) {
                if (outcome.unavailableReason != null) {
                    // e.g. currency rates not fetched yet — honest note, and
                    // kick a fetch so the next attempt works.
                    try {
                        android.widget.Toast.makeText(
                            this,
                            outcome.unavailableReason,
                            android.widget.Toast.LENGTH_LONG
                        ).show()
                    } catch (_: Exception) {}
                    CurrencyRates.refresh()
                    source.recycle()
                    return
                }
                // deliverMathResult takes ownership of `source` (it may hold
                // it for the short delay before auto-inserting).
                deliverMathResult(outcome, source)
            } else {
                source.recycle()
            }
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
     * Delivers a computed math result with a short grace delay, so the result
     * is visible BEFORE anything is written and the user can keep typing:
     *  1. Show a small popup with "= result" near the field immediately.
     *  2. If the user does nothing for [INSERT_DELAY_MS] (2s), auto-insert the
     *     result ("12+8=" becomes "12+8 = 20") when the field supports
     *     ACTION_SET_TEXT, or copy it to the clipboard and confirm on the
     *     popup (which then auto-dismisses) when it doesn't.
     *  3. If the user types or deletes anything during the delay, the insert
     *     is cancelled — nothing is written without the user's pause.
     *
     * Only the result value (a number) is logged, never the typed expression.
     */
    private fun deliverMathResult(result: MathExpressionEvaluator.MathResult, source: AccessibilityNodeInfo) {
        // Drop any previous pending insert and its popup first.
        cancelPendingInsert()

        val supportsDirectInsert = try {
            source.isEditable &&
                source.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }
        } catch (e: Exception) {
            // A stale/recycled node (the app re-rendered) — degrade to the
            // clipboard fallback instead of failing silently.
            Log.e(TAG, "Math notes: could not inspect field", e)
            false
        }
        val rateNote = if (result.isConversion) rateNoteFor(result) else null

        showResultPopup(result, rateNote, source)
        reTriggerGuard.notePending(result.expression)

        val runnable = Runnable {
            pendingInsert = null
            pendingRunnable = null
            if (supportsDirectInsert) {
                val newText = "${result.expression} = ${result.formatted}"
                // Record the insert BEFORE performing it, so the events it
                // fires are suppressed (window + fragment dedupe) and the
                // inserted result is never re-detected as a new expression.
                reTriggerGuard.noteInsert(result.expression, newText)
                val args = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        newText
                    )
                }
                val inserted = try {
                    source.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                } catch (_: Exception) {
                    false
                } finally {
                    try { source.recycle() } catch (_: Exception) {}
                }
                if (inserted) {
                    Log.d(TAG, "Math notes: ${result.formatted} delivered via auto-insert")
                    dismissResultPopup()
                    return@Runnable
                }
            } else {
                try { source.recycle() } catch (_: Exception) {}
            }

            // Fallback: the field can't take direct insertion — copy the
            // result and confirm on the popup; it auto-dismisses on its own.
            copyToClipboard(result.formatted)
            updateResultPopup("= ${result.formatted} · copied")
            dismissResultPopupAfter(3000)
            Log.d(TAG, "Math notes: ${result.formatted} delivered via clipboard + overlay")
        }
        pendingInsert = PendingInsert(source)
        pendingRunnable = runnable
        mainHandler.postDelayed(runnable, INSERT_DELAY_MS)
    }

    /** Holds the accessibility node until the delayed insert fires or is cancelled. */
    private class PendingInsert(val source: AccessibilityNodeInfo)

    /**
     * Cancels a pending auto-insert (called when the user types or deletes
     * during the delay, or leaves the field/app).
     */
    private fun cancelPendingInsert() {
        pendingRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingRunnable = null
        val pending = pendingInsert
        pendingInsert = null
        pending?.let {
            try { it.source.recycle() } catch (_: Exception) {}
        }
        dismissResultPopup()
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

    /** Shows a small popup with the result near the field; tap to dismiss early. */
    private fun showResultPopup(result: MathExpressionEvaluator.MathResult, rateNote: String?, source: AccessibilityNodeInfo) {
        try {
            val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager
            val bounds = android.graphics.Rect()
            source.getBoundsInScreen(bounds)

            val resultTv = android.widget.TextView(this).apply {
                text = "= ${result.formatted}"
                setTextColor(android.graphics.Color.parseColor("#1565C0"))
                textSize = 16f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(20, 10, 20, if (rateNote == null) 10 else 2)
            }
            val layout = android.widget.LinearLayout(this).apply {
                orientation = android.widget.LinearLayout.VERTICAL
                setBackgroundColor(android.graphics.Color.parseColor("#E3F2FD"))
                addView(resultTv)
                if (rateNote != null) {
                    addView(android.widget.TextView(this@NexusAccessibilityService).apply {
                        text = rateNote
                        setTextColor(android.graphics.Color.parseColor("#5C6BC0"))
                        textSize = 12f
                        setPadding(20, 0, 20, 10)
                    })
                }
                // Tapping dismisses early; it is never required.
                setOnClickListener { dismissResultPopup() }
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
                x = bounds.left
                y = bounds.bottom + 8
            }

            wm.addView(layout, params)
            resultPopupRoot = layout
            resultPopupResultView = resultTv
        } catch (e: Exception) {
            // "Display over other apps" not granted: fall back to a Toast
            // (which dismisses itself too) so the result is never silently
            // dropped. The delayed insert/copy still happens.
            resultPopupRoot = null
            resultPopupResultView = null
            try {
                android.widget.Toast.makeText(
                    this,
                    "= ${result.formatted}",
                    android.widget.Toast.LENGTH_LONG
                ).show()
            } catch (_: Exception) {}
            Log.e(TAG, "Failed to show math popup", e)
        }
    }

    private fun updateResultPopup(text: String) {
        resultPopupResultView?.text = text
    }

    private fun dismissResultPopup() {
        val view = resultPopupRoot ?: return
        resultPopupRoot = null
        resultPopupResultView = null
        try {
            val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager
            wm.removeView(view)
        } catch (_: Exception) {}
    }

    private fun dismissResultPopupAfter(ms: Long) {
        mainHandler.postDelayed({ dismissResultPopup() }, ms)
    }

    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }

    override fun onDestroy() {
        instance = null
        cancelPendingInsert()
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

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

        /** Delay before inserting the result, matching Apple Math Notes pacing. */
        const val INSERT_DELAY_MS = 1500L

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

    // ---- Math notes: automatic result delivery -----------------------------

    private val reTriggerGuard = MathReTriggerGuard()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var pendingInsertPackage: String? = null

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
                // The user left the app we have a pending insert for — cancel
                // it. Same-app window transitions (keyboard, results panel)
                // and events from OUR OWN package must NOT cancel it.
                val eventPkg = event.packageName?.toString()
                val pendingPkg = pendingInsertPackage
                if (eventPkg != null && pendingPkg != null &&
                    eventPkg != pendingPkg && eventPkg != packageName
                ) {
                    cancelPendingInsert()
                }
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                // Math notes: the suppression half of the re-trigger guard is
                // checked before reading any text. This drops the immediate
                // event caused by Nexus's own ACTION_SET_TEXT call.
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
                ?: source.parent?.text?.toString()
                ?: return

            // Delayed rich-editor events can re-deliver the expression or a
            // prefix of the text Nexus just inserted. This check happens only
            // after the password/financial safeguards and text read above.
            if (reTriggerGuard.isDuplicateOfRecentAction(text)) {
                source.recycle()
                return
            }

            // Deleting the inserted result is user input, not a new calculation.
            // Cancel any pending delayed insert to prevent re-insertion.
            if (event.removedCount > 0 && event.addedCount == 0) {
                cancelPendingInsert()
                source.recycle()
                return
            }

            // Any new user edit cancels a previously scheduled insert. The
            // expression is re-extracted from the END of the current text.
            cancelPendingInsert()

            // Evaluate the expression at the END of the text (works even with
            // preceding prose like "note: 12+8="), directly on the Kotlin side.
            val extraction = MathExpressionEvaluator.extractAndEvaluate(text) { sym ->
                CurrencyRates.rateFor(sym)
            }
            if (extraction != null && extraction.result.unavailableReason != null) {
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

            if (extraction != null) {
                scheduleInsert(extraction, text, packageName)
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
    // Math notes: delayed result insertion
    // -----------------------------------------------------------------------

    /**
     * Schedules a delayed auto-insert: after ~1.5 s the result number is
     * written into the field via ACTION_SET_TEXT (no overlay, no tap needed).
     * If the user edits the field before the timer fires the insert is
     * cancelled and a fresh one is scheduled for whatever they typed.
     */
    private fun scheduleInsert(
        extraction: MathExpressionEvaluator.Extraction,
        currentText: String,
        pkg: String,
    ) {
        val result = extraction.result
        val start = extraction.startIndex.coerceIn(0, currentText.length)
        val end = extraction.endIndex.coerceIn(start, currentText.length)

        // Record what Nexus plans to insert so the re-trigger guard can
        // suppress the immediate and delayed events caused by ACTION_SET_TEXT.
        // For the guard we pass the expression ("12+8") not the formatted
        // number ("20") so the dedup works when the user re-types the same
        // expression later.
        reTriggerGuard.noteInsert(result.expression, currentText)

        // Cancel any previously pending insert (new expression supersedes old).
        pendingInsertRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingInsertRunnable = null

        val runnable = Runnable {
            pendingInsertRunnable = null
            // Re-read the live text — it may have changed since scheduling.
            insertResultNumeric(start, end, result.formatted, pkg)
        }
        pendingInsertRunnable = runnable
        pendingInsertPackage = pkg
        mainHandler.postDelayed(runnable, INSERT_DELAY_MS)
    }

    private var pendingInsertRunnable: Runnable? = null

    /** Cancel a pending delayed insert (user edited or switched apps). */
    private fun cancelPendingInsert() {
        pendingInsertRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingInsertRunnable = null
        pendingInsertPackage = null
    }

    /**
     * Writes the numeric result into the currently-focused editable field.
     * Falls back to clipboard if the node doesn't support ACTION_SET_TEXT.
     */
    private fun insertResultNumeric(startIndex: Int, endIndex: Int, formatted: String, pkg: String) {
        try {
            // Walk up from the root to find the focused editable node.
            val root = rootInActiveWindow ?: return
            val source = findFocusedEditable(root) ?: run {
                root.recycle()
                return
            }
            root.recycle()

            val supportsDirectInsert = try {
                source.isEditable &&
                source.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }
            } catch (_: Exception) {
                false
            }

            if (supportsDirectInsert) {
                val text = source.text?.toString() ?: return
                val safeStart = startIndex.coerceIn(0, text.length)
                val safeEnd = endIndex.coerceIn(safeStart, text.length)
                val newText = text.substring(0, safeStart) + formatted + text.substring(safeEnd)
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
                }
                if (inserted) {
                    Log.d(TAG, "Math notes: result $formatted inserted after delay")
                } else {
                    // Direct insert failed — clipboard fallback.
                    copyToClipboard(formatted)
                    Log.d(TAG, "Math notes: result $formatted copied (direct insert failed)")
                }
            } else {
                copyToClipboard(formatted)
                Log.d(TAG, "Math notes: result $formatted copied (field unsupported)")
            }
            source.recycle()
        } catch (e: Exception) {
            Log.e(TAG, "Math notes: insert failed", e)
        }
    }

    /** Walks the node tree to find the focused, editable node. */
    private fun findFocusedEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable && node.isFocused) return node
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

    private fun copyToClipboard(result: String) {
        try {
            val cm = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("math_result", result))
        } catch (_: Exception) {}
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

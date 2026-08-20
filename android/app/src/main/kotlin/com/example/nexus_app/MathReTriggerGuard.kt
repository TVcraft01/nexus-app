package com.example.nexus_app

/**
 * Prevents a re-trigger loop in the math-notes feature: when Nexus auto-inserts
 * a computed result into a text field, the field fires TYPE_VIEW_TEXT_CHANGED
 * events for that insert. Without a guard, the detector would re-run on the
 * inserted text and — if any fragment of it ever ends in '=' — loop forever.
 *
 * Two layers of protection:
 *  1. Suppression window: text-change events arriving within
 *     [SUPPRESS_WINDOW_MS] of an auto-insert are ignored. This covers the
 *     immediate events fired by the insert itself.
 *  2. Delayed-event dedupe: some apps (rich text editors, the Settings search
 *     field) fire DELAYED text-change events carrying the inserted content,
 *     often well after the suppression window has expired. Real observed
 *     fragments include "12+8 = 2" and "12+8 = " — the trailing fragment ends
 *     in '=' and re-triggers detection. The dedupe therefore ignores any event
 *     whose whitespace-normalized text is either the expression Nexus just
 *     acted on OR a prefix of the full inserted text, within
 *     [DEDUPE_COOLDOWN_MS] — killing the loop regardless of when the stale
 *     event arrives, while still allowing a genuinely different expression a
 *     moment later.
 *
 * Pure Kotlin with an injectable clock so it is unit-testable on the JVM.
 */
class MathReTriggerGuard(
    private val now: () -> Long = System::currentTimeMillis,
    private val suppressForMs: Long = SUPPRESS_WINDOW_MS,
    private val dedupeCooldownMs: Long = DEDUPE_COOLDOWN_MS,
) {
    // Long.MIN_VALUE means "no suppression scheduled": every event processes.
    private var suppressUntilMs = Long.MIN_VALUE
    private var lastActedExpression: String? = null
    private var lastInsertedText: String? = null
    private var lastActedAtMs = Long.MIN_VALUE

    /**
     * Records that Nexus just auto-inserted [insertedText] for [expressionText].
     * The suppression window starts now, and both texts are remembered for
     * dedupe (whitespace-normalized).
     */
    fun noteInsert(expressionText: String, insertedText: String) {
        suppressUntilMs = now() + suppressForMs
        lastActedExpression = normalize(expressionText)
        lastInsertedText = normalize(insertedText)
        lastActedAtMs = now()
    }

    /**
     * True while inside the suppression window (immediate events fired by the
     * insert itself). Checked in onAccessibilityEvent BEFORE any field text is
     * read, so the password/financial safeguards keep their ordering.
     */
    fun isWithinSuppressionWindow(): Boolean = now() <= suppressUntilMs

    /**
     * True if [currentText] is a delayed re-delivery of the expression Nexus
     * just acted on, or a fragment of the text Nexus just inserted. Called only
     * AFTER the password/financial checks have already read the text, so the
     * privacy ordering is preserved.
     */
    fun isDuplicateOfRecentAction(currentText: String): Boolean {
        if (now() - lastActedAtMs >= dedupeCooldownMs) return false
        val normalized = normalize(currentText)
        if (normalized.isEmpty()) return false
        if (normalized == lastActedExpression) return true
        // Fragment of the inserted text: e.g. expression "12+8=" inserted as
        // "12+8 = 20"; delayed events may carry "12+8 = ", "12+8 = 2", "12+8".
        val inserted = lastInsertedText
        return inserted != null && inserted.startsWith(normalized)
    }

    companion object {
        /** How long to ignore text-change events right after an auto-insert. */
        const val SUPPRESS_WINDOW_MS = 750L

        /**
         * How long to ignore re-delivered copies of the expression/fragments
         * just acted on. Longer than the suppression window because delayed
         * events from editors can arrive well after the insert.
         */
        const val DEDUPE_COOLDOWN_MS = 4000L

        /** Strips all whitespace so "12+8=" and "12 + 8 =" compare equal. */
        private fun normalize(s: String): String = s.filter { !it.isWhitespace() }
    }
}

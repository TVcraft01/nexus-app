package com.example.nexus_app

/**
 * Prevents a re-trigger loop in math notes after Nexus inserts a result.
 * Immediate events are suppressed briefly; delayed editor fragments are
 * deduplicated against the expression and full text Nexus inserted.
 */
class MathReTriggerGuard(
    private val now: () -> Long = System::currentTimeMillis,
    private val suppressForMs: Long = SUPPRESS_WINDOW_MS,
    private val dedupeCooldownMs: Long = DEDUPE_COOLDOWN_MS,
) {
    private var suppressUntilMs = Long.MIN_VALUE
    private var lastActedExpression: String? = null
    private var lastInsertedText: String? = null
    private var lastActedAtMs = Long.MIN_VALUE

    fun noteInsert(expressionText: String, insertedText: String) {
        suppressUntilMs = now() + suppressForMs
        lastActedExpression = normalize(expressionText)
        lastInsertedText = normalize(insertedText)
        lastActedAtMs = now()
    }

    fun isWithinSuppressionWindow(): Boolean = now() <= suppressUntilMs

    fun isDuplicateOfRecentAction(currentText: String): Boolean {
        if (now() - lastActedAtMs >= dedupeCooldownMs) return false
        val normalized = normalize(currentText)
        if (normalized.isEmpty()) return false
        if (normalized == lastActedExpression) return true
        val inserted = lastInsertedText
        return inserted != null && inserted.startsWith(normalized)
    }

    companion object {
        const val SUPPRESS_WINDOW_MS = 750L
        const val DEDUPE_COOLDOWN_MS = 4000L

        private fun normalize(s: String): String = s.filter { !it.isWhitespace() }
    }
}

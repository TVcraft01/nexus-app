package com.example.nexus_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [MathReTriggerGuard] — the loop-prevention guard that drops
 * text-change events caused by Nexus's own auto-insert.
 *
 * Two layers are covered:
 *  1. The suppression window that drops the immediate event fired by an insert.
 *  2. The delayed-event dedupe that drops events re-delivering the expression
 *     just acted on, or fragments of the inserted text (rich editors fire
 *     stale events seconds later, beyond the suppression window — the observed
 *     real-world loop failure).
 */
class MathReTriggerGuardTest {

    private class FakeClock {
        var nowMs: Long = 0L
        fun advance(ms: Long) {
            nowMs += ms
        }
        fun time(): Long = nowMs
    }

    // ---- Layer 1: suppression window -------------------------------------

    @Test
    fun eventsAreProcessedBeforeAnyInsert() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        assertFalse(guard.isWithinSuppressionWindow())
        assertFalse(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun eventsDuringTheSuppressionWindowAreIgnored() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS / 2)
        assertTrue(guard.isWithinSuppressionWindow())
    }

    @Test
    fun eventsAtTheWindowBoundaryAreStillIgnored() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS)
        assertTrue(guard.isWithinSuppressionWindow())
    }

    @Test
    fun eventsJustAfterTheWindowAreProcessedAgain() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1)
        assertFalse(guard.isWithinSuppressionWindow())
    }

    // ---- Layer 2: delayed-event dedupe ------------------------------------

    @Test
    fun delayedEventReDeliveringTheSameExpressionIsIgnored() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        // A stale event arrives LONG after the suppression window expired.
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 2000)
        assertFalse(guard.isWithinSuppressionWindow())
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun delayedEventWithWhitespaceVariantsIsIgnored() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        // Whitespace-normalized equality: the field may re-report with spaces.
        assertTrue(guard.isDuplicateOfRecentAction("12 + 8 ="))
    }

    @Test
    fun delayedFragmentOfTheInsertedTextIsIgnored() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        // The observed real failure: the Settings search field re-fires
        // fragments of the inserted text, e.g. "12+8 = 2" and "12+8 = ".
        // The trailing fragment ends in '=' and would re-trigger detection.
        assertTrue(guard.isDuplicateOfRecentAction("12+8 = 2"))
        assertTrue(guard.isDuplicateOfRecentAction("12+8 = "))
        assertTrue(guard.isDuplicateOfRecentAction("12+8 ="))
        assertTrue(guard.isDuplicateOfRecentAction("12+8"))
    }

    @Test
    fun delayedEventWithDifferentTextIsProcessed() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        // The user typed something genuinely new (even ending in '='): process.
        assertFalse(guard.isDuplicateOfRecentAction("5+5="))
        // A different expression that merely starts with the same digit.
        assertFalse(guard.isDuplicateOfRecentAction("12*4="))
    }

    @Test
    fun sameExpressionAfterTheCooldownIsProcessedAgain() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.DEDUPE_COOLDOWN_MS + 1)
        // The user legitimately re-typed the same expression later: allow it.
        assertFalse(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun aNewInsertReplacesTheDedupedExpression() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))

        // A second, different insert changes what is deduped.
        guard.noteInsert("5+5=", "5+5 = 10")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("5+5="))
        assertFalse(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun whitespaceIsNormalizedWhenDeduping() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("  12+8=  ", " 12+8 = 20 ")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))
    }

    // ---- Pending window (delay before auto-insert) -----------------------

    @Test
    fun pendingExpressionReDeliveryIsDuplicate() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        // The 2s grace delay: while a result is pending, apps re-render the
        // field and re-fire the same text — that must not cancel the insert.
        guard.notePending("12+8=")
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))
        assertTrue(guard.isDuplicateOfRecentAction("12 + 8 ="))
    }

    @Test
    fun pendingDoesNotStartTheSuppressionWindow() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.notePending("12+8=")
        // The detecting event has already been processed; real user input
        // right after must still be seen (to cancel the pending insert).
        assertFalse(guard.isWithinSuppressionWindow())
    }

    @Test
    fun differentTextDuringPendingIsNotDuplicate() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.notePending("12+8=")
        // Genuine new input during the delay cancels the pending insert.
        assertFalse(guard.isDuplicateOfRecentAction("5+5=" ))
        assertFalse(guard.isDuplicateOfRecentAction("12+8+3=" ))
    }

    @Test
    fun pendingThenInsertSuppressesItsOwnEvents() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.notePending("12+8=")
        // The delay elapses; the insert happens and is recorded.
        guard.noteInsert("12+8=", "12+8 = 20")
        assertTrue(guard.isWithinSuppressionWindow())
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        // Post-insert fragments of the inserted text are still deduped.
        assertTrue(guard.isDuplicateOfRecentAction("12+8 = 2"))
        assertTrue(guard.isDuplicateOfRecentAction("12+8 ="))
    }
}

package com.example.nexus_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MathReTriggerGuardTest {
    private class FakeClock {
        var nowMs = 0L
        fun advance(ms: Long) { nowMs += ms }
        fun time(): Long = nowMs
    }

    @Test
    fun eventsBeforeAnyInsertAreProcessed() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        assertFalse(guard.isWithinSuppressionWindow())
        assertFalse(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun immediateInsertEventsAreSuppressed() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS / 2)
        assertTrue(guard.isWithinSuppressionWindow())
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS / 2)
        assertTrue(guard.isWithinSuppressionWindow())
    }

    @Test
    fun eventsAfterSuppressionWindowCanBeProcessed() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1)
        assertFalse(guard.isWithinSuppressionWindow())
    }

    @Test
    fun delayedExpressionAndWhitespaceVariantsAreDeduped() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 2000)
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))
        assertTrue(guard.isDuplicateOfRecentAction("12 + 8 ="))
    }

    @Test
    fun delayedInsertedFragmentsAreDeduped() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("12+8 = 2"))
        assertTrue(guard.isDuplicateOfRecentAction("12+8 = "))
        assertTrue(guard.isDuplicateOfRecentAction("12+8 ="))
        assertTrue(guard.isDuplicateOfRecentAction("12+8"))
    }

    @Test
    fun differentTextIsNotDeduped() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertFalse(guard.isDuplicateOfRecentAction("5+5="))
        assertFalse(guard.isDuplicateOfRecentAction("12*4="))
    }

    @Test
    fun sameExpressionIsAllowedAfterCooldown() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.DEDUPE_COOLDOWN_MS + 1)
        assertFalse(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun newInsertReplacesTheDedupedText() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))
        guard.noteInsert("5+5=", "5+5 = 10")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("5+5="))
        assertFalse(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun whitespaceIsNormalized() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert(" 12+8= ", " 12+8 = 20 ")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertTrue(guard.isDuplicateOfRecentAction("12+8="))
    }

    @Test
    fun userDeletionIsNotAResultFragmentToRecalculate() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.DEDUPE_COOLDOWN_MS + 1)
        // The event handler separately rejects removed-only events; the guard
        // must not make a later legitimate expression look like old text.
        assertFalse(guard.isDuplicateOfRecentAction("5+5="))
    }

    @Test
    fun prefixMatchingDoesNotDeduplicateALongerUserEdit() {
        val clock = FakeClock()
        val guard = MathReTriggerGuard(now = clock::time)
        guard.noteInsert("12+8=", "12+8 = 20")
        clock.advance(MathReTriggerGuard.SUPPRESS_WINDOW_MS + 1000)
        assertFalse(guard.isDuplicateOfRecentAction("12+8 = 20 + 1="))
    }
}

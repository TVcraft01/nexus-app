package com.example.nexus_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [MathExpressionEvaluator] — the strict arithmetic evaluator
 * behind the math-notes feature.
 *
 * Includes the real regression found live on the phone: "9-4=" produced no
 * result because the tokenizer misclassified the binary '-' as a unary minus
 * (the "9" was still in the token buffer when '-' arrived).
 */
class MathExpressionEvaluatorTest {

    private fun eval(text: String): String? =
        MathExpressionEvaluator.evaluate(text)?.formatted

    // ---- basic arithmetic --------------------------------------------------

    @Test
    fun addition() {
        assertEquals("20", eval("12+8="))
    }

    @Test
    fun subtraction() {
        // Regression: binary minus as the FIRST operator crashed the parse.
        assertEquals("5", eval("9-4="))
        assertEquals("13", eval("12-(-1)="))
    }

    @Test
    fun multiplication() {
        assertEquals("42", eval("6*7="))
    }

    @Test
    fun division() {
        assertEquals("3", eval("9/3="))
        assertEquals("2.5", eval("5/2="))
    }

    @Test
    fun operatorPrecedence() {
        assertEquals("14", eval("2+3*4="))
        assertEquals("20", eval("(2+3)*4="))
    }

    @Test
    fun parentheses() {
        assertEquals("20", eval("(2+3)*4="))
        assertEquals("35", eval("(2+5)*(3+2)="))
    }

    @Test
    fun unaryMinus() {
        assertEquals("-3", eval("-3="))
        assertEquals("-3", eval("0-3="))
    }

    @Test
    fun decimals() {
        assertEquals("1.5", eval("0.5+1="))
        assertEquals("2.5", eval("1.25*2="))
    }

    @Test
    fun whitespaceIsAllowed() {
        assertEquals("20", eval(" 12 + 8 = "))
        assertEquals("14", eval("2 + 3 * 4="))
    }

    // ---- user-friendly symbols ---------------------------------------------

    @Test
    fun divisionSignWorks() {
        assertEquals("5", eval("10÷2="))
        assertEquals("3", eval("12÷4="))
    }

    @Test
    fun timesSignWorks() {
        assertEquals("42", eval("6×7="))
    }

    @Test
    fun xAsMultiplicationWorks() {
        assertEquals("6", eval("2x3="))
        assertEquals("24", eval("2x3x4="))
    }

    // ---- exponentiation ------------------------------------------------------

    @Test
    fun caretExponent() {
        assertEquals("8", eval("2^3="))
        assertEquals("1", eval("2^0="))
        assertEquals("0.5", eval("2^-1="))
    }

    @Test
    fun superscriptExponent() {
        assertEquals("4", eval("2²="))
        assertEquals("9", eval("3²="))
        assertEquals("8", eval("2³="))
    }

    @Test
    fun exponentPrecedence() {
        // The unary minus is folded into the base (like a phone calculator):
        // -2^2 = (-2)^2 = 4.
        assertEquals("4", eval("-2^2=" ))
        // A binary minus applies AFTER the exponent: 0-2^2 = 0-4 = -4.
        assertEquals("-4", eval("0-2^2=" ))
        // Right-associative: 2^3^2 = 2^(3^2) = 512.
        assertEquals("512", eval("2^3^2=" ))
    }

    // ---- percent -------------------------------------------------------------

    @Test
    fun percentIsPostfix() {
        assertEquals("0.5", eval("50%="))
        assertEquals("20", eval("200*10%="))
        assertEquals("0.6", eval("50%+10%="))
    }

    // ---- rejections -----------------------------------------------------------

    @Test
    fun divisionByZeroIsRejected() {
        assertNull(eval("1/0="))
    }

    @Test
    fun missingEqualsIsRejected() {
        assertNull(eval("12+8"))
    }

    @Test
    fun lettersAreRejected() {
        assertNull(eval("12+a="))
        assertNull(eval("abc="))
    }

    @Test
    fun emptyExpressionIsRejected() {
        assertNull(eval("="))
        assertNull(eval(""))
    }

    @Test
    fun trailingOperatorIsRejected() {
        assertNull(eval("12+="))
        assertNull(eval("12*="))
        assertNull(eval("2x="))
        assertNull(eval("2^="))
    }

    @Test
    fun functionCallsAreRejected() {
        assertNull(eval("sin(0)="))
    }

    @Test
    fun percentWithoutOperandIsRejected() {
        assertNull(eval("%="))
        assertNull(eval("2%3=")) // % is postfix-only in this narrow grammar
    }

    // ---- currency conversion ---------------------------------------------------

    private val testRates: (String) -> Double? = { sym ->
        when (sym) {
            "€" -> 1.0
            "$" -> 1.087
            "£" -> 0.85
            "¥" -> 163.0
            else -> null
        }
    }

    @Test
    fun currencyInForm() {
        val r = MathExpressionEvaluator.evaluate("10€ in $ =", testRates)
        assertNotNull(r)
        assertTrue(r!!.isConversion)
        assertEquals("10.87 $", r.formatted)
        assertEquals("10 €", r.expression)
        assertEquals("€", r.fromSymbol)
        assertEquals("$", r.toSymbol)
    }

    @Test
    fun currencyEqualsForm() {
        val r = MathExpressionEvaluator.evaluate("10€=$", testRates)
        assertNotNull(r)
        assertEquals("10.87 $", r!!.formatted)
    }

    @Test
    fun currencyReverse() {
        val r = MathExpressionEvaluator.evaluate("10$ in € =", testRates)
        assertNotNull(r)
        assertEquals("9.20 €", r!!.formatted)
    }

    @Test
    fun currencyWithSpaces() {
        val r = MathExpressionEvaluator.evaluate(" 10 € in $ = ", testRates)
        assertNotNull(r)
        assertEquals("10.87 $", r!!.formatted)
    }

    @Test
    fun currencyWithoutEqualsSign() {
        val r = MathExpressionEvaluator.evaluate("10€ in $", testRates)
        assertNotNull(r)
        assertEquals("10.87 $", r!!.formatted)
    }

    @Test
    fun currencyRatesMissingIsReportedHonestly() {
        val r = MathExpressionEvaluator.evaluate("10€ in $ =") { null }
        assertNotNull(r)
        assertNotNull(r!!.unavailableReason)
    }

    @Test
    fun currencyGarbageIsRejected() {
        assertNull(MathExpressionEvaluator.evaluate("10€", testRates))
        assertNull(MathExpressionEvaluator.evaluate("10€ in =", testRates))
        assertNull(MathExpressionEvaluator.evaluate("hello 10€ in $", testRates))
        assertNull(MathExpressionEvaluator.evaluate("10€ in $ in € =", testRates))
    }

    @Test
    fun plainArithmeticWithCurrencySymbolIsNotConverted() {
        // A currency symbol present but not in conversion form → rejected.
        assertNull(MathExpressionEvaluator.evaluate("2+€=", testRates))
    }

    // ---- extraction with preceding text -------------------------------------

    @Test
    fun extractionIgnoresPrecedingProse() {
        val e = MathExpressionEvaluator.extractAndEvaluate("note: 12+8=")
        assertNotNull(e)
        assertEquals("20", e!!.result.formatted)
        assertEquals("12+8", e.result.expression)
        // The expression starts right after "note: ".
        assertEquals(6, e.startIndex)
    }

    @Test
    fun extractionWithSpacesInExpression() {
        val e = MathExpressionEvaluator.extractAndEvaluate("the total is 2 + 2 =")
        assertNotNull(e)
        assertEquals("4", e!!.result.formatted)
    }

    @Test
    fun extractionUsesTheLastEqualsSign() {
        val e = MathExpressionEvaluator.extractAndEvaluate("x = 5; 12+8=")
        assertNotNull(e)
        assertEquals("20", e!!.result.formatted)
    }

    @Test
    fun extractionRejectsNonMathProseBefore() {
        assertNull(MathExpressionEvaluator.extractAndEvaluate("I have 3 cats ="))
        assertNull(MathExpressionEvaluator.extractAndEvaluate("the answer is ="))
    }

    @Test
    fun extractionCurrencyWithProse() {
        val e = MathExpressionEvaluator.extractAndEvaluate("price: 10€ in $ =", testRates)
        assertNotNull(e)
        assertEquals("10.87 $", e!!.result.formatted)
        assertTrue(e.result.isConversion)
    }

    @Test
    fun extractionCurrencyEqualsForm() {
        val e = MathExpressionEvaluator.extractAndEvaluate("10€=$", testRates)
        assertNotNull(e)
        assertEquals("10.87 $", e!!.result.formatted)
        assertEquals(0, e.startIndex)
    }

    @Test
    fun extractionStartIndexKeepsThePrecedingText() {
        val text = "total: 3*4="
        val e = MathExpressionEvaluator.extractAndEvaluate(text)
        assertNotNull(e)
        // Rebuilding the insertion the service performs must round-trip.
        val inserted = text.substring(0, e!!.startIndex) +
            e.result.expression + " = " + e.result.formatted
        assertEquals("total: 3*4 = 12", inserted)
    }
}

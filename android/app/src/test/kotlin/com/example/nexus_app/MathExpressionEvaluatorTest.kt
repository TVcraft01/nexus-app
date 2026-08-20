package com.example.nexus_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    @Test
    fun addition() {
        assertEquals("20", MathExpressionEvaluator.evaluate("12+8="))
    }

    @Test
    fun subtraction() {
        // Regression: binary minus as the FIRST operator crashed the parse.
        assertEquals("5", MathExpressionEvaluator.evaluate("9-4="))
        assertEquals("13", MathExpressionEvaluator.evaluate("12-(-1)="))
    }

    @Test
    fun multiplication() {
        assertEquals("42", MathExpressionEvaluator.evaluate("6*7="))
    }

    @Test
    fun division() {
        assertEquals("3", MathExpressionEvaluator.evaluate("9/3="))
        assertEquals("2.5", MathExpressionEvaluator.evaluate("5/2="))
    }

    @Test
    fun operatorPrecedence() {
        // Multiplication binds tighter than addition.
        assertEquals("14", MathExpressionEvaluator.evaluate("2+3*4="))
        assertEquals("20", MathExpressionEvaluator.evaluate("(2+3)*4="))
    }

    @Test
    fun parentheses() {
        assertEquals("20", MathExpressionEvaluator.evaluate("(2+3)*4="))
        assertEquals("35", MathExpressionEvaluator.evaluate("(2+5)*(3+2)="))
    }

    @Test
    fun unaryMinus() {
        assertEquals("-3", MathExpressionEvaluator.evaluate("-3="))
        assertEquals("-3", MathExpressionEvaluator.evaluate("0-3="))
    }

    @Test
    fun decimals() {
        assertEquals("1.5", MathExpressionEvaluator.evaluate("0.5+1="))
        assertEquals("2.5", MathExpressionEvaluator.evaluate("1.25*2="))
    }

    @Test
    fun whitespaceIsAllowed() {
        assertEquals("20", MathExpressionEvaluator.evaluate(" 12 + 8 = "))
        assertEquals("14", MathExpressionEvaluator.evaluate("2 + 3 * 4="))
    }

    @Test
    fun divisionByZeroIsRejected() {
        assertNull(MathExpressionEvaluator.evaluate("1/0="))
    }

    @Test
    fun missingEqualsIsRejected() {
        assertNull(MathExpressionEvaluator.evaluate("12+8"))
    }

    @Test
    fun lettersAreRejected() {
        assertNull(MathExpressionEvaluator.evaluate("12+a="))
        assertNull(MathExpressionEvaluator.evaluate("abc="))
    }

    @Test
    fun emptyExpressionIsRejected() {
        assertNull(MathExpressionEvaluator.evaluate("="))
        assertNull(MathExpressionEvaluator.evaluate(""))
    }

    @Test
    fun trailingOperatorIsRejected() {
        assertNull(MathExpressionEvaluator.evaluate("12+="))
        assertNull(MathExpressionEvaluator.evaluate("12*="))
    }

    @Test
    fun divisionSignIsRejected() {
        // The ÷ symbol is outside the strict grammar.
        assertNull(MathExpressionEvaluator.evaluate("10÷2="))
    }

    @Test
    fun functionCallsAreRejected() {
        assertNull(MathExpressionEvaluator.evaluate("sin(0)="))
        assertNull(MathExpressionEvaluator.evaluate("2^3="))
    }
}

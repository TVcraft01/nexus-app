package com.example.nexus_app

/**
 * Evaluates a simple arithmetic expression (numbers, + - * /, parentheses,
 * decimal points) — no general expression evaluation, no function calls, no
 * variables. This is the exact same narrow grammar used by MathTriggerDetector
 * on the Dart side.
 *
 * Pure Kotlin with no Android dependencies so it is unit-testable on the JVM.
 */
object MathExpressionEvaluator {

    /** Allowed characters: digits, decimal point, + - * /, parens, whitespace. */
    private val allowedChars = Regex("^[\\d+\\-*/().\\s]+$")
    private val hasDigit = Regex("\\d")
    private val hasOperator = Regex("[+\\-*/]")
    private val trailingEquals = Regex("=\\s*$")

    /**
     * Evaluates [text] if it is a strict arithmetic expression ending with '='.
     * Returns the formatted result string, or null if not a valid expression.
     *
     * Validation mirrors the Dart MathTriggerDetector: character allowlist,
     * must contain a digit and an operator, must not end with an operator,
     * and parentheses must be balanced. Anything else is discarded immediately.
     */
    fun evaluate(text: String): String? {
        if (text.isEmpty()) return null
        if (!trailingEquals.containsMatchIn(text)) return null

        val expr = text.replace(trailingEquals, "").trim()
        if (expr.isEmpty()) return null

        if (!allowedChars.containsMatchIn(expr)) return null
        if (!hasDigit.containsMatchIn(expr) || !hasOperator.containsMatchIn(expr)) return null

        val lastChar = expr.trimEnd().last()
        if ("+-*/".contains(lastChar)) return null

        // Parentheses must be balanced.
        var depth = 0
        for (c in expr) {
            if (c == '(') depth++
            if (c == ')') depth--
            if (depth < 0) return null
        }
        if (depth != 0) return null

        return try {
            val result = evalArithmetic(expr)
            if (result.isNaN() || result.isInfinite()) null
            else if (result == result.toLong().toDouble()) result.toLong().toString()
            else String.format(
                "%.${minOf(result.toString().split(".").getOrElse(1) { "" }.length.coerceIn(1, 6))}f",
                result
            )
        } catch (_: Exception) {
            null
        }
    }

    // Parser state shared across recursive-descent methods
    private var tokens = listOf<String>()
    private var pos = 0

    /** Simple recursive-descent arithmetic evaluator (no external eval). */
    private fun evalArithmetic(expr: String): Double {
        tokens = tokenize(expr)
        pos = 0
        val result = parseAddSub()
        if (pos < tokens.size) return Double.NaN
        return result
    }

    private fun parseAddSub(): Double {
        var left = parseMulDiv()
        while (pos < tokens.size && (tokens[pos] == "+" || tokens[pos] == "-")) {
            val op = tokens[pos++]
            val right = parseMulDiv()
            left = if (op == "+") left + right else left - right
        }
        return left
    }

    private fun parseMulDiv(): Double {
        var left = parseUnary()
        while (pos < tokens.size && (tokens[pos] == "*" || tokens[pos] == "/")) {
            val op = tokens[pos++]
            val right = parseUnary()
            left = if (op == "*") left * right else left / right
        }
        return left
    }

    private fun parseUnary(): Double {
        if (pos < tokens.size && tokens[pos] == "-") {
            pos++
            return -parseAtom()
        }
        return parseAtom()
    }

    private fun parseAtom(): Double {
        if (pos >= tokens.size) return 0.0
        if (tokens[pos] == "(") {
            pos++
            val v = parseAddSub()
            if (pos < tokens.size && tokens[pos] == ")") pos++
            return v
        }
        return tokens[pos++].toDouble()
    }

    private fun tokenize(expr: String): List<String> {
        val out = mutableListOf<String>()
        val buf = StringBuilder()
        for (c in expr) {
            if (c == ' ') continue
            if (c == '+' || c == '-' || c == '*' || c == '/') {
                // A '-' is a unary minus only when no number is being built
                // AND the previous token is an operator/start. Otherwise it is
                // a binary operator. (Checking buf.isEmpty() is essential:
                // for "9-4", the "9" is still in buf when '-' arrives, so it
                // must be binary — treating it as unary would produce "9-4"
                // as one token and crash the parse.)
                if (c == '-' && buf.isEmpty() &&
                    (out.isEmpty() || out.last().let { it == "+" || it == "-" || it == "*" || it == "/" })
                ) {
                    buf.append(c)
                } else {
                    if (buf.isNotEmpty()) {
                        out.add(buf.toString())
                        buf.clear()
                    }
                    out.add(c.toString())
                }
            } else if (c == '(' || c == ')') {
                if (buf.isNotEmpty()) {
                    out.add(buf.toString())
                    buf.clear()
                }
                out.add(c.toString())
            } else {
                buf.append(c)
            }
        }
        if (buf.isNotEmpty()) out.add(buf.toString())
        return out
    }
}

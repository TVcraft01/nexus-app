package com.example.nexus_app

/**
 * Evaluates a simple arithmetic expression — numbers, + - * /, parentheses,
 * decimal points, exponentiation (^, ², ³), percent (%) — and currency
 * conversions (e.g. "10€ in $ =" or "10€=$"). No general expression
 * evaluation, no function calls, no variables.
 *
 * User-friendly symbols are normalized before parsing:
 *   ÷ → /,  × → *,  x → *,  ² → ^2,  ³ → ^3
 *
 * Exchange rates are supplied by the caller via [rateProvider] (symbol → rate
 * vs. EUR). The evaluator itself never fetches anything and never touches the
 * network.
 *
 * [extractAndEvaluate] finds the arithmetic/conversion expression at the END
 * of a larger piece of text (e.g. "note: 12+8=" → 20) so the feature works
 * even when there is text before the expression.
 *
 * Pure Kotlin with no Android dependencies so it is unit-testable on the JVM.
 */
object MathExpressionEvaluator {

    /**
     * The outcome of evaluating a recognized expression.
     *
     * [expression] is the CLEANED expression text in canonical form, used when
     * the result is inserted back into the field (so an already-inserted
     * "2+2 = 4" can never be re-inserted as "2+2 = = 4").
     */
    data class MathResult(
        val expression: String,
        val value: Double,
        val formatted: String,
        val isConversion: Boolean = false,
        val fromSymbol: String? = null,
        val toSymbol: String? = null,
        val amount: Double = 0.0,
        /** Set when the expression was recognized but can't be completed yet
         *  (e.g. exchange rates not available). */
        val unavailableReason: String? = null,
    )

    /** A recognized expression plus the span it occupies in the original text,
     *  so the caller can replace exactly that range with the result. */
    data class Extraction(
        val result: MathResult,
        val startIndex: Int,
        val endIndex: Int, // exclusive
    )

    private val trailingEquals = Regex("=\\s*$")
    private val hasDigit = Regex("\\d")
    private val hasOperator = Regex("[+\\-*/^%]")
    private val trailingOperator = "+-*/^"

    /** Characters allowed in an arithmetic expression after normalization. */
    private val allowedChars = Regex("^[\\d+\\-*/().\\s^%]+$")

    private val currencySymbols = "€$£¥"
    private val conversionPattern =
        Regex("^(\\d+(?:\\.\\d+)?)\\s*([€$£¥])\\s*(?:in|=)\\s*([€$£¥])\\s*=?\\s*$")

    /**
     * Characters that can belong to the trailing expression when scanning
     * backwards through surrounding text. Includes '=' so the "10€=$"
     * conversion form survives, and 'x' so "2x3" multiplication does too.
     */
    private val suffixChars = "0123456789.+-*/().^%÷×x²³€$£¥="

    /**
     * Evaluates [text], which must BE the expression itself (optionally with a
     * trailing '=' for arithmetic). Currency conversions may end in '=' or in
     * the target symbol. Returns null if it doesn't match the narrow grammar.
     */
    fun evaluate(
        text: String,
        rateProvider: (String) -> Double? = { null },
    ): MathResult? {
        if (text.isEmpty()) return null

        if (text.any { it in currencySymbols }) {
            return evaluateConversion(text.trim(), rateProvider)
        }
        if (!trailingEquals.containsMatchIn(text)) return null

        val expr = text.replace(trailingEquals, "").trim()
        if (expr.isEmpty()) return null
        return evaluateArithmetic(expr)
    }

    /**
     * Finds and evaluates an arithmetic/conversion expression at the END of
     * [text], ignoring any preceding prose (e.g. "note: 12+8="). Returns the
     * result and the index in [text] where the expression begins, or null.
     *
     * The expression must still be complete: arithmetic ends with '=', and a
     * conversion ends with '=' or a currency symbol.
     */
    fun extractAndEvaluate(
        text: String,
        rateProvider: (String) -> Double? = { null },
    ): Extraction? {
        if (text.isEmpty()) return null

        // Locate the trigger at the end of the text (ignoring trailing whitespace).
        var j = text.length - 1
        while (j >= 0 && text[j].isWhitespace()) j--
        if (j < 0) return null

        val last = text[j]
        val hasTrailingEquals = last == '='
        val endsWithCurrency = last in currencySymbols
        if (!hasTrailingEquals && !endsWithCurrency) return null

        // `end` is exclusive; for arithmetic the trailing '=' is the trigger
        // and is not part of the expression. For a conversion ending in a
        // currency symbol, that symbol IS part of the expression.
        val end = if (hasTrailingEquals) j else j + 1

        // Walk backwards over expression characters.
        var i = end - 1
        val sb = StringBuilder()
        while (i >= 0) {
            val c = text[i]
            when {
                c.isWhitespace() || suffixChars.contains(c) -> {
                    sb.append(c)
                    i--
                }
                c == 'n' && i >= 1 && text[i - 1] == 'i' && sb.any { it in currencySymbols } -> {
                    // The word "in" inside a currency conversion. The buffer
                    // is built backwards, so append it reversed ("ni").
                    sb.append("ni")
                    i -= 2
                }
                else -> break
            }
        }
        val raw = sb.reverse().toString()
        val leadingWs = raw.length - raw.trimStart().length
        val expr = raw.trim()
        if (expr.isEmpty()) return null
        val startIndex = i + 1 + leadingWs

        // Include trailing whitespace after the trigger (e.g. "12+8=  ").
        val endIndex = if (hasTrailingEquals) {
            var k = j + 1
            while (k < text.length && text[k].isWhitespace()) k++
            k
        } else {
            j + 1
        }

        val result = evaluateExpression(expr, rateProvider) ?: return null
        return Extraction(result, startIndex, endIndex)
    }

    /** Evaluates an already-extracted expression (no trailing '=' expected). */
    private fun evaluateExpression(
        expr: String,
        rateProvider: (String) -> Double?,
    ): MathResult? {
        if (expr.isEmpty()) return null
        return if (expr.any { it in currencySymbols }) {
            evaluateConversion(expr, rateProvider)
        } else {
            evaluateArithmetic(expr)
        }
    }

    // -----------------------------------------------------------------------
    // Arithmetic
    // -----------------------------------------------------------------------

    private fun evaluateArithmetic(expr: String): MathResult? {
        val normalized = normalize(expr)

        if (!allowedChars.containsMatchIn(normalized)) return null
        if (!hasDigit.containsMatchIn(normalized) || !hasOperator.containsMatchIn(normalized)) return null

        val trimmed = normalized.trimEnd()
        if (trimmed.isEmpty()) return null
        if (trailingOperator.contains(trimmed.last())) return null

        // Parentheses must be balanced.
        var depth = 0
        for (c in normalized) {
            if (c == '(') depth++
            if (c == ')') depth--
            if (depth < 0) return null
        }
        if (depth != 0) return null

        return try {
            val result = evalArithmetic(normalized)
            if (result.isNaN() || result.isInfinite()) null
            else MathResult(
                expression = expr.trimEnd(),
                value = result,
                formatted = formatNumber(result),
            )
        } catch (_: Exception) {
            null
        }
    }

    /** Normalizes user-friendly symbols to canonical math syntax. */
    private fun normalize(expr: String): String = expr
        .replace("÷", "/")
        .replace("×", "*")
        .replace('x', '*')
        .replace("²", "^2")
        .replace("³", "^3")

    private fun formatNumber(result: Double): String =
        if (result == result.toLong().toDouble()) result.toLong().toString()
        else String.format(
            "%.${minOf(result.toString().split(".").getOrElse(1) { "" }.length.coerceIn(1, 6))}f",
            result
        )

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
            return -parseUnary()
        }
        return parsePower()
    }

    /**
     * Exponent. A unary minus is folded into the base by the tokenizer, so
     * -2^2 = (-2)^2 = 4 (like a phone calculator); a binary minus applies
     * after the exponent: 0-2^2 = -4.
     */
    private fun parsePower(): Double {
        val left = parsePostfix()
        if (pos < tokens.size && tokens[pos] == "^") {
            pos++
            val right = parseUnary() // right-associative; allows 2^-1
            return Math.pow(left, right)
        }
        return left
    }

    /** Percent is postfix: 50% → 0.5. */
    private fun parsePostfix(): Double {
        var v = parseAtom()
        while (pos < tokens.size && tokens[pos] == "%") {
            pos++
            v /= 100.0
        }
        return v
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
            if (c == '+' || c == '-' || c == '*' || c == '/' || c == '^') {
                // A '-' is a unary minus only when no number is being built
                // AND the previous token is an operator/paren/start. Otherwise
                // it is a binary operator. (Checking buf.isEmpty() is
                // essential: for "9-4", the "9" is still in buf when '-'
                // arrives, so it must be binary — treating it as unary would
                // produce "9-4" as one token and crash the parse.)
                if (c == '-' && buf.isEmpty() &&
                    (out.isEmpty() || out.last().let { it == "+" || it == "-" || it == "*" || it == "/" || it == "^" || it == "(" })
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
            } else if (c == '%') {
                if (buf.isNotEmpty()) {
                    out.add(buf.toString())
                    buf.clear()
                }
                out.add("%")
            } else {
                buf.append(c)
            }
        }
        if (buf.isNotEmpty()) out.add(buf.toString())
        return out
    }

    // -----------------------------------------------------------------------
    // Currency conversion
    // -----------------------------------------------------------------------

    private fun evaluateConversion(
        text: String,
        rateProvider: (String) -> Double?,
    ): MathResult? {
        val match = conversionPattern.find(text.trim()) ?: return null
        val amount = match.groupValues[1].toDoubleOrNull() ?: return null
        val from = match.groupValues[2]
        val to = match.groupValues[3]
        val fromRate = rateProvider(from)
        val toRate = rateProvider(to)
        if (fromRate == null || toRate == null || fromRate <= 0.0 || toRate <= 0.0) {
            return MathResult(
                expression = formatAmount(amount) + " " + from,
                value = Double.NaN,
                formatted = "",
                isConversion = true,
                fromSymbol = from,
                toSymbol = to,
                amount = amount,
                unavailableReason = "Exchange rates not available yet — Nexus needs internet once to fetch them.",
            )
        }
        val result = amount * toRate / fromRate
        return MathResult(
            expression = formatAmount(amount) + " " + from,
            value = result,
            formatted = String.format("%.2f %s", result, to),
            isConversion = true,
            fromSymbol = from,
            toSymbol = to,
            amount = amount,
        )
    }

    private fun formatAmount(amount: Double): String =
        if (amount == amount.toLong().toDouble()) amount.toLong().toString()
        else amount.toString().trimEnd('0').trimEnd('.')
}

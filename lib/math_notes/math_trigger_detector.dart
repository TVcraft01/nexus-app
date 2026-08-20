import 'dart:math' as math;

/// Detects simple arithmetic expressions ending with `=` and computes the result.
///
/// This is a **narrow, safe** evaluator — it only handles:
///   - Integers and decimals (positive and negative)
///   - The four basic operators: + - * / (plus the user-friendly ÷ and ×, and
///     `x` for multiplication)
///   - Exponentiation via ^, ², or ³
///   - Percent as a postfix operator (50% → 0.5)
///   - Parentheses for grouping
///   - An optional trailing `=` sign
///
/// It deliberately does NOT support:
///   - Variables, function calls, or assignments
///   - General expression evaluation beyond the grammar above
///   - String interpolation or any non-numeric tokens
///
/// The grammar is enforced by a strict character allowlist. Anything that
/// doesn't match is immediately discarded — no parsing, no evaluation, no
/// side effects.
///
/// NOTE: the live math-notes path runs on the Android (Kotlin) side via
/// MathExpressionEvaluator. This Dart class mirrors the same grammar so the
/// two never drift; currency conversion lives on the Kotlin side only.
class MathTriggerDetector {
  MathTriggerDetector._();

  /// Characters allowed in a math expression (after normalization): digits,
  /// decimal point, operators + - * / ^ %, parentheses, and whitespace.
  static final _allowedChars = RegExp(r'^[\d+\-*/().\s^%]+$');

  /// Must contain at least one digit and one operator.
  static final _hasDigit = RegExp(r'\d');
  static final _hasOperator = RegExp(r'[+\-*/^%]');

  /// Must end with `=` (possibly with trailing whitespace).
  static final _trailingEquals = RegExp(r'=\s*$');

  /// User-friendly symbols → canonical math syntax.
  static String _normalize(String expr) => expr
      .replaceAll('÷', '/')
      .replaceAll('×', '*')
      .replaceAll('x', '*')
      .replaceAll('²', '^2')
      .replaceAll('³', '^3');

  /// Evaluates the given [text] as a simple arithmetic expression.
  ///
  /// Returns a [MathResult] if the text is a valid arithmetic expression
  /// ending with `=`, or null if it doesn't match.
  ///
  /// **Privacy guarantee:** if the text doesn't match the criteria, it is
  /// immediately discarded — no parsing, no storage, no logging.
  static MathResult? detect(String text) {
    if (text.isEmpty) return null;

    // Step 1: Must end with =
    if (!_trailingEquals.hasMatch(text)) return null;

    // Strip trailing = and whitespace
    final raw = text.replaceFirst(_trailingEquals, '').trim();
    if (raw.isEmpty) return null;

    final expr = _normalize(raw);

    // Step 2: Only allowed characters
    if (!_allowedChars.hasMatch(expr)) return null;

    // Step 3: Must have at least one digit and one operator
    if (!_hasDigit.hasMatch(expr) || !_hasOperator.hasMatch(expr)) return null;

    // Step 3b: Expression must not end with an operator (incomplete)
    final trimmed = expr.trimRight();
    final lastChar = trimmed[trimmed.length - 1];
    if ('+-*/^'.contains(lastChar)) return null;

    // Step 3c: Parentheses must be balanced
    var depth = 0;
    for (var i = 0; i < expr.length; i++) {
      if (expr[i] == '(') depth++;
      if (expr[i] == ')') depth--;
      if (depth < 0) return null;
    }
    if (depth != 0) return null;

    // Step 4: Try to evaluate
    try {
      final result = _evaluate(expr);
      if (result.isNaN || result.isInfinite) return null;

      // Format: show as integer if it's a whole number, otherwise as decimal
      final formatted = result == result.roundToDouble()
          ? result.toInt().toString()
          : result.toStringAsFixed(
              result.toString().split('.').last.length.clamp(1, 6),
            );
      return MathResult(expression: raw, value: result, formatted: formatted);
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Recursive-descent parser for simple arithmetic (no external eval)
  // -----------------------------------------------------------------------

  /// Tokenizes the expression into numbers, operators, and parentheses.
  static List<String> _tokenize(String expr) {
    final tokens = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < expr.length; i++) {
      final c = expr[i];
      if (c == ' ' || c == '\t') continue;
      if (c == '(' || c == ')') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
        tokens.add(c);
      } else if (c == '+' || c == '-' || c == '*' || c == '/' || c == '^') {
        // Handle unary minus: only if we are NOT mid-number (buf is empty)
        // and at the start or after an operator/open-paren
        if (c == '-' && buf.isEmpty &&
            (tokens.isEmpty ||
                tokens.last == '(' ||
                tokens.last == '+' ||
                tokens.last == '-' ||
                tokens.last == '*' ||
                tokens.last == '/' ||
                tokens.last == '^')) {
          buf.write(c);
        } else {
          if (buf.isNotEmpty) {
            tokens.add(buf.toString());
            buf.clear();
          }
          tokens.add(c);
        }
      } else if (c == '%') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
        tokens.add('%');
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());
    return tokens;
  }

  /// Recursive-descent evaluator using a class to avoid Dart's
  /// forward-reference limitation with local functions.
  static double _evaluate(String expr) {
    final tokens = _tokenize(expr);
    return _Parser(tokens).parse();
  }
}

/// Recursive-descent parser for arithmetic expressions.
class _Parser {
  final List<String> tokens;
  int pos = 0;

  _Parser(this.tokens);

  double parse() {
    final result = _parseAddSub();
    if (pos < tokens.length) return double.nan;
    return result;
  }

  double _parseAddSub() {
    var left = _parseMulDiv();
    while (pos < tokens.length && (tokens[pos] == '+' || tokens[pos] == '-')) {
      final op = tokens[pos++];
      final right = _parseMulDiv();
      left = op == '+' ? left + right : left - right;
    }
    return left;
  }

  double _parseMulDiv() {
    var left = _parseUnary();
    while (pos < tokens.length && (tokens[pos] == '*' || tokens[pos] == '/')) {
      final op = tokens[pos++];
      final right = _parseUnary();
      left = op == '*' ? left * right : left / right;
    }
    return left;
  }

  double _parseUnary() {
    if (pos < tokens.length && tokens[pos] == '-') {
      pos++;
      return -_parseUnary();
    }
    return _parsePower();
  }

  /// Exponent. A unary minus is folded into the base by the tokenizer, so
  /// -2^2 = (-2)^2 = 4 (like a phone calculator); a binary minus applies
  /// after the exponent: 0-2^2 = -4.
  double _parsePower() {
    final left = _parsePostfix();
    if (pos < tokens.length && tokens[pos] == '^') {
      pos++;
      final right = _parseUnary(); // right-associative; allows 2^-1
      return math.pow(left, right).toDouble();
    }
    return left;
  }

  /// Percent is postfix: 50% → 0.5.
  double _parsePostfix() {
    var v = _parseAtom();
    while (pos < tokens.length && tokens[pos] == '%') {
      pos++;
      v /= 100.0;
    }
    return v;
  }

  double _parseAtom() {
    if (pos >= tokens.length) return 0;
    if (tokens[pos] == '(') {
      pos++; // skip '('
      final val = _parseAddSub();
      if (pos < tokens.length && tokens[pos] == ')') pos++; // skip ')'
      return val;
    }
    return double.parse(tokens[pos++]);
  }
}

/// The result of evaluating a math expression.
class MathResult {
  /// The original expression (without the trailing `=`).
  final String expression;

  /// The computed numeric result.
  final double value;

  /// A human-readable formatted result string.
  final String formatted;

  const MathResult({
    required this.expression,
    required this.value,
    required this.formatted,
  });

  @override
  String toString() => '$expression = $formatted';
}

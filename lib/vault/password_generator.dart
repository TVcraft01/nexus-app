import 'dart:math';

/// Cryptographically secure password generator.
///
/// Uses [Random.secure()] for randomness — never [Random()] which is predictable.
/// Character sets are configurable; the generator guarantees at least one
/// character from each enabled set is included.
class PasswordGenerator {
  PasswordGenerator._();

  static const uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const lowercase = 'abcdefghijklmnopqrstuvwxyz';
  static const digits = '0123456789';
  static const symbols = '!@#\$%^&*()_+-=[]{}|;:,.<>?';

  /// Generates a password of [length] characters using the specified character
  /// sets. At least one character from each enabled set is guaranteed.
  ///
  /// Throws [ArgumentError] if [length] is less than the number of enabled
  /// character sets (to ensure the "at least one from each" guarantee).
  static String generate({
    int length = 16,
    bool useUppercase = true,
    bool useLowercase = true,
    bool useDigits = true,
    bool useSymbols = true,
  }) {
    final charPool = StringBuffer();
    final required = <String>[];

    if (useUppercase) {
      charPool.write(uppercase);
      required.add(_securePick(uppercase));
    }
    if (useLowercase) {
      charPool.write(lowercase);
      required.add(_securePick(lowercase));
    }
    if (useDigits) {
      charPool.write(digits);
      required.add(_securePick(digits));
    }
    if (useSymbols) {
      charPool.write(symbols);
      required.add(_securePick(symbols));
    }

    if (charPool.isEmpty) {
      throw ArgumentError('At least one character set must be enabled');
    }

    final pool = charPool.toString();
    if (length < required.length) {
      throw ArgumentError(
        'Length ($length) must be at least ${required.length} '
        '(one per enabled character set)',
      );
    }

    // Fill remaining slots from the full pool
    final remaining = length - required.length;
    final chars = List<String>.from(required);
    for (var i = 0; i < remaining; i++) {
      chars.add(_securePick(pool));
    }

    // Shuffle to avoid predictable positions of required characters
    _secureShuffle(chars);

    return chars.join();
  }

  /// Picks a single random character from [pool] using cryptographic randomness.
  static String _securePick(String pool) {
    return pool[Random.secure().nextInt(pool.length)];
  }

  /// Fisher-Yates shuffle using [Random.secure()].
  static void _secureShuffle(List<String> list) {
    final rng = Random.secure();
    for (var i = list.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final temp = list[i];
      list[i] = list[j];
      list[j] = temp;
    }
  }
}

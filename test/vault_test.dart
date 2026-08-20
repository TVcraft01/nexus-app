import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/vault/password_generator.dart';
import 'package:nexus_app/vault/vault_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PasswordGenerator', () {
    test('generates password of correct length', () {
      final pw = PasswordGenerator.generate(length: 20);
      expect(pw.length, 20);
    });

    test('generates password with all character sets', () {
      final pw = PasswordGenerator.generate(
        length: 100,
        useUppercase: true,
        useLowercase: true,
        useDigits: true,
        useSymbols: true,
      );
      expect(pw, matches(RegExp(r'[A-Z]'))); // has uppercase
      expect(pw, matches(RegExp(r'[a-z]'))); // has lowercase
      expect(pw, matches(RegExp(r'[0-9]'))); // has digit
      expect(pw, matches(RegExp(r'[!@#\$%^&*()_+\-=\[\]{}|;:,.<>?]'))); // has symbol
    });

    test('generates password with only lowercase', () {
      final pw = PasswordGenerator.generate(
        length: 50,
        useUppercase: false,
        useLowercase: true,
        useDigits: false,
        useSymbols: false,
      );
      expect(pw.length, 50);
      expect(pw, matches(RegExp(r'^[a-z]+$')));
    });

    test('generates password with only digits', () {
      final pw = PasswordGenerator.generate(
        length: 8,
        useUppercase: false,
        useLowercase: false,
        useDigits: true,
        useSymbols: false,
      );
      expect(pw.length, 8);
      expect(pw, matches(RegExp(r'^[0-9]+$')));
    });

    test('throws when no character sets enabled', () {
      expect(
        () => PasswordGenerator.generate(
          useUppercase: false,
          useLowercase: false,
          useDigits: false,
          useSymbols: false,
        ),
        throwsArgumentError,
      );
    });

    test('throws when length < number of enabled sets', () {
      expect(
        () => PasswordGenerator.generate(
          length: 2,
          useUppercase: true,
          useLowercase: true,
          useDigits: true,
        ),
        throwsArgumentError,
      );
    });

    test('generates different passwords each time (statistical)', () {
      final passwords = <String>{};
      for (var i = 0; i < 100; i++) {
        passwords.add(PasswordGenerator.generate(length: 16));
      }
      // With 100 tries, we should get at least 90 unique passwords
      expect(passwords.length, greaterThanOrEqualTo(90));
    });

    test('default length is 16', () {
      final pw = PasswordGenerator.generate();
      expect(pw.length, 16);
    });
  });

  group('VaultEntry', () {
    test('create sets timestamps', () {
      final entry = VaultEntry.create(
        id: 'test-id',
        name: 'Example',
        username: 'user@example.com',
        password: 'secret123',
      );
      expect(entry.id, 'test-id');
      expect(entry.name, 'Example');
      expect(entry.username, 'user@example.com');
      expect(entry.password, 'secret123');
      expect(entry.createdAt, isA<DateTime>());
      expect(entry.updatedAt, isA<DateTime>());
    });

    test('toJson/fromJson round-trip preserves all fields', () {
      final entry = VaultEntry.create(
        id: 'test-id',
        name: 'Example',
        username: 'user@example.com',
        password: 'secret123',
        notes: 'Some notes',
      );
      final json = entry.toJson();
      final restored = VaultEntry.fromJson(json);
      expect(restored.id, entry.id);
      expect(restored.name, entry.name);
      expect(restored.username, entry.username);
      expect(restored.password, entry.password);
      expect(restored.notes, entry.notes);
    });

    test('encode/decode round-trip preserves all fields', () {
      final entry = VaultEntry.create(
        id: 'test-id',
        name: 'Example',
        username: 'user@example.com',
        password: 'secret123',
      );
      final encoded = entry.encode();
      final decoded = VaultEntry.decode(encoded);
      expect(decoded.id, entry.id);
      expect(decoded.password, entry.password);
    });

    test('copyWith updates specified fields', () {
      final entry = VaultEntry.create(
        id: 'test-id',
        name: 'Example',
        username: 'user@example.com',
        password: 'old-password',
      );
      final updated = entry.copyWith(password: 'new-password');
      expect(updated.password, 'new-password');
      expect(updated.name, 'Example'); // unchanged
      expect(updated.id, 'test-id'); // unchanged
    });

    test('toString does NOT include password', () {
      final entry = VaultEntry.create(
        id: 'test-id',
        name: 'Example',
        username: 'user@example.com',
        password: 'super-secret-password',
      );
      final str = entry.toString();
      expect(str, isNot(contains('super-secret-password')));
      expect(str, contains('Example'));
    });
  });

  group('Security invariants', () {
    test('VaultEntry.toString never contains password', () {
      // Use passwords that are unique enough not to appear in other fields
      final passwords = ['abc123', 'P@ssw0rd!', 'zzz999xxx', 'x'.padRight(1000, 'y')];
      for (final pw in passwords) {
        final entry = VaultEntry.create(
          id: 'id',
          name: 'name',
          username: 'user',
          password: pw,
        );
        expect(entry.toString(), isNot(contains(pw)),
            reason: 'Password "$pw" leaked in toString()');
      }
    });

    test('VaultEntry.toJson contains password (for storage) but not in toString', () {
      final entry = VaultEntry.create(
        id: 'id',
        name: 'name',
        username: 'user',
        password: 'secret',
      );
      // toJson must contain password for secure storage
      expect(entry.toJson()['password'], 'secret');
      // But toString must not
      expect(entry.toString(), isNot(contains('secret')));
    });
  });
}

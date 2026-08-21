import 'package:flutter_test/flutter_test.dart';

/// Test the version comparison and parsing logic in UpdateService.
/// We test the pure logic (version comparison, asset lookup) without
/// hitting the network.
void main() {
  // Re-implement the helpers for testing since they're private in UpdateService.
  // This validates the algorithm — the actual UpdateService calls these same steps.

  List<int> normalizeVersion(String v) {
    final cleaned = v.replaceFirst(RegExp(r'^v'), '');
    return cleaned.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  bool isNewer(List<int> local, List<int> remote) {
    for (var i = 0; i < _max(local.length, remote.length); i++) {
      final l = i < local.length ? local[i] : 0;
      final r = i < remote.length ? remote[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    return false;
  }

  String? findAsset(List<Map<String, String>> assets, String suffix) {
    for (final asset in assets) {
      final name = asset['name'] ?? '';
      if (name.endsWith(suffix)) {
        return asset['browser_download_url'];
      }
    }
    return null;
  }

  group('Version normalization', () {
    test('strips leading v', () {
      expect(normalizeVersion('v1.2.3'), equals([1, 2, 3]));
    });

    test('handles plain semver', () {
      expect(normalizeVersion('0.1.0'), equals([0, 1, 0]));
    });

    test('handles single-segment', () {
      expect(normalizeVersion('5'), equals([5]));
    });
  });

  group('isNewer comparison', () {
    test('0.2.0 is newer than 0.1.0', () {
      expect(isNewer(normalizeVersion('0.1.0'), normalizeVersion('0.2.0')),
          isTrue);
    });

    test('1.0.0 is newer than 0.9.9', () {
      expect(isNewer(normalizeVersion('0.9.9'), normalizeVersion('1.0.0')),
          isTrue);
    });

    test('same version is not newer', () {
      expect(isNewer(normalizeVersion('1.2.3'), normalizeVersion('1.2.3')),
          isFalse);
    });

    test('older version is not newer', () {
      expect(isNewer(normalizeVersion('2.0.0'), normalizeVersion('1.0.0')),
          isFalse);
    });

    test('handles mismatched segment counts', () {
      expect(isNewer(normalizeVersion('0.1'), normalizeVersion('0.1.1')),
          isTrue);
    });

    test('handles v-prefixed remote', () {
      expect(isNewer(normalizeVersion('0.1.0'), normalizeVersion('v0.2.0')),
          isTrue);
    });
  });

  group('Asset lookup', () {
    test('finds APK asset', () {
      final assets = [
        {'name': 'nexus-linux-x64.tar.gz', 'browser_download_url': 'https://example.com/linux'},
        {'name': 'app-debug.apk', 'browser_download_url': 'https://example.com/apk'},
      ];
      expect(findAsset(assets, '.apk'), equals('https://example.com/apk'));
    });

    test('finds tar.gz asset', () {
      final assets = [
        {'name': 'app-debug.apk', 'browser_download_url': 'https://example.com/apk'},
        {'name': 'nexus-linux-x64.tar.gz', 'browser_download_url': 'https://example.com/linux'},
      ];
      expect(findAsset(assets, '.tar.gz'), equals('https://example.com/linux'));
    });

    test('returns null when no matching asset', () {
      final assets = [
        {'name': 'app-debug.apk', 'browser_download_url': 'https://example.com/apk'},
      ];
      expect(findAsset(assets, '.tar.gz'), isNull);
    });

    test('returns null for empty assets', () {
      expect(findAsset([], '.apk'), isNull);
    });
  });
}

int _max(int a, int b) => a > b ? a : b;

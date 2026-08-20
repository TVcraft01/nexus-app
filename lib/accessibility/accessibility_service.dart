import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side interface to the Android AccessibilityService. Provides:
///  - Checking whether the OS-level accessibility service is enabled
///  - Deep-linking to Android's Accessibility Settings (user must flip it)
///  - Reading the current screen's simplified element tree
///  - Performing a single tap or text-input action
///
/// All screen content is processed entirely by the on-device LLM — never sent
/// externally. This is a platform channel wrapper; on non-Android platforms
/// every method returns a clear "not available" result.
class AccessibilityService {
  AccessibilityService._();
  static final AccessibilityService instance = AccessibilityService._();

  static const _channel = MethodChannel('com.example.nexus_app/accessibility');

  final ValueNotifier<bool> _serviceRunning = ValueNotifier(false);

  /// Whether the Android AccessibilityService is currently connected.
  ValueListenable<bool> get serviceRunning => _serviceRunning;

  bool _initialized = false;

  /// Call once at startup to set up the platform channel listener.
  void init() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAccessibilityServiceChanged':
          _serviceRunning.value = call.arguments as bool;
          break;
      }
    });

    // Check current state
    _checkServiceStatus();
  }

  Future<void> _checkServiceStatus() async {
    if (!Platform.isAndroid) {
      _serviceRunning.value = false;
      return;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isAccessibilityServiceEnabled');
      _serviceRunning.value = result ?? false;
    } catch (_) {
      _serviceRunning.value = false;
    }
  }

  /// Refresh the service status (e.g. after returning from Settings).
  Future<void> refreshStatus() async => _checkServiceStatus();

  /// Deep-links to Android's Accessibility Settings. Nexus cannot enable the
  /// service programmatically — this is intentional OS security. The user must
  /// flip the toggle themselves.
  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } catch (_) {
      // Best-effort: the toggle itself has already taken effect regardless.
    }
  }

  /// Returns the simplified screen tree of the current foreground app as a
  /// JSON string. The tree contains element IDs, text labels, roles, bounds,
  /// and interactivity flags — enough for the LLM to reason over, but not
  /// a raw dump of the entire view hierarchy.
  ///
  /// Returns null if the accessibility service is not running.
  Future<String?> getScreenTree() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getScreenTree');
    } catch (_) {
      return null;
    }
  }

  /// Taps the center of the element identified by [elementId] in the given
  /// [screenTree] JSON. Returns true if the gesture was dispatched.
  Future<bool> tapElement({
    required String screenTree,
    required int elementId,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('tapElement', {
        'screenTree': screenTree,
        'elementId': elementId,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Types [text] into the element identified by [elementId] in the given
  /// [screenTree] JSON. Returns true if the text was set.
  Future<bool> typeIntoElement({
    required String screenTree,
    required int elementId,
    required String text,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('typeIntoElement', {
        'screenTree': screenTree,
        'elementId': elementId,
        'text': text,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // Financial-app detection
  // -----------------------------------------------------------------------

  /// Known financial/banking/payment package prefixes. Used to refuse acting
  /// in high-stakes apps where a misclick could move real money.
  static const _financialPackages = [
    'com.paypal.',
    'com.venmo',
    'com.squareup.cash',
    'com.zelle.',
    'com.bankofamerica.',
    'com.chase.',
    'com.wellsfargo.',
    'com.citi.',
    'com.usaa.',
    'com.capitalone.',
    'com.discover.',
    'com.americanexpress.',
    'com.goldmansachs.',
    'com.schwab.',
    'com.fidelity.',
    'com.vanguard.',
    'com.robinhood.',
    'com.coinbase.',
    'com.kraken.',
    'com.binance.',
    'com.block.',
    'com.revolut.',
    'com.monzo.',
    'com.n26.',
    'com.starling.',
    'com.td.',
    'com.rbc.',
    'com.scotiabank.',
    'com.bmo.',
    'com.nationwide.',
    'com.barclays.',
    'com.hsbc.',
    'com.lloyds.',
    'com.natwest.',
    'com.santander.',
    'com.bbva.',
    'com.deutschebank.',
    'com.db.',
    'com.ing.',
    'com.abnamro.',
    'com.postfinance.',
    'com.ubs.',
    'com.credit.suisse.',
    'com WESTPAC.',
    'com.commbank.',
    'com.anz.',
    'com.nab.',
  ];

  /// Returns true if the foreground app looks like a financial or banking app.
  /// This is a best-effort heuristic — not every financial app is covered, so
  /// this is explicitly documented as an open risk rather than a guarantee.
  static bool looksFinancial(String packageName) {
    final lower = packageName.toLowerCase();
    return _financialPackages.any((prefix) => lower.startsWith(prefix.toLowerCase()));
  }
}

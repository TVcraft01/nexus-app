import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'math_trigger_detector.dart';
import '../accessibility/accessibility_service.dart';

/// Manages the "math notes" feature: listens for text changes from the
/// accessibility service, detects arithmetic expressions, and shows results
/// in a floating overlay.
///
/// This feature is Android-only and requires:
///  1. The OS-level accessibility service to be enabled
///  2. The Nexus-side "Math notes" toggle to be ON (default OFF)
///
/// **Privacy guarantees:**
///  - Password/secure fields are never processed (checked on Kotlin side)
///  - Financial apps are never processed (checked on Kotlin side)
///  - Text that doesn't match the arithmetic regex is immediately discarded
///  - No text is ever stored, transmitted, or logged
class MathNotesService {
  MathNotesService._();
  static final MathNotesService instance = MathNotesService._();

  static const _channel = MethodChannel('com.example.nexus_app/math_notes');
  static const _prefsKey = 'nexus_math_notes_enabled';

  /// Overridden by tests to exercise the Android channel path on any host.
  @visibleForTesting
  static bool debugIsAndroid = Platform.isAndroid;

  final ValueNotifier<bool> _enabled = ValueNotifier(false);
  final ValueNotifier<MathOverlay?> _overlay = ValueNotifier(null);

  bool _initialized = false;

  /// Whether the math notes feature is enabled by the user.
  ValueNotifier<bool> get enabled => _enabled;

  /// Whether the app may draw the result overlay over other apps. Android
  /// requires the user to grant "Display over other apps" at runtime — the
  /// manifest permission alone is not enough.
  ValueNotifier<bool> canDrawOverlays = ValueNotifier(false);

  /// The current overlay to display (null when no result is showing).
  ValueNotifier<MathOverlay?> get overlay => _overlay;

  /// Initialize the service. Call once at startup.
  void init() {
    if (_initialized) return;
    _initialized = true;

    if (!debugIsAndroid) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTextChanged') {
        final text = call.arguments['text'] as String? ?? '';
        final packageName = call.arguments['packageName'] as String? ?? '';
        _onTextChanged(text, packageName);
      }
    });

    // Load persisted state
    _loadEnabled();
  }

  Future<void> _loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled.value = prefs.getBool(_prefsKey) ?? false;
    _syncToNative();
    await refreshOverlayPermission();
  }

  /// Toggle the math notes feature on/off.
  Future<void> setEnabled(bool value) async {
    _enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
    _syncToNative();
    if (!value) _clearOverlay();
  }

  void _syncToNative() {
    if (!debugIsAndroid) return;
    // Best-effort: never let a platform-channel error (e.g. a missing native
    // handler) surface as an unhandled async exception during startup.
    unawaited(
      _channel
          .invokeMethod<void>(
              'setMathNotesEnabled', {'enabled': _enabled.value})
          .catchError((_) {}),
    );
  }

  /// Refreshes whether the app may draw overlays over other apps. Call after
  /// the user returns from the overlay-permission settings screen.
  Future<void> refreshOverlayPermission() async {
    if (!debugIsAndroid) return;
    try {
      final ok = await _channel.invokeMethod<bool>('canDrawOverlays');
      canDrawOverlays.value = ok ?? false;
    } catch (_) {
      canDrawOverlays.value = false;
    }
  }

  /// Deep-links to the OS screen where the user grants "Display over other
  /// apps". Nexus cannot grant this itself — the user must approve it.
  Future<void> openOverlaySettings() async {
    if (!debugIsAndroid) return;
    try {
      await _channel.invokeMethod('openOverlaySettings');
    } catch (_) {
      // Best-effort: the permission screen is a convenience, not critical.
    }
  }

  /// Called when the accessibility service reports a text change.
  void _onTextChanged(String text, String packageName) {
    if (!_enabled.value) return;

    // Safeguard: financial apps should never reach here (checked on Kotlin
    // side), but double-check on the Dart side too.
    if (AccessibilityService.looksFinancial(packageName)) return;

    // Run the detector — if it doesn't match, text is immediately discarded
    final result = MathTriggerDetector.detect(text);
    if (result == null) {
      _clearOverlay();
      return;
    }

    _overlay.value = MathOverlay(
      expression: result.expression,
      result: result.formatted,
      packageName: packageName,
    );
  }

  void _clearOverlay() {
    _overlay.value = null;
  }

  /// Dismiss the current overlay.
  void dismiss() {
    _clearOverlay();
  }

  /// Copy the result to clipboard and dismiss the overlay.
  Future<void> copyResult(BuildContext context) async {
    final o = _overlay.value;
    if (o == null) return;
    // Copy to clipboard would use Clipboard.setData — but we need context.
    // The caller handles this.
    _clearOverlay();
  }
}

/// Data for a floating math result overlay.
class MathOverlay {
  final String expression;
  final String result;
  final String packageName;

  const MathOverlay({
    required this.expression,
    required this.result,
    required this.packageName,
  });
}

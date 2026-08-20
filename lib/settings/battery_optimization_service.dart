import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// User-controlled Android background-reliability settings.
///
/// This only requests the OS battery-optimization exemption; it cannot and
/// does not silently change Samsung's separate sleeping-app policy.
class BatteryOptimizationService {
  BatteryOptimizationService._();

  static final BatteryOptimizationService instance =
      BatteryOptimizationService._();

  static const _channel =
      MethodChannel('com.example.nexus_app/battery_optimization');

  final ValueNotifier<bool> ignoringBatteryOptimizations =
      ValueNotifier<bool>(false);

  Future<void> refresh() async {
    if (!Platform.isAndroid) {
      ignoringBatteryOptimizations.value = false;
      return;
    }
    try {
      ignoringBatteryOptimizations.value =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
              false;
    } catch (_) {
      ignoringBatteryOptimizations.value = false;
    }
  }

  /// Opens Android's explicit user-consent dialog for this app.
  Future<void> requestExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {
      // The Settings entry remains usable even on an OEM that rejects the
      // request intent; the user can use the manual battery settings link.
    }
    await refresh();
  }

  /// Opens Android's battery-optimization app list as a manual fallback.
  Future<void> openBatterySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openBatterySettings');
    } catch (_) {
      // Best effort only; no background permission is changed silently.
    }
  }
}

import 'dart:io';

import 'package:flutter/services.dart';

import 'vault_service.dart';

/// Bridges the Dart vault to the Android AutofillService.
///
/// When the vault is unlocked, credentials are synced to the native side
/// so the OS can present them during autofill. When locked, the cache is cleared.
class AutofillBridge {
  static const _channel = MethodChannel('com.example.nexus_app/accessibility');

  static final AutofillBridge instance = AutofillBridge._();
  AutofillBridge._();

  /// Sync all vault entries to the native autofill service.
  /// Call this when the vault is unlocked.
  Future<void> syncCredentials() async {
    if (!Platform.isAndroid) return;
    try {
      final entries = await VaultService.instance.getAll();
      final credentials = entries
          .map((e) => {
                'name': e.name,
                'username': e.username,
                'password': e.password,
              })
          .toList();
      await _channel.invokeMethod('syncAutofillCredentials', {
        'entries': credentials,
      });
    } catch (e) {
      // Best-effort — autofill is a convenience, not a requirement.
    }
  }

  /// Clear the native autofill credential cache.
  /// Call this when the vault is locked.
  Future<void> clearCredentials() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('clearAutofillCredentials');
    } catch (_) {}
  }

  /// Open Android's autofill service settings so the user can enable Nexus.
  Future<void> openAutofillSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openAutofillSettings');
    } catch (_) {}
  }
}

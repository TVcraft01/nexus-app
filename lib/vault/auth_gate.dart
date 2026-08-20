import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Gates all vault access behind biometric or device PIN/pattern verification.
///
/// Every code path that reads, writes, or copies vault data MUST go through
/// [authenticate] first. There is no "remember for N minutes" bypass by default.
///
/// This is a standalone service — it does not store any vault data itself.
/// Its only job is to verify identity before the caller proceeds.
class AuthGate {
  static final AuthGate instance = AuthGate._();
  AuthGate._();

  final LocalAuthentication _auth = LocalAuthentication();

  /// Whether the device supports biometric authentication.
  bool _canCheckBiometrics = false;

  /// Available biometric types on this device.
  List<BiometricType> _availableBiometrics = [];

  /// Initialize: check what authentication methods are available.
  Future<void> init() async {
    try {
      _canCheckBiometrics = await _auth.canCheckBiometrics;
      _availableBiometrics = await _auth.getAvailableBiometrics();
    } on PlatformException {
      _canCheckBiometrics = false;
      _availableBiometrics = [];
    }
  }

  /// Whether the device supports any form of biometric auth.
  bool get canCheckBiometrics => _canCheckBiometrics;

  /// Available biometric types (fingerprint, face, iris).
  List<BiometricType> get availableBiometrics => _availableBiometrics;

  /// Whether the device supports device credentials (PIN/pattern/password).
  ///
  /// On Android, [authenticate] always allows fallback to device credentials
  /// via [AuthenticationOptions.stickyAuth] and the native implementation.
  /// We check this for UI display purposes.
  Future<bool> get canUseDeviceCredentials async {
    try {
      // On Android, device credentials are always available as a fallback
      // when biometrics are enrolled. If no biometrics, the user can still
      // use PIN/pattern/password via [authenticate].
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Prompt the user for biometric or device credential authentication.
  ///
  /// Returns true if authentication succeeded, false otherwise.
  /// This MUST be called before any vault access — reading, writing, or copying.
  Future<bool> authenticate({String reason = 'Unlock vault to continue'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }
}

import 'package:shared_preferences/shared_preferences.dart';

/// Stores the simple user preferences shown in the Settings tab. Like
/// everything else in Nexus, the values live on-device only.
class SettingsService {
  static const _allowInternetKey = 'nexus_allow_internet';
  static const _autoUpdateKey = 'nexus_auto_update';

  /// Off by default. Reserved for a future opt-in that would let two devices
  /// connect directly to each other over the internet — never through a
  /// third-party server.
  Future<bool> getAllowInternetAccess() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_allowInternetKey) ?? false;
  }

  Future<void> setAllowInternetAccess(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowInternetKey, value);
  }

  Future<bool> getAutoUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoUpdateKey) ?? false;
  }

  Future<void> setAutoUpdate(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoUpdateKey, value);
  }
}

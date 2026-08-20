import 'package:shared_preferences/shared_preferences.dart';

/// Stores the simple user preferences shown in the Settings tab. Like
/// everything else in Nexus, the values live on-device only.
class SettingsService {
  static const _allowInternetKey = 'nexus_allow_internet';
  static const _autoUpdateKey = 'nexus_auto_update';
  static const _allowDevTasksKey = 'nexus_allow_dev_tasks';
  static const _devTaskCommandKey = 'nexus_dev_task_command';
  static const _devTaskCwdKey = 'nexus_dev_task_cwd';
  static const _assistAppKey = 'nexus_assist_app';

  /// Default command shown on a device that enables "Allow remote dev tasks"
  /// before configuring anything. It exists so a request never runs against
  /// an empty/undefined command and always returns a clear report. The user
  /// replaces it with a real wrapper (see README -> Remote dev tasks).
  static const defaultDevTaskCommand = 'echo "Remote dev tasks are enabled '
      'on this PC, but no task command is configured yet. Edit the command in '
      'Settings > Developer bridge (a wrapper script that runs your coding '
      'agent headlessly). Prompt received: {prompt}"';

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

  // ---- Remote dev tasks (the dev bridge) --------------------------------

  /// Whether a paired device may submit a dev task to THIS device.
  ///
  /// Deliberately separate from [getAllowInternetAccess]: a device can be
  /// reachable over the internet without letting a peer run code on it.
  /// Default OFF, and turning it on requires a confirmation in the UI.
  Future<bool> getAllowDevTasks() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_allowDevTasksKey) ?? false;
  }

  Future<void> setAllowDevTasks(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowDevTasksKey, value);
  }

  /// The shell command a dev task runs, with {prompt} and {promptFile}
  /// placeholders. See [defaultDevTaskCommand].
  Future<String> getDevTaskCommand() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_devTaskCommandKey) ?? defaultDevTaskCommand;
  }

  Future<void> setDevTaskCommand(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_devTaskCommandKey, value);
  }

  /// Working directory the dev-task command runs in (e.g. the repo path).
  /// Defaults to the app's current directory when empty.
  Future<String> getDevTaskCwd() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_devTaskCwdKey) ?? '';
  }

  Future<void> setDevTaskCwd(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_devTaskCwdKey, value);
  }

  // ---- Assist with other apps (accessibility) ---------------------------

  /// Whether Nexus may use the Accessibility service to read the screen and
  /// perform a single user-requested action in another app. Default OFF.
  /// Requires both this toggle AND the OS-level accessibility service to be
  /// enabled.
  Future<bool> getAssistApp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_assistAppKey) ?? false;
  }

  Future<void> setAssistApp(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_assistAppKey, value);
  }
}

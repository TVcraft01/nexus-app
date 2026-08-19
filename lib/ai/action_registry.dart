import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nexus_brain.dart';

/// One user-controllable Nexus action: its command, how it is described in the
/// UI, the phrases that trigger it in command mode, and (when relevant) the
/// Android runtime permission it depends on.
///
/// This is the single source of truth shared by the Settings toggle screen,
/// the "What can I say?" help screen, and the local-model schema — so a new
/// action is added in exactly one place.
class NexusActionDefinition {
  final NexusCommand command;

  /// The token the LLM schema uses for this command (e.g. "createFolder").
  final String schemaName;

  final String title;
  final IconData icon;
  final String description;
  final List<String> examples;

  /// The Android runtime permission this action relies on, if any. Used to
  /// offer a deep link to system settings when the action is turned off, since
  /// Android does not let an app revoke its own permissions programmatically.
  final String? runtimePermission;

  const NexusActionDefinition({
    required this.command,
    required this.schemaName,
    required this.title,
    required this.icon,
    required this.description,
    required this.examples,
    this.runtimePermission,
  });
}

/// Every action Nexus can perform, in the order they appear in Settings and on
/// the help screen. [NexusCommand.unknown] is deliberately not listed — it is
/// the fallback reply, not a user-controllable action.
const List<NexusActionDefinition> nexusActions = [
  NexusActionDefinition(
    command: NexusCommand.createFolder,
    schemaName: 'createFolder',
    title: 'Create a folder',
    icon: Icons.create_new_folder_outlined,
    description: 'Creates a folder inside your Nexus documents folder. Use '
        '"named" or "called" to pick the folder name.',
    examples: [
      'create a folder',
      'create a folder named recipes',
      'make a directory called notes',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.openWifiSettings,
    schemaName: 'openWifiSettings',
    title: 'Open Wi-Fi settings',
    icon: Icons.wifi,
    description: 'Opens this device\'s system Wi-Fi settings screen.',
    examples: [
      'open Wi-Fi settings',
      'open wireless settings',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.setReminder,
    schemaName: 'setReminder',
    title: 'Set a reminder',
    icon: Icons.alarm,
    description: 'Schedules a notification. Say "in N minutes/hours" or '
        '"at HH:MM" (am/pm optional) to set the time.',
    examples: [
      'remind me in 30 minutes',
      'remind me to call Sam at 7 pm',
      'remind me to stretch in 2 hours',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.setAlarm,
    schemaName: 'setAlarm',
    title: 'Set an alarm',
    icon: Icons.alarm_on_outlined,
    description: 'Opens your Clock app with an alarm pre-filled. On Android '
        'only — other platforms say so honestly instead of doing nothing.',
    examples: [
      'set an alarm for 7 am',
      'set an alarm at 6:30 pm',
      'set an alarm for 19:00',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.setTimer,
    schemaName: 'setTimer',
    title: 'Set a timer',
    icon: Icons.timer_outlined,
    description: 'Opens your Clock app with a countdown timer pre-filled. '
        'Android only, like alarms.',
    examples: [
      'set a timer for 10 minutes',
      'set a timer for 30 seconds',
      'set a timer for 2 hours',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.playDeezerFlow,
    schemaName: 'playDeezerFlow',
    title: 'Play Deezer Flow',
    icon: Icons.music_note_outlined,
    description: 'Opens Deezer and starts Flow. Works on Android and Linux '
        'when Deezer is installed; otherwise it says so.',
    examples: [
      'play Deezer Flow',
      'play my Flow on Deezer',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.callContact,
    schemaName: 'callContact',
    title: 'Call someone',
    icon: Icons.call_outlined,
    description: 'Opens your dialer pre-filled with the number — you tap call '
        'yourself, so Nexus never places a call. Names are looked up in your '
        'contacts (asking permission the first time); otherwise say the '
        'number.',
    examples: [
      'call Sam',
      'call 555-1234',
      'dial 911',
    ],
    runtimePermission: 'android.permission.READ_CONTACTS',
  ),
  NexusActionDefinition(
    command: NexusCommand.openEmail,
    schemaName: 'openEmail',
    title: 'Open email',
    icon: Icons.email_outlined,
    description: 'Opens your default email app (or Gmail). It never reads or '
        'connects to your mail — it only opens the app for you.',
    examples: [
      'check email',
      'open Gmail',
      'open my inbox',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.navigate,
    schemaName: 'navigate',
    title: 'Navigate / get directions',
    icon: Icons.directions_outlined,
    description: 'Starts turn-by-turn navigation to a place. On Android it '
        'hands off to your maps app; other platforms say so honestly instead '
        'of doing nothing.',
    examples: [
      'navigate to the nearest pharmacy',
      'get directions to work',
      'drive to 1 Main Street',
    ],
  ),
  NexusActionDefinition(
    command: NexusCommand.setPreference,
    schemaName: 'setPreference',
    title: 'Choose which device notifies you',
    icon: Icons.notifications_outlined,
    description: 'Tells Nexus to only interrupt you on one paired device for '
        'reminders. Reminders still sync everywhere; only the chosen device '
        'fires a notification. Clear it in Settings -> Notifications.',
    examples: [
      'only remind me on my phone',
      'always notify me on my phone',
      'notifications only on my laptop',
    ],
  ),
];

/// Looks up the catalogue entry for [command], or null when there isn't one
/// (e.g. [NexusCommand.unknown]).
NexusActionDefinition? actionDefinitionFor(NexusCommand command) {
  for (final def in nexusActions) {
    if (def.command == command) return def;
  }
  return null;
}

/// The reply shared by both brains and the runner when a recognized action has
/// been turned off in Settings -> Actions & permissions.
String disabledActionReply(NexusCommand command) {
  final title = actionDefinitionFor(command)?.title ?? 'That action';
  return '$title is turned off. Re-enable it in Settings → '
      'Actions & permissions.';
}

/// Persisted on/off switches for each action. The default is every action ON,
/// so a user who never opens this screen sees no change in behaviour.
///
/// Kept as a [ChangeNotifier] so the Settings screen, help screen, and any
/// live listeners rebuild the moment an action is toggled.
class ActionRegistry extends ChangeNotifier {
  static const _keyPrefix = 'nexus_action_enabled_';

  static final ActionRegistry instance = ActionRegistry();

  final Map<NexusCommand, bool> _disabled = {};

  /// True unless the user has explicitly turned [command] off.
  bool isEnabled(NexusCommand command) {
    if (command == NexusCommand.unknown) return true;
    return !(_disabled[command] ?? false);
  }

  Future<void> setEnabled(NexusCommand command, bool enabled) async {
    if (enabled) {
      _disabled.remove(command);
    } else {
      _disabled[command] = true;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_keyPrefix${command.name}', enabled);
  }

  /// Loads the persisted toggles. Call once at startup; until then the default
  /// (all ON) applies, which is safe for the first frame.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    for (final def in nexusActions) {
      if (prefs.getBool('$_keyPrefix${def.command.name}') == false) {
        _disabled[def.command] = true;
      }
    }
    notifyListeners();
  }

  /// Test-only: resets every toggle back to the default (all ON).
  @visibleForTesting
  void debugReset() {
    _disabled.clear();
    notifyListeners();
  }
}

/// The LLM schema tokens for the actions currently enabled, plus "chat" so the
/// model can still answer conversationally when nothing matches.
List<String> enabledActionTokens() => [
      for (final def in nexusActions)
        if (ActionRegistry.instance.isEnabled(def.command)) def.schemaName,
      'chat',
    ];

import 'package:flutter/material.dart';

/// The \"What can I say?\" screen: the list of actions Nexus actually
/// understands right now.
///
/// EXTENSION POINT: when a new action is wired into KeywordBrain (and its
/// runner), add exactly one [CommandHelpEntry] to [commandHelpEntries] below —
/// that's all that's needed for it to show up here. Keep the examples
/// copy-pasteable from the real match patterns, not invented phrasings.
class CommandHelpEntry {
  final String title;
  final IconData icon;
  final String description;
  final List<String> examples;

  const CommandHelpEntry({
    required this.title,
    required this.icon,
    required this.description,
    required this.examples,
  });
}

/// The currently wired actions. The keywords in [CommandHelpEntry.examples]
/// are taken verbatim from the KeywordBrain match patterns in
/// lib/ai/keyword_brain.dart — they are the phrases that really trigger each
/// action in command mode.
const List<CommandHelpEntry> commandHelpEntries = [
  CommandHelpEntry(
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
  CommandHelpEntry(
    title: 'Open Wi-Fi settings',
    icon: Icons.wifi,
    description: 'Opens this device\'s system Wi-Fi settings screen.',
    examples: [
      'open Wi-Fi settings',
      'open wireless settings',
    ],
  ),
  CommandHelpEntry(
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
  CommandHelpEntry(
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
  CommandHelpEntry(
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
  CommandHelpEntry(
    title: 'Play Deezer Flow',
    icon: Icons.music_note_outlined,
    description: 'Opens Deezer and starts Flow. Works on Android and Linux when '
        'Deezer is installed; otherwise it says so.',
    examples: [
      'play Deezer Flow',
      'play my Flow on Deezer',
    ],
  ),
  CommandHelpEntry(
    title: 'Call someone',
    icon: Icons.call_outlined,
    description: 'Opens your dialer pre-filled with the number — you tap call '
        'yourself, so Nexus never places a call. Names are looked up in your '
        'contacts (asking permission the first time); otherwise say the number.',
    examples: [
      'call Sam',
      'call 555-1234',
      'dial 911',
    ],
  ),
  CommandHelpEntry(
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
  CommandHelpEntry(
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

/// Renders the help list. Reads only [commandHelpEntries], so it needs no
/// changes when a new action is added.
class CommandHelpScreen extends StatelessWidget {
  const CommandHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('What can I say?')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('How Nexus understands you',
                          style: theme.textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'When a local model is installed, Nexus handles natural '
                    'phrasing. Without one it runs in command mode, which '
                    'matches the specific words shown below — the closer your '
                    'wording, the more reliable the match.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in commandHelpEntries) ...[
            Card(
              child: ListTile(
                leading: Icon(entry.icon, color: theme.colorScheme.primary),
                title: Text(entry.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(entry.description),
                    const SizedBox(height: 8),
                    for (final example in entry.examples)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '“$example”',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                isThreeLine: true,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

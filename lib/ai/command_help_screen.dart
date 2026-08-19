import 'package:flutter/material.dart';

import 'action_registry.dart';

/// The entries currently visible on the "What can I say?" screen: every action
/// that hasn't been turned off in Settings -> Actions & permissions.
List<NexusActionDefinition> visibleHelpEntries() => [
      for (final def in nexusActions)
        if (ActionRegistry.instance.isEnabled(def.command)) def,
    ];

/// Renders the help list from [nexusActions], filtered to the actions that are
/// currently enabled. When a new action is added to the registry it shows up
/// here automatically.
class CommandHelpScreen extends StatelessWidget {
  const CommandHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('What can I say?')),
      body: ListenableBuilder(
        listenable: ActionRegistry.instance,
        builder: (context, _) {
          final entries = visibleHelpEntries();
          return ListView(
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
                        'matches the specific words shown below — the closer '
                        'your wording, the more reliable the match. Turned-off '
                        'actions are hidden here and no longer recognized.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (entries.isEmpty)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.block),
                    title: Text('All actions are turned off'),
                    subtitle: Text('Re-enable some in Settings → '
                        'Actions & permissions.'),
                  ),
                ),
              for (final entry in entries) ...[
                Card(
                  child: ListTile(
                    leading: Icon(entry.icon,
                        color: theme.colorScheme.primary),
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
          );
        },
      ),
    );
  }
}

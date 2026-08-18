import 'package:flutter/material.dart';

import 'knowledge_store.dart';
import 'sync_service.dart';

/// \"Known facts\" / \"Shared knowledge\": a visible list of what this device and
/// its paired devices have learned and shared — reminders and short facts the
/// assistant logged from real commands. Shows which device each event came
/// from so sync is observable, not silent. A manual \"Sync now\" also triggers
/// an exchange on demand (sync additionally runs after transfers and at start).
class KnownFactsScreen extends StatefulWidget {
  const KnownFactsScreen({super.key});

  @override
  State<KnownFactsScreen> createState() => _KnownFactsScreenState();
}

class _KnownFactsScreenState extends State<KnownFactsScreen> {
  bool _syncing = false;
  String? _syncResult;

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _syncResult = null;
    });
    final ok = await SyncService.instance.syncAll();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncResult = ok > 0
          ? 'Synced with $ok device${ok == 1 ? '' : 's'}'
          : 'No device reachable right now — it will catch up next time.';
    });
  }

  String _relativeTime(DateTime when) {
    final diff = DateTime.now().difference(when.toLocal());
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
    if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    return '${when.toLocal().year}-${when.toLocal().month}-${when.toLocal().day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Known facts'),
        actions: [
          IconButton(
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync now',
            onPressed: _syncing ? null : _syncNow,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: KnowledgeStore.instance,
        builder: (context, _) {
          final events = KnowledgeStore.instance.eventsNewestFirst;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Reminders and facts you and your paired devices have shared. '
                'Each one is created on one device and synced directly to the '
                'others — nothing goes through a server.',
                style: theme.textTheme.bodySmall,
              ),
              if (_syncResult != null) ...[
                const SizedBox(height: 8),
                Text(
                  _syncResult!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Column(
                    children: [
                      Icon(Icons.lightbulb_outline,
                          size: 48, color: theme.colorScheme.outline),
                      const SizedBox(height: 8),
                      const Text(
                        'Nothing yet. Set a reminder or create a folder on any '
                        'paired device and it will show up here after a sync.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else
                ...events.map(
                  (e) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _iconFor(e),
                      color: e.type == KnowledgeEventType.reminder
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.primary,
                    ),
                    title: Text(_titleFor(e)),
                    subtitle: Text(
                      'from ${e.originDeviceName} · ${_relativeTime(e.createdAt)}',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _reminderText(KnowledgeEvent e) {
    final when = DateTime.tryParse(e.payload['when'] as String? ?? '')?.toLocal();
    final message = e.payload['message'] as String? ?? 'Reminder';
    final time = when == null
        ? 'a set time'
        : '${when.hour.toString().padLeft(2, '0')}:'
            '${when.minute.toString().padLeft(2, '0')}';
    return 'Reminder ($time): $message';
  }

  IconData _iconFor(KnowledgeEvent e) {
    switch (e.type) {
      case KnowledgeEventType.reminder:
        return Icons.alarm;
      case KnowledgeEventType.preference:
        return Icons.notifications_outlined;
      case KnowledgeEventType.fact:
        return Icons.tips_and_updates_outlined;
    }
  }

  String _titleFor(KnowledgeEvent e) {
    switch (e.type) {
      case KnowledgeEventType.reminder:
        return _reminderText(e);
      case KnowledgeEventType.preference:
        return _preferenceText(e);
      case KnowledgeEventType.fact:
        return e.payload['text'] as String? ?? '';
    }
  }

  String _preferenceText(KnowledgeEvent e) {
    final key = e.payload['key'] as String? ?? '';
    final value = e.payload['value'] as String? ?? '';
    final name = e.payload['valueName'] as String? ?? '';
    if (key == 'notify_device') {
      return value.isEmpty
          ? 'Notifications on all devices'
          : 'Notifications only on ${name.isEmpty ? 'a device' : name}';
    }
    return 'Preference: $key = ${value.isEmpty ? name : value}';
  }
}

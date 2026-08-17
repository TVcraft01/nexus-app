import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import 'transfer_service.dart';

/// The Files tab: every transfer this device has made (sent or received),
/// most recent first, with a direction icon, the file name, the other device,
/// size, and a relative timestamp. Tapping a record opens the file with the
/// platform's default app (falling back to its containing folder).
class FilesScreen extends StatelessWidget {
  final List<TransferRecord> records;
  final Future<void> Function() onClear;

  const FilesScreen({super.key, required this.records, required this.onClear});

  Future<void> _open(BuildContext context, TransferRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    OpenResult result;
    try {
      result = await OpenFilex.open(record.localPath);
    } catch (_) {
      result = OpenResult(type: ResultType.error, message: 'open failed');
    }
    if (result.type == ResultType.done) return;

    // Direct open didn't work (uncommon type, no handler, or a folder) —
    // reveal the containing folder instead so the file is still findable.
    try {
      final parent = p.dirname(record.localPath);
      if (parent != record.localPath) {
        result = await OpenFilex.open(parent);
        if (result.type == ResultType.done) return;
      }
    } catch (_) {
      // fall through to the error snackbar
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Couldn\'t open "${record.fileName}".')),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear transfer history?'),
        content: const Text(
            'This removes the list of files you\'ve sent and received. '
            'The files themselves stay on your device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await onClear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          if (records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear history',
              onPressed: () => _confirmClear(context),
            ),
        ],
      ),
      body: records.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No transfers yet.\nFiles you send or receive will show '
                  'up here.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: records.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = records[i];
                final sent = r.isSent;
                final icon = sent ? Icons.arrow_upward : Icons.arrow_downward;
                final color =
                    sent ? theme.colorScheme.primary : Colors.green.shade700;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  title: Text(
                    r.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${sent ? 'To' : 'From'} ${r.otherDeviceName} · '
                    '${humanSize(r.sizeBytes)}',
                  ),
                  trailing: Text(
                    relativeTime(r.timestamp),
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () => _open(context, r),
                );
              },
            ),
    );
  }
}

/// Compact human-readable size, e.g. "1.2 MB".
String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Relative timestamp like "2 minutes ago", falling back to a short date for
/// anything older than a week.
String relativeTime(DateTime time, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(time);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  }
  if (diff.inDays < 7) {
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
  return '${time.day}/${time.month}/${time.year}';
}

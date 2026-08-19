import 'package:flutter/material.dart';

import '../ai/model_service.dart';
import '../ai/model_ui.dart';
import '../devbridge/dev_bridge_service.dart';
import '../maintenance/maintenance_service.dart';
import '../models/paired_device.dart';
import '../remote/remote_access_service.dart';
import '../sync/known_facts_screen.dart';
import '../sync/knowledge_store.dart';
import '../transfer/transfer_service.dart';
import 'action_permissions_screen.dart';
import 'settings_service.dart';

/// The Settings tab: the internet/auto-update toggles, the paired-devices
/// list with "Forget device", and a history of files this device received.
class SettingsScreen extends StatefulWidget {
  final List<PairedDevice> devices;
  final List<ReceivedFile> receivedFiles;
  final ModelService modelService;
  final Future<void> Function(String deviceId) onForgetDevice;
  final Future<void> Function() onClearReceived;

  const SettingsScreen({
    super.key,
    required this.devices,
    required this.receivedFiles,
    required this.modelService,
    required this.onForgetDevice,
    required this.onClearReceived,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  bool? _allowInternet;
  bool? _autoUpdate;
  bool? _allowDevTasks;
  String _devTaskCommand = SettingsService.defaultDevTaskCommand;
  String _devTaskCwd = '';
  MaintenanceRunReport? _lastMaintenance;
  bool _maintenanceRunning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final allow = await _settings.getAllowInternetAccess();
    final auto = await _settings.getAutoUpdate();
    final devTasks = await _settings.getAllowDevTasks();
    final command = await _settings.getDevTaskCommand();
    final cwd = await _settings.getDevTaskCwd();
    final maintenance = await MaintenanceService.instance.lastReport();
    if (mounted) {
      setState(() {
        _allowInternet = allow;
        _autoUpdate = auto;
        _allowDevTasks = devTasks;
        _devTaskCommand = command;
        _devTaskCwd = cwd;
        _lastMaintenance = maintenance;
      });
    }
  }

  Future<void> _confirmForget(PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget device?'),
        content: Text(
            '${device.deviceName} will be removed from your paired devices. '
            'You can pair again later by scanning its QR code.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onForgetDevice(device.deviceId);
    }
  }

  Future<void> _runMaintenance() async {
    setState(() => _maintenanceRunning = true);
    await MaintenanceService.instance.run();
    final report = await MaintenanceService.instance.lastReport();
    if (mounted) {
      setState(() {
        _maintenanceRunning = false;
        _lastMaintenance = report;
      });
    }
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    }
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays} days ago';
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _sectionHeader('Network'),
          SwitchListTile(
            title: const Text('Allow internet access'),
            subtitle: const Text(
                'Off = LAN only. On = reach your paired devices on other '
                'networks, direct device-to-device. Uses a public STUN '
                'server only to discover your public address \u2014 never to '
                'relay files, commands, or messages.'),
            secondary: const Icon(Icons.public_off),
            value: _allowInternet ?? false,
            onChanged: _allowInternet == null
                ? null
                : (v) async {
                    await RemoteAccessService.instance.setEnabled(v);
                    if (mounted) setState(() => _allowInternet = v);
                  },
          ),
          SwitchListTile(
            title: const Text('Auto-update'),
            subtitle: const Text('Off. Reserved for future updates.'),
            secondary: const Icon(Icons.system_update_alt),
            value: _autoUpdate ?? false,
            onChanged: _autoUpdate == null
                ? null
                : (v) async {
                    await _settings.setAutoUpdate(v);
                    setState(() => _autoUpdate = v);
                  },
          ),
          const Divider(),
          _sectionHeader('Local assistant'),
          _buildModelSection(context),
          const Divider(),
          _sectionHeader('Remote access'),
          _buildRemoteSection(context),
          const Divider(),
          _sectionHeader('Developer bridge'),
          _buildDevBridgeSection(context),
          const Divider(),
          _sectionHeader('Shared knowledge'),
          ListTile(
            leading: const Icon(Icons.tips_and_updates_outlined),
            title: const Text('Known facts'),
            subtitle: const Text(
                'Reminders and facts shared with your paired devices'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const KnownFactsScreen()),
            ),
          ),
          const Divider(),
          _sectionHeader('Notifications'),
          _buildNotificationsSection(context),
          const Divider(),
          _sectionHeader('Actions & permissions'),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Nexus Permissions'),
            subtitle: const Text(
                'Turn individual actions on or off, and manage the system '
                'permissions they use.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const ActionPermissionsScreen()),
            ),
          ),
          const Divider(),
          _sectionHeader('Maintenance'),
          _buildMaintenanceSection(context),
          const Divider(),
          _sectionHeader('Paired devices'),
          if (widget.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                  'No paired devices yet. Pair one from the Devices tab.'),
            )
          else
            ...widget.devices.map(
              (d) => ListTile(
                leading: const Icon(Icons.devices),
                title: Text(d.deviceName),
                subtitle: Text(d.ipAddress),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Forget device',
                  onPressed: () => _confirmForget(d),
                ),
              ),
            ),
          const Divider(),
          _sectionHeader('Received files'),
          if (widget.receivedFiles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('Files you receive will appear here.'),
            )
          else ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => widget.onClearReceived(),
                child: const Text('Clear history'),
              ),
            ),
            ...widget.receivedFiles.map(
              (f) => ListTile(
                leading: const Icon(Icons.download_done),
                title: Text(f.fileName),
                subtitle: Text(
                  'From ${f.fromDeviceName} \u00b7 ${_humanSize(f.sizeBytes)}\n'
                  '${f.savedPath}',
                ),
                isThreeLine: true,
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// "Remote dev tasks" toggle (default OFF, with an explicit confirmation
  /// before it can be switched on) plus the task command / working directory
  /// editors that control what a paired device may actually run here.
  Widget _buildDevBridgeSection(BuildContext context) {
    final devBridgeBusy = DevBridgeService.instance.busy;
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Allow remote dev tasks'),
          subtitle: const Text(
              'OFF. When ON, a paired device can send a prompt that runs the '
              'configured task command on THIS device (code execution + '
              'builds). Separate from "Allow internet access".'),
          secondary: const Icon(Icons.developer_mode),
          value: _allowDevTasks ?? false,
          onChanged: _allowDevTasks == null || devBridgeBusy
              ? null
              : (v) async {
                  if (v) {
                    // Deliberate confirmation: this hands a paired device the
                    // ability to run code on this machine.
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Allow remote dev tasks?'),
                        content: const Text(
                            'This lets a paired device send a prompt that runs '
                            'the task command on this device — it can execute '
                            'code and run builds here. Only turn this on for '
                            'devices you fully trust.\n\nYou can change it '
                            'back any time.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Enable'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                  }
                  await _settings.setAllowDevTasks(v);
                  if (mounted) setState(() => _allowDevTasks = v);
                },
        ),
        if (devBridgeBusy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'A dev task is running right now; the toggle is locked until '
              'it finishes.',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.terminal),
          title: const Text('Dev task command'),
          subtitle: const Text(
              'The command a paired device\'s prompt runs. {prompt} and '
              '{promptFile} are substituted. Defaults to a placeholder that '
              'explains how to configure it.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editDevTaskSetting(
            title: 'Dev task command',
            help: 'Shell command run for each dev task. {prompt} is replaced '
                'by the prompt text and {promptFile} by the path of a file '
                'containing it (prefer {promptFile} to avoid quoting issues).',
            initial: _devTaskCommand,
            onSave: (v) async {
              await _settings.setDevTaskCommand(v);
              if (mounted) setState(() => _devTaskCommand = v);
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Dev task working directory'),
          subtitle: Text(
              _devTaskCwd.trim().isEmpty
                  ? 'Defaults to the app\'s current directory (often where the '
                      'app was launched from).'
                  : _devTaskCwd),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editDevTaskSetting(
            title: 'Working directory',
            help: 'Directory the task command runs in, e.g. the repo path.',
            initial: _devTaskCwd,
            onSave: (v) async {
              await _settings.setDevTaskCwd(v);
              if (mounted) setState(() => _devTaskCwd = v);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _editDevTaskSetting({
    required String title,
    required String help,
    required String initial,
    required Future<void> Function(String value) onSave,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(help, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: title.contains('command') ? 4 : 1,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await onSave(result.trim());
  }

  /// "Last maintenance" — the visible record of what the idle-time
  /// housekeeping actually did. Honest copy: no dreaming, just cleanup.
  Widget _buildMaintenanceSection(BuildContext context) {
    if (_maintenanceRunning) {
      return const ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Running maintenance…'),
        subtitle: Text(
          'Removing stale files, pruning old shared-knowledge events, and '
          'checking the local model.',
        ),
      );
    }

    final report = _lastMaintenance;
    if (report == null) {
      return ListTile(
        leading: const Icon(Icons.cleaning_services_outlined),
        title: const Text('No maintenance run yet'),
        subtitle: const Text(
          'While the device is idle, Nexus removes stale dev-bridge files and '
          'interrupted downloads, prunes old shared-knowledge events, and '
          'checks the local model. On Android this runs in the background '
          '(idle + charging); on Linux it runs at startup when due.',
        ),
        isThreeLine: true,
        trailing: TextButton(
          onPressed: _runMaintenance,
          child: const Text('Run now'),
        ),
      );
    }

    final parts = <String>[
      if (report.filesRemoved > 0)
        'removed ${report.filesRemoved} stale '
            'file${report.filesRemoved == 1 ? '' : 's'} '
            '(${_humanSize(report.bytesFreed)} freed)'
      else
        'no stale files to remove',
      'pruned ${report.knowledgeEventsPruned} knowledge '
          'event${report.knowledgeEventsPruned == 1 ? '' : 's'}',
      report.modelVerdictLabel,
    ];

    return ListTile(
      leading: Icon(
        report.hasIssues
            ? Icons.warning_amber_outlined
            : Icons.cleaning_services_outlined,
        color: report.hasIssues ? Colors.orange : null,
      ),
      title: Text('Last maintenance: ${_relativeTime(report.ranAt)}'),
      subtitle: Text(
        '${parts.join(' · ')}'
        '${report.hasIssues ? '\n${report.issues.join('\n')}' : ''}',
      ),
      isThreeLine: report.hasIssues,
      trailing: TextButton(
        onPressed: _runMaintenance,
        child: const Text('Run now'),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
            ),
      ),
    );
  }

  /// Shows the learned "which device notifies" preference, with a way to
  /// clear it back to the default (every device notifies).
  Widget _buildNotificationsSection(BuildContext context) {
    return ListenableBuilder(
      listenable: KnowledgeStore.instance,
      builder: (context, _) {
        final store = KnowledgeStore.instance;
        final pref = store.currentPreference('notify_device');
        final value = pref?.payload['value'] as String? ?? '';
        final name = pref?.payload['valueName'] as String? ?? '';

        final title = value.isEmpty
            ? 'Notify on all devices'
            : 'Notifications only on ${name.isEmpty ? 'this device' : name}';
        final subtitle = value.isEmpty
            ? 'Each paired device that has a reminder will fire its own '
                'notification.'
            : 'Reminders still sync to every device, but only $name'
                '${name.isEmpty ? '' : ' '}interrupts you with a notification.';

        return ListTile(
          leading: Icon(
            value.isEmpty
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
          ),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: value.isEmpty
              ? null
              : TextButton(
                  onPressed: () async {
                    // Appending an empty-value preference clears it; the
                    // latest event for a key wins.
                    await store.addPreference('notify_device', '');
                  },
                  child: const Text('Clear'),
                ),
        );
      },
    );
  }

  /// Per-device connectivity status (Local / Remote / Unreachable), updated
  /// live on each connection attempt so it's never stale.
  Widget _buildRemoteSection(BuildContext context) {
    return ListenableBuilder(
      listenable: RemoteAccessService.instance,
      builder: (context, _) {
        final remote = RemoteAccessService.instance;
        if (!remote.enabled) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Turn on "Allow internet access" above to reach paired devices '
              'when you\'re not on the same network.',
            ),
          );
        }

        final header = remote.publicAddress == null
            ? 'No public port mapped yet. Your router may not support '
                'UPnP/NAT-PMP, so remote connections may not work.'
            : 'This device is reachable at ${remote.publicAddress}';
        final items = <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(header, style: Theme.of(context).textTheme.bodySmall),
          ),
        ];

        if (widget.devices.isEmpty) {
          items.add(const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('No paired devices yet.'),
          ));
        } else {
          items.addAll(widget.devices.map((d) {
            final status = remote.statusOf(d.deviceId);
            return ListTile(
              leading: Icon(_statusIcon(status), color: _statusColor(status)),
              title: Text(d.deviceName),
              subtitle: Text(_statusLabel(status)),
            );
          }));
        }
        return Column(children: items);
      },
    );
  }

  IconData _statusIcon(DeviceLinkStatus s) {
    switch (s) {
      case DeviceLinkStatus.local:
        return Icons.wifi;
      case DeviceLinkStatus.remote:
        return Icons.cloud;
      case DeviceLinkStatus.remoteUdp:
        return Icons.cell_tower;
      case DeviceLinkStatus.unreachable:
        return Icons.cloud_off;
      case DeviceLinkStatus.unknown:
        return Icons.help_outline;
    }
  }

  Color? _statusColor(DeviceLinkStatus s) {
    switch (s) {
      case DeviceLinkStatus.local:
        return Colors.green;
      case DeviceLinkStatus.remote:
        return Colors.blue;
      case DeviceLinkStatus.remoteUdp:
        return Colors.teal;
      case DeviceLinkStatus.unreachable:
        return Colors.red;
      case DeviceLinkStatus.unknown:
        return null;
    }
  }

  String _statusLabel(DeviceLinkStatus s) {
    switch (s) {
      case DeviceLinkStatus.local:
        return 'Local network';
      case DeviceLinkStatus.remote:
        return 'Remote (direct)';
      case DeviceLinkStatus.remoteUdp:
        return 'Remote (UDP direct)';
      case DeviceLinkStatus.unreachable:
        return 'Unreachable';
      case DeviceLinkStatus.unknown:
        return 'Not connected yet';
    }
  }

  /// Shows the local LLM's tier/download state and lets the user switch or
  /// delete it. Also surfaces whether the offline voice model is available.
  Widget _buildModelSection(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.modelService,
      builder: (context, _) {
        final model = widget.modelService;
        Widget tile;

        if (model.isDownloading) {
          tile = ListTile(
            leading: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Downloading ${model.tier?.name} model…'),
            subtitle: Text(
              '${(model.downloadProgress * 100).toStringAsFixed(0)}% of '
              '${model.tier?.sizeLabel ?? ''}',
            ),
          );
        } else if (model.isReady) {
          tile = ListTile(
            leading: const Icon(Icons.memory),
            title: Text('${model.tier?.name} model'),
            subtitle: Text(
              '${model.tier?.sizeLabel} · Qwen2.5, runs offline',
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'switch') {
                  final tier = await pickModelTier(
                    context,
                    recommended: model.tier,
                  );
                  if (tier != null && context.mounted) {
                    await downloadModelWithProgress(
                        context, model, tier);
                  }
                } else if (value == 'delete') {
                  if (!context.mounted) return;
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Remove model?'),
                      content: const Text(
                          'Nexus will go back to its built-in command mode.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await model.deleteModel();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'switch', child: Text('Switch model')),
                PopupMenuItem(value: 'delete', child: Text('Delete model')),
              ],
            ),
          );
        } else if (model.declined) {
          tile = ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Local model disabled'),
            subtitle: const Text(
                'You chose to stay in command mode on this device.'),
            trailing: FilledButton.tonal(
              onPressed: () async {
                await model.setDeclined(false);
                if (!context.mounted) return;
                final recommended = await model.recommendTier();
                if (!context.mounted) return;
                final tier = await pickModelTier(
                  context,
                  recommended: recommended,
                );
                if (tier != null && context.mounted) {
                  await downloadModelWithProgress(context, model, tier);
                }
              },
              child: const Text('Enable'),
            ),
          );
        } else {
          tile = ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('Command mode (no model)'),
            subtitle: const Text(
                'Nexus understands a fixed set of commands offline.'),
            trailing: FilledButton.tonal(
              onPressed: () async {
                final recommended = await model.recommendTier();
                if (!context.mounted) return;
                final tier = await pickModelTier(
                  context,
                  recommended: recommended,
                );
                if (tier != null && context.mounted) {
                  await downloadModelWithProgress(context, model, tier);
                }
              },
              child: const Text('Download'),
            ),
          );
        }

        return Column(
          children: [
            tile,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Voice input: offline speech model downloads automatically '
                  'the first time you tap the mic.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

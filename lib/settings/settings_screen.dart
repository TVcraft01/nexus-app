import 'package:flutter/material.dart';

import '../ai/model_service.dart';
import '../ai/model_ui.dart';
import '../models/paired_device.dart';
import '../remote/remote_access_service.dart';
import '../transfer/transfer_service.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final allow = await _settings.getAllowInternetAccess();
    final auto = await _settings.getAutoUpdate();
    if (mounted) {
      setState(() {
        _allowInternet = allow;
        _autoUpdate = auto;
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

import 'package:flutter/material.dart';

import '../models/paired_device.dart';
import '../transfer/transfer_service.dart';
import 'settings_service.dart';

/// The Settings tab: the internet/auto-update toggles, the paired-devices
/// list with "Forget device", and a history of files this device received.
class SettingsScreen extends StatefulWidget {
  final List<PairedDevice> devices;
  final List<ReceivedFile> receivedFiles;
  final Future<void> Function(String deviceId) onForgetDevice;
  final Future<void> Function() onClearReceived;

  const SettingsScreen({
    super.key,
    required this.devices,
    required this.receivedFiles,
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
                'Off. When on, Nexus may later connect two devices directly '
                'over the internet \u2014 never through anyone else\u2019s server.'),
            secondary: const Icon(Icons.public_off),
            value: _allowInternet ?? false,
            onChanged: _allowInternet == null
                ? null
                : (v) async {
                    await _settings.setAllowInternetAccess(v);
                    setState(() => _allowInternet = v);
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
}

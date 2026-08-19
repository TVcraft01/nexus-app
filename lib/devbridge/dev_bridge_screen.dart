/// Phone-side remote dev task: type a prompt, send it over the encrypted
/// channel to a paired PC, watch it run, then read the report and install the
/// build artifact the PC pushed back (also over the encrypted file path).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../models/paired_device.dart';
import '../transfer/transfer_service.dart';
import 'dev_bridge_protocol.dart';

class DevBridgeScreen extends StatefulWidget {
  final TransferService transferService;
  final List<PairedDevice> devices;

  const DevBridgeScreen({
    super.key,
    required this.transferService,
    required this.devices,
  });

  @override
  State<DevBridgeScreen> createState() => _DevBridgeScreenState();
}

class _DevBridgeScreenState extends State<DevBridgeScreen> {
  final _promptController = TextEditingController();
  PairedDevice? _target;
  bool _busy = false;
  String _status = '';
  String? _report;
  String? _error;

  /// Artifact reported by the PC, once its file arrives on this device.
  String? _artifactPath;
  String? _artifactFileName;
  StreamSubscription<ReceivedFile>? _receivedSub;

  List<PairedDevice> get _candidates {
    final computers =
        widget.devices.where((d) => d.isComputer).toList();
    return computers.isNotEmpty ? computers : widget.devices;
  }

  @override
  void initState() {
    super.initState();
    _target = _candidates.isNotEmpty ? _candidates.first : null;
    _receivedSub = widget.transferService.receivedFiles.listen(_onFileArrived);
  }

  @override
  void dispose() {
    _receivedSub?.cancel();
    _promptController.dispose();
    super.dispose();
  }

  /// The PC pushes the artifact before answering, so the file usually arrives
  /// before (or right after) the report. Match it by name.
  void _onFileArrived(ReceivedFile file) {
    final expected = _artifactFileName;
    if (expected == null || file.fileName != expected) return;
    if (!mounted) return;
    setState(() {
      _artifactPath = file.savedPath;
      _status = 'Artifact received.';
    });
  }

  Future<void> _checkArtifactAlreadyHere(String name) async {
    final records = await widget.transferService.getReceivedFiles();
    if (!mounted) return;
    for (final r in records) {
      if (r.fileName == name) {
        setState(() {
          _artifactPath = r.savedPath;
          _status = 'Artifact received.';
        });
        return;
      }
    }
    setState(() => _status = 'Waiting for artifact: $name …');
  }

  Future<void> _send() async {
    final target = _target;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pair a device first.')),
      );
      return;
    }
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = 'Sending prompt to ${target.deviceName} …';
      _report = null;
      _error = null;
      _artifactPath = null;
      _artifactFileName = null;
    });

    final result = await sendDevTask(device: target, prompt: prompt);

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!result.ok || result.error != null) {
        _error = result.error ?? 'The task failed on the remote device.';
        _status = '';
      } else {
        _report = result.report;
        _status = 'Task finished.';
      }
    });

    if (result.ok && result.artifactFileName != null) {
      _artifactFileName = result.artifactFileName;
      await _checkArtifactAlreadyHere(result.artifactFileName!);
    }
  }

  Future<void> _openArtifact() async {
    final path = _artifactPath;
    if (path == null) return;
    final isApk = _artifactFileName?.endsWith('.apk') ?? false;
    final res = await OpenFilex.open(
      path,
      type: isApk ? 'application/vnd.android.package-archive' : null,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.type == ResultType.done
            ? 'Opening ${_artifactFileName ?? path}…'
            : 'Could not open ${_artifactFileName ?? path}: '
                '${res.message}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    return Scaffold(
      appBar: AppBar(title: const Text('Remote dev task')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Send a text prompt to a paired device and have it run a coding '
            'task for you. Only works with paired devices over the encrypted '
            'connection, and only when the receiving device has '
            '"Allow remote dev tasks" turned on in its Settings.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<PairedDevice>(
            initialValue: _target,
            decoration: const InputDecoration(
              labelText: 'Run on',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final d in candidates)
                DropdownMenuItem(value: d, child: Text(d.deviceName)),
            ],
            onChanged: _busy ? null : (d) => setState(() => _target = d),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            enabled: !_busy,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Prompt',
              hintText: 'e.g. Fix the failing test in nexus_action_runner.dart',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.send),
            label: const Text('Send'),
          ),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.check_circle_outline,
                      size: 16, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(child: Text(_status)),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!),
              ),
            ),
          ],
          if (_report != null) ...[
            const SizedBox(height: 16),
            const Text('Report', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(_report!),
              ),
            ),
          ],
          if (_artifactPath != null) ...[
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.build),
              title: Text(_artifactFileName ?? 'Build artifact'),
              subtitle: Text(_artifactPath!),
              trailing: FilledButton.tonal(
                onPressed: _openArtifact,
                child: const Text('Open / Install'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

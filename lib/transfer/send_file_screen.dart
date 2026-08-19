import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/paired_device.dart';
import 'transfer_service.dart';

/// Shown when the user taps a paired device. Lets them pick a file on this
/// device and send it straight to that device over the local network.
class SendFileScreen extends StatefulWidget {
  final PairedDevice target;
  const SendFileScreen({super.key, required this.target});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  final _transferService = TransferService();

  String? _path;
  String? _name;
  int? _size;
  bool _sending = false;
  bool _sent = false;
  double _progress = 0;
  String? _error;

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile();
    if (file == null) return;

    String? path = file.path;
    // On some Android devices the picker hands back a content:// URI instead
    // of a real file path, so copy it somewhere local we can stream from.
    // The copy lives in a dedicated folder so background maintenance can
    // safely remove abandoned copies later (never while a send is in flight).
    if (path == null) {
      final dir = await getTemporaryDirectory();
      final tmp = Directory(p.join(dir.path, 'nexus_send_tmp'));
      await tmp.create(recursive: true);
      path = p.join(tmp.path, file.name);
      await file.xFile.saveTo(path);
    }
    final size = await file.length();
    if (!mounted) return;
    setState(() {
      _path = path;
      _name = file.name;
      _size = size;
      _sent = false;
      _progress = 0;
      _error = null;
    });
  }

  Future<void> _send() async {
    if (_path == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
      _sent = false;
    });
    try {
      await _transferService.sendFile(
        target: widget.target,
        filePath: _path!,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sent = true;
        _progress = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Send to ${widget.target.deviceName}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sends a file from this device straight to '
              '${widget.target.deviceName} over your local network. Nothing '
              'goes through the internet.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Card(
              child: ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: Text(_name ?? 'No file chosen'),
                subtitle: Text(
                  _name == null ? 'Tap to choose a file' : _humanSize(_size ?? 0),
                ),
                trailing: const Icon(Icons.folder_open),
                onTap: _sending ? null : _pickFile,
              ),
            ),
            const SizedBox(height: 24),
            if (_sending) ...[
              LinearProgressIndicator(value: _progress, minHeight: 8),
              const SizedBox(height: 8),
              Text(
                'Sending… ${(_progress * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.center,
              ),
            ],
            if (_sent) ...[
              const Icon(Icons.check_circle, color: Colors.green, size: 56),
              const SizedBox(height: 8),
              Text(
                'Sent to ${widget.target.deviceName}!',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ),
            ],
            const Spacer(),
            FilledButton.icon(
              onPressed: (_path == null || _sending) ? null : _send,
              icon: const Icon(Icons.send),
              label: Text(_sent ? 'Send again' : 'Send file'),
            ),
          ],
        ),
      ),
    );
  }
}

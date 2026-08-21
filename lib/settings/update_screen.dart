import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'update_service.dart';

/// Full-screen update checker: shows the current version, a "Check for
/// updates" button, and (when an update is available) a download + install
/// flow appropriate for the current platform.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  bool _checking = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  ReleaseInfo? _release;
  String? _error;
  String? _linuxScriptPath;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _release = null;
    });
    final info = await UpdateService.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (info == null) {
        _error = 'Could not check for updates. Make sure you have internet access.';
      } else {
        _release = info;
      }
    });
  }

  Future<void> _downloadAndInstall() async {
    final release = _release;
    if (release == null || !release.isNewer) return;

    if (Platform.isAndroid) {
      await _downloadAndroid(release);
    } else if (Platform.isLinux) {
      await _downloadLinux(release);
    }
  }

  Future<void> _downloadAndroid(ReleaseInfo release) async {
    final url = release.apkDownloadUrl;
    if (url == null) {
      setState(() => _error = 'No APK found in this release.');
      return;
    }

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _error = null;
    });

    final file = await UpdateService.downloadApk(url, onProgress: (p) {
      if (mounted) setState(() => _downloadProgress = p);
    });

    if (!mounted) return;
    setState(() => _downloading = false);

    if (file == null) {
      setState(() => _error = 'Download failed. Check your connection.');
      return;
    }

    // Launch the system package installer
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done && mounted) {
      setState(() => _error =
          'Could not open the installer (${result.message}). '
          'The APK was saved to: ${file.path}');
    }
  }

  Future<void> _downloadLinux(ReleaseInfo release) async {
    final url = release.linuxTarDownloadUrl;
    if (url == null) {
      setState(() => _error =
          'No Linux bundle found in this release. '
          'Download manually from:\nhttps://github.com/TVcraft01/nexus-app/releases');
      return;
    }

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _error = null;
    });

    final bundlePath = await UpdateService.downloadLinuxBundle(url, onProgress: (p) {
      if (mounted) setState(() => _downloadProgress = p);
    });

    if (!mounted) return;
    setState(() => _downloading = false);

    if (bundlePath == null) {
      setState(() => _error = 'Download failed. Check your connection.');
      return;
    }

    // Generate the self-update script
    final script = UpdateService.generateLinuxUpdateScript(bundlePath);
    final scriptDir = await getTemporaryDirectory();
    final scriptFile = File(p.join(scriptDir.path, 'nexus_update.sh'));
    await scriptFile.writeAsString(script);
    await Process.run('chmod', ['+x', scriptFile.path]);

    setState(() => _linuxScriptPath = scriptFile.path);
  }

  @override
  Widget build(BuildContext context) {
    final currentVersion = _release?.currentVersion ?? '…';
    final latestVersion = _release?.tagName ?? '…';

    return Scaffold(
      appBar: AppBar(title: const Text('Check for updates')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Current version
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current version: $currentVersion',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (_release != null)
                          Text(
                            'Latest: $latestVersion '
                                '(${_release!.publishedLabel})',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Check button
          if (_checking)
            const Center(child: CircularProgressIndicator())
          else if (_release != null && _release!.isNewer)
            _buildUpdateAvailable()
          else if (_release != null && !_release!.isNewer)
            _buildUpToDate()
          else if (_error != null)
            _buildError(),

          const SizedBox(height: 16),

          // Refresh button
          TextButton.icon(
            onPressed: _checking ? null : _check,
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),

          // Linux update instructions
          if (_linuxScriptPath != null) ...[
            const SizedBox(height: 16),
            _buildLinuxInstructions(),
          ],
        ],
      ),
    );
  }

  Widget _buildUpdateAvailable() {
    final release = _release!;
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_alt),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Update available: ${release.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (release.body.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                release.body,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            if (_downloading)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: _downloadProgress),
                  const SizedBox(height: 4),
                  Text(
                    'Downloading… ${(_downloadProgress * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              )
            else
              FilledButton.icon(
                onPressed: _downloadAndInstall,
                icon: const Icon(Icons.download),
                label: const Text('Download & install'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpToDate() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('You\'re up to date!'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinuxInstructions() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Linux update ready',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The update has been downloaded and extracted. To install it:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'bash $_linuxScriptPath',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Close Nexus first, then run the command above in a terminal. '
              'It will replace the current installation and relaunch.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () async {
                // Copy the script path to clipboard via a snackbar
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Script saved to: $_linuxScriptPath'),
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Show path'),
            ),
          ],
        ),
      ),
    );
  }
}

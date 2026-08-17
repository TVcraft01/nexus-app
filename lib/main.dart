import 'dart:async';

import 'package:flutter/material.dart';

import 'ai/model_service.dart';
import 'ai/model_tiers.dart';
import 'ai/model_ui.dart';
import 'ai/talk_screen.dart';
import 'ai/vosk_ffi.dart';
import 'ai/vosk_service.dart';
import 'models/paired_device.dart';
import 'pairing/pairing_service.dart';
import 'remote/remote_access_service.dart';
import 'pairing/qr_pairing_screen.dart';
import 'pairing/qr_scan_screen.dart';
import 'settings/settings_screen.dart';
import 'tasks/batch_task_screen.dart';
import 'tasks/task_worker.dart';
import 'transfer/send_file_screen.dart';
import 'transfer/transfer_service.dart';

void main() {
  voskQuiet(); // silence Vosk's stderr logging on the C side.
  runApp(const NexusApp());
}

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

/// Top-level screen that owns the app-wide services: the always-on local
/// file-receive server and the list of paired devices.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _pairingService = PairingService();
  final _transferService = TransferService();
  final _modelService = ModelService();
  final _voskService = VoskService();
  StreamSubscription<ReceivedFile>? _receivedSub;
  List<PairedDevice> _devices = [];
  List<ReceivedFile> _receivedFiles = [];
  int _tab = 0;
  bool _offeredModel = false;

  @override
  void initState() {
    super.initState();
    _transferService.start();
    // Let this device act as a worker for distributed batch tasks.
    _transferService.taskWorker = TaskWorker(modelService: _modelService);
    _receivedSub = _transferService.receivedFiles.listen(_onFileReceived);
    _loadDevices();
    _loadReceivedFiles();
    _modelService.init().then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOfferModel());
    });
    _initRemoteAccess();
  }

  /// Brings the opt-in remote-access service up to date: reads the toggle and,
  /// if enabled, opens a public port mapping + shares our public endpoint.
  Future<void> _initRemoteAccess() async {
    final remote = RemoteAccessService.instance;
    await remote.init();
    await remote.refreshPublicAddress(receivePort: TransferService.receivePort);
  }

  @override
  void dispose() {
    _receivedSub?.cancel();
    _transferService.stop();
    _voskService.dispose();
    _modelService.dispose();
    super.dispose();
  }

  /// On first run, explains which model the device can handle and offers to
  /// download it. The user can also pick a different tier, decline (staying
  /// in command-mode KeywordBrain forever), or snooze it via "Not now" — the
  /// prompt then stays quiet for a few days instead of re-asking every launch.
  Future<void> _maybeOfferModel() async {
    if (_offeredModel) return;
    _offeredModel = true;
    if (_modelService.declined ||
        _modelService.isReady ||
        _modelService.isDownloading ||
        _modelService.isSnoozed ||
        !mounted) {
      return;
    }

    final capability = await _modelService.detectCapability();
    final recommended = pickTierFor(capability);
    if (!mounted) return;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final reason = recommended == null
            ? 'Your device does not have enough free memory for a local model '
              'right now, so Nexus will run in its built-in command mode. You '
              'can ask it to check again later from Settings.'
            : 'Your device has about ${capability.freeRamLabel} of free memory '
              'and ${capability.cpuCores} CPU cores — the ${recommended.name} '
              'model (${recommended.sizeLabel}) fits best.';
        return AlertDialog(
          title: const Text('Set up your local assistant'),
          content: Text(
            'Nexus can run a private AI entirely on this device. $reason\n\n'
            'You can change or remove it later in Settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'notNow'),
              child: const Text('Not now'),
            ),
            if (recommended != null) ...[
              TextButton(
                onPressed: () => Navigator.pop(context, 'pick'),
                child: const Text('Pick a different size'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'download'),
                child: Text('Download (${recommended.sizeLabel})'),
              ),
            ] else
              FilledButton(
                onPressed: () => Navigator.pop(context, 'decline'),
                child: const Text('Stay in command mode'),
              ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (choice == 'decline') {
      // Persistent: the user opted out of a local model on this device.
      await _modelService.setDeclined(true);
      return;
    }
    if (choice == 'notNow') {
      // Not permanent: snooze the prompt for a few days so it doesn't nag on
      // every launch. The user can still set up a model any time from
      // Settings -> Local assistant.
      await _modelService.snoozePrompt();
      return;
    }
    if (choice == 'pick' && recommended != null) {
      final tier = await pickModelTier(context, recommended: recommended);
      if (tier != null && mounted) {
        await downloadModelWithProgress(context, _modelService, tier);
      }
      return;
    }
    if (choice == 'download' && recommended != null) {
      await downloadModelWithProgress(context, _modelService, recommended);
    }
  }

  Future<void> _loadDevices() async {
    final devices = await _pairingService.getPairedDevices();
    if (mounted) setState(() => _devices = devices);
  }

  Future<void> _loadReceivedFiles() async {
    final files = await _transferService.getReceivedFiles();
    if (mounted) setState(() => _receivedFiles = files);
  }

  Future<void> _forgetDevice(String deviceId) async {
    await _pairingService.forgetDevice(deviceId);
    await _loadDevices();
  }

  Future<void> _clearReceived() async {
    await _transferService.clearReceivedFiles();
    if (mounted) setState(() => _receivedFiles = []);
  }

  void _onFileReceived(ReceivedFile file) {
    if (!mounted) return;
    setState(() => _receivedFiles.insert(0, file));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'File received from ${file.fromDeviceName}: ${file.fileName}'),
      ),
    );
  }

  void _openSendFile(PairedDevice device) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SendFileScreen(target: device)),
    );
  }

  void _openBatchTask() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BatchTaskScreen(
          modelService: _modelService,
          devices: _devices,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          HomeScreen(
            devices: _devices,
            onDevicesChanged: _loadDevices,
            onDeviceTap: _openSendFile,
            onBatchTask: _openBatchTask,
          ),
          TalkScreen(
            modelService: _modelService,
            voskService: _voskService,
          ),
          SettingsScreen(
            devices: _devices,
            receivedFiles: _receivedFiles,
            modelService: _modelService,
            onForgetDevice: _forgetDevice,
            onClearReceived: _clearReceived,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.devices),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.mic_none),
            label: 'Talk',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// The Devices tab: lists paired devices and offers pairing + file sending.
class HomeScreen extends StatefulWidget {
  final List<PairedDevice> devices;
  final VoidCallback onDevicesChanged;
  final void Function(PairedDevice device) onDeviceTap;
  final VoidCallback onBatchTask;

  const HomeScreen({
    super.key,
    required this.devices,
    required this.onDevicesChanged,
    required this.onDeviceTap,
    required this.onBatchTask,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<void> _showPairMenu() async {
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: const Text('Show my QR code'),
              subtitle: const Text('Let another device scan you'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context)
                    .push(MaterialPageRoute(
                        builder: (_) => const QrPairingScreen()))
                    .then((_) => widget.onDevicesChanged());
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan a QR code'),
              subtitle: const Text('Pair with a device showing its QR'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context)
                    .push(
                        MaterialPageRoute(builder: (_) => const QrScanScreen()))
                    .then((_) => widget.onDevicesChanged());
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nexus'),
        actions: [
          IconButton(
            icon: const Icon(Icons.summarize_outlined),
            tooltip: 'Batch task',
            onPressed: widget.onBatchTask,
          ),
        ],
      ),
      body: widget.devices.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No paired devices yet.\nTap the + button to pair your '
                  'first device.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: widget.devices.length,
              itemBuilder: (context, i) {
                final d = widget.devices[i];
                return ListTile(
                  leading: const Icon(Icons.devices),
                  title: Text(d.deviceName),
                  subtitle: Text(d.ipAddress),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onDeviceTap(d),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showPairMenu,
        child: const Icon(Icons.add),
      ),
    );
  }
}

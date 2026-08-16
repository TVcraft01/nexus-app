import 'dart:async';

import 'package:flutter/material.dart';

import 'models/paired_device.dart';
import 'pairing/pairing_service.dart';
import 'pairing/qr_pairing_screen.dart';
import 'pairing/qr_scan_screen.dart';
import 'settings/settings_screen.dart';
import 'transfer/send_file_screen.dart';
import 'transfer/transfer_service.dart';

void main() {
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
  StreamSubscription<ReceivedFile>? _receivedSub;
  List<PairedDevice> _devices = [];
  List<ReceivedFile> _receivedFiles = [];
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _transferService.start();
    _receivedSub = _transferService.receivedFiles.listen(_onFileReceived);
    _loadDevices();
    _loadReceivedFiles();
  }

  @override
  void dispose() {
    _receivedSub?.cancel();
    _transferService.stop();
    super.dispose();
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
          ),
          SettingsScreen(
            devices: _devices,
            receivedFiles: _receivedFiles,
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

  const HomeScreen({
    super.key,
    required this.devices,
    required this.onDevicesChanged,
    required this.onDeviceTap,
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
      appBar: AppBar(title: const Text('Nexus')),
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

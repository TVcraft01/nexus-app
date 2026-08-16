import 'package:flutter/material.dart';
import 'models/paired_device.dart';
import 'pairing/pairing_service.dart';
import 'pairing/qr_pairing_screen.dart';
import 'pairing/qr_scan_screen.dart';

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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _pairingService = PairingService();
  List<PairedDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    final devices = await _pairingService.getPairedDevices();
    setState(() => _devices = devices);
  }

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
                    .push(MaterialPageRoute(builder: (_) => const QrPairingScreen()))
                    .then((_) => _loadDevices());
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan a QR code'),
              subtitle: const Text('Pair with a device showing its QR'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const QrScanScreen()))
                    .then((_) => _loadDevices());
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
      body: _devices.isEmpty
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
              itemCount: _devices.length,
              itemBuilder: (context, i) {
                final d = _devices[i];
                return ListTile(
                  leading: const Icon(Icons.devices),
                  title: Text(d.deviceName),
                  subtitle: Text(d.ipAddress),
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

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/paired_device.dart';
import 'pairing_service.dart';

/// Shown when the user taps "Pair a new device" -> "Show my QR code".
/// Displays a QR code the OTHER device scans, and waits in the background
/// for that device's handshake to arrive.
class QrPairingScreen extends StatefulWidget {
  const QrPairingScreen({super.key});

  @override
  State<QrPairingScreen> createState() => _QrPairingScreenState();
}

class _QrPairingScreenState extends State<QrPairingScreen> {
  final _pairingService = PairingService();
  PairedDevice? _thisDevice;
  PairedDevice? _pairedResult;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final device = await _pairingService.getThisDeviceIdentity();
    await _pairingService.startListening(
      thisDevice: device,
      onPaired: (paired) {
        // Called automatically the instant the other device scans us.
        setState(() => _pairedResult = paired);
      },
    );
    setState(() => _thisDevice = device);
  }

  @override
  void dispose() {
    _pairingService.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a device')),
      body: Center(
        child: _thisDevice == null
            ? const CircularProgressIndicator()
            : _pairedResult != null
                ? _PairedSuccess(device: _pairedResult!)
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'On your other device, tap "Pair a device" -> '
                          '"Scan a QR code" and point it at this screen.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        QrImageView(
                          data: jsonEncode(_thisDevice!.toJson()),
                          size: 260,
                          backgroundColor: Colors.white,
                        ),
                        const SizedBox(height: 24),
                        const CircularProgressIndicator(),
                        const SizedBox(height: 8),
                        const Text('Waiting for the other device...'),
                      ],
                    ),
                  ),
      ),
    );
  }
}

class _PairedSuccess extends StatelessWidget {
  final PairedDevice device;
  const _PairedSuccess({required this.device});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 64),
        const SizedBox(height: 12),
        Text('Paired with ${device.deviceName}',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

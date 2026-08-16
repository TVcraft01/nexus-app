import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/paired_device.dart';
import 'pairing_service.dart';

/// Shown when the user taps "Pair a device" -> "Scan a QR code".
/// Uses the camera to read the other device's QR, then completes pairing.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _pairingService = PairingService();
  bool _isProcessing = false; // prevents pairing twice from rapid scans
  String? _errorMessage;

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;

    setState(() => _isProcessing = true);

    try {
      final scanned = PairedDevice.fromJson(jsonDecode(raw));
      final thisDevice = await _pairingService.getThisDeviceIdentity();
      final confirmed = await _pairingService.pairWithScannedDevice(
        scannedDevice: scanned,
        thisDevice: thisDevice,
      );

      if (!mounted) return;
      Navigator.of(context).pop(confirmed); // return the paired device
    } catch (e) {
      setState(() {
        _errorMessage = 'Could not pair: make sure both devices are on the '
            'same network and try again.';
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a device')),
      body: Stack(
        children: [
          MobileScanner(onDetect: _handleDetection),
          if (_isProcessing)
            const Center(child: CircularProgressIndicator()),
          if (_errorMessage != null)
            Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_errorMessage!,
                      style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:math' as math;
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
          // The scanner itself — detection keeps working across the whole
          // camera view; the frame below is purely a visual aiming guide.
          MobileScanner(onDetect: _handleDetection),
          // Dimmed "aim here" frame: dark outside a clear rounded square.
          const _ScannerOverlay(),
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

/// Purely visual scanning guide: a semi-transparent dark mask with a clear,
/// bordered rounded-square window in the middle, so the user knows where to
/// aim the QR code. Does not affect detection at all.
class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth * 0.72, 320.0);
        final frameCenter = Offset(
          constraints.maxWidth / 2,
          constraints.maxHeight / 2 - 28,
        );
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ScannerOverlayPainter(
                  frameCenter: frameCenter,
                  side: side,
                  color: color,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: frameCenter.dy + side / 2 + 20,
              child: const Text(
                'Point the camera at the QR code',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  final Offset frameCenter;
  final double side;
  final Color color;

  _ScannerOverlayPainter({
    required this.frameCenter,
    required this.side,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final frameRect = Rect.fromCenter(
      center: frameCenter,
      width: side,
      height: side,
    );
    final frame = RRect.fromRectAndRadius(frameRect, const Radius.circular(20));
    final whole = Path()..addRect(Offset.zero & size);

    // Dark mask everywhere except a clear window inside the frame.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        whole,
        Path()..addRRect(frame),
      ),
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();

    // A crisp white border around the window.
    canvas.drawRRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.9),
    );

    // Corner brackets in the theme color, so the window reads as a scanner.
    final bracket = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = color;
    final len = side * 0.18;
    final r = frameRect.right;
    final b = frameRect.bottom;
    final l = frameRect.left;
    final t = frameRect.top;
    // top-left
    canvas.drawLine(Offset(l, t + len), Offset(l, t), bracket);
    canvas.drawLine(Offset(l, t), Offset(l + len, t), bracket);
    // top-right
    canvas.drawLine(Offset(r - len, t), Offset(r, t), bracket);
    canvas.drawLine(Offset(r, t), Offset(r, t + len), bracket);
    // bottom-left
    canvas.drawLine(Offset(l, b - len), Offset(l, b), bracket);
    canvas.drawLine(Offset(l, b), Offset(l + len, b), bracket);
    // bottom-right
    canvas.drawLine(Offset(r - len, b), Offset(r, b), bracket);
    canvas.drawLine(Offset(r, b), Offset(r, b - len), bracket);
  }

  @override
  bool shouldRepaint(_ScannerOverlayPainter oldDelegate) =>
      oldDelegate.frameCenter != frameCenter ||
      oldDelegate.side != side ||
      oldDelegate.color != color;
}

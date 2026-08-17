import '../crypto/transfer_keys.dart';

/// Represents another Nexus device that this device has paired with.
///
/// This is what gets saved locally after a successful QR pairing, and what
/// gets encoded INTO the QR code before pairing happens.
class PairedDevice {
  final String deviceId; // unique ID for that device (UUID)
  final String deviceName; // human-readable name, e.g. "Sam's Laptop"
  final String ipAddress; // local network IP, e.g. "192.168.1.42"
  final int port; // port Nexus is listening on for handshakes
  final String pairingKey; // shared secret created at pairing time

  /// base64 AES-256 key derived from [pairingKey] via HKDF. Used only to
  /// encrypt/decrypt file transfers; the raw pairing key is never used as a
  /// key directly.
  final String transferKey;

  PairedDevice({
    required this.deviceId,
    required this.deviceName,
    required this.ipAddress,
    required this.port,
    required this.pairingKey,
    String? transferKey,
  }) : transferKey = transferKey ?? deriveTransferKeyBase64(pairingKey);

  /// Turns this device's info into JSON — this JSON string is what actually
  /// gets embedded inside the QR code image.
  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'ipAddress': ipAddress,
        'port': port,
        'pairingKey': pairingKey,
        'transferKey': transferKey,
      };

  /// Rebuilds a PairedDevice from the JSON that came out of a scanned QR code
  /// or a saved preferences entry. Older saved entries have no transfer key;
  /// it is derived on the fly in that case.
  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String,
        ipAddress: json['ipAddress'] as String,
        port: json['port'] as int,
        pairingKey: json['pairingKey'] as String,
        transferKey: json['transferKey'] as String?,
      );

  PairedDevice copyWith({
    String? deviceId,
    String? deviceName,
    String? ipAddress,
    int? port,
    String? pairingKey,
  }) =>
      PairedDevice(
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
        ipAddress: ipAddress ?? this.ipAddress,
        port: port ?? this.port,
        pairingKey: pairingKey ?? this.pairingKey,
        // Re-derive whenever the pairing key changes, otherwise keep it.
        transferKey: pairingKey == null ? transferKey : null,
      );
}

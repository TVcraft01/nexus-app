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

  PairedDevice({
    required this.deviceId,
    required this.deviceName,
    required this.ipAddress,
    required this.port,
    required this.pairingKey,
  });

  /// Turns this device's info into JSON — this JSON string is what actually
  /// gets embedded inside the QR code image.
  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'ipAddress': ipAddress,
        'port': port,
        'pairingKey': pairingKey,
      };

  /// Rebuilds a PairedDevice from the JSON that came out of a scanned QR code.
  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String,
        ipAddress: json['ipAddress'] as String,
        port: json['port'] as int,
        pairingKey: json['pairingKey'] as String,
      );
}

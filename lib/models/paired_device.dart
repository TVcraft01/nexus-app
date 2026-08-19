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

  /// Last-known public TCP endpoint ("ip:port") shared over a prior connection.
  /// Used only for the opt-in remote-connect path via UPnP/port forwarding.
  final String? publicAddress;

  /// Last-known public UDP endpoint ("ip:port") for hole-punching.
  /// Shared by the peer's NAT keep-alive; used when the TCP path fails.
  final String? publicUdpEndpoint;

  /// The platform this device reported at pairing time ("android", "ios",
  /// "linux", "windows", "macos"). Devices paired before this field existed
  /// have null here; [platformFamily] falls back to the device name in that
  /// case so spoken references like "my phone" still resolve.
  final String? platform;

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
    this.publicAddress,
    this.publicUdpEndpoint,
    this.platform,
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
        if (publicAddress != null) 'publicAddress': publicAddress,
        if (publicUdpEndpoint != null) 'publicUdpEndpoint': publicUdpEndpoint,
        if (platform != null) 'platform': platform,
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
        publicAddress: json['publicAddress'] as String?,
        publicUdpEndpoint: json['publicUdpEndpoint'] as String?,
        platform: json['platform'] as String?,
      );

  PairedDevice copyWith({
    String? deviceId,
    String? deviceName,
    String? ipAddress,
    int? port,
    String? pairingKey,
    String? publicAddress,
    String? publicUdpEndpoint,
    String? platform,
    bool clearPublicAddress = false,
    bool clearPublicUdpEndpoint = false,
  }) =>
      PairedDevice(
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
        ipAddress: ipAddress ?? this.ipAddress,
        port: port ?? this.port,
        pairingKey: pairingKey ?? this.pairingKey,
        publicAddress: clearPublicAddress ? null : (publicAddress ?? this.publicAddress),
        publicUdpEndpoint: clearPublicUdpEndpoint ? null : (publicUdpEndpoint ?? this.publicUdpEndpoint),
        platform: platform ?? this.platform,
        // Re-derive whenever the pairing key changes, otherwise keep it.
        transferKey: pairingKey == null ? transferKey : null,
      );

  /// The device's platform family, resolved from the explicit [platform] field
  /// with a name-based fallback for devices paired before platform was
  /// recorded. Returns one of "android", "ios", "linux", "windows", "macos",
  /// or null when it can't be determined.
  String? get platformFamily {
    final p = platform?.toLowerCase();
    if (const {'android', 'ios', 'linux', 'windows', 'macos'}.contains(p)) {
      return p;
    }
    final n = deviceName.toLowerCase();
    if (n.contains('phone') || n.contains('android')) return 'android';
    if (n.contains('pc') ||
        n.contains('laptop') ||
        n.contains('computer') ||
        n.contains('desktop') ||
        n.contains('linux') ||
        n.contains('windows') ||
        n.contains('mac')) {
      return 'linux';
    }
    return null;
  }

  /// Whether this device reads as a hand-held phone (Android/iOS).
  bool get isPhone {
    final f = platformFamily;
    return f == 'android' || f == 'ios';
  }

  /// Whether this device reads as a desktop/laptop computer.
  bool get isComputer {
    final f = platformFamily;
    return f == 'linux' || f == 'windows' || f == 'macos';
  }
}

/// Resolves a spoken device reference ("phone", "pc", "laptop", "computer",
/// "desktop", "tablet") to the paired devices it could mean.
///
/// "phone"/"tablet" map to hand-held (Android/iOS) devices, and the rest map
/// to desktop OSes. Returns ALL matches — never a guess — so the caller can
/// act when there's exactly one and ask for clarification when there are
/// several.
List<PairedDevice> resolveDeviceReference(
  String deviceRef,
  List<PairedDevice> devices,
) {
  final ref = deviceRef.toLowerCase().trim();
  final phones = const {'phone', 'mobile', 'tablet'};
  final computers = const {'pc', 'laptop', 'computer', 'desktop'};
  if (phones.contains(ref)) {
    return devices.where((d) => d.isPhone).toList();
  }
  if (computers.contains(ref)) {
    return devices.where((d) => d.isComputer).toList();
  }
  return const [];
}

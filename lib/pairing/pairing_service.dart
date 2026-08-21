import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';
import '../crypto/pairing_proof.dart';
import '../models/paired_device.dart';

/// Handles everything about pairing two Nexus devices together:
///
/// 1. This device's own identity (ID, name, secret key).
/// 2. A tiny local web server that listens for "someone wants to pair" requests.
/// 3. A client that sends a "let's pair" request after scanning someone else's QR.
/// 4. Saving/loading the list of already-paired devices, stored on-device only
///    (SharedPreferences) — nothing here ever leaves the local network.
class PairingService {
  static const _storageKey = 'nexus_paired_devices';
  static const _deviceIdKey = 'nexus_device_id';
  static const _deviceNameKey = 'nexus_device_name';
  static const pairingPort = 51820; // arbitrary local port for the handshake

  HttpServer? _server;

  /// Gets (or creates, on first run) this device's permanent ID and name.
  Future<PairedDevice> getThisDeviceIdentity({String? preferredName}) async {
    final prefs = await SharedPreferences.getInstance();

    String? id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }

    String name = prefs.getString(_deviceNameKey) ??
        preferredName ??
        Platform.operatingSystem; // falls back to "android" / "linux"
    await prefs.setString(_deviceNameKey, name);

    final ip = await _getLocalIpAddress();
    final pairingKey = const Uuid().v4(); // fresh one-time key per QR shown

    return PairedDevice(
      deviceId: id,
      deviceName: name,
      ipAddress: ip,
      port: pairingPort,
      pairingKey: pairingKey,
      platform: Platform.operatingSystem, // "android", "linux", ...
    );
  }

  /// Finds this device's local network IP (e.g. 192.168.x.x) so it can be
  /// embedded in the QR code for the other device to connect to.
  Future<String> _getLocalIpAddress() async {
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
    return '0.0.0.0'; // no network found — pairing will fail until connected
  }

  /// Starts listening for incoming pairing requests. Call this BEFORE
  /// showing the QR code, so the other device has something to connect to.
  ///
  /// Returns the device that just paired with us, via [onPaired], the
  /// moment a valid handshake comes in.
  Future<void> startListening({
    required PairedDevice thisDevice,
    required void Function(PairedDevice pairedWith) onPaired,
  }) async {
    final handler = const Pipeline().addHandler((Request request) async {
      if (request.method != 'POST' || request.url.path != 'pair') {
        return Response.notFound('not found');
      }

      final body = await request.readAsString();
      final Map<String, dynamic> json = jsonDecode(body);

      // The scanner sends only its PUBLIC identity — no secret material — plus
      // an HMAC proof that it actually scanned our QR (it proves knowledge of
      // the pairing key without ever transmitting it).
      final deviceJson = json['device'] as Map<String, dynamic>?;
      final proof = json['proof'] as String?;
      if (deviceJson == null || proof == null) {
        return Response.badRequest(body: 'missing device or proof');
      }

      // Rebuild the peer using OUR QR pairing key as the shared secret (the
      // key is never received from the wire — it was established via the QR).
      final incoming = PairedDevice.fromPublicJson(
        deviceJson,
        pairingKey: thisDevice.pairingKey,
      );

      final expected = computePairingProof(
        pairingKey: thisDevice.pairingKey,
        scannerDeviceId: incoming.deviceId,
        showerDeviceId: thisDevice.deviceId,
      );
      if (proof != expected) {
        return Response.forbidden('pairing proof mismatch');
      }

      await _saveDevice(incoming);
      onPaired(incoming);

      // Reply with our PUBLIC identity (no pairing key / transfer key) so the
      // scanner saves us using the key it already holds from the QR.
      return Response.ok(
        jsonEncode({'status': 'ok', 'device': thisDevice.toPublicJson()}),
        headers: {'content-type': 'application/json'},
      );
    });

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, pairingPort);
  }

  Future<void> stopListening() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Called on the SCANNING device after it reads a QR code. Sends a
  /// handshake to the device that generated the QR, completing the pairing.
  Future<PairedDevice> pairWithScannedDevice({
    required PairedDevice scannedDevice, // decoded from the QR contents
    required PairedDevice thisDevice,
  }) async {
    final uri = Uri.parse(
        'http://${scannedDevice.ipAddress}:${scannedDevice.port}/pair');

    // Prove we scanned the QR without sending the pairing key: an HMAC keyed
    // by the QR secret, bound to both identities.
    final proof = computePairingProof(
      pairingKey: scannedDevice.pairingKey,
      scannerDeviceId: thisDevice.deviceId,
      showerDeviceId: scannedDevice.deviceId,
    );

    final response = await http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'device': thisDevice.toPublicJson(),
        'proof': proof,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Pairing failed: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final confirmed = PairedDevice.fromPublicJson(
      json['device'] as Map<String, dynamic>,
      pairingKey: scannedDevice.pairingKey, // the shared secret from the QR
    );
    await _saveDevice(confirmed);
    return confirmed;
  }

  Future<void> _saveDevice(PairedDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_storageKey) ?? [];
    existing.removeWhere((raw) =>
        (jsonDecode(raw) as Map<String, dynamic>)['deviceId'] ==
        device.deviceId); // avoid duplicate entries if re-paired
    existing.add(jsonEncode(device.toJson()));
    await prefs.setStringList(_storageKey, existing);
  }

  Future<List<PairedDevice>> getPairedDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? [];
    return raw
        .map((r) => PairedDevice.fromJson(jsonDecode(r) as Map<String, dynamic>))
        .toList();
  }

  /// Removes a paired device from this device's list (Settings -> Forget).
  Future<void> forgetDevice(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_storageKey) ?? [];
    existing.removeWhere((raw) =>
        (jsonDecode(raw) as Map<String, dynamic>)['deviceId'] == deviceId);
    await prefs.setStringList(_storageKey, existing);
  }

  /// Updates a paired device's stored IP address after it was re-discovered
  /// on the local network (DHCP lease changes). Preserves the shared secret.
  Future<void> updateDeviceIp(String deviceId, String newIp) async {
    await _updateField(deviceId, (map) => map['ipAddress'] = newIp);
  }

  /// Stores a paired device's last-known public TCP endpoint, learned by
  /// piggybacking on a successful connection (LAN or remote).
  Future<void> updateDevicePublicAddress(
      String deviceId, String publicAddress) async {
    await _updateField(
        deviceId, (map) => map['publicAddress'] = publicAddress);
  }

  /// Stores a paired device's last-known public UDP endpoint, shared by the
  /// peer's NAT keep-alive. Used for UDP hole-punching when the TCP path
  /// fails.
  Future<void> updateDevicePublicUdpEndpoint(
      String deviceId, String udpEndpoint) async {
    await _updateField(
        deviceId, (map) => map['publicUdpEndpoint'] = udpEndpoint);
  }

  Future<void> _updateField(
      String deviceId, void Function(Map<String, dynamic> map) mutate) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_storageKey) ?? [];
    final updated = <String>[];
    for (final raw in existing) {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['deviceId'] == deviceId) {
        mutate(map);
      }
      updated.add(jsonEncode(map));
    }
    await prefs.setStringList(_storageKey, updated);
  }
}

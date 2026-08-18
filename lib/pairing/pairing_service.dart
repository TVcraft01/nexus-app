import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';
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
      final incoming = PairedDevice.fromJson(json);

      // The scanning device must send back the exact pairingKey that was
      // encoded in the QR code we're showing — proves it actually scanned
      // OUR QR code and isn't some random device on the network guessing.
      if (json['respondingToKey'] != thisDevice.pairingKey) {
        return Response.forbidden('pairing key mismatch');
      }

      // Both devices must end up storing the SAME shared secret so they can
      // later derive the same transfer-encryption key. The secret embedded in
      // the QR code is the one both sides know, so we persist the peer using
      // OUR key rather than the key the peer generated for itself.
      final shared = incoming.copyWith(pairingKey: thisDevice.pairingKey);
      await _saveDevice(shared);
      onPaired(shared);

      // Reply with our own identity so the scanning device saves us too.
      return Response.ok(jsonEncode(thisDevice.toJson()),
          headers: {'content-type': 'application/json'});
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

    final response = await http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        ...thisDevice.toJson(),
        'respondingToKey': scannedDevice.pairingKey,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Pairing failed: ${response.statusCode} ${response.body}');
    }

    final confirmed = PairedDevice.fromJson(jsonDecode(response.body));
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

  /// Stores a paired device's last-known public endpoint, learned by
  /// piggybacking on a successful connection (LAN or remote).
  Future<void> updateDevicePublicAddress(
      String deviceId, String publicAddress) async {
    await _updateField(
        deviceId, (map) => map['publicAddress'] = publicAddress);
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

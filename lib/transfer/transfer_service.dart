import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../devbridge/dev_bridge_service.dart';
import '../models/paired_device.dart';
import '../pairing/pairing_service.dart';
import '../remote/remote_access_service.dart';
import '../sync/sync_service.dart';
import '../tasks/task_crypto.dart';
import '../tasks/task_protocol.dart';
import '../tasks/task_worker.dart';

enum TransferDirection { sent, received }

/// One entry in the persisted transfer log: a file sent from or received by
/// this device. Stored in SharedPreferences as a JSON list (same pattern as
/// the paired-devices list), most recent first.
class TransferRecord {
  final TransferDirection direction;
  final String fileName;
  final int sizeBytes;
  final String otherDeviceName;
  final DateTime timestamp;
  final String localPath; // where the file lives on THIS device

  const TransferRecord({
    required this.direction,
    required this.fileName,
    required this.sizeBytes,
    required this.otherDeviceName,
    required this.timestamp,
    required this.localPath,
  });

  bool get isSent => direction == TransferDirection.sent;

  Map<String, dynamic> toJson() => {
        'direction': direction.name,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'otherDeviceName': otherDeviceName,
        'timestamp': timestamp.toIso8601String(),
        'localPath': localPath,
      };

  factory TransferRecord.fromJson(Map<String, dynamic> json) =>
      TransferRecord(
        direction:
            TransferDirection.values.byName(json['direction'] as String),
        fileName: json['fileName'] as String,
        sizeBytes: json['sizeBytes'] as int,
        otherDeviceName: json['otherDeviceName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        localPath: json['localPath'] as String,
      );
}

/// A file that arrived on this device over the local network.
class ReceivedFile {
  final String fileName;
  final int sizeBytes;
  final String fromDeviceName;
  final String savedPath;
  final DateTime receivedAt;

  ReceivedFile({
    required this.fileName,
    required this.sizeBytes,
    required this.fromDeviceName,
    required this.savedPath,
    required this.receivedAt,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'fromDeviceName': fromDeviceName,
        'savedPath': savedPath,
        'receivedAt': receivedAt.toIso8601String(),
      };

  factory ReceivedFile.fromJson(Map<String, dynamic> json) => ReceivedFile(
        fileName: json['fileName'] as String,
        sizeBytes: json['sizeBytes'] as int,
        fromDeviceName: json['fromDeviceName'] as String,
        savedPath: json['savedPath'] as String,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
      );
}

/// Sends files to, and receives files from, paired Nexus devices — always
/// direct device-to-device over the local network. No cloud, no relay.
///
/// Every device runs a small HTTP server on [receivePort] while the app is
/// open, so a paired device can push a file straight to it. The sender must
/// present the pairing key we exchanged during QR pairing, and the file body
/// is encrypted with AES-GCM using a key derived from that shared secret.
class TransferService {
  static const receivePort = 51821;
  static const _historyKey = 'nexus_transfer_history';
  static const _legacyHistoryKey = 'nexus_received_files';
  static const _deviceIdKey = 'nexus_device_id';
  static const _deviceNameKey = 'nexus_device_name';
  static const _pairedKey = 'nexus_paired_devices';

  // Wire format for an encrypted transfer: 6-byte magic, 4-byte plaintext
  // length, then repeating chunks of nonce | ciphertext-length | ciphertext |
  // GCM tag.
  static const _magic = 'NEXUS1';
  static const _nonceLength = 12;
  static const _macLength = 16;
  static const _chunkSize = 1024 * 1024; // 1 MiB of plaintext per chunk

  static final _aes = AesGcm.with256bits();

  final _pairing = PairingService();
  HttpServer? _server;
  final _receivedController = StreamController<ReceivedFile>.broadcast();
  final _historyController = StreamController<TransferRecord>.broadcast();

  /// Wired up by the app at startup; lets this device act as a worker in the
  /// distributed batch-summarization task (capability reporting + execution).
  /// Null means this device reports "no model" and refuses tasks.
  TaskWorker? taskWorker;

  /// Emits whenever a file finishes arriving on this device.
  Stream<ReceivedFile> get receivedFiles => _receivedController.stream;

  /// Emits every time a transfer is logged (sent or received), so the Files
  /// tab can refresh itself without polling.
  Stream<TransferRecord> get transferHistory => _historyController.stream;

  /// Starts the local server that accepts incoming files and answers
  /// reachability "ping"s. Safe to call at app start; it only binds once.
  Future<void> start() async {
    if (_server != null) return;
    final handler = const Pipeline().addHandler(_handleRequest);
    _server =
        await shelf_io.serve(handler, InternetAddress.anyIPv4, receivePort);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _receivedController.close();
    await _historyController.close();
  }

  /// Executes an incoming batch-task share: decrypts it, summarizes each item
  /// with the local model, and returns the encrypted results.
  Future<Response> _handleTask(Request request) async {
    final key = request.headers['x-nexus-key'] ?? '';
    final device = await _deviceForPairingKey(key);
    if (device == null) {
      return Response.forbidden('device not paired');
    }

    final worker = taskWorker;
    if (worker == null || !worker.isAvailable) {
      return Response(409,
          body: '{"error":"no local model on this device"}',
          headers: {'content-type': 'application/json'});
    }

    try {
      final keyBytes = base64Decode(device.transferKey);
      final encrypted = await request.read().expand((chunk) => chunk).toList();
      final plain = await decryptTaskPayload(encrypted, keyBytes);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final items = [
        for (final i in json['items'] as List)
          TaskItem.fromJson(i as Map<String, dynamic>),
      ];
      final results = await worker.summarizeItems(items);
      final responsePayload = utf8.encode(jsonEncode({
        'results': [for (final r in results) r.toJson()],
      }));
      return Response.ok(
        await encryptTaskPayload(responsePayload, keyBytes),
        headers: {'content-type': 'application/octet-stream'},
      );
    } catch (e) {
      return Response.badRequest(
        body: jsonEncode({'error': 'task failed: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _handleRequest(Request request) async {
    // Lightweight liveness probe used for the stale-IP recovery in sendFile.
    // Also shares our current public endpoint so the caller can store it for
    // the opt-in remote-connect path.
    if (request.method == 'GET' && request.url.path == 'ping') {
      final public = RemoteAccessService.instance.publicAddress;
      return Response.ok(
        jsonEncode({
          'deviceId': await _thisDeviceId(),
          'deviceName': await _thisDeviceName(),
          if (public != null) 'publicAddress': public,
        }),
        headers: {
          'content-type': 'application/json',
          if (public != null) 'x-nexus-public': public,
        },
      );
    }

    // Capability check for the batch task: does this device have a model that
    // can actually be loaded RIGHT NOW, and which tier? "Installed" is not the
    // same as "loadable" — under memory pressure a device may have the model
    // file but not the free RAM to load it. Reporting that distinction up front
    // lets the coordinator skip such a device instead of dispatching work that
    // fails and relies on redistribution to recover.
    if (request.method == 'GET' && request.url.path == 'status') {
      final worker = taskWorker;
      final installed = worker?.isAvailable ?? false;
      final loadable = installed && await (worker?.canLoadNow() ?? Future.value(false));
      return Response.ok(
        jsonEncode({
          'deviceId': await _thisDeviceId(),
          'deviceName': await _thisDeviceName(),
          // True only when the model can be loaded right now. This is what the
          // coordinator checks; an installed-but-RAM-starved device reports
          // false here and is skipped up front.
          'llmAvailable': loadable,
          'llmTier': worker?.tierId,
          'llmInstalled': installed,
          'llmStatus': !installed
              ? 'none'
              : (loadable ? 'ready' : 'installed_but_unloadable'),
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Distributed-task endpoint: summarize an assigned share with the local
    // model and return the summaries. AES-GCM encrypted like file transfer,
    // authenticated by the pairing key.
    if (request.method == 'POST' && request.url.path == 'task') {
      return _handleTask(request);
    }

    // Knowledge sync: exchange newer reminder/fact events with a paired device
    // in one encrypted round trip. Auth + encryption identical to /task.
    if (request.method == 'POST' && request.url.path == 'sync') {
      final key = request.headers['x-nexus-key'] ?? '';
      final device = await _deviceForPairingKey(key);
      if (device == null) {
        return Response.forbidden('device not paired');
      }
      return SyncService.instance.handleSyncRequest(request, device);
    }

    // Remote dev task (the dev bridge): a paired device submits a prompt to be
    // run by this PC's configured task command. Auth + encryption identical to
    // /task and /sync; the DevBridgeService adds the safety gate (toggle off
    // by default, one task at a time). The sender piggybacks its current
    // public endpoint so we can push the build artifact back to it.
    if (request.method == 'POST' && request.url.path == 'devtask') {
      final key = request.headers['x-nexus-key'] ?? '';
      final device = await _deviceForPairingKey(key);
      if (device == null) {
        return Response.forbidden('device not paired');
      }
      final senderPublic = request.headers['x-nexus-public'];
      if (senderPublic != null && senderPublic.isNotEmpty) {
        await _pairing.updateDevicePublicAddress(device.deviceId, senderPublic);
      }
      return DevBridgeService.instance.handleDevTask(request, device);
    }

    if (request.method != 'POST' || request.url.path != 'receive') {
      return Response.notFound('not found');
    }

    final key = request.headers['x-nexus-key'] ?? '';
    final device = await _deviceForPairingKey(key);
    if (device == null) {
      return Response.forbidden('device not paired');
    }

    // The sender piggybacks its current public endpoint; remember it so we can
    // reach back later when not on the same LAN.
    final senderPublic = request.headers['x-nexus-public'];
    if (senderPublic != null && senderPublic.isNotEmpty) {
      await _pairing.updateDevicePublicAddress(device.deviceId, senderPublic);
    }

    final keyBytes = base64Decode(device.transferKey);

    final rawName = request.headers['x-nexus-filename'] ?? 'received_file';
    final fileName = _safeFileName(rawName);
    final fromName = request.headers['x-nexus-sender'] ?? 'Unknown device';

    final dir = await _receiveDir();
    final dest = _uniquePath(File(p.join(dir.path, fileName)));

    try {
      await _decryptToFile(request.read(), dest, keyBytes);
    } catch (_) {
      // Never keep bytes that failed authentication.
      if (await dest.exists()) await dest.delete();
      return Response.badRequest(
        body: jsonEncode({'status': 'error', 'message': 'decryption failed'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final received = ReceivedFile(
      fileName: p.basename(dest.path),
      sizeBytes: await dest.length(),
      fromDeviceName: fromName,
      savedPath: dest.path,
      receivedAt: DateTime.now(),
    );
    final record = TransferRecord(
      direction: TransferDirection.received,
      fileName: received.fileName,
      sizeBytes: received.sizeBytes,
      otherDeviceName: received.fromDeviceName,
      timestamp: received.receivedAt,
      localPath: received.savedPath,
    );
    await _saveToHistory(record);
    _receivedController.add(received);
    _historyController.add(record);

    // The sender just proved it's reachable — a natural moment to exchange
    // knowledge (reminders/facts). Best-effort; a slow peer is never a reason
    // to fail the file transfer.
    unawaited(SyncService.instance.syncAll());

    final myPublic = RemoteAccessService.instance.publicAddress;
    return Response.ok(
      jsonEncode({'status': 'ok', 'savedPath': dest.path}),
      headers: {
        'content-type': 'application/json',
        if (myPublic != null) 'x-nexus-public': myPublic,
      },
    );
  }

  /// Pushes [filePath] directly to [target], encrypted with AES-GCM.
  /// [onProgress] reports 0.0..1.0 as plaintext bytes are processed.
  ///
  /// Connection order is always: local IP first, then a quick subnet
  /// re-discovery (DHCP change), then — only if the user opted into "Allow
  /// internet access" — the peer's last-known public endpoint. Each attempt
  /// also piggybacks our public endpoint so the peer can reach us back later.
  Future<void> sendFile({
    required PairedDevice target,
    required String filePath,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('That file no longer exists.');
    }

    final remote = RemoteAccessService.instance;
    final senderName = await _thisDeviceName();
    final keyBytes = base64Decode(target.transferKey);

    // 1. Local network first (same behavior as before).
    if (await _isReachable(target)) {
      await _sendTo(target, target.ipAddress, receivePort, file, keyBytes,
          senderName, onProgress);
      remote.reportStatus(target.deviceId, DeviceLinkStatus.local);
      return;
    }

    // 2. Re-discover on the last-known subnet (DHCP lease change).
    final newIp = await _discoverIp(target);
    if (newIp != null) {
      await _pairing.updateDeviceIp(target.deviceId, newIp);
      await _sendTo(target, newIp, receivePort, file, keyBytes, senderName,
          onProgress);
      remote.reportStatus(target.deviceId, DeviceLinkStatus.local);
      return;
    }

    // 3. Remote path — only when the user opted in and we know the peer's
    //    public endpoint. Direct device-to-device over the peer's forwarded
    //    port; no relay.
    if (remote.enabled && target.publicAddress != null) {
      final parts = target.publicAddress!.split(':');
      final host = parts.first;
      final port = parts.length > 1 ? (int.tryParse(parts[1]) ?? receivePort) : receivePort;
      try {
        await _sendTo(target, host, port, file, keyBytes, senderName, onProgress);
        remote.reportStatus(target.deviceId, DeviceLinkStatus.remote);
        return;
      } catch (_) {
        // Both paths failed; fall through to the honest, actionable message.
      }
    }

    remote.reportStatus(target.deviceId, DeviceLinkStatus.unreachable);
    if (remote.enabled) {
      throw Exception(
          "Can't reach ${target.deviceName} remotely right now — you'll need "
          'to be on the same network.');
    }
    throw Exception('Couldn\'t reach ${target.deviceName} — make sure both '
        'devices are on the same Wi-Fi network with Nexus open.');
  }

  /// Performs the actual encrypted POST to `host:port` and, on success,
  /// remembers the peer's public endpoint from its response header.
  Future<void> _sendTo(
    PairedDevice target,
    String host,
    int port,
    File file,
    List<int> keyBytes,
    String senderName,
    void Function(double progress)? onProgress,
  ) async {
    final myPublic = RemoteAccessService.instance.publicAddress;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('http://$host:$port/receive'),
      );
      request.headers.set('content-type', 'application/octet-stream');
      request.headers.set(
          'x-nexus-filename', Uri.encodeComponent(p.basename(file.path)));
      request.headers.set('x-nexus-sender', senderName);
      request.headers.set('x-nexus-key', target.pairingKey);
      if (myPublic != null) {
        request.headers.set('x-nexus-public', myPublic);
      }

      await request
          .addStream(_encryptedBody(file, keyBytes, onProgress: onProgress));
      final response = await request.close();

      final peerPublic = response.headers.value('x-nexus-public');
      if (peerPublic != null && peerPublic.isNotEmpty) {
        await _pairing.updateDevicePublicAddress(target.deviceId, peerPublic);
      }

      if (response.statusCode != 200) {
        await response.drain<void>();
        throw Exception(
            'The other device refused the file (${response.statusCode}).');
      }
      await response.drain<void>();
      await _logSent(target, file);
      // The peer answered us — sync knowledge with all paired devices while
      // we know at least one is reachable. Best-effort, never blocks the send.
      unawaited(SyncService.instance.syncAll());
    } on SocketException {
      throw Exception('Could not reach ${target.deviceName}.');
    } on TimeoutException {
      throw Exception('Could not reach ${target.deviceName} in time.');
    } finally {
      client.close(force: true);
    }
  }

  // ---- encryption (sender side) -------------------------------------------

  Stream<List<int>> _encryptedBody(
    File file,
    List<int> keyBytes, {
    void Function(double progress)? onProgress,
  }) async* {
    yield ascii.encode(_magic);
    final size = await file.length();
    yield _uint32(size);

    var offset = 0;
    while (offset < size) {
      final end = min(offset + _chunkSize, size);
      final plain = await _readRange(file, offset, end);
      final box = await _aes.encrypt(
        plain,
        secretKey: SecretKey(keyBytes),
        nonce: _aes.newNonce(),
      );
      yield Uint8List.fromList(box.nonce);
      yield _uint32(box.cipherText.length);
      yield Uint8List.fromList(box.cipherText);
      yield Uint8List.fromList(box.mac.bytes);
      offset = end;
      onProgress?.call(size == 0 ? 1.0 : offset / size);
    }
  }

  Future<Uint8List> _readRange(File file, int start, int end) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, end)) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  Uint8List _uint32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
    return bytes;
  }

  // ---- decryption (receiver side) -----------------------------------------

  Future<void> _decryptToFile(
    Stream<List<int>> stream,
    File dest,
    List<int> keyBytes,
  ) async {
    final reader = _BodyReader(stream);

    final magic = await reader.readBytes(6);
    if (magic == null || ascii.decode(magic) != _magic) {
      throw StateError('not an encrypted transfer');
    }
    final total = await reader.readUint32();
    if (total == null) throw StateError('truncated envelope');

    final sink = dest.openWrite();
    try {
      var written = 0;
      while (written < total) {
        final nonce = await reader.readBytes(_nonceLength);
        final len = await reader.readUint32();
        final cipherText = len == null ? null : await reader.readBytes(len);
        final macBytes = await reader.readBytes(_macLength);
        if (nonce == null || len == null || cipherText == null || macBytes == null) {
          throw StateError('truncated transfer');
        }

        // Throws SecretBoxAuthenticationError if the tag does not match.
        final clear = await _aes.decrypt(
          SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
          secretKey: SecretKey(keyBytes),
        );

        if (written + clear.length > total) {
          throw StateError('transfer larger than declared');
        }
        sink.add(clear);
        written += clear.length;
      }
    } finally {
      await sink.close();
    }
  }

  // ---- reachability + re-discovery ----------------------------------------

  /// True only if a Nexus instance answering at the stored IP reports the same
  /// device ID. This prevents sending a file to the wrong device that happened
  /// to grab the old IP.
  Future<bool> _isReachable(PairedDevice target) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(Uri.parse('http://${target.ipAddress}:$receivePort/ping'));
      final response = await request.close().timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return false;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['deviceId'] != target.deviceId) return false;

      // Learn the peer's public endpoint for the opt-in remote path.
      final peerPublic = json['publicAddress'] as String?;
      if (peerPublic != null && peerPublic.isNotEmpty) {
        await _pairing.updateDevicePublicAddress(target.deviceId, peerPublic);
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Scans the last-known subnet (and our current one) for the target device,
  /// returning its current IP if found.
  Future<String?> _discoverIp(PairedDevice target) async {
    final subnets = <String>{};
    final stored = _subnetBase(target.ipAddress);
    if (stored != null) subnets.add(stored);
    final mine = _subnetBase(await _localIpAddress() ?? '');
    if (mine != null) subnets.add(mine);

    for (final subnet in subnets) {
      final found = await _scanSubnet(subnet, target.deviceId);
      if (found != null) return found;
    }
    return null;
  }

  /// Assumes a /24 home network (the common case) and probes hosts .1..254 in
  /// parallel batches with a very short timeout.
  Future<String?> _scanSubnet(String base, String deviceId) async {
    for (var batchStart = 1; batchStart <= 254; batchStart += 64) {
      final batch = <Future<String?>>[];
      for (var i = batchStart; i < batchStart + 64 && i <= 254; i++) {
        batch.add(_probe('$base.$i', deviceId));
      }
      final results = await Future.wait(batch);
      final matches = results.whereType<String>();
      if (matches.isNotEmpty) return matches.first;
    }
    return null;
  }

  Future<String?> _probe(String ip, String deviceId) async {
    final client =
        HttpClient()..connectionTimeout = const Duration(milliseconds: 300);
    try {
      final request =
          await client.getUrl(Uri.parse('http://$ip:$receivePort/ping'));
      final response =
          await request.close().timeout(const Duration(milliseconds: 400));
      if (response.statusCode != 200) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 400));
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['deviceId'] == deviceId ? ip : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String? _subnetBase(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  Future<String?> _localIpAddress() async {
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
    return null;
  }

  // ---- helpers ------------------------------------------------------------

  Future<PairedDevice?> _deviceForPairingKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pairedKey) ?? [];
    for (final r in raw) {
      final map = jsonDecode(r) as Map<String, dynamic>;
      if (map['pairingKey'] == key) {
        return PairedDevice.fromJson(map);
      }
    }
    return null;
  }

  Future<String> _thisDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceIdKey) ?? '';
  }

  Future<String> _thisDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceNameKey) ?? Platform.operatingSystem;
  }

  Future<Directory> _receiveDir() async {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      base = null; // not supported on every platform
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'Nexus'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Logs a successful outbound transfer (called from [_sendTo], so every
  /// send path — LAN, re-discovered IP, or remote — is covered).
  Future<void> _logSent(PairedDevice target, File file) async {
    final record = TransferRecord(
      direction: TransferDirection.sent,
      fileName: p.basename(file.path),
      sizeBytes: await file.length(),
      otherDeviceName: target.deviceName,
      timestamp: DateTime.now(),
      localPath: file.path,
    );
    await _saveToHistory(record);
    _historyController.add(record);
  }

  Future<void> _saveToHistory(TransferRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_historyKey) ?? [];
    existing.insert(0, jsonEncode(record.toJson()));
    if (existing.length > 100) existing.removeRange(100, existing.length);
    await prefs.setStringList(_historyKey, existing);
  }

  /// Full transfer history (sent + received), most recent first.
  Future<List<TransferRecord>> getTransferHistory() async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getStringList(_historyKey) ?? [];

    // One-time migration: before the unified log existed, received files were
    // stored under a separate key. Convert those entries and retire the key.
    if (raw.isEmpty) {
      final legacy = prefs.getStringList(_legacyHistoryKey) ?? [];
      if (legacy.isNotEmpty) {
        raw = [
          for (final r in legacy)
            jsonEncode(_legacyToRecord(jsonDecode(r) as Map<String, dynamic>)
                .toJson()),
        ];
        await prefs.setStringList(_historyKey, raw);
        await prefs.remove(_legacyHistoryKey);
      }
    }

    return raw
        .map((r) =>
            TransferRecord.fromJson(jsonDecode(r) as Map<String, dynamic>))
        .toList();
  }

  TransferRecord _legacyToRecord(Map<String, dynamic> legacy) =>
      TransferRecord(
        direction: TransferDirection.received,
        fileName: legacy['fileName'] as String,
        sizeBytes: legacy['sizeBytes'] as int,
        otherDeviceName: legacy['fromDeviceName'] as String,
        timestamp: DateTime.parse(legacy['receivedAt'] as String),
        localPath: legacy['savedPath'] as String,
      );

  /// Received-only view of the history, for the Settings section.
  Future<List<ReceivedFile>> getReceivedFiles() async {
    final records = await getTransferHistory();
    return [
      for (final r in records.where((r) => r.direction == TransferDirection.received))
        ReceivedFile(
          fileName: r.fileName,
          sizeBytes: r.sizeBytes,
          fromDeviceName: r.otherDeviceName,
          savedPath: r.localPath,
          receivedAt: r.timestamp,
        ),
    ];
  }

  /// Clears the whole transfer log (sent and received).
  Future<void> clearTransferHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    await prefs.remove(_legacyHistoryKey);
  }

  /// Kept for the Settings screen, which still labels this "Clear history".
  Future<void> clearReceivedFiles() => clearTransferHistory();

  /// Strips anything that could be used for path traversal, so a peer can't
  /// write outside the Nexus receive folder.
  String _safeFileName(String name) {
    String decoded;
    try {
      decoded = Uri.decodeComponent(name);
    } on FormatException {
      decoded = name;
    }
    final base = p.basename(decoded.replaceAll('\\', '/'));
    final cleaned = base.replaceAll(RegExp(r'[^\w.\- ]'), '_');
    return cleaned.isEmpty ? 'received_file' : cleaned;
  }

  File _uniquePath(File file) {
    if (!file.existsSync()) return file;
    final dir = file.parent.path;
    final name = p.basenameWithoutExtension(file.path);
    final ext = p.extension(file.path);
    var i = 1;
    File candidate;
    do {
      candidate = File(p.join(dir, '$name ($i)$ext'));
      i++;
    } while (candidate.existsSync());
    return candidate;
  }
}

/// Reads exact byte counts out of a byte stream, buffering whatever arrives in
/// arbitrary chunk sizes.
class _BodyReader {
  final StreamIterator<List<int>> _it;
  final List<int> _buffer = [];

  _BodyReader(Stream<List<int>> stream) : _it = StreamIterator(stream);

  Future<bool> _fill(int n) async {
    while (_buffer.length < n) {
      if (!await _it.moveNext()) return false;
      _buffer.addAll(_it.current);
    }
    return true;
  }

  /// Returns exactly [n] bytes, or null if the stream ends early.
  Future<List<int>?> readBytes(int n) async {
    if (!await _fill(n)) return null;
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  Future<int?> readUint32() async {
    final bytes = await readBytes(4);
    if (bytes == null) return null;
    return ByteData.sublistView(Uint8List.fromList(bytes))
        .getUint32(0, Endian.big);
  }
}

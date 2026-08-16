import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/paired_device.dart';

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
/// Every device runs a small receive-only HTTP server on [receivePort] while
/// the app is open, so a paired device can push a file straight to it. The
/// sender must present the pairing key we exchanged during QR pairing, which
/// stops random devices on the network from dropping files on us.
class TransferService {
  static const receivePort = 51821;
  static const _historyKey = 'nexus_received_files';
  static const _deviceNameKey = 'nexus_device_name';

  HttpServer? _server;
  final _receivedController = StreamController<ReceivedFile>.broadcast();

  /// Emits whenever a file finishes arriving on this device.
  Stream<ReceivedFile> get receivedFiles => _receivedController.stream;

  /// Starts the local server that accepts incoming files. Safe to call at
  /// app start; it only binds the port once.
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
  }

  Future<Response> _handleRequest(Request request) async {
    if (request.method != 'POST' || request.url.path != 'receive') {
      return Response.notFound('not found');
    }

    final key = request.headers['x-nexus-key'] ?? '';
    if (!await _isPairedKey(key)) {
      return Response.forbidden('device not paired');
    }

    final rawName = request.headers['x-nexus-filename'] ?? 'received_file';
    final fileName = _safeFileName(rawName);
    final fromName = request.headers['x-nexus-sender'] ?? 'Unknown device';

    final dir = await _receiveDir();
    final dest = _uniquePath(File(p.join(dir.path, fileName)));

    final sink = dest.openWrite();
    try {
      await for (final chunk in request.read()) {
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final received = ReceivedFile(
      fileName: p.basename(dest.path),
      sizeBytes: await dest.length(),
      fromDeviceName: fromName,
      savedPath: dest.path,
      receivedAt: DateTime.now(),
    );
    await _saveToHistory(received);
    _receivedController.add(received);

    return Response.ok(
      jsonEncode({'status': 'ok', 'savedPath': dest.path}),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Pushes [filePath] directly to [target]. [onProgress] reports 0.0..1.0
  /// as the bytes leave this device.
  Future<void> sendFile({
    required PairedDevice target,
    required String filePath,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('That file no longer exists.');
    }
    final size = await file.length();
    final senderName = await _thisDeviceName();

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('http://${target.ipAddress}:$receivePort/receive'),
      );
      request.headers.set('content-type', 'application/octet-stream');
      request.headers.set(
          'x-nexus-filename', Uri.encodeComponent(p.basename(filePath)));
      request.headers.set('x-nexus-size', '$size');
      request.headers.set('x-nexus-sender', senderName);
      request.headers.set('x-nexus-key', target.pairingKey);

      var sent = 0;
      final stream = file.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(size == 0 ? 1.0 : sent / size);
        return chunk;
      });

      await request.addStream(stream);
      final response = await request.close();

      if (response.statusCode != 200) {
        await response.drain<void>();
        throw Exception(
            'The other device refused the file (${response.statusCode}).');
      }
      await response.drain<void>();
    } on SocketException {
      throw Exception(
          'Could not reach ${target.deviceName}. Make sure it is on the same '
          'Wi-Fi network with Nexus open.');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _thisDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceNameKey) ?? Platform.operatingSystem;
  }

  Future<bool> _isPairedKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('nexus_paired_devices') ?? [];
    return raw.any(
      (r) => (jsonDecode(r) as Map<String, dynamic>)['pairingKey'] == key,
    );
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

  Future<void> _saveToHistory(ReceivedFile received) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_historyKey) ?? [];
    existing.insert(0, jsonEncode(received.toJson()));
    if (existing.length > 50) existing.removeRange(50, existing.length);
    await prefs.setStringList(_historyKey, existing);
  }

  Future<List<ReceivedFile>> getReceivedFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_historyKey) ?? [];
    return raw
        .map((r) => ReceivedFile.fromJson(jsonDecode(r) as Map<String, dynamic>))
        .toList();
  }

  Future<void> clearReceivedFiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

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

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
/// Every device runs a small HTTP server on [receivePort] while the app is
/// open, so a paired device can push a file straight to it. The sender must
/// present the pairing key we exchanged during QR pairing, and the file body
/// is encrypted with AES-GCM using a key derived from that shared secret.
class TransferService {
  static const receivePort = 51821;
  static const _historyKey = 'nexus_received_files';
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

  HttpServer? _server;
  final _receivedController = StreamController<ReceivedFile>.broadcast();

  /// Emits whenever a file finishes arriving on this device.
  Stream<ReceivedFile> get receivedFiles => _receivedController.stream;

  /// Starts the local server that accepts incoming files. Safe to call at
  /// app start; it only binds once.
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
    final device = await _deviceForPairingKey(key);
    if (device == null) {
      return Response.forbidden('device not paired');
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
    await _saveToHistory(received);
    _receivedController.add(received);

    return Response.ok(
      jsonEncode({'status': 'ok', 'savedPath': dest.path}),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Pushes [filePath] directly to [target], encrypted with AES-GCM.
  /// [onProgress] reports 0.0..1.0 as plaintext bytes are processed.
  Future<void> sendFile({
    required PairedDevice target,
    required String filePath,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('That file no longer exists.');
    }

    final senderName = await _thisDeviceName();
    final keyBytes = base64Decode(target.transferKey);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('http://${target.ipAddress}:$receivePort/receive'),
      );
      request.headers.set('content-type', 'application/octet-stream');
      request.headers.set(
          'x-nexus-filename', Uri.encodeComponent(p.basename(filePath)));
      request.headers.set('x-nexus-sender', senderName);
      request.headers.set('x-nexus-key', target.pairingKey);

      await request
          .addStream(_encryptedBody(file, keyBytes, onProgress: onProgress));
      final response = await request.close();

      if (response.statusCode != 200) {
        await response.drain<void>();
        throw Exception(
            'The other device refused the file (${response.statusCode}).');
      }
      await response.drain<void>();
    } on SocketException {
      throw Exception('Could not reach ${target.deviceName}. Make sure it is '
          'on the same Wi-Fi network with Nexus open.');
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

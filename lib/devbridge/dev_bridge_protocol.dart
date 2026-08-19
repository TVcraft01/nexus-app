/// Wire types + the client side of the remote-dev-task exchange.
///
/// The phone encrypts a {prompt} with the shared pairing-key-derived AES-GCM
/// key (same box as /task and /sync), POSTs it to the PC's /devtask endpoint,
/// and gets back an encrypted report. If the task produced a build artifact,
/// the PC also pushes it back over the existing encrypted file-transfer path
/// (TransferService.sendFile), so the phone receives it through its normal
/// /receive server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../models/paired_device.dart';
import '../remote/remote_access_service.dart';
import '../tasks/task_crypto.dart';
import '../transfer/transfer_service.dart';

/// A parsed, decrypted /devtask response.
class DevTaskResult {
  final bool ok;
  final String report;
  final String? error;

  /// File name of the artifact the PC is sending back, if any.
  final String? artifactFileName;

  /// Local path of the artifact (only meaningful on the PC side).
  final String? artifactPath;

  const DevTaskResult({
    required this.ok,
    required this.report,
    this.error,
    this.artifactFileName,
    this.artifactPath,
  });
}

/// Sends a dev-task prompt to [device] over the encrypted channel.
///
/// Mirrors the /task and /sync request shape: AES-GCM-encrypted body,
/// authenticated by the pairing key in the `x-nexus-key` header. Also
/// piggybacks our public endpoint so the PC can push the artifact back to us
/// over the remote path when we're not on the same LAN.
Future<DevTaskResult> sendDevTask({
  required PairedDevice device,
  required String prompt,
  Duration timeout = const Duration(minutes: 40),
  int? port,
}) async {
  final keyBytes = base64Decode(device.transferKey);
  final payload = utf8.encode(jsonEncode({'prompt': prompt}));
  final encrypted = await encryptTaskPayload(payload, keyBytes);

  final myPublic = RemoteAccessService.instance.publicAddress;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(Uri.parse(
      'http://${device.ipAddress}:${port ?? TransferService.receivePort}/devtask',
    ));
    request.headers.set('content-type', 'application/octet-stream');
    request.headers.set('x-nexus-key', device.pairingKey);
    if (myPublic != null && myPublic.isNotEmpty) {
      request.headers.set('x-nexus-public', myPublic);
    }
    request.add(encrypted);
    final response = await request.close().timeout(timeout);
    final body = await response.expand((chunk) => chunk).toList().timeout(timeout);

    // Error responses are plain JSON (not encrypted), so a peer that can't
    // decrypt or rejects the request still gets a readable reason.
    if (response.statusCode != 200) {
      return _errorResult(body);
    }

    final plain = await decryptTaskPayload(body, keyBytes);
    final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return DevTaskResult(
      ok: json['status'] == 'ok',
      report: json['report'] as String? ?? '',
      error: json['error'] as String?,
      artifactFileName: json['artifactFileName'] as String?,
      artifactPath: json['artifactPath'] as String?,
    );
  } on TimeoutException {
    return const DevTaskResult(
      ok: false,
      report: '',
      error: 'The task did not finish in time on the remote device.',
    );
  } on SocketException {
    return const DevTaskResult(
      ok: false,
      report: '',
      error: "Couldn't reach the remote device.",
    );
  } catch (e) {
    return DevTaskResult(ok: false, report: '', error: 'Task failed: $e');
  } finally {
    client.close(force: true);
  }
}

DevTaskResult _errorResult(List<int> body) {
  String text;
  try {
    text = utf8.decode(body);
  } catch (_) {
    text = '';
  }
  String message = 'The remote device rejected the task.';
  try {
    final json = jsonDecode(text) as Map<String, dynamic>;
    message = json['error'] as String? ?? message;
  } catch (_) {
    if (text.trim().isNotEmpty) message = text.trim();
  }
  return DevTaskResult(ok: false, report: '', error: message);
}

/// Produces the encrypted success response body for the /devtask handler.
Future<List<int>> devTaskResponseBody(
  List<int> keyBytes, {
  required bool statusOk,
  required String report,
  String? error,
  String? artifactFileName,
  String? artifactPath,
}) {
  final payload = utf8.encode(jsonEncode({
    'status': statusOk ? 'ok' : 'error',
    'report': report,
    if (error != null) 'error': error,
    if (artifactFileName != null) 'artifactFileName': artifactFileName,
    if (artifactPath != null) 'artifactPath': artifactPath,
  }));
  return encryptTaskPayload(payload, keyBytes);
}

/// Builds the plain (non-encrypted) error Response used for rejections that
/// happen before any decryption (toggle off, already busy).
Response devTaskRejection(String message, {int status = 403}) => Response(
      status,
      body: jsonEncode({'error': message}),
      headers: {'content-type': 'application/json'},
    );

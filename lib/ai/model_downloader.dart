import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown when the user cancels a download mid-way.
class DownloadCancelled implements Exception {}

/// Downloads [url] into [target] with progress reporting.
///
/// Shared by the LLM model download and the Vosk speech model download so both
/// follow the same "download once, store locally, never re-download" pattern.
/// Throws an exception on failure (and deletes the partial file); throws
/// [DownloadCancelled] when [isCancelled] returns true mid-download.
Future<void> downloadToFile(
  String url,
  File target, {
  required void Function(int receivedBytes, int totalBytes) onProgress,
  bool Function()? isCancelled,
}) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'Download failed (HTTP ${response.statusCode})',
        uri: Uri.parse(url),
      );
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in response.stream) {
        if (isCancelled?.call() ?? false) {
          await sink.close();
          throw DownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received, total);
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      rethrow;
    }
    await sink.close();

    // Even without a Content-Length, report one final tick so the UI closes
    // its progress bar.
    onProgress(received, total > 0 ? total : received);
  } finally {
    client.close();
  }
}

/// Writes [bytes] to [target] (used when a small file was fetched into
/// memory, e.g. to unzip).
Future<void> writeBytes(File target, Uint8List bytes) async {
  await target.parent.create(recursive: true);
  await target.writeAsBytes(bytes, flush: true);
}

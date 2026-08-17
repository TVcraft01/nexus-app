import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'model_downloader.dart';
import 'vosk_ffi.dart';

/// Fully-offline speech-to-text using Vosk (Apache-2.0).
///
/// The English model (~41 MB) is downloaded once from the official Vosk site
/// and stored in the app's private data directory; the recognizer runs through
/// the vendored libvosk.so native library. No audio ever leaves the device.
class VoskService {
  static const _modelUrl =
      'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';
  static const _modelFolder = 'vosk-model-small-en-us-0.15';
  static const _sampleRate = 16000.0;

  final ValueNotifier<double> downloadProgress = ValueNotifier(-1);
  final ValueNotifier<bool> listening = ValueNotifier(false);
  final ValueNotifier<String> partialText = ValueNotifier('');

  String? _modelPath;
  bool _downloading = false;
  Pointer<Void>? _model;
  Pointer<Void>? _recognizer;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _recSub;
  bool _finalized = false;

  bool get modelReady => _modelPath != null && Directory(_modelPath!).existsSync();

  /// Downloads (if needed) and extracts the Vosk model. Returns true when a
  /// usable model directory is available.
  Future<bool> ensureModel() async {
    if (modelReady) return true;
    if (_downloading) return false;

    _downloading = true;
    downloadProgress.value = 0;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final modelsDir = Directory(p.join(supportDir.path, 'vosk'));
      await modelsDir.create(recursive: true);
      final modelDir = p.join(modelsDir.path, _modelFolder);

      if (!Directory(modelDir).existsSync()) {
        final zipFile = File(p.join(modelsDir.path, 'model.zip'));
        if (zipFile.existsSync()) await zipFile.delete();
        await downloadToFile(
          _modelUrl,
          zipFile,
          onProgress: (received, total) {
            downloadProgress.value = total > 0 ? received / total : 0;
          },
        );
        final bytes = await zipFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final file in archive) {
          if (!file.isFile) continue;
          final out = File(p.join(modelsDir.path, file.name));
          await out.create(recursive: true);
          await out.writeAsBytes(file.content as List<int>, flush: true);
        }
        await zipFile.delete();
      }

      _modelPath = modelDir;
      downloadProgress.value = 1;
      return true;
    } catch (_) {
      downloadProgress.value = -1;
      return false;
    } finally {
      _downloading = false;
    }
  }

  /// Starts listening on the microphone and transcribing with Vosk.
  ///
  /// [onResult] fires once with the final transcription (auto-stops after it).
  /// [onPartial] fires with live interim text. [onError] fires for permission
  /// or mic-capture problems.
  Future<void> startListening({
    required ValueChanged<String> onPartial,
    required ValueChanged<String> onResult,
    required ValueChanged<String> onError,
  }) async {
    if (listening.value) return;
    if (!await ensureModel()) {
      onError('Could not download the speech model.');
      return;
    }

    final recorder = AudioRecorder();
    final ok = await recorder.hasPermission();
    if (!ok) {
      onError('Microphone permission was denied.');
      return;
    }

    _model ??= voskModelNew(_modelPath!);
    if (_model == null) {
      onError('Could not load the speech model.');
      return;
    }
    _recognizer = voskRecognizerNew(_model!, _sampleRate);
    if (_recognizer == null) {
      onError('Could not start the speech recognizer.');
      return;
    }
    _finalized = false;
    _recorder = recorder;

    try {
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _recSub = stream.listen(
        (chunk) => _feed(chunk, onPartial, onResult, onError),
        onError: (Object e) => onError('Microphone error: $e'),
      );
      listening.value = true;
      partialText.value = '';
    } catch (e) {
      _freeRecognizer();
      onError('Could not start the microphone. On Linux this needs '
          'pulseaudio-utils (parecord).');
    }
  }

  void _feed(
    List<int> chunk,
    ValueChanged<String> onPartial,
    ValueChanged<String> onResult,
    ValueChanged<String> onError,
  ) {
    final rec = _recognizer;
    if (rec == null || _finalized) return;
    try {
      final accepted = voskAcceptWaveform(rec, chunk);
      if (accepted == 1) {
        _finalized = true;
        final text = _textFromJson(voskResult(rec));
        if (text.isNotEmpty) onResult(text);
        unawaited(stopListening());
      } else {
        final partial = _textFromJson(voskPartial(rec));
        if (partial.isNotEmpty) partialText.value = partial;
      }
    } catch (e) {
      onError('Speech recognition error.');
    }
  }

  /// Stops the microphone and frees the recognizer.
  Future<void> stopListening() async {
    if (!listening.value && _recSub == null) return;
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    _recorder = null;
    _freeRecognizer();
    listening.value = false;
    partialText.value = '';
  }

  void _freeRecognizer() {
    final rec = _recognizer;
    if (rec != null) {
      voskRecognizerFree(rec);
      _recognizer = null;
    }
  }

  /// Extracts the "text" field from a Vosk result JSON string.
  String _textFromJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        final text = decoded['text'] as String?;
        return text?.trim() ?? '';
      }
    } catch (_) {}
    return '';
  }

  void dispose() {
    _recSub?.cancel();
    _freeRecognizer();
    if (_model != null) {
      voskModelFree(_model!);
      _model = null;
    }
    downloadProgress.dispose();
    listening.dispose();
    partialText.dispose();
  }
}

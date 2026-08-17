import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Minimal dart:ffi bindings to the Vosk C API (https://alphacephei.com/vosk/).
///
/// Vosk is Apache-2.0 and runs fully on-device: no audio ever leaves the
/// device. The native library is vendored with the app:
///   - Android: android/app/src/main/jniLibs/`<abi>`/libvosk.so
///   - Linux:   linux/vendor/libvosk.so (installed into the bundle's lib/)
final DynamicLibrary voskLib = DynamicLibrary.open('libvosk.so');

typedef _ModelNewNative = Pointer<Void> Function(Pointer<Utf8> modelPath);
typedef _ModelNewDart = Pointer<Void> Function(Pointer<Utf8> modelPath);
typedef _ModelFreeNative = Void Function(Pointer<Void> model);
typedef _ModelFreeDart = void Function(Pointer<Void> model);

typedef _RecognizerNewNative = Pointer<Void> Function(
    Pointer<Void> model, Float sampleRate);
typedef _RecognizerNewDart = Pointer<Void> Function(
    Pointer<Void> model, double sampleRate);
typedef _RecognizerFreeNative = Void Function(Pointer<Void> recognizer);
typedef _RecognizerFreeDart = void Function(Pointer<Void> recognizer);

typedef _AcceptWaveformNative = Int32 Function(
    Pointer<Void> recognizer, Pointer<Uint8> data, Int32 len);
typedef _AcceptWaveformDart = int Function(
    Pointer<Void> recognizer, Pointer<Uint8> data, int len);

typedef _ResultNative = Pointer<Utf8> Function(Pointer<Void> recognizer);
typedef _ResultDart = Pointer<Utf8> Function(Pointer<Void> recognizer);

typedef _SetLogLevelNative = Void Function(Int32 level);
typedef _SetLogLevelDart = void Function(int level);

final _modelNew = voskLib.lookupFunction<_ModelNewNative, _ModelNewDart>(
    'vosk_model_new');
final _modelFree = voskLib.lookupFunction<_ModelFreeNative, _ModelFreeDart>(
    'vosk_model_free');
final _recognizerNew =
    voskLib.lookupFunction<_RecognizerNewNative, _RecognizerNewDart>(
        'vosk_recognizer_new');
final _recognizerFree =
    voskLib.lookupFunction<_RecognizerFreeNative, _RecognizerFreeDart>(
        'vosk_recognizer_free');
final _acceptWaveform =
    voskLib.lookupFunction<_AcceptWaveformNative, _AcceptWaveformDart>(
        'vosk_recognizer_accept_waveform');
final _result = voskLib.lookupFunction<_ResultNative, _ResultDart>(
    'vosk_recognizer_result');
final _partial = voskLib.lookupFunction<_ResultNative, _ResultDart>(
    'vosk_recognizer_partial_result');
final _final = voskLib.lookupFunction<_ResultNative, _ResultDart>(
    'vosk_recognizer_final_result');
final _setLogLevel = voskLib.lookupFunction<_SetLogLevelNative, _SetLogLevelDart>(
    'vosk_set_log_level');

/// Quiet Vosk's stderr logging; call once at startup.
void voskQuiet() {
  try {
    _setLogLevel(-1);
  } catch (_) {}
}

/// Loads a Vosk model from [modelPath] (a directory). Returns an opaque handle
/// or null on failure. Caller owns the handle and must free it.
Pointer<Void>? voskModelNew(String modelPath) {
  final path = modelPath.toNativeUtf8();
  try {
    final model = _modelNew(path);
    return model == nullptr ? null : model;
  } finally {
    mallocFree(path);
  }
}

void voskModelFree(Pointer<Void> model) => _modelFree(model);

/// Creates a recognizer for [model] at [sampleRate] Hz. Returns an opaque
/// handle or null on failure. Caller owns the handle and must free it.
Pointer<Void>? voskRecognizerNew(Pointer<Void> model, double sampleRate) {
  final rec = _recognizerNew(model, sampleRate);
  return rec == nullptr ? null : rec;
}

void voskRecognizerFree(Pointer<Void> recognizer) => _recognizerFree(recognizer);

/// Feeds PCM16 mono audio to the recognizer. Returns 1 when a final result is
/// ready (use voskResult), 0 otherwise (use voskPartial).
int voskAcceptWaveform(Pointer<Void> recognizer, List<int> pcmBytes) {
  final data = _toNative(pcmBytes);
  try {
    return _acceptWaveform(recognizer, data, pcmBytes.length);
  } finally {
    _freeNative(data);
  }
}

String voskResult(Pointer<Void> recognizer) =>
    _readResult(_result(recognizer));

String voskPartial(Pointer<Void> recognizer) =>
    _readResult(_partial(recognizer));

String voskFinal(Pointer<Void> recognizer) =>
    _readResult(_final(recognizer));

String _readResult(Pointer<Utf8> ptr) {
  if (ptr == nullptr) return '{}';
  return ptr.toDartString();
}

Pointer<Uint8> _toNative(List<int> bytes) {
  final ptr = calloc<Uint8>(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    ptr[i] = bytes[i];
  }
  return ptr;
}

void _freeNative(Pointer<Uint8> ptr) => calloc.free(ptr);

// Small helpers so the native pointers are freed with the same allocator.
// (calloc from dart:ffi is used above; mallocFree below frees the Utf8.)
void mallocFree(Pointer<Utf8> ptr) => malloc.free(ptr);

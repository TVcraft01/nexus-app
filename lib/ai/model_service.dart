import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_downloader.dart';
import 'model_tiers.dart';

/// Where the downloaded model is in its lifecycle.
enum ModelState { none, downloading, ready, error }

/// Thrown when the user cancels an in-progress download.
class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
}

/// Holds the on-device LLM model: which tier is installed, downloading it with
/// progress, switching tiers, and deleting it. Extends [ChangeNotifier] so the
/// UI (first-run dialog, Settings card) rebuilds as the state changes.
class ModelService extends ChangeNotifier {
  static const _kState = 'ai_model_state';
  static const _kTier = 'ai_model_tier';
  static const _kPath = 'ai_model_path';
  static const _kSize = 'ai_model_size';
  static const _kDeclined = 'ai_model_declined';

  ModelState _state = ModelState.none;
  ModelTier? _tier;
  String? _modelPath;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  bool _declined = false;
  bool _cancelRequested = false;

  ModelState get state => _state;
  ModelTier? get tier => _tier;
  String? get modelPath => _modelPath;
  bool get isReady => _state == ModelState.ready;
  bool get isDownloading => _state == ModelState.downloading;
  bool get declined => _declined;
  double get downloadProgress =>
      _totalBytes == 0 ? 0 : (_downloadedBytes / _totalBytes).clamp(0.0, 1.0);
  int get totalBytes => _totalBytes;

  /// Loads persisted state. Call once at startup.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _declined = prefs.getBool(_kDeclined) ?? false;
    final tierId = prefs.getString(_kTier);
    _tier = ModelTier.all.where((t) => t.id == tierId).firstOrNull;
    _modelPath = prefs.getString(_kPath);
    final state = prefs.getString(_kState);
    _state = state == 'ready' && _modelPath != null && File(_modelPath!).existsSync()
        ? ModelState.ready
        : ModelState.none;
    if (_state == ModelState.ready) {
      _totalBytes = prefs.getInt(_kSize) ?? _tier?.sizeBytes ?? 0;
    }
    notifyListeners();
  }

  /// Measures the device (free RAM, cores, free disk) for the tier picker.
  Future<DeviceCapability> detectCapability() async {
    final supportDir = await getApplicationSupportDirectory();
    await supportDir.create(recursive: true);
    return DeviceCapability(
      freeRamBytes: await readFreeRamBytes(),
      cpuCores: Platform.numberOfProcessors,
      freeDiskBytes: freeDiskBytesFor(supportDir.path),
    );
  }

  /// Measures the device and picks the best tier, or null if nothing fits.
  Future<ModelTier?> recommendTier() async =>
      pickTierFor(await detectCapability());

  /// Cancels the in-progress download, if any.
  void cancelDownload() {
    _cancelRequested = true;
  }

  /// Downloads [tier]'s model into the app's private storage (no permission
  /// needed, survives as long as the app). Throws on failure.
  Future<void> download(ModelTier tier) async {
    final prefs = await SharedPreferences.getInstance();
    final supportDir = await getApplicationSupportDirectory();
    final modelsDir = Directory(p.join(supportDir.path, 'models'));
    await modelsDir.create(recursive: true);
    final target = File(p.join(modelsDir.path, '${tier.id}.gguf'));

    _state = ModelState.downloading;
    _tier = tier;
    _downloadedBytes = 0;
    _totalBytes = tier.sizeBytes;
    _cancelRequested = false;
    notifyListeners();

    try {
      if (target.existsSync()) {
        // A previous download may have been interrupted; start fresh.
        await target.delete();
      }
      await downloadToFile(
        tier.downloadUrl,
        target,
        onProgress: (received, total) {
          if (_cancelRequested) throw const ModelDownloadCancelled();
          _downloadedBytes = received;
          _totalBytes = total;
          notifyListeners();
        },
      );
      final actual = await target.length();
      if (actual < tier.sizeBytes) {
        throw Exception('Download incomplete: $actual of ${tier.sizeBytes}');
      }

      _state = ModelState.ready;
      _modelPath = target.path;
      _declined = false;
      await prefs.setString(_kState, 'ready');
      await prefs.setString(_kTier, tier.id);
      await prefs.setString(_kPath, target.path);
      await prefs.setInt(_kSize, actual);
      await prefs.setBool(_kDeclined, false);
      notifyListeners();
    } on ModelDownloadCancelled {
      _state = ModelState.none;
      _tier = null;
      if (target.existsSync()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      notifyListeners();
      rethrow;
    } catch (e) {
      _state = ModelState.error;
      if (target.existsSync()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      notifyListeners();
      rethrow;
    }
  }

  /// Removes the model file and reverts to command-mode (KeywordBrain).
  Future<void> deleteModel() async {
    final prefs = await SharedPreferences.getInstance();
    final path = _modelPath;
    if (path != null) {
      final f = File(path);
      if (f.existsSync()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    _state = ModelState.none;
    _tier = null;
    _modelPath = null;
    _downloadedBytes = 0;
    _totalBytes = 0;
    await prefs.remove(_kState);
    await prefs.remove(_kTier);
    await prefs.remove(_kPath);
    await prefs.remove(_kSize);
    notifyListeners();
  }

  /// Persists "the user chose not to download a model for now".
  Future<void> setDeclined(bool value) async {
    _declined = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDeclined, value);
    notifyListeners();
  }
}

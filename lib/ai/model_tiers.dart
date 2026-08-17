import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// One of the three model tiers Nexus can run.
///
/// All three are Qwen2.5-Instruct GGUF conversions (Apache-2.0) hosted on
/// Hugging Face by bartowski. They were chosen because they are genuinely
/// open-weight (no license gate, no API key) and are not "gated" repos, which
/// means the in-app downloader can fetch them without any login.
class ModelTier {
  final String id;
  final String name;
  final String description;
  final String downloadUrl;
  final int sizeBytes;
  final int minFreeRamBytes; // free memory required to run comfortably
  final int contextSize; // tokens of context the model is loaded with

  const ModelTier({
    required this.id,
    required this.name,
    required this.description,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.minFreeRamBytes,
    required this.contextSize,
  });

  static const compact = ModelTier(
    id: 'compact',
    name: 'Compact',
    description: 'Qwen2.5 1.5B, heavily quantized — runs on modest hardware',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf',
    sizeBytes: 986048768, // ~941 MB
    minFreeRamBytes: 3 * 1024 * 1024 * 1024, // 3 GB free RAM
    contextSize: 2048,
  );

  static const balanced = ModelTier(
    id: 'balanced',
    name: 'Balanced',
    description: 'Qwen2.5 3B, quantized — good quality, needs ~4 GB free RAM',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf',
    sizeBytes: 1929903264, // ~1.8 GB
    minFreeRamBytes: 4 * 1024 * 1024 * 1024, // 4 GB free RAM
    contextSize: 4096,
  );

  static const large = ModelTier(
    id: 'large',
    name: 'Large',
    description: 'Qwen2.5 7B, quantized — best quality, needs ~7 GB free RAM',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    sizeBytes: 4683074240, // ~4.4 GB
    minFreeRamBytes: 7 * 1024 * 1024 * 1024, // 7 GB free RAM
    contextSize: 8192,
  );

  static const all = [compact, balanced, large];

  /// The download must also fit on disk (leave 1.5x the model size free).
  int get minFreeDiskBytes => (sizeBytes * 1.5).round();

  /// Human-readable download size, e.g. "941 MB" / "1.8 GB".
  String get sizeLabel {
    if (sizeBytes >= 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / (1024 * 1024)).round()} MB';
  }
}

/// What we learned about the device when picking a model tier.
class DeviceCapability {
  final int freeRamBytes;
  final int cpuCores;
  final int freeDiskBytes; // free space in the app's own data directory

  const DeviceCapability({
    required this.freeRamBytes,
    required this.cpuCores,
    required this.freeDiskBytes,
  });

  String get freeRamLabel => _bytesToGb(freeRamBytes);
  String get freeDiskLabel => _bytesToGb(freeDiskBytes);
}

/// Reads the device's free memory from /proc/meminfo. Works on both Linux and
/// Android (the file is world-readable on both) with no platform channel.
Future<int> readFreeRamBytes() async {
  try {
    final lines = await File('/proc/meminfo').readAsLines();
    int? memAvailableKb;
    for (final line in lines) {
      if (line.startsWith('MemAvailable:')) {
        memAvailableKb = int.tryParse(line.split(RegExp(r'\s+'))[1]);
        break;
      }
    }
    if (memAvailableKb == null) {
      // Older kernels: fall back to MemFree + Cached.
      int? freeKb;
      int? cachedKb;
      for (final line in lines) {
        if (line.startsWith('MemFree:')) {
          freeKb = int.tryParse(line.split(RegExp(r'\s+'))[1]);
        } else if (line.startsWith('Cached:')) {
          cachedKb = int.tryParse(line.split(RegExp(r'\s+'))[1]);
        }
      }
      if (freeKb != null && cachedKb != null) {
        memAvailableKb = freeKb + cachedKb;
      }
    }
    if (memAvailableKb == null) return 0;
    return memAvailableKb * 1024;
  } catch (_) {
    return 0;
  }
}

/// Free disk space (in bytes) for [path] via statvfs(3). Uses dart:ffi so it
/// works identically on Linux and Android with no platform channel.
int freeDiskBytesFor(String path) {
  final libc = DynamicLibrary.process();
  final statvfs = libc.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<_StatVfs>),
      int Function(Pointer<Utf8>, Pointer<_StatVfs>)>('statvfs');
  final pathPtr = path.toNativeUtf8();
  final buf = calloc<_StatVfs>();
  try {
    final rc = statvfs(pathPtr, buf);
    if (rc != 0) return 0;
    final free = buf.ref.fFrsize * buf.ref.fBavail;
    return free > 0 ? free : 0;
  } finally {
    calloc.free(buf);
    malloc.free(pathPtr);
  }
}

/// Picks the best tier for this device. Returns null when even the smallest
/// model can't run (the app stays in command-mode KeywordBrain, which is the
/// guaranteed floor on any hardware).
ModelTier? pickTierFor(DeviceCapability cap) {
  for (final tier in ModelTier.all) {
    if (cap.freeRamBytes >= tier.minFreeRamBytes &&
        cap.freeDiskBytes >= tier.minFreeDiskBytes) {
      return tier;
    }
  }
  return null;
}

String _bytesToGb(int bytes) =>
    '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';

final class _StatVfs extends Struct {
  @Uint64()
  external int fBsize;
  @Uint64()
  external int fFrsize;
  @Uint64()
  external int fBlocks;
  @Uint64()
  external int fBfree;
  @Uint64()
  external int fBavail;
  // Remaining statvfs fields (files/inodes/flags) are not needed.
}

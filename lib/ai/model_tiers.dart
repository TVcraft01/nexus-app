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

  static const tiny = ModelTier(
    id: 'tiny',
    name: 'Tiny',
    description:
        'Qwen2.5 0.5B, Q4_K_M — fits Raspberry Pi and small ARM devices',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
    sizeBytes: 397808192, // ~379 MB (~0.4 GB)
    minFreeRamBytes: 768 * 1024 * 1024, // 768 MB free RAM (a 1 GB Pi fits)
    contextSize: 2048,
  );

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

  static const all = [tiny, compact, balanced, large];

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

/// Picks the best tier for this device: the LARGEST model it can actually
/// sustain, so more capable devices get a better assistant rather than the
/// minimum. Returns null when even the smallest model can't run (the app
/// stays in command-mode KeywordBrain, which is the guaranteed floor on any
/// hardware). The user can still override downward from Settings — this only
/// sets the default/first-run recommendation.
ModelTier? pickTierFor(DeviceCapability cap) {
  // Largest-first so a high-RAM device is offered Large, not Compact.
  for (final tier in ModelTier.all.reversed) {
    if (cap.freeRamBytes >= tier.minFreeRamBytes &&
        cap.freeDiskBytes >= tier.minFreeDiskBytes) {
      return tier;
    }
  }
  return null;
}

/// Rough prompt overhead in tokens (system instruction, template wrappers, and
/// the generation prompt) that must be reserved OUT of a tier's context window
/// before file content is budgeted. Generous on purpose — under-budgeting is
/// what caused the context-overflow hard failures.
const int kPromptOverheadTokens = 96;

/// Character budget for file content handed to a model loaded with
/// [contextSizeTokens] of context. Roughly 4 chars per token (fine as a safe
/// estimate; it does not need to be exact), minus template overhead, with a
/// floor so tiny contexts never round to nothing.
int contentCharBudget(int contextSizeTokens) {
  final usable = (contextSizeTokens - kPromptOverheadTokens).clamp(64, 1 << 30);
  return usable * 4;
}

/// Truncates [content] so it fits within [budget] characters. Returns the
/// (possibly unchanged) text and whether truncation actually happened — the
/// caller appends a visible note when it did, so a truncated-but-real summary
/// is produced instead of a context-overflow hard failure.
(String, bool) truncateContentToBudget(String content, int budget) {
  if (content.length <= budget) return (content, false);
  return (content.substring(0, budget), true);
}

/// Whether [freeRamBytes] currently meets [tier]'s memory requirement. This is
/// the exact check [LlmBrain.ensureLoaded] runs right before loading — exposed
/// here so /status and the task coordinator can report/skip a device that has
/// a model installed but can't actually load it right now. An unknown/zero
/// reading never blocks (some platforms can't read /proc/meminfo).
bool canLoadTierWithFreeRam(ModelTier tier, int freeRamBytes) =>
    freeRamBytes <= 0 || freeRamBytes >= tier.minFreeRamBytes;

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

  // statvfs(3) writes the FULL struct (112 bytes on glibc x86_64, 88 on
  // Android bionic) no matter how few fields we read. The buffer must be at
  // least as large as the platform's struct or the C call overflows the
  // allocation and corrupts the heap — observed as "free(): invalid next
  // size" when the app started on Linux. The unused tail is padding.
  @Array(128)
  // ignore: unused_field
  external Array<Uint8> _padding;
}

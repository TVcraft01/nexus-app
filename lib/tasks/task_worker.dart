import '../ai/llm_brain.dart';
import '../ai/model_service.dart';
import '../ai/model_tiers.dart';
import 'task_protocol.dart';

/// The local half of the batch-summarization task: reports whether this
/// device can act as a worker (a model is installed) and runs summarization
/// with the on-device LLM when it is.
///
/// A device in command-mode-only (no model) reports [isAvailable] as false and
/// is skipped by the coordinator — surfaced clearly in the UI, not silently.
class TaskWorker {
  final ModelService modelService;

  LlmBrain? _brain;
  String? _brainModelPath;

  TaskWorker({required this.modelService});

  /// True when a model is installed. This is a *capability* flag — the model
  /// is still loaded lazily on first use. See [canLoadNow] for whether it can
  /// actually be loaded right now (it may not, under memory pressure).
  bool get isAvailable => modelService.isReady && modelService.modelPath != null;

  /// True when a model is installed AND the device currently has enough free
  /// RAM to load it — the same free-RAM check [LlmBrain.ensureLoaded] runs
  /// before loading. Lets /status and the task coordinator skip a device up
  /// front instead of dispatching work that will fail and need redistributing.
  Future<bool> canLoadNow() async {
    if (!isAvailable) return false;
    final tier = modelService.tier;
    if (tier == null) return true;
    return canLoadTierWithFreeRam(tier, await readFreeRamBytes());
  }

  /// The installed tier id ('compact'/'balanced'/'large'), or null if none.
  String? get tierId => isAvailable ? modelService.tier?.id : null;

  LlmBrain _ensureBrain() {
    final path = modelService.modelPath;
    if (path == null) {
      throw StateError('No local model installed');
    }
    if (_brain == null || _brainModelPath != path) {
      _brain = LlmBrain(
        modelPath: path,
        contextSize: modelService.tier?.contextSize ?? 2048,
        minFreeRamBytes: modelService.tier?.minFreeRamBytes ?? 0,
      );
      _brainModelPath = path;
    }
    return _brain!;
  }

  /// Summarizes each item in order and returns one result per item.
  Future<List<TaskResult>> summarizeItems(List<TaskItem> items) async {
    final brain = _ensureBrain();
    final results = <TaskResult>[];
    for (final item in items) {
      final summary = await brain.summarizeText(item.content);
      results.add(TaskResult(name: item.name, summary: summary));
    }
    return results;
  }
}

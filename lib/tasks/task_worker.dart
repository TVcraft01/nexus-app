import '../ai/llm_brain.dart';
import '../ai/model_service.dart';
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

  /// True when a model is installed and could be loaded for the task. The
  /// model is still loaded lazily on first use; a load failure mid-task makes
  /// that item fail and get redistributed by the coordinator.
  bool get isAvailable => modelService.isReady && modelService.modelPath != null;

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

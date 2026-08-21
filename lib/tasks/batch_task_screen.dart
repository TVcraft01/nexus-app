import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/model_service.dart';
import '../ai/model_tiers.dart';
import '../models/paired_device.dart';
import 'task_coordinator.dart';
import 'task_protocol.dart';
import 'task_worker.dart';

/// How much of a file to read into memory for summarization. The cap is
/// derived from the SMALLEST participating worker's model context (a file must
/// fit every worker, since shares are rebalanced live), not a fixed size. When
/// no worker is known yet, the compact tier's budget is the safe floor — any
/// real worker can handle at least that much, and workers truncate
/// defensively in [LlmBrain.summarizeText] anyway.
int charCapForWorkers(List<WorkerInfo> workers) {
  final budgets = [
    for (final w in workers)
      if (w.tierId != null) contentCharBudget(_contextForTier(w.tierId!)),
  ];
  if (budgets.isEmpty) return contentCharBudget(ModelTier.compact.contextSize);
  return budgets.reduce(math.min);
}

int _contextForTier(String tierId) =>
    ModelTier.all.where((t) => t.id == tierId).firstOrNull?.contextSize ??
    ModelTier.compact.contextSize;

/// The "Batch task" screen: pick several text files, summarize them across
/// this device and any paired devices that have a local model, and combine the
/// results into one Markdown file.
class BatchTaskScreen extends StatefulWidget {
  final ModelService modelService;
  final List<PairedDevice> devices;

  const BatchTaskScreen({
    super.key,
    required this.modelService,
    required this.devices,
  });

  @override
  State<BatchTaskScreen> createState() => _BatchTaskScreenState();
}

class _BatchTaskScreenState extends State<BatchTaskScreen> {
  final List<TaskItem> _items = [];
  bool _running = false;
  bool _checking = false;
  Map<String, WorkerProgress> _progress = {};
  List<WorkerInfo> _workers = [];
  String? _resultMarkdown;
  String? _savedPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshWorkers();
  }

  Future<void> _refreshWorkers() async {
    setState(() => _checking = true);
    final coordinator = _coordinator();
    final workers = await coordinator.discoverWorkers();
    if (mounted) {
      setState(() {
        _workers = workers;
        _checking = false;
      });
    }
  }

  BatchSummaryCoordinator _coordinator() => BatchSummaryCoordinator(
        localWorker: TaskWorker(modelService: widget.modelService),
        pairedDevices: widget.devices,
      );

  Future<void> _pickFiles() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final cap = charCapForWorkers(_workers);
    final items = <TaskItem>[];
    for (final file in picked) {
      try {
        var content = await file.xFile.readAsString();
        if (content.length > cap) {
          content = content.substring(0, cap);
        }
        if (content.trim().isEmpty) continue;
        items.add(TaskItem(name: file.name, content: content));
      } catch (_) {
        // Skip files that can't be read as text (e.g. binary).
      }
    }
    if (mounted) setState(() => _items.addAll(items));
  }

  Future<void> _start() async {
    if (_items.isEmpty || _running) return;
    setState(() {
      _running = true;
      _error = null;
      _resultMarkdown = null;
      _savedPath = null;
      _progress = {};
    });

    final coordinator = _coordinator();
    try {
      final result = await coordinator.run(
        items: List.of(_items),
        onProgress: (progress) {
          if (mounted) setState(() => _progress = Map.of(progress));
        },
      );
      final markdown = result.toMarkdown(_items);
      final savedPath = await _saveResult(markdown);
      if (!mounted) return;
      setState(() {
        _resultMarkdown = markdown;
        _savedPath = savedPath;
        _running = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _running = false;
        });
      }
    }
  }

  Future<String?> _saveResult(String markdown) async {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      base = null;
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'Nexus'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'batch_summary.md'));
    await file.writeAsString(markdown);
    return file.path;
  }

  void _clear() {
    setState(() {
      _items.clear();
      _resultMarkdown = null;
      _savedPath = null;
      _error = null;
      _progress = {};
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch task'),
        actions: [
          if (_items.isNotEmpty && !_running)
            IconButton(
              icon: const Icon(Icons.clear_all),
              tooltip: 'Clear files',
              onPressed: _clear,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Pick several text files; Nexus splits them across your devices and '
            'each summarizes its share with its own local model.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.note_add),
            label: Text(_items.isEmpty
                ? 'Choose files'
                : 'Add more files (${_items.length} selected)'),
            onPressed: _running ? null : _pickFiles,
          ),
          const SizedBox(height: 16),
          _buildWorkersSection(),
          if (_items.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildFilesSection(),
          ],
          const SizedBox(height: 16),
          if (_items.isNotEmpty)
            FilledButton.icon(
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_running ? 'Running…' : 'Start'),
              onPressed: _running ? null : _start,
            ),
          if (_running) _buildProgressSection(),
          if (_error != null) _buildErrorSection(),
          if (_resultMarkdown != null) _buildResultSection(),
        ],
      ),
    );
  }

  /// Shows which devices will participate and calls out that command-mode-only
  /// devices are skipped (not silently excluded).
  Widget _buildWorkersSection() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices),
                const SizedBox(width: 8),
                Text('Workers', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_checking)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    onPressed: _refreshWorkers,
                    child: const Text('Refresh'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_workers.isEmpty)
              Text(
                'No device has a local model loaded. Download a model first '
                '(Settings → Local assistant) so there is at least one worker.',
                style: theme.textTheme.bodySmall,
              )
            else
              ..._workers.map(
                (w) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(w.isSelf ? Icons.home : Icons.smartphone),
                  title: Text(w.name),
                  subtitle: Text(
                    w.tierId == null
                        ? 'model tier unknown'
                        : '${_tierLabel(w.tierId!)} model',
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Devices in command-mode only (no model) are skipped.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilesSection() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Files (${_items.length})', style: theme.textTheme.titleMedium),
            Text(
              'Each file capped at ${charCapForWorkers(_workers)} characters '
              '(fits the smallest worker model\'s context).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            ..._items.map(
              (item) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description),
                title: Text(item.name),
                subtitle: Text('${item.content.length} characters'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Progress', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_progress.isEmpty)
                Text('Checking workers…', style: theme.textTheme.bodySmall)
              else
                ..._progress.values.map(
                  (w) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: w.failed
                        ? const Icon(Icons.error_outline, color: Colors.red)
                        : Icon(
                            w.done >= w.total && w.total > 0
                                ? Icons.check_circle
                                : Icons.hourglass_top,
                            color: w.done >= w.total && w.total > 0
                                ? Colors.green
                                : null,
                          ),
                    title: Text(w.name),
                    subtitle: Text(
                      w.failed
                          ? 'unreachable — share redistributed'
                          : '${w.done}/${w.total} files done',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorSection() {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
      ),
    );
  }

  Widget _buildResultSection() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                Text('Combined result', style: theme.textTheme.titleMedium),
              ],
            ),
            if (_savedPath != null) ...[
              const SizedBox(height: 4),
              Text(
                'Saved to $_savedPath',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _resultMarkdown!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tierLabel(String tierId) {
    switch (tierId) {
      case 'tiny':
        return 'Tiny';
      case 'balanced':
        return 'Balanced';
      case 'large':
        return 'Large';
      case 'compact':
      default:
        return 'Compact';
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/paired_device.dart';
import '../transfer/transfer_service.dart';
import 'split_plan.dart';
import 'task_crypto.dart';
import 'task_protocol.dart';
import 'task_worker.dart';

/// Per-worker progress for the live UI ("PC: 3/5 files done").
class WorkerProgress {
  final String name;
  int done = 0;
  int total = 0;
  bool failed = false;

  WorkerProgress(this.name);
}

/// A device that can act as a worker for the batch task (has a local model).
class WorkerInfo {
  final String id;
  final String name;
  final String? tierId;
  final double weight;
  final bool isSelf;
  final PairedDevice? device; // null when this is the local device

  const WorkerInfo({
    required this.id,
    required this.name,
    required this.tierId,
    required this.weight,
    required this.isSelf,
    this.device,
  });
}

/// The outcome of a batch-summarization run. [summaries] maps each item's
/// original index to its summary; [failedIndices] are items no worker managed
/// to complete.
class BatchSummaryResult {
  final Map<int, String> summaries;
  final List<int> failedIndices;

  const BatchSummaryResult({
    required this.summaries,
    required this.failedIndices,
  });

  bool get complete => failedIndices.isEmpty;

  /// Combines the summaries into one Markdown document, one section per input
  /// file, in the ORIGINAL file order (not completion order).
  String toMarkdown(List<TaskItem> items) {
    final b = StringBuffer('# Batch summary\n\n');
    for (var i = 0; i < items.length; i++) {
      b.writeln('## ${items[i].name}');
      b.writeln();
      final summary = summaries[i];
      b.writeln(summary ?? '_(no summary produced)_');
      b.writeln();
    }
    return b.toString().trimRight();
  }
}

class _RoundResult {
  final WorkerInfo worker;
  final List<int> itemIndices;
  final List<String> summaries;
  final bool success;
  const _RoundResult({
    required this.worker,
    required this.itemIndices,
    required this.summaries,
    required this.success,
  });
}

/// Splits a batch of files across this device and any paired devices that
/// currently have a local model, runs each share, and reassembles the results.
///
/// This device always participates as a worker when it has a model. The split
/// is weighted by tier; if a worker becomes unreachable or times out, its
/// unfinished share is redistributed to the remaining workers.
class BatchSummaryCoordinator {
  final TaskWorker localWorker;
  final List<PairedDevice> pairedDevices;

  BatchSummaryCoordinator({
    required this.localWorker,
    required this.pairedDevices,
  });

  /// How long a single remote share may take before it is treated as failed.
  /// Model load can be slow, so this scales with the share size.
  Duration timeoutFor(int itemCount) => Duration(seconds: 30 + 60 * itemCount);

  /// Asks each paired device whether it has a model it can load RIGHT NOW (and
  /// which tier). This device is included first when it qualifies. A device is
  /// skipped when it has no model, OR when it has one installed but currently
  /// lacks the free RAM to load it — reporting "installed" as "loadable" was
  /// what dispatched work to a RAM-starved phone and relied on failure /
  /// redistribution to recover. Redistribution stays as a safety net for
  /// genuine mid-task failures, not the primary exclusion mechanism.
  Future<List<WorkerInfo>> discoverWorkers() async {
    final workers = <WorkerInfo>[];
    if (localWorker.isAvailable && await localWorker.canLoadNow()) {
      workers.add(WorkerInfo(
        id: 'self',
        name: 'This device',
        tierId: localWorker.tierId,
        weight: tierWeight(localWorker.tierId),
        isSelf: true,
      ));
    }
    for (final device in pairedDevices) {
      final cap = await _queryStatus(device);
      if (cap != null && cap.llmAvailable) {
        workers.add(WorkerInfo(
          id: device.deviceId,
          name: device.deviceName,
          tierId: cap.tierId,
          weight: tierWeight(cap.tierId),
          isSelf: false,
          device: device,
        ));
      }
    }
    return workers;
  }

  Future<BatchSummaryResult> run({
    required List<TaskItem> items,
    void Function(Map<String, WorkerProgress> progress)? onProgress,
  }) async {
    if (items.isEmpty) {
      return const BatchSummaryResult(summaries: {}, failedIndices: []);
    }

    final workers = await discoverWorkers();
    final progress = <String, WorkerProgress>{
      for (final w in workers) w.id: WorkerProgress(w.name),
    };

    final summaries = <int, String>{};
    final remaining = {for (var i = 0; i < items.length; i++) i};
    final dead = <String>{};

    while (remaining.isNotEmpty) {
      final active = workers.where((w) => !dead.contains(w.id)).toList();
      if (active.isEmpty) break;

      final ordered = remaining.toList()..sort();
      final assignment = splitItemIndices(
        ordered.length,
        [for (final w in active) w.weight],
      );

      final rounds = await Future.wait([
        for (var pos = 0; pos < active.length; pos++)
          _runShare(
            active[pos],
            [for (final idx in assignment[pos] ?? const <int>[]) ordered[idx]],
            items,
            progress,
          ),
      ]);

      var madeProgress = false;
      for (final round in rounds) {
        final p = progress[round.worker.id]!;
        if (round.success) {
          for (var i = 0; i < round.itemIndices.length; i++) {
            summaries[round.itemIndices[i]] = round.summaries[i];
            remaining.remove(round.itemIndices[i]);
          }
          p.done += round.itemIndices.length;
          madeProgress = true;
        } else {
          // Redistribute this worker's share next round by dropping it.
          dead.add(round.worker.id);
          p.failed = true;
        }
      }
      onProgress?.call(progress);

      if (!madeProgress) break; // every active worker failed this round
    }

    return BatchSummaryResult(
      summaries: summaries,
      failedIndices: remaining.toList()..sort(),
    );
  }

  /// GET /status on a paired device; returns null when unreachable, wrong
  /// device, or not a valid Nexus peer.
  Future<({String name, String? tierId, bool llmAvailable})?> _queryStatus(
    PairedDevice device,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse(
        'http://${device.ipAddress}:${TransferService.receivePort}/status',
      ));
      final response =
          await request.close().timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['deviceId'] != device.deviceId) return null;
      return (
        name: json['deviceName'] as String? ?? device.deviceName,
        tierId: json['llmTier'] as String?,
        llmAvailable: json['llmAvailable'] == true,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Executes one worker's share, returning results on success or marking the
  /// worker dead on any failure/timeout.
  Future<_RoundResult> _runShare(
    WorkerInfo worker,
    List<int> itemIndices,
    List<TaskItem> items,
    Map<String, WorkerProgress> progress,
  ) async {
    final p = progress[worker.id]!;
    p.total += itemIndices.length;
    final share = [for (final i in itemIndices) items[i]];
    try {
      final results = worker.isSelf
          ? await localWorker.summarizeItems(share)
          : await _executeRemote(worker.device!, share);
      return _RoundResult(
        worker: worker,
        itemIndices: itemIndices,
        summaries: [for (final r in results) r.summary],
        success: true,
      );
    } catch (_) {
      return _RoundResult(
        worker: worker,
        itemIndices: itemIndices,
        summaries: const [],
        success: false,
      );
    }
  }

  /// POST /task with the share, AES-GCM encrypted with the shared transfer
  /// key, and decrypt the response.
  Future<List<TaskResult>> _executeRemote(
    PairedDevice device,
    List<TaskItem> items,
  ) async {
    final keyBytes = base64Decode(device.transferKey);
    final payload = utf8.encode(jsonEncode({
      'items': [for (final i in items) i.toJson()],
    }));
    final encrypted = await encryptTaskPayload(payload, keyBytes);
    final timeout = timeoutFor(items.length);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(Uri.parse(
        'http://${device.ipAddress}:${TransferService.receivePort}/task',
      ));
      request.headers.set('content-type', 'application/octet-stream');
      request.headers.set('x-nexus-key', device.authToken);
      request.add(encrypted);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('task rejected (${response.statusCode})');
      }
      final body =
          await response.expand((chunk) => chunk).toList().timeout(timeout);
      final plain = await decryptTaskPayload(body, keyBytes);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      return [
        for (final r in json['results'] as List)
          TaskResult.fromJson(r as Map<String, dynamic>),
      ];
    } finally {
      client.close(force: true);
    }
  }
}

import 'package:flutter/material.dart';

import 'model_service.dart';
import 'model_tiers.dart';

/// Asks the user which model tier to download. Returns null if they cancel.
/// [recommended] gets a "Recommended" badge.
Future<ModelTier?> pickModelTier(
  BuildContext context, {
  required ModelTier? recommended,
}) {
  return showDialog<ModelTier>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Choose a model'),
      children: [
        for (final tier in ModelTier.all)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, tier),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Row(
                children: [
                  Text(tier.name),
                  if (tier.id == recommended?.id) ...[
                    const SizedBox(width: 8),
                    const Chip(
                      label: Text('Recommended',
                          style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                '${tier.description}\nDownload ${tier.sizeLabel}, needs '
                '~${tier.minFreeRamBytes ~/ (1024 * 1024 * 1024)} GB free RAM',
              ),
              isThreeLine: true,
            ),
          ),
      ],
    ),
  );
}

/// Runs [ModelService.download] and shows a progress dialog with a Cancel
/// button. The dialog closes on its own once the download finishes (or fails).
/// Shows a confirmation snackbar on success and an error on failure.
Future<void> downloadModelWithProgress(
  BuildContext context,
  ModelService modelService,
  ModelTier tier,
) async {
  final future = modelService.download(tier);

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _DownloadProgressDialog(
      modelService: modelService,
      tier: tier,
      onCancel: () {
        modelService.cancelDownload();
        Navigator.pop(dialogContext);
      },
    ),
  );

  try {
    await future;
  } on ModelDownloadCancelled {
    return;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Model download failed. Check your connection and '
              'storage, then try again.'),
        ),
      );
    }
    return;
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${tier.name} model is ready.')),
    );
  }
}

/// Progress dialog that auto-dismisses when the model reaches the ready (or
/// error) state, so a finished download doesn't linger at 100% until the user
/// taps Cancel.
class _DownloadProgressDialog extends StatefulWidget {
  final ModelService modelService;
  final ModelTier tier;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.modelService,
    required this.tier,
    required this.onCancel,
  });

  @override
  State<_DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.modelService.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    widget.modelService.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (_closing) return;
    final state = widget.modelService.state;
    if (state == ModelState.ready || state == ModelState.error) {
      _closing = true;
      // Give the user a brief look at 100% (or the error) before closing.
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Downloading ${widget.tier.name} model'),
      content: ListenableBuilder(
        listenable: widget.modelService,
        builder: (context, _) {
          final progress = widget.modelService.downloadProgress;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 12),
              Text(
                '${(progress * 100).toStringAsFixed(0)}% of '
                '${widget.tier.sizeLabel}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

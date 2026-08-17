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
/// button. Shows a confirmation snackbar on success and an error on failure.
Future<void> downloadModelWithProgress(
  BuildContext context,
  ModelService modelService,
  ModelTier tier,
) async {
  final future = modelService.download(tier);

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text('Downloading ${tier.name} model'),
      content: ListenableBuilder(
        listenable: modelService,
        builder: (context, _) {
          final progress = modelService.downloadProgress;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 12),
              Text(
                '${(progress * 100).toStringAsFixed(0)}% of ${tier.sizeLabel}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            modelService.cancelDownload();
            Navigator.pop(dialogContext);
          },
          child: const Text('Cancel'),
        ),
      ],
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

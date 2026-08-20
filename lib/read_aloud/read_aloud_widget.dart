import 'package:flutter/material.dart';

import 'read_aloud_service.dart';

/// A floating action button that appears while Nexus is reading text aloud.
/// Tapping it stops the speech. Appears in the bottom-right corner.
class ReadAloudFab extends StatelessWidget {
  const ReadAloudFab({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ReadAloudService.instance.isSpeaking,
      builder: (context, speaking, _) {
        if (!speaking) return const SizedBox.shrink();
        return FloatingActionButton(
          onPressed: () => ReadAloudService.instance.stop(),
          backgroundColor: Theme.of(context).colorScheme.error,
          tooltip: 'Stop reading',
          child: const Icon(Icons.stop, color: Colors.white),
        );
      },
    );
  }
}

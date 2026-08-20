import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'math_notes_service.dart';

/// A floating overlay that displays the result of a detected math expression.
///
/// This widget is designed to be placed in an Overlay/Navigator so it can
/// float above other apps' content. It shows:
///  - The computed result ("= 20")
///  - A tap-to-copy button
///  - An insert button (if the field supports it)
///
/// The overlay auto-dismisses after a few seconds or when the user taps away.
class MathResultOverlay extends StatefulWidget {
  final MathOverlay overlay;

  const MathResultOverlay({super.key, required this.overlay});

  @override
  State<MathResultOverlay> createState() => _MathResultOverlayState();
}

class _MathResultOverlayState extends State<MathResultOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();

    // Auto-dismiss after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        _dismiss();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) {
      if (mounted) {
        MathNotesService.instance.dismiss();
      }
    });
  }

  void _copyResult() {
    Clipboard.setData(ClipboardData(text: widget.overlay.result));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${widget.overlay.result} to clipboard'),
        duration: const Duration(seconds: 1),
      ),
    );
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: _dismiss,
          child: Container(
            color: Colors.black26,
            child: Center(
              child: GestureDetector(
                onTap: () {}, // Prevent tap from propagating to background
                child: Container(
                  margin: const EdgeInsets.all(32),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Expression
                      Text(
                        '${widget.overlay.expression} =',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 4),
                      // Result (large and prominent)
                      Text(
                        widget.overlay.result,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 12),
                      // Action buttons
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _copyResult,
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _dismiss,
                            child: const Text('Dismiss'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the math result overlay on top of the current screen.
///
/// Call this from the app's top-level navigator or overlay. The overlay
/// is self-dismissing after 4 seconds or on tap.
void showMathOverlay(BuildContext context, MathOverlay overlay) {
  Overlay.of(context).insert(
    OverlayEntry(
      builder: (_) => MathResultOverlay(overlay: overlay),
    ),
  );
}

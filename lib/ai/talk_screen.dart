import 'package:flutter/material.dart';

import 'command_help_screen.dart';
import 'keyword_brain.dart';
import 'llm_brain.dart';
import 'model_service.dart';
import 'nexus_action_runner.dart';
import 'nexus_brain.dart';
import 'message_kind.dart';
import 'vosk_service.dart';
import '../models/paired_device.dart';

/// The "Talk to Nexus" entry point: type a command, or tap the mic and speak.
/// Nexus decides what it means with the local brain (the downloaded LLM when
/// one is installed, otherwise the offline keyword parser), performs the
/// action, and speaks the reply using the device's on-device text-to-speech.
class TalkScreen extends StatefulWidget {
  final ModelService modelService;
  final VoskService voskService;

  /// Supplies the paired-devices list, so a "notify on my phone" preference
  /// can resolve "my phone" to an actual device.
  final Future<List<PairedDevice>> Function() devicesProvider;

  const TalkScreen({
    super.key,
    required this.modelService,
    required this.voskService,
    required this.devicesProvider,
  });

  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

class _TalkScreenState extends State<TalkScreen> {
  late final NexusActionRunner _runner;
  final TextEditingController _controller = TextEditingController();
  final List<({bool fromUser, String text, NexusMessageKind? kind})>
      _messages = [];
  bool _busy = false;

  LlmBrain? _llmBrain;
  String? _llmBrainModelPath;

  @override
  void initState() {
    super.initState();
    _runner = NexusActionRunner(
      devicesProvider: widget.devicesProvider,
      confirmAction: _confirmAssistAction,
    );
  }

  /// Shows a confirmation dialog for assistApp actions. Returns true if the
  /// user approved, false if cancelled. This is the ONLY way to execute an
  /// assistApp action — it cannot be bypassed.
  Future<bool> _confirmAssistAction(AssistAppPlan plan) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.touch_app, size: 32),
        title: const Text('Confirm action'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plan.description, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 12),
            Text(
              'This will interact with another app on your device. '
              'Only approve if you trust this action.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Do it'),
          ),
        ],
      ),
    );
    return result == true;
  }

  NexusBrain get _brain {
    final model = widget.modelService;
    if (model.isReady && model.modelPath != null) {
      if (_llmBrain == null || _llmBrainModelPath != model.modelPath) {
        _llmBrain = LlmBrain(
          modelPath: model.modelPath!,
          contextSize: model.tier?.contextSize ?? 2048,
          minFreeRamBytes: model.tier?.minFreeRamBytes ?? 0,
        );
        _llmBrainModelPath = model.modelPath;
      }
      return _llmBrain!;
    }
    return KeywordBrain();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit([String? text]) async {
    final input = (text ?? _controller.text).trim();
    if (input.isEmpty || _busy) return;

    _controller.clear();
    setState(() {
      _messages.add((fromUser: true, text: input, kind: null));
      _busy = true;
    });

    // If Nexus just asked "Which device?", the reply is the answer to that
    // question — don't run it through the brain as a fresh command.
    final clarification = await _runner.answerClarification(input);
    late final String response;
    late final NexusMessageKind? kind;
    if (clarification != null) {
      response = clarification;
      kind = NexusMessageKind.action;
    } else {
      final action = await _brain.interpret(input);
      kind = messageKindFor(action);
      response = await _runner.run(action);
    }
    await _runner.speak(response);

    if (!mounted) return;
    setState(() {
      _messages.add((fromUser: false, text: response, kind: kind));
      _busy = false;
    });
  }

  Future<void> _toggleListening() async {
    final vosk = widget.voskService;
    if (vosk.listening.value) {
      await vosk.stopListening();
      return;
    }
    // If the speech model isn't downloaded yet, let the user know and show
    // progress while it fetches (~41 MB, once).
    if (!vosk.modelReady && vosk.downloadProgress.value < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Downloading the offline speech model (41 MB)…'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    await vosk.startListening(
      onPartial: (partial) {
        if (mounted) _controller.text = partial;
      },
      onResult: (result) {
        if (mounted) _submit(result);
      },
      onError: (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error)));
        }
      },
    );
  }

  /// A one-line status row that makes it unambiguous whether replies are
  /// coming from the local LLM or from the built-in keyword parser. When the
  /// model is installed but can't be loaded (e.g. not enough free memory), it
  /// says so explicitly rather than silently falling back.
  Widget _buildModeIndicator(ThemeData theme) {
    final model = widget.modelService;

    // No model installed -> the guaranteed command-mode floor.
    if (!model.isReady) {
      return _ModeBadge(
        icon: Icons.handyman_outlined,
        label: 'Command mode',
        detail: 'Built-in command parser (no local model)',
        color: theme.colorScheme.tertiary,
      );
    }

    _brain; // ensure the LlmBrain exists so its load state can be watched
    final llm = _llmBrain;
    if (llm == null) {
      return _ModeBadge(
        icon: Icons.handyman_outlined,
        label: 'Command mode',
        detail: 'Built-in command parser (no local model)',
        color: theme.colorScheme.tertiary,
      );
    }

    return ListenableBuilder(
      listenable: llm.status,
      builder: (context, _) {
        switch (llm.status.value) {
          case LlmStatus.ready:
            return _ModeBadge(
              icon: Icons.memory,
              label: 'LLM — ${model.tier?.name ?? 'local'} model',
              detail: 'Replies come from the on-device model',
              color: Colors.green.shade700,
            );
          case LlmStatus.insufficientMemory:
            return _ModeBadge(
              icon: Icons.speed,
              label: 'Command mode — low memory',
              detail: 'Not enough free RAM for the model; using the built-in '
                  'parser',
              color: Colors.orange.shade800,
            );
          case LlmStatus.loadFailed:
            return _ModeBadge(
              icon: Icons.error_outline,
              label: 'Command mode — model error',
              detail: 'The model failed to load; using the built-in parser',
              color: Colors.orange.shade800,
            );
          case LlmStatus.loading:
            return _ModeBadge(
              icon: Icons.hourglass_top,
              label: 'Loading model…',
              detail: 'The first command is loading the local model',
              color: theme.colorScheme.primary,
            );
          case LlmStatus.notLoaded:
            return _ModeBadge(
              icon: Icons.memory,
              label: 'Local model ready',
              detail: 'Loads on your first command',
              color: theme.colorScheme.primary,
            );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vosk = widget.voskService;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talk to Nexus'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'What can I say?',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CommandHelpScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Runs entirely on this device'),
                subtitle: Text(
                  'Type a command, or tap the mic and speak. '
                  'Nothing is sent to a server. Try "create a folder", '
                  '"open Wi-Fi settings", or "remind me to call Sam at 7 pm".',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
          _buildModeIndicator(theme),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'Type or speak a command below to get started.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final message = _messages[i];
                      final bubble = Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: const BoxConstraints(maxWidth: 320),
                        decoration: BoxDecoration(
                          color: message.fromUser
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(message.text),
                      );

                      if (message.fromUser || message.kind == null) {
                        return Align(
                          alignment: message.fromUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: bubble,
                        );
                      }

                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            bubble,
                            _KindLabel(kind: message.kind!),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: vosk.listening,
                    builder: (context, listening, _) {
                      return IconButton(
                        icon: Icon(
                          listening ? Icons.mic : Icons.mic_none,
                          color: listening ? theme.colorScheme.error : null,
                        ),
                        tooltip: listening ? 'Stop listening' : 'Voice input',
                        onPressed: _toggleListening,
                      );
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_busy,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _submit,
                      decoration: InputDecoration(
                        hintText: 'Type a command…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: ValueListenableBuilder<String>(
                          valueListenable: vosk.partialText,
                          builder: (context, partial, _) => partial.isEmpty
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Text(
                                    '…listening',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    tooltip: 'Send',
                    onPressed: _busy ? null : () => _submit(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact, single-row status badge for the Talk screen's brain mode.
class _ModeBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  final Color color;

  const _ModeBadge({
    required this.icon,
    required this.label,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tiny tag under an assistant bubble distinguishing an executed action from
/// a general conversational answer, so "done" vs "discussed" is never ambiguous.
class _KindLabel extends StatelessWidget {
  final NexusMessageKind kind;

  const _KindLabel({required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final IconData icon;
    final String label;
    final Color color;
    if (kind == NexusMessageKind.action) {
      icon = Icons.check_circle_outline;
      label = 'Action';
      color = theme.colorScheme.primary;
    } else {
      icon = Icons.psychology_outlined;
      label = 'General response';
      color = theme.colorScheme.tertiary;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'keyword_brain.dart';
import 'llm_brain.dart';
import 'model_service.dart';
import 'nexus_action_runner.dart';
import 'nexus_brain.dart';
import 'vosk_service.dart';

/// The "Talk to Nexus" entry point: type a command, or tap the mic and speak.
/// Nexus decides what it means with the local brain (the downloaded LLM when
/// one is installed, otherwise the offline keyword parser), performs the
/// action, and speaks the reply using the device's on-device text-to-speech.
class TalkScreen extends StatefulWidget {
  final ModelService modelService;
  final VoskService voskService;

  const TalkScreen({
    super.key,
    required this.modelService,
    required this.voskService,
  });

  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

class _TalkScreenState extends State<TalkScreen> {
  final NexusActionRunner _runner = NexusActionRunner();
  final TextEditingController _controller = TextEditingController();
  final List<({bool fromUser, String text})> _messages = [];
  bool _busy = false;

  LlmBrain? _llmBrain;
  String? _llmBrainModelPath;

  NexusBrain get _brain {
    final model = widget.modelService;
    if (model.isReady && model.modelPath != null) {
      if (_llmBrain == null || _llmBrainModelPath != model.modelPath) {
        _llmBrain = LlmBrain(
          modelPath: model.modelPath!,
          contextSize: model.tier?.contextSize ?? 2048,
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
      _messages.add((fromUser: true, text: input));
      _busy = true;
    });

    final action = await _brain.interpret(input);
    final response = await _runner.run(action);
    await _runner.speak(response);

    if (!mounted) return;
    setState(() {
      _messages.add((fromUser: false, text: response));
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vosk = widget.voskService;
    return Scaffold(
      appBar: AppBar(title: const Text('Talk to Nexus')),
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
                      return Align(
                        alignment: message.fromUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
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

import 'package:flutter/material.dart';

import 'keyword_brain.dart';
import 'nexus_action_runner.dart';
import 'nexus_brain.dart';

/// The "Talk to Nexus" entry point. Type a command, and Nexus decides what it
/// means using the offline keyword brain, performs the action, and speaks the
/// reply using the device's on-device text-to-speech engine.
class TalkScreen extends StatefulWidget {
  const TalkScreen({super.key});

  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

class _TalkScreenState extends State<TalkScreen> {
  final NexusBrain _brain = KeywordBrain();
  final _runner = NexusActionRunner();
  final _controller = TextEditingController();
  final _messages = <({bool fromUser, String text})>[];
  bool _busy = false;

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

  void _showVoiceNote() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Voice input needs an on-device speech engine. The common Android '
          'speech package sends your voice to Google, so Nexus keeps text '
          'input for now to stay 100% local. Type your command instead.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  'Try "create a folder", "open Wi-Fi settings", or '
                  '"remind me to call Sam at 7 pm". Nothing is sent to a '
                  'server.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'Type a command below to get started.',
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
                  IconButton(
                    icon: const Icon(Icons.mic_none),
                    tooltip: 'Voice input',
                    onPressed: _showVoiceNote,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_busy,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _submit,
                      decoration: const InputDecoration(
                        hintText: 'Type a command…',
                        border: OutlineInputBorder(),
                        isDense: true,
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

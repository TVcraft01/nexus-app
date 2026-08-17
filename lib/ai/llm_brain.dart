import 'dart:convert';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';

import 'keyword_brain.dart';
import 'nexus_brain.dart';

/// A [NexusBrain] that runs the downloaded local LLM (via llama.cpp bindings).
///
/// The model is asked to reply with a small JSON action that [NexusActionRunner]
/// already knows how to execute; commands we can't map cleanly fall through to
/// a plain spoken reply. If the model fails to load for any reason, [KeywordBrain]
/// (the guaranteed command-mode floor) takes over automatically.
class LlmBrain implements NexusBrain {
  final String modelPath;
  final int contextSize;
  final KeywordBrain _fallback = KeywordBrain();

  LlamaOpenAIClient? _client;
  bool _loadFailed = false;

  LlmBrain({required this.modelPath, required this.contextSize});

  /// Loads the model into the llama.cpp engine the first time it's used.
  /// Returns false if it couldn't be loaded (caller falls back to command mode).
  Future<bool> ensureLoaded() async {
    if (_client != null) return true;
    if (_loadFailed) return false;
    try {
      _client = LlamaOpenAIClient(
        models: {
          'local': LlamaModelConfig(modelPath: modelPath, contextSize: contextSize),
        },
      );
      // The engine loads the model lazily on the first request; do one trivial
      // warm-up so load failures surface here rather than mid-conversation.
      await _client!.chat.completions.create(
        model: 'local',
        messages: const [
          LlamaChatMessage(role: 'user', content: 'ping'),
        ],
        maxTokens: 1,
      );
      return true;
    } catch (_) {
      _loadFailed = true;
      _client = null;
      return false;
    }
  }

  @override
  Future<NexusAction> interpret(String input) async {
    if (!await ensureLoaded()) {
      return _fallback.interpret(input);
    }

    final system = 'You are Nexus, a private on-device assistant. '
        'Respond with ONLY one JSON object and nothing else, with this shape: '
        '{"command":"createFolder|openWifiSettings|setReminder|chat",'
        '"args":{},"reply":"short reply to the user (max 2 sentences)". '
        'Rules: for createFolder put the folder name in args.name. '
        'For setReminder put an ISO-8601 time in args.when and the thing to '
        'remember in args.message. For anything else use command "chat" and '
        'write your helpful answer in reply.';

    try {
      final completion = await _client!.chat.completions.create(
        model: 'local',
        messages: [
          LlamaChatMessage(role: 'system', content: system),
          LlamaChatMessage(role: 'user', content: input),
        ],
        maxTokens: 220,
        temperature: 0.2,
      );
      final raw = llamaContentToPlainText(
        completion.choices.first.message.content,
      );

      // Prefer the model's structured action when it produced one.
      final parsed = _parseAction(raw);
      if (parsed != null && parsed.command != NexusCommand.unknown) {
        return parsed;
      }

      // Safety net: small models sometimes miss the JSON instruction, so let
      // the keyword parser still catch a clear command ("create a folder").
      final keyword = await _fallback.interpret(input);
      if (keyword.command != NexusCommand.unknown) return keyword;

      // Otherwise answer conversationally with whatever the model said.
      return parsed ??
          NexusAction(
            command: NexusCommand.unknown,
            reply: _cleanReply(raw),
          );
    } catch (e) {
      // Model ran out of context or errored; degrade to command mode once.
      return _fallback.interpret(input);
    }
  }

  /// Tries to read a NexusAction out of the model's JSON reply.
  NexusAction? _parseAction(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw.substring(start, end + 1));
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final command = (decoded['command'] as String?)?.trim().toLowerCase();
    final args = (decoded['args'] as Map?)?.cast<String, dynamic>() ?? {};
    final reply = (decoded['reply'] as String?)?.trim() ?? '';

    switch (command) {
      case 'createfolder':
        return NexusAction(
          command: NexusCommand.createFolder,
          reply: reply.isEmpty ? 'Creating a folder.' : reply,
          args: {'name': (args['name'] as String?) ?? 'New Folder'},
        );
      case 'openwifisettings':
        return NexusAction(
          command: NexusCommand.openWifiSettings,
          reply: reply.isEmpty ? 'Opening Wi-Fi settings.' : reply,
        );
      case 'setreminder':
        final when = DateTime.tryParse((args['when'] as String?) ?? '');
        if (when == null) {
          return NexusAction(
            command: NexusCommand.setReminder,
            reply: 'When should I remind you? Try "remind me at 7 pm".',
            args: const {'needsTime': true},
          );
        }
        return NexusAction(
          command: NexusCommand.setReminder,
          reply: reply.isEmpty ? 'Reminder set.' : reply,
          args: {'when': when, 'message': (args['message'] as String?) ?? 'Reminder'},
        );
      default:
        return NexusAction(
          command: NexusCommand.unknown,
          reply: _cleanReply(reply.isEmpty ? raw : reply),
        );
    }
  }

  String _cleanReply(String raw) => raw.trim().replaceAll(RegExp(r'\s+'), ' ');
}

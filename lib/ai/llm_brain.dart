import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

import 'keyword_brain.dart';
import 'model_tiers.dart';
import 'nexus_brain.dart';

/// What stage the local LLM's loading is in. The Talk screen watches this so
/// it can show unambiguously whether a reply came from the LLM or from the
/// built-in keyword parser.
enum LlmStatus {
  /// Nothing has been attempted yet (the model is only loaded on first use).
  notLoaded,

  /// The model is being loaded into memory right now.
  loading,

  /// The model loaded successfully and is answering requests.
  ready,

  /// Loading was refused because the device no longer has enough free RAM.
  insufficientMemory,

  /// Loading was attempted but the native library/model failed.
  loadFailed,
}

/// A [NexusBrain] that runs the downloaded local LLM (via llama.cpp bindings).
///
/// The model is asked to reply with a small JSON action that [NexusActionRunner]
/// already knows how to execute; commands we can't map cleanly fall through to
/// a plain spoken reply. If the model can't be loaded — including when free
/// memory has dropped below what the tier needs since it was selected — this
/// falls back to [KeywordBrain] (the guaranteed command-mode floor) and reports
/// the reason through [status] so the UI can say so.
class LlmBrain implements NexusBrain {
  final String modelPath;
  final int contextSize;

  /// Free RAM (bytes) the selected tier needs. Re-checked right before loading
  /// so a stale tier selection or a low-memory moment refuses to load instead
  /// of risking an OOM kill or silent empty output.
  final int minFreeRamBytes;

  final KeywordBrain _fallback = KeywordBrain();

  /// Observable load state; the Talk screen shows command-mode vs. LLM mode
  /// from this.
  final ValueNotifier<LlmStatus> status = ValueNotifier(LlmStatus.notLoaded);

  LlamaOpenAIClient? _client;
  bool _loadFailed = false;

  LlmBrain({
    required this.modelPath,
    required this.contextSize,
    this.minFreeRamBytes = 0,
  });

  /// Loads the model into the llama.cpp engine the first time it's used.
  /// Returns false if it couldn't be loaded (caller falls back to command mode).
  Future<bool> ensureLoaded() async {
    if (_client != null) return true;
    if (_loadFailed) return false;

    status.value = LlmStatus.loading;

    // Re-check free RAM immediately before loading (not just at first-run tier
    // selection). The device may have less memory now than when the tier was
    // chosen, or the user may have overridden to a tier that doesn't fit.
    // Loading anyway risks a mid-load OOM kill (the process just dies) or
    // silent empty output.
    if (minFreeRamBytes > 0) {
      final freeRam = await readFreeRamBytes();
      if (freeRam > 0 && freeRam < minFreeRamBytes) {
        developer.log(
          'LlmBrain: refusing to load model — ${_gb(freeRam)} free RAM is '
          'below the ${_gb(minFreeRamBytes)} this tier needs.',
          name: 'nexus.ai',
        );
        _loadFailed = true;
        status.value = LlmStatus.insufficientMemory;
        return false;
      }
    }

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
      status.value = LlmStatus.ready;
      return true;
    } catch (e) {
      // A process-killing OOM can't be caught here (the OS ends us), but a
      // Dart-level failure from the native bindings can. Log it so the
      // command-mode fallback is attributable to a real failure.
      developer.log('LlmBrain: model load failed: $e', name: 'nexus.ai');
      _loadFailed = true;
      _client = null;
      status.value = LlmStatus.loadFailed;
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

      // Safety net: small models sometimes miss the JSON instruction (or
      // return empty output under memory pressure), so let the keyword parser
      // still catch a clear command ("create a folder"). Log it so an
      // empty-output failure is distinguishable from a clean LLM answer.
      final keyword = await _fallback.interpret(input);
      if (keyword.command != NexusCommand.unknown) {
        developer.log(
          'LlmBrain: model output was unusable (${raw.isEmpty ? "empty" : "not valid JSON"}); '
          'command "$input" handled by the keyword safety net.',
          name: 'nexus.ai',
        );
        return keyword;
      }

      // Otherwise answer conversationally with whatever the model said.
      return parsed ??
          NexusAction(
            command: NexusCommand.unknown,
            reply: _cleanReply(raw),
          );
    } catch (e) {
      // Model ran out of context or errored; degrade to command mode once.
      developer.log('LlmBrain: inference failed, using keyword fallback: $e',
          name: 'nexus.ai');
      return _fallback.interpret(input);
    }
  }

  /// Produces a short plain-text summary of [content] with the loaded model.
  /// Used by the distributed batch-summarization task. Throws if the model is
  /// unavailable, so a worker that can't summarize fails loudly (and the
  /// coordinator redistributes its share) instead of returning junk.
  Future<String> summarizeText(String content) async {
    if (!await ensureLoaded()) {
      throw StateError('Local model is not available on this device');
    }
    final completion = await _client!.chat.completions.create(
      model: 'local',
      messages: [
        const LlamaChatMessage(
          role: 'system',
          content: 'Summarize the following text in 2-4 sentences, capturing '
              'the key points. Reply with only the summary and no preamble.',
        ),
        LlamaChatMessage(role: 'user', content: content),
      ],
      maxTokens: 200,
      temperature: 0.3,
    );
    final raw = llamaContentToPlainText(
      completion.choices.first.message.content,
    );
    return _cleanReply(raw);
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

  static String _gb(int bytes) =>
      '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

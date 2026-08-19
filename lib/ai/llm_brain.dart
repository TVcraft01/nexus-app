import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

import 'action_registry.dart';
import 'keyword_brain.dart';
import 'model_tiers.dart';
import 'nexus_brain.dart';
import 'spoken_time.dart';

/// Visible marker appended to a summary whose input file had to be truncated
/// to fit the worker's model context. A truncated-but-real summary is better
/// than a hard context-overflow failure.
const String kTruncationNote = '[truncated — file exceeds model context]';

/// Formats a prompt the way the Qwen2.5 models are actually trained to see it
/// (the ChatML-style `<|im_start|>` format). All three Nexus tiers are Qwen2.5
/// GGUFs, and their vocabularies contain the `<|im_start|>`/`<|im_end|>`
/// tokens.
///
/// Why this exists: lib_llama_cpp 0.7.3 only runs the model's Jinja chat
/// template when the request forces "messages" generation (tools/media/etc.).
/// For a plain text chat it falls back to naive `"role: content"`
/// concatenation — which is why the model regurgitated input and past runs
/// showed a stray "system:" label. Sending the fully-formatted prompt as one
/// user message sidesteps that binding quirk entirely.
String qwenChatPrompt({String? system, required String user}) {
  final b = StringBuffer();
  if (system != null && system.isNotEmpty) {
    b.writeln('<|im_start|>system');
    b.writeln(system);
    b.writeln('<|im_end|>');
  }
  b.writeln('<|im_start|>user');
  b.writeln(user);
  b.writeln('<|im_end|>');
  b.write('<|im_start|>assistant');
  return b.toString();
}

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

    // Only offer commands the user hasn't turned off, so a disabled action
    // can't even be suggested by the model.
    final commandList = enabledActionTokens().join('|');
    final system = 'You are Nexus, a private on-device assistant. '
        'Respond with ONLY one JSON object and nothing else, with this shape: '
        '{"command":"$commandList",'
        '"args":{},"reply":"short reply to the user (max 2 sentences)". '
        'Rules: for createFolder put the folder name in args.name. '
        'For setReminder do NOT compute a date. Extract a RELATIVE time: for '
        '"in 3 minutes" put args.relative={"unit":"minutes","amount":3} (unit is '
        '"minutes" or "hours"); for "at 7pm" put args.absolute_time="19:00" '
        '(24-hour HH:MM). Put the thing to remember in args.message. '
        'For setPreference put args.key="notify_device" and args.deviceRef as one of '
        'phone, pc, laptop, computer, desktop, or tablet. '
        'For setAlarm put args.time="HH:MM" in 24-hour form (e.g. "07:00" for 7am). '
        'For setTimer put args.duration={"unit":"minutes"|"seconds"|"hours","amount":N}. '
        'For callContact put args.target with the name or number to call. '
        'For navigate put args.destination with the place to navigate to. '
        'For anything else use command "chat" and write your helpful answer in reply.';

    try {
      final completion = await _client!.chat.completions.create(
        model: 'local',
        // Send the fully-formatted ChatML prompt as ONE user message. The
        // binding only runs the Jinja template when it decides to generate
        // "messages"; for a plain text chat it naive-concatenates
        // "system: …" / "user: …" instead, which the Qwen2.5 model doesn't
        // parse as instructions (the "stray system: label" quirk).
        messages: [
          LlamaChatMessage(role: 'user', content: qwenChatPrompt(system: system, user: input)),
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
        if (!ActionRegistry.instance.isEnabled(parsed.command)) {
          return NexusAction(
            command: NexusCommand.unknown,
            reply: disabledActionReply(parsed.command),
          );
        }
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
  ///
  /// Oversized files are truncated to this tier's context budget (with a
  /// visible [kTruncationNote] appended) instead of throwing a
  /// context-overflow error that kills the whole item.
  Future<String> summarizeText(String content) async {
    if (!await ensureLoaded()) {
      throw StateError('Local model is not available on this device');
    }
    // Budget the file against THIS tier's context window, leaving room for the
    // prompt template (system instruction + ChatML wrappers). A truncated-but-
    // real summary beats a hard context-overflow failure.
    final budget = contentCharBudget(contextSize);
    final (clipped, truncated) = truncateContentToBudget(content, budget);
    final prompt = qwenChatPrompt(
      system: 'Summarize the following text in 2-4 sentences, capturing the '
          'key points. Reply with only the summary and no preamble.',
      user: clipped,
    );
    final completion = await _client!.chat.completions.create(
      model: 'local',
      // Single user message with the full ChatML prompt (same reasoning as
      // interpret(): the binding's plain-text path bypasses the template).
      messages: [LlamaChatMessage(role: 'user', content: prompt)],
      maxTokens: 200,
      temperature: 0.3,
    );
    final raw = llamaContentToPlainText(
      completion.choices.first.message.content,
    );
    var cleaned = _cleanReply(raw);
    if (truncated) {
      cleaned = '$kTruncationNote $cleaned';
    }
    return cleaned;
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
      case 'setreminder': {
        final message = (args['message'] as String?) ?? 'Reminder';
        final relative = args['relative'];
        DateTime? when;
        if (relative is Map) {
          final amount = int.tryParse('${relative['amount'] ?? ''}');
          final unit = (relative['unit'] as String?) ?? '';
          if (amount != null) {
            when = reminderTimeFromDuration(amount: amount, unit: unit);
          }
        } else if (args['absolute_time'] is String) {
          when = reminderTimeFromClockString(args['absolute_time'] as String);
        }
        // Safety: never schedule a moment that isn't in the future.
        if (when == null || !when.isAfter(DateTime.now())) {
          return NexusAction(
            command: NexusCommand.setReminder,
            reply: 'When should I remind you? Try "remind me at 7 pm".',
            args: const {'needsTime': true},
          );
        }
        return NexusAction(
          command: NexusCommand.setReminder,
          reply: reply.isEmpty ? 'Reminder set.' : reply,
          args: {'when': when, 'message': message},
        );
      }
      case 'setpreference':
        final deviceRef =
            (args['deviceRef'] as String?)?.trim().toLowerCase() ?? '';
        if (deviceRef.isEmpty) {
          return NexusAction(
            command: NexusCommand.unknown,
            reply: _cleanReply(reply.isEmpty ? raw : reply),
          );
        }
        return NexusAction(
          command: NexusCommand.setPreference,
          reply: reply.isEmpty ? 'Got it.' : reply,
          args: {
            'key': (args['key'] as String?) ?? 'notify_device',
            'deviceRef': deviceRef,
          },
        );
      case 'setalarm': {
        final time = parseClockTime((args['time'] as String?) ?? '');
        if (time == null) {
          return NexusAction(
            command: NexusCommand.setAlarm,
            reply: 'What time should I set the alarm for? Try '
                '"set an alarm for 7 am".',
            args: const {'needsTime': true},
          );
        }
        return NexusAction(
          command: NexusCommand.setAlarm,
          reply: reply.isEmpty ? 'Opening your Clock app…' : reply,
          args: {'hour': time.hour, 'minute': time.minute},
        );
      }
      case 'settimer': {
        final duration = args['duration'];
        var seconds = int.tryParse('${args['seconds'] ?? ''}');
        if (duration is Map && seconds == null) {
          final amount = int.tryParse('${duration['amount'] ?? ''}');
          final unit = (duration['unit'] as String?) ?? '';
          if (amount != null) {
            seconds = durationFromParts(amount: amount, unit: unit)?.inSeconds;
          }
        }
        if (seconds == null || seconds <= 0) {
          return NexusAction(
            command: NexusCommand.setTimer,
            reply: 'How long should I set the timer for? Try '
                '"set a timer for 10 minutes".',
            args: const {'needsTime': true},
          );
        }
        return NexusAction(
          command: NexusCommand.setTimer,
          reply: reply.isEmpty ? 'Opening your Clock app…' : reply,
          args: {'seconds': seconds},
        );
      }
      case 'playdeezerflow':
        return NexusAction(
          command: NexusCommand.playDeezerFlow,
          reply: reply.isEmpty ? 'Opening Deezer Flow…' : reply,
        );
      case 'callcontact': {
        final target = (args['target'] as String?)?.trim() ?? '';
        if (target.isEmpty) {
          return NexusAction(
            command: NexusCommand.callContact,
            reply: 'Who should I call? Say a name or a number — for example '
                '"call Sam".',
            args: const {'needsTarget': true},
          );
        }
        return NexusAction(
          command: NexusCommand.callContact,
          reply: reply.isEmpty ? 'Opening your dialer…' : reply,
          args: {'target': target},
        );
      }
      case 'openemail':
        return NexusAction(
          command: NexusCommand.openEmail,
          reply: reply.isEmpty ? 'Opening your email app…' : reply,
        );
      case 'navigate': {
        final destination = (args['destination'] as String?)?.trim() ?? '';
        if (destination.isEmpty) {
          return NexusAction(
            command: NexusCommand.navigate,
            reply: 'Where should I navigate to? Try "navigate to the nearest '
                'pharmacy".',
            args: const {'needsDestination': true},
          );
        }
        return NexusAction(
          command: NexusCommand.navigate,
          reply: reply.isEmpty ? 'Opening navigation…' : reply,
          args: {'destination': destination},
        );
      }
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

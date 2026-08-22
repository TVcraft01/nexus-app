import 'package:flutter/foundation.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

import '../ai/llm_brain.dart';
import '../ai/model_service.dart';
import 'brain_store.dart';

/// Watches conversations and automatically extracts knowledge into Brain
/// notes. The AI decides what's worth remembering — facts the user shared,
/// preferences learned, things it did for them, connections between topics.
///
/// This is the AI's memory system, not a user-facing note tool.
class AIBrainWriter {
  final BrainStore _store;
  final ModelService _modelService;
  LlamaOpenAIClient? _client;
  String? _clientModelPath;

  /// Recent conversation turns buffered for batch processing.
  final List<_Turn> _buffer = [];
  bool _processing = false;

  AIBrainWriter({
    required BrainStore store,
    required ModelService modelService,
  })  : _store = store,
        _modelService = modelService;

  bool get isAiAvailable =>
      _modelService.isReady && _modelService.modelPath != null;

  Future<bool> _ensureClient() async {
    // Invalidate stale client if model path changed.
    if (_client != null && _clientModelPath != _modelService.modelPath) {
      _client = null;
      _clientModelPath = null;
    }
    if (_client != null) return true;
    if (!isAiAvailable) return false;
    try {
      _client = LlamaOpenAIClient(
        models: {
          'local': LlamaModelConfig(
            modelPath: _modelService.modelPath!,
            contextSize: _modelService.tier?.contextSize ?? 2048,
          ),
        },
      );
      _clientModelPath = _modelService.modelPath;
      await _client!.chat.completions.create(
        model: 'local',
        messages: const [LlamaChatMessage(role: 'user', content: 'ping')],
        maxTokens: 1,
      );
      return true;
    } catch (_) {
      _client = null;
      return false;
    }
  }

  /// Call this after each user→assistant exchange. Buffers turns and
  /// periodically asks the LLM what's worth remembering.
  void recordTurn({
    required String userSaid,
    required String assistantReplied,
    String? actionTaken,
  }) {
    _buffer.add(_Turn(
      user: userSaid,
      assistant: assistantReplied,
      action: actionTaken,
      time: DateTime.now(),
    ));

    // Process every 3 turns or if the buffer is getting large.
    if (_buffer.length >= 3) {
      _processBuffer();
    }
  }

  /// Process all buffered turns and extract knowledge.
  Future<void> _processBuffer() async {
    if (_processing || _buffer.isEmpty || !isAiAvailable) return;
    _processing = true;

    final turns = List<_Turn>.from(_buffer);
    _buffer.clear();

    try {
      if (!await _ensureClient()) {
        _buffer.addAll(turns);
        _processing = false;
        return;
      }

      // Build a conversation transcript for the LLM to analyze.
      final transcript = turns.map((t) {
        final parts = ['User: ${t.user}', 'Assistant: ${t.assistant}'];
        if (t.action != null) parts.add('Action: ${t.action}');
        return parts.join('\n');
      }).join('\n\n');

      // Existing notes summary so the AI knows what's already stored.
      final existingNotes = _store.notes.take(20).map((n) {
        final preview = n.content.length > 100
            ? '${n.content.substring(0, 100)}…'
            : n.content;
        return '- ${n.title}: $preview';
      }).join('\n');

      final prompt = qwenChatPrompt(
        system: 'You are a memory system. Analyze this conversation and '
            'extract knowledge worth remembering. For each piece of '
            'knowledge, output a JSON object with:\n'
            '- "title": short descriptive title (max 5 words)\n'
            '- "content": 1-3 sentence summary of what was learned\n'
            '- "links": array of existing note titles this connects to (empty if none)\n\n'
            'Only extract genuinely useful facts, preferences, or context. '
            'Skip trivial acknowledgments, greetings, or one-off commands. '
            'If nothing is worth remembering, output an empty array [].\n\n'
            'Output ONLY a JSON array of objects, nothing else.',
        user: 'Existing notes:\n${existingNotes.isEmpty ? "(none yet)" : existingNotes}\n\n'
            'New conversation:\n$transcript',
      );

      final completion = await _client?.chat.completions.create(
        model: 'local',
        messages: [LlamaChatMessage(role: 'user', content: prompt)],
        maxTokens: 500,
        temperature: 0.2,
      );

      if (completion == null) {
        _buffer.addAll(turns);
        _processing = false;
        return;
      }

      final raw = llamaContentToPlainText(
        completion.choices.first.message.content,
      );

      final entries = _parseEntries(raw);
      for (final entry in entries) {
        // Check if a note with this title already exists — update it instead.
        final existing = _store.findByTitle(entry['title'] ?? '');
        if (existing != null) {
          // Append new info to existing note.
          final newContent = '${existing.content}\n\n${entry['content']}';
          await _store.updateNote(existing.id, content: newContent);
        } else {
          await _store.createNote(
            title: entry['title'] ?? 'Untitled',
            content: entry['content'] ?? '',
          );
        }
      }

      if (entries.isNotEmpty) {
        debugPrint('[AIBrainWriter] stored ${entries.length} new memories');
      }
    } catch (e) {
      debugPrint('[AIBrainWriter] error: $e');
      // Put unprocessed turns back in the buffer.
      _buffer.insertAll(0, turns);
    } finally {
      _processing = false;
    }
  }

  /// Parses the LLM's JSON output into a list of title/content/links maps.
  List<Map<String, String>> _parseEntries(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return [];

    try {
      final decoded = raw.substring(start, end + 1);
      final list = (decoded as dynamic) as List;
      return list.map<Map<String, String>>((e) {
        if (e is! Map) return {};
        return {
          'title': (e['title'] ?? '').toString(),
          'content': (e['content'] ?? '').toString(),
        };
      }).where((e) => e['title']!.isNotEmpty && e['content']!.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }
}

class _Turn {
  final String user;
  final String assistant;
  final String? action;
  final DateTime time;

  const _Turn({
    required this.user,
    required this.assistant,
    this.action,
    required this.time,
  });
}

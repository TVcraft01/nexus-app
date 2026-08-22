import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A single note in the brain: a markdown file with a title, tags, and
/// [[backlinks]] to other notes. Notes are stored as individual .md files
/// in the app's support directory under a `brain/` subfolder.
class BrainNote {
  final String id;
  final String title;
  final String content;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime modifiedAt;

  const BrainNote({
    required this.id,
    required this.title,
    required this.content,
    this.tags = const [],
    required this.createdAt,
    required this.modifiedAt,
  });

  /// Parses [[Note Title]] links from the markdown content.
  List<String> get outgoingLinks {
    final matches = RegExp(r'\[\[([^\]]+)\]\]').allMatches(content);
    return matches.map((m) => m.group(1)!).toSet().toList();
  }

  /// Serializes to a markdown file with YAML-like front matter.
  String toFileContent() {
    final buf = StringBuffer();
    buf.writeln('---');
    buf.writeln('id: $id');
    buf.writeln('title: $title');
    if (tags.isNotEmpty) buf.writeln('tags: [${tags.join(", ")}]');
    buf.writeln('created: ${createdAt.toIso8601String()}');
    buf.writeln('modified: ${modifiedAt.toIso8601String()}');
    buf.writeln('---');
    buf.writeln();
    buf.write(content);
    return buf.toString();
  }

  /// Parses a markdown file with optional YAML-like front matter.
  factory BrainNote.fromFileContent(String filePath, String raw) {
    final lines = raw.split('\n');
    String id = p.basenameWithoutExtension(filePath);
    String title = id.replaceAll('-', ' ');
    List<String> tags = [];
    DateTime created = DateTime.fromMillisecondsSinceEpoch(0);
    DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
    int contentStart = 0;

    // Parse front matter
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      for (int i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line == '---') {
          contentStart = i + 1;
          break;
        }
        if (line.startsWith('id:')) id = line.substring(3).trim();
        if (line.startsWith('title:')) title = line.substring(6).trim();
        if (line.startsWith('tags:')) {
          final tagStr = line.substring(5).trim();
          tags = tagStr
              .replaceAll('[', '')
              .replaceAll(']', '')
              .split(',')
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty)
              .toList();
        }
        if (line.startsWith('created:')) {
          created = DateTime.tryParse(line.substring(8).trim()) ?? created;
        }
        if (line.startsWith('modified:')) {
          modified = DateTime.tryParse(line.substring(9).trim()) ?? modified;
        }
      }
    }

    final content = lines.skip(contentStart).join('\n').trimLeft();

    // Fallback: derive title from first # heading if no front matter title
    if (title == id.replaceAll('-', ' ')) {
      final headingMatch = RegExp(r'^#\s+(.+)', multiLine: true).firstMatch(content);
      if (headingMatch != null) {
        title = headingMatch.group(1)!.trim();
      }
    }

    return BrainNote(
      id: id,
      title: title,
      content: content,
      tags: tags,
      createdAt: created,
      modifiedAt: modified,
    );
  }

  BrainNote copyWith({
    String? title,
    String? content,
    List<String>? tags,
    DateTime? modifiedAt,
  }) {
    return BrainNote(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      tags: tags ?? this.tags,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }
}

/// Manages the collection of brain notes as markdown files on disk.
/// Extends ChangeNotifier so the UI rebuilds as notes are created/edited.
class BrainStore extends ChangeNotifier {
  static final BrainStore instance = BrainStore();
  static const _folderName = 'brain';

  final List<BrainNote> _notes = [];

  bool _initialized = false;

  List<BrainNote> get notes => List.unmodifiable(_notes);

  /// Notes sorted by most recently modified.
  List<BrainNote> get notesByRecent =>
      List<BrainNote>.from(_notes)..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));

  /// Returns notes that link to [noteId] (incoming backlinks).
  List<BrainNote> backlinksFor(String noteId) {
    final note = _notes.where((n) => n.id == noteId).firstOrNull;
    if (note == null) return [];
    return _notes
        .where((n) => n.id != noteId && n.outgoingLinks.contains(note.title))
        .toList();
  }

  /// Initializes the brain store: reads all .md files from the brain folder.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final dir = await _brainDir();
    final files = dir.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.md'),
        );

    _notes.clear();
    for (final file in files) {
      try {
        final raw = await file.readAsString();
        _notes.add(BrainNote.fromFileContent(file.path, raw));
      } catch (_) {
        // Skip corrupt files.
      }
    }
    notifyListeners();
  }

  /// Creates a new note and persists it to disk.
  Future<BrainNote> createNote({
    required String title,
    String content = '',
    List<String> tags = const [],
  }) async {
    var id = _sanitizeId(title);
    // Deduplicate: if a note with this ID already exists, append a suffix.
    while (_notes.any((n) => n.id == id)) {
      id = '$id-${DateTime.now().millisecondsSinceEpoch}';
    }
    final now = DateTime.now();
    final note = BrainNote(
      id: id,
      title: title,
      content: content,
      tags: tags,
      createdAt: now,
      modifiedAt: now,
    );

    _notes.add(note);
    await _writeNote(note);
    notifyListeners();
    return note;
  }

  /// Updates an existing note's content and persists it to disk.
  Future<void> updateNote(String noteId, {String? content}) async {
    final index = _notes.indexWhere((n) => n.id == noteId);
    if (index == -1) return;

    final old = _notes[index];
    final updated = old.copyWith(content: content, modifiedAt: DateTime.now());
    _notes[index] = updated;
    await _writeNote(updated);
    notifyListeners();
  }

  /// Full-text search across note titles and content.
  List<BrainNote> search(String query) {
    if (query.trim().isEmpty) return notesByRecent;
    final lower = query.toLowerCase();
    return _notes.where((n) {
      return n.title.toLowerCase().contains(lower) ||
          n.content.toLowerCase().contains(lower) ||
          n.tags.any((t) => t.toLowerCase().contains(lower));
    }).toList();
  }

  /// Finds the note with the given [title] (case-insensitive).
  BrainNote? findByTitle(String title) {
    final lower = title.toLowerCase();
    return _notes.firstWhereOrNull(
      (n) => n.title.toLowerCase() == lower,
    );
  }

  Future<File> _noteFile(String id) async {
    final dir = await _brainDir();
    return File(p.join(dir.path, '$id.md'));
  }

  Future<void> _writeNote(BrainNote note) async {
    final file = await _noteFile(note.id);
    await file.writeAsString(note.toFileContent());
  }

  Future<Directory> _brainDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final brainDir = Directory(p.join(supportDir.path, _folderName));
    await brainDir.create(recursive: true);
    return brainDir;
  }

  String _sanitizeId(String title) {
    var id = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    // Fallback: if sanitization strips everything (emoji-only, whitespace,
    // etc.), use a timestamp-based ID so the file has a valid name.
    if (id.isEmpty) {
      id = 'note-${DateTime.now().millisecondsSinceEpoch}';
    }
    return id;
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

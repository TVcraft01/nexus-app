import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'vault_entry.dart';

/// Manages password vault entries stored in Android's hardware-backed Keystore
/// via flutter_secure_storage.
///
/// SECURITY INvariantS:
/// - All data is stored exclusively in flutter_secure_storage (never SharedPreferences,
///   plain files, or any other storage).
/// - Passwords are NEVER logged, printed, or included in any debug output.
/// - No cross-device sync — this is local-to-this-device only.
/// - The vault requires authentication before ANY access (enforced by AuthGate,
///   not here — this service trusts its callers to have verified auth).
class VaultService {
  static const _storage = FlutterSecureStorage();
  static const _vaultKey = 'nexus_vault_entries';

  static final VaultService instance = VaultService._();
  VaultService._();

  /// Internal cache of decoded entries (never exposed as a raw list).
  List<VaultEntry>? _cache;

  /// Load all entries from secure storage. Returns a copy of the list.
  Future<List<VaultEntry>> getAll() async {
    if (_cache != null) return List.unmodifiable(_cache!);
    await _loadFromStorage();
    return List.unmodifiable(_cache!);
  }

  /// Get a single entry by ID. Returns null if not found.
  Future<VaultEntry?> getById(String id) async {
    final entries = await getAll();
    try {
      return entries.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Add a new entry. Returns the created entry.
  Future<VaultEntry> add({
    required String name,
    required String username,
    required String password,
    String notes = '',
  }) async {
    final entry = VaultEntry.create(
      id: const Uuid().v4(),
      name: name,
      username: username,
      password: password,
      notes: notes,
    );
    _cache ??= [];
    _cache!.add(entry);
    await _saveToStorage();
    return entry;
  }

  /// Update an existing entry. Returns the updated entry, or null if not found.
  Future<VaultEntry?> update(
    String id, {
    String? name,
    String? username,
    String? password,
    String? notes,
  }) async {
    final entries = await getAll();
    final index = entries.indexWhere((e) => e.id == id);
    if (index == -1) return null;

    final updated = entries[index].copyWith(
      name: name,
      username: username,
      password: password,
      notes: notes,
    );
    _cache![index] = updated;
    await _saveToStorage();
    return updated;
  }

  /// Delete an entry by ID. Returns true if deleted, false if not found.
  Future<bool> delete(String id) async {
    final entries = await getAll();
    _cache!.removeWhere((e) => e.id == id);
    if (_cache!.length < entries.length) {
      await _saveToStorage();
      return true;
    }
    return false;
  }

  /// Search entries by name or username (case-insensitive).
  Future<List<VaultEntry>> search(String query) async {
    final entries = await getAll();
    if (query.isEmpty) return entries;
    final q = query.toLowerCase();
    return entries
        .where((e) =>
            e.name.toLowerCase().contains(q) ||
            e.username.toLowerCase().contains(q))
        .toList();
  }

  /// Clear the in-memory cache (e.g. on lock).
  void clearCache() {
    _cache = null;
  }

  // ---- Private helpers ----

  Future<void> _loadFromStorage() async {
    try {
      final data = await _storage.read(key: _vaultKey);
      if (data == null || data.isEmpty) {
        _cache = [];
        return;
      }
      final list = jsonDecode(data) as List;
      _cache = list.map((e) => VaultEntry.decode(e as String)).toList();
    } catch (e) {
      // If storage is corrupted, start fresh rather than crashing.
      // ignore: avoid_print
      print('[VaultService] Error loading vault: storage corrupted, starting fresh');
      _cache = [];
    }
  }

  Future<void> _saveToStorage() async {
    final entries = _cache ?? [];
    final encoded = entries.map((e) => e.encode()).toList();
    await _storage.write(key: _vaultKey, value: jsonEncode(encoded));
  }
}

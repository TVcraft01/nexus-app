import 'dart:convert';

/// A single vault entry: site/app credentials stored in secure storage.
///
/// All fields are serialized to JSON for storage. Passwords are NEVER logged,
/// printed, or included in crash reports — this model is only ever serialized
/// for secure storage, never for debug output.
class VaultEntry {
  final String id;
  final String name; // site or app name
  final String username;
  final String password;
  final String notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  const VaultEntry({
    required this.id,
    required this.name,
    required this.username,
    required this.password,
    this.notes = '',
    required this.createdAt,
    required this.updatedAt,
  });

  /// Create a new entry with generated timestamps.
  factory VaultEntry.create({
    required String id,
    required String name,
    required String username,
    required String password,
    String notes = '',
  }) {
    final now = DateTime.now().toUtc();
    return VaultEntry(
      id: id,
      name: name,
      username: username,
      password: password,
      notes: notes,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Deserialize from JSON stored in secure storage.
  factory VaultEntry.fromJson(Map<String, dynamic> json) {
    return VaultEntry(
      id: json['id'] as String,
      name: json['name'] as String,
      username: json['username'] as String,
      password: json['password'] as String,
      notes: json['notes'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  /// Serialize to JSON for secure storage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'username': username,
        'password': password,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// Encode to a JSON string for flutter_secure_storage.
  String encode() => jsonEncode(toJson());

  /// Decode from a JSON string stored in flutter_secure_storage.
  static VaultEntry decode(String data) {
    return VaultEntry.fromJson(jsonDecode(data) as Map<String, dynamic>);
  }

  /// Create a copy with updated fields.
  VaultEntry copyWith({
    String? name,
    String? username,
    String? password,
    String? notes,
  }) {
    return VaultEntry(
      id: id,
      name: name ?? this.name,
      username: username ?? this.username,
      password: password ?? this.password,
      notes: notes ?? this.notes,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// Never log the password — override toString to redact it.
  @override
  String toString() => 'VaultEntry(id: $id, name: $name, username: $username)';
}

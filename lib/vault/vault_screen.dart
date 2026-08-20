import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_gate.dart';
import 'password_generator.dart';
import 'vault_entry.dart';
import 'vault_service.dart';

/// Main vault screen: lists saved entries, supports search and add/edit/delete.
/// All access is gated by biometric/PIN authentication.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final VaultService _vault = VaultService.instance;
  final AuthGate _auth = AuthGate.instance;
  List<VaultEntry> _entries = [];
  String _searchQuery = '';
  bool _authenticated = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _auth.init();
    // Require authentication on every entry
    final ok = await _auth.authenticate(reason: 'Unlock your password vault');
    if (!mounted) return;
    if (!ok) {
      Navigator.of(context).pop();
      return;
    }
    _authenticated = true;
    await _loadEntries();
  }

  Future<void> _loadEntries() async {
    final entries = _searchQuery.isEmpty
        ? await _vault.getAll()
        : await _vault.search(_searchQuery);
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  Future<void> _onSearch(String query) async {
    setState(() {
      _searchQuery = query;
      _loading = true;
    });
    await _loadEntries();
  }

  Future<void> _addEntry() async {
    final result = await Navigator.of(context).push<VaultEntry>(
      MaterialPageRoute(builder: (_) => const _VaultEntryEditor()),
    );
    if (result != null) await _loadEntries();
  }

  Future<void> _editEntry(VaultEntry entry) async {
    final result = await Navigator.of(context).push<VaultEntry>(
      MaterialPageRoute(builder: (_) => _VaultEntryEditor(entry: entry)),
    );
    if (result != null) await _loadEntries();
  }

  Future<void> _deleteEntry(VaultEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete entry'),
        content: Text('Delete "${entry.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _vault.delete(entry.id);
      await _loadEntries();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_authenticated) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Password vault'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search entries…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: _onSearch,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? const Center(
                        child: Text(
                          'No saved entries yet.\nTap + to add one.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return _VaultEntryTile(
                            entry: entry,
                            onEdit: () => _editEntry(entry),
                            onDelete: () => _deleteEntry(entry),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addEntry,
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// A single vault entry tile with reveal/edit/delete actions.
class _VaultEntryTile extends StatefulWidget {
  final VaultEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _VaultEntryTile({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_VaultEntryTile> createState() => _VaultEntryTileState();
}

class _VaultEntryTileState extends State<_VaultEntryTile> {
  bool _revealed = false;

  Future<void> _toggleReveal() async {
    if (_revealed) {
      setState(() => _revealed = false);
      return;
    }
    // Require re-authentication to reveal password
    final ok = await AuthGate.instance.authenticate(
      reason: 'Verify identity to reveal password',
    );
    if (ok) {
      setState(() => _revealed = true);
      // Auto-hide after 30 seconds
      Future.delayed(const Duration(seconds: 30), () {
        if (mounted) setState(() => _revealed = false);
      });
    }
  }

  Future<void> _copyPassword() async {
    // Require re-authentication to copy password
    final ok = await AuthGate.instance.authenticate(
      reason: 'Verify identity to copy password',
    );
    if (!ok) return;
    await Clipboard.setData(ClipboardData(text: widget.entry.password));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    // Clear clipboard after 60 seconds for safety
    Future.delayed(const Duration(seconds: 60), () async {
      try {
        final data = await Clipboard.getData('text/plain');
        if (data?.text == widget.entry.password) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.lock_outline),
      title: Text(widget.entry.name),
      subtitle: Text(widget.entry.username),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
            tooltip: _revealed ? 'Hide password' : 'Reveal password',
            onPressed: _toggleReveal,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy password',
            onPressed: _copyPassword,
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit entry',
            onPressed: widget.onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete entry',
            onPressed: widget.onDelete,
          ),
        ],
      ),
      onTap: widget.onEdit,
    );
  }
}

/// Add/edit screen for a vault entry.
class _VaultEntryEditor extends StatefulWidget {
  final VaultEntry? entry;

  const _VaultEntryEditor({this.entry});

  @override
  State<_VaultEntryEditor> createState() => _VaultEntryEditorState();
}

class _VaultEntryEditorState extends State<_VaultEntryEditor> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _notesController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    if (widget.entry != null) {
      _nameController.text = widget.entry!.name;
      _usernameController.text = widget.entry!.username;
      _passwordController.text = widget.entry!.password;
      _notesController.text = widget.entry!.notes;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _generatePassword() {
    final password = PasswordGenerator.generate(
      length: 20,
      useUppercase: true,
      useLowercase: true,
      useDigits: true,
      useSymbols: true,
    );
    setState(() {
      _passwordController.text = password;
      _obscurePassword = false;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final vault = VaultService.instance;
    VaultEntry? result;

    if (widget.entry != null) {
      result = await vault.update(
        widget.entry!.id,
        name: _nameController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        notes: _notesController.text.trim(),
      );
    } else {
      result = await vault.add(
        name: _nameController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        notes: _notesController.text.trim(),
      );
    }

    if (mounted && result != null) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.entry != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit entry' : 'Add entry'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Site or app name',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Name is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username or email',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Username is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    IconButton(
                      icon: const Icon(Icons.casino_outlined),
                      tooltip: 'Generate password',
                      onPressed: _generatePassword,
                    ),
                  ],
                ),
              ),
              validator: (v) =>
                  v == null || v.isEmpty ? 'Password is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

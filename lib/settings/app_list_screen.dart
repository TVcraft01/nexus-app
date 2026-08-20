import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings_service.dart';

/// Represents an installed app with its metadata.
class InstalledApp {
  final String packageName;
  final String? name;
  final Uint8List? icon;

  const InstalledApp({
    required this.packageName,
    this.name,
    this.icon,
  });
}

/// Queries installed apps via a platform channel (Android only).
/// On other platforms, returns an empty list.
class InstalledAppsService {
  static const _channel = MethodChannel('com.example.nexus_app/installed_apps');

  static final InstalledAppsService instance = InstalledAppsService._();
  InstalledAppsService._();

  /// Returns all installed apps on the device, sorted by name.
  Future<List<InstalledApp>> getInstalledApps() async {
    if (!Platform.isAndroid) return [];
    try {
      final result = await _channel.invokeMethod<List>('getInstalledApps');
      if (result == null) return [];
      return result.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        return InstalledApp(
          packageName: map['packageName'] as String,
          name: map['name'] as String?,
          icon: map['icon'] as Uint8List?,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}

/// Curated list of clearly low-risk app categories for the "Quick-enable"
/// shortcut. Only apps that exist on the device get toggled — if a package
/// isn't installed, it's silently skipped.
const _quickEnablePackages = <String>{
  // Notes / text editors
  'com.google.android.keep',
  'com.samsung.android.app.notes',
  'com.microsoft.office.onenote',
  'com.dropbox.android',
  'com.zoho.notebook',
  // Calendar
  'com.google.android.calendar',
  'com.samsung.android.calendar',
  // Browser
  'com.android.chrome',
  'org.mozilla.firefox',
  'com.brave.browser',
  'com.opera.browser',
  'com.microsoft.emmx',
  // Maps (read-only assistance, no driving control)
  'com.google.android.apps.maps',
  // Calculator
  'com.google.android.calculator',
  'com.sec.android.app.popupcalculator',
};

/// Screen that lists installed apps with individual toggles for the per-app
/// assistApp allowlist. Every app starts OFF — the user must explicitly
/// approve each one.
class AppListScreen extends StatefulWidget {
  const AppListScreen({super.key});

  @override
  State<AppListScreen> createState() => _AppListScreenState();
}

class _AppListScreenState extends State<AppListScreen> {
  final SettingsService _settings = SettingsService();
  Set<String> _allowedApps = {};
  List<InstalledApp> _installedApps = [];
  bool _loading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final allowed = await _settings.getAllowedApps();
    final apps = await InstalledAppsService.instance.getInstalledApps();
    if (mounted) {
      setState(() {
        _allowedApps = allowed;
        _installedApps = apps;
        _loading = false;
      });
    }
  }

  Future<void> _toggleApp(String packageName, bool enabled) async {
    if (enabled) {
      await _settings.allowApp(packageName);
    } else {
      await _settings.disallowApp(packageName);
    }
    if (mounted) {
      setState(() {
        if (enabled) {
          _allowedApps.add(packageName);
        } else {
          _allowedApps.remove(packageName);
        }
      });
    }
  }

  Future<void> _quickEnable() async {
    var count = 0;
    for (final pkg in _quickEnablePackages) {
      if (!_allowedApps.contains(pkg) &&
          _installedApps.any((a) => a.packageName == pkg)) {
        await _settings.allowApp(pkg);
        _allowedApps.add(pkg);
        count++;
      }
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count > 0
                ? 'Enabled $count app${count == 1 ? '' : 's'}'
                : 'All common apps are already enabled',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _searchQuery.isEmpty
        ? _installedApps
        : _installedApps.where((app) {
            final q = _searchQuery.toLowerCase();
            return (app.name?.toLowerCase().contains(q) ?? false) ||
                app.packageName.toLowerCase().contains(q);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('App permissions'),
        actions: [
          TextButton(
            onPressed: _quickEnable,
            child: const Text('Quick-enable common apps'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    'Choose which apps Nexus may interact with. Every app is '
                    'blocked by default \u2014 toggle on only what you want Nexus '
                    'to help with.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search apps\u2026',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('No apps found'))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final app = filtered[index];
                            final isAllowed =
                                _allowedApps.contains(app.packageName);
                            return SwitchListTile(
                              secondary: app.icon != null
                                  ? Image.memory(
                                      app.icon!,
                                      width: 32,
                                      height: 32,
                                    )
                                  : const Icon(Icons.android),
                              title: Text(app.name ?? app.packageName),
                              subtitle: Text(
                                app.packageName,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              value: isAllowed,
                              onChanged: (v) =>
                                  _toggleApp(app.packageName, v),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

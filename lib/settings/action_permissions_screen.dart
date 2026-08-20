import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../accessibility/accessibility_service.dart';
import '../ai/action_registry.dart';
import '../ai/nexus_brain.dart';
import '../math_notes/math_notes_service.dart';
import 'app_list_screen.dart';
import 'settings_service.dart';

/// This app's applicationId (see android/app/build.gradle.kts). Used to deep
/// link to the app's page in the system settings, where permissions are
/// actually revocable.
const String _applicationId = 'com.example.nexus_app';

/// A system permission Nexus uses. Shown so the user can open this app's
/// system settings page and revoke it there — Android does not let an app
/// revoke its own permissions, so these are honest deep links rather than
/// pretend revocation.
class _AppPermission {
  final IconData icon;
  final String label;
  final String purpose;

  const _AppPermission({
    required this.icon,
    required this.label,
    required this.purpose,
  });
}

const List<_AppPermission> _appPermissions = [
  _AppPermission(
    icon: Icons.qr_code_scanner,
    label: 'Camera',
    purpose: 'Scanning pairing QR codes',
  ),
  _AppPermission(
    icon: Icons.mic_none,
    label: 'Microphone',
    purpose: 'Offline voice commands',
  ),
  _AppPermission(
    icon: Icons.contacts_outlined,
    label: 'Contacts',
    purpose: 'Resolving a spoken name to a phone number',
  ),
];

/// The "Actions & permissions" screen: one switch per action, plus honest
/// pointers to the system settings for the permissions the actions rely on.
class ActionPermissionsScreen extends StatelessWidget {
  const ActionPermissionsScreen({super.key});

  Future<void> _openAppSettings() async {
    const intent = AndroidIntent(
      action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
      data: 'package:$_applicationId',
    );
    try {
      await intent.launch();
    } catch (_) {
      // Best-effort: the toggle itself has already taken effect regardless.
    }
  }

  Future<void> _offerRevoke(
      BuildContext context, NexusActionDefinition def) async {
    final permission = (def.runtimePermission ?? '')
        .replaceAll('android.permission.', '')
        .replaceAll('_', ' ')
        .trim()
        .toLowerCase();
    if (!context.mounted) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('"${def.title}" turned off'),
        content: Text(
          'Nexus will no longer recognize "${def.examples.first}" until you '
          'turn it back on.\n\n'
          'Android doesn\'t let apps revoke their own permissions, so if you '
          'also want to remove ${permission.isEmpty ? 'the permission it uses' : '$permission access'}, '
          'you can do that in the system settings. This step is optional.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Done'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      await _openAppSettings();
    }
  }

  Future<void> _onToggle(
      BuildContext context, NexusActionDefinition def, bool value) async {
    await ActionRegistry.instance.setEnabled(def.command, value);
    if (!value && def.runtimePermission != null && Platform.isAndroid) {
      if (!context.mounted) return;
      await _offerRevoke(context, def);
    }
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Actions & permissions')),
      body: ListenableBuilder(
        listenable: ActionRegistry.instance,
        builder: (context, _) {
          final registry = ActionRegistry.instance;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Choose what Nexus is allowed to do. A turned-off action is '
                  'no longer recognized by command mode or the local model, '
                  'and disappears from "What can I say?".',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              for (final def in nexusActions)
                if (def.command != NexusCommand.assistApp)
                  SwitchListTile(
                    secondary: Icon(def.icon),
                    title: Text(def.title),
                    subtitle: Text(def.description),
                    value: registry.isEnabled(def.command),
                    onChanged: (v) => _onToggle(context, def, v),
                  ),
              const Divider(),
              _sectionHeader(context, 'Assist with other apps'),
              _buildAssistAppSection(context),
              const Divider(),
              _sectionHeader(context, 'Math notes'),
              _buildMathNotesSection(context),
              const Divider(),
              _sectionHeader(context, 'System permissions'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Nexus can\'t revoke its own permissions on Android. Each '
                  'entry opens this app\'s system settings page, where you '
                  'turn the permission off yourself.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final p in _appPermissions)
                ListTile(
                  leading: Icon(p.icon),
                  title: Text(p.label),
                  subtitle: Text(p.purpose),
                  trailing: Platform.isAndroid
                      ? TextButton(
                          onPressed: _openAppSettings,
                          child: const Text('Manage'),
                        )
                      : null,
                ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAssistAppSection(BuildContext context) {
    final settings = SettingsService();
    return _AssistAppToggle(settings: settings);
  }

  Widget _buildMathNotesSection(BuildContext context) {
    final settings = SettingsService();
    return _MathNotesToggle(settings: settings);
  }
}

/// Stateful widget for the "Assist with other apps" toggle that shows
/// both the Nexus-side toggle AND the OS-level accessibility service status.
class _AssistAppToggle extends StatefulWidget {
  final SettingsService settings;

  const _AssistAppToggle({required this.settings});

  @override
  State<_AssistAppToggle> createState() => _AssistAppToggleState();
}

class _AssistAppToggleState extends State<_AssistAppToggle> {
  bool? _nexusEnabled;
  bool _osEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
    AccessibilityService.instance.init();
    AccessibilityService.instance.serviceRunning.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    AccessibilityService.instance.serviceRunning.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) {
      setState(() {
        _osEnabled = AccessibilityService.instance.serviceRunning.value;
      });
    }
  }

  Future<void> _load() async {
    final enabled = await widget.settings.getAssistApp();
    final osEnabled = AccessibilityService.instance.serviceRunning.value;
    if (mounted) {
      setState(() {
        _nexusEnabled = enabled;
        _osEnabled = osEnabled;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_nexusEnabled == null) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.touch_app),
          title: const Text('Assist with other apps'),
          subtitle: const Text(
              'Let Nexus see and interact with other apps\' screens, '
              'one action at a time, to help with things it can\'t do through '
              'built-in commands. Requires a local model (LLM). Off by default.'),
          value: _nexusEnabled!,
          onChanged: (v) async {
            await widget.settings.setAssistApp(v);
            await ActionRegistry.instance.setEnabled(
              NexusCommand.assistApp,
              v,
            );
            if (mounted) setState(() => _nexusEnabled = v);
          },
        ),
        if (_nexusEnabled!)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _osEnabled ? Icons.check_circle : Icons.error_outline,
                      size: 16,
                      color: _osEnabled ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _osEnabled
                            ? 'System accessibility: enabled'
                            : 'System accessibility: NOT enabled',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _osEnabled ? Colors.green : Colors.orange,
                            ),
                      ),
                    ),
                  ],
                ),
                if (!_osEnabled) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Nexus can\'t read screens until you also enable the '
                    'accessibility service in Android Settings. Nexus can\'t '
                    'do this for you — Android requires you to flip the '
                    'toggle yourself.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => _openAccessibilitySettings(context),
                    child: const Text('Open accessibility settings'),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Screen content is processed entirely by the on-device '
                  'model and never leaves this device. Only one action is '
                  'performed per request, with your explicit confirmation '
                  'before every tap or type.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AppListScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.app_registration, size: 18),
                  label: const Text('Manage app permissions'),
                ),
                const SizedBox(height: 4),
                Text(
                  'Choose which specific apps Nexus is allowed to interact '
                  'with. Every app is blocked by default.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _openAccessibilitySettings(BuildContext context) async {
    await AccessibilityService.instance.openAccessibilitySettings();
    await AccessibilityService.instance.refreshStatus();
    if (mounted) {
      setState(() {
        _osEnabled = AccessibilityService.instance.serviceRunning.value;
      });
    }
  }
}

/// Toggle for the "Math notes" feature — watches typed text for arithmetic
/// and shows inline results. Separate from the assist-app toggle.
class _MathNotesToggle extends StatefulWidget {
  final SettingsService settings;
  const _MathNotesToggle({required this.settings});
  @override
  State<_MathNotesToggle> createState() => _MathNotesToggleState();
}

class _MathNotesToggleState extends State<_MathNotesToggle> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await widget.settings.getMathNotes();
    // Refresh the overlay-permission state (e.g. after the user returns from
    // the OS "Display over other apps" screen).
    await MathNotesService.instance.refreshOverlayPermission();
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _onToggle(bool v) async {
    await widget.settings.setMathNotes(v);
    await MathNotesService.instance.setEnabled(v);
    await MathNotesService.instance.refreshOverlayPermission();
    if (mounted) setState(() => _enabled = v);
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.calculate_outlined),
          title: const Text('Math notes'),
          subtitle: const Text(
              'When you type a simple arithmetic expression ending with = '
              '(like 12+8=), Nexus shows the result inline. Password fields '
              'and financial apps are always skipped. Off by default.'),
          value: _enabled!,
          onChanged: _onToggle,
        ),
        if (_enabled == true)
          ValueListenableBuilder<bool>(
            valueListenable: MathNotesService.instance.canDrawOverlays,
            builder: (context, canOverlay, _) {
              if (canOverlay) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(56, 0, 16, 12),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 16, color: Colors.green),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Results will appear as a floating overlay on top '
                          'of other apps.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_outlined,
                        size: 16, color: Colors.orange),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'To show results over other apps, Android needs you '
                        'to allow Nexus to display over other apps. Until '
                        'then, results appear as a notification-style toast '
                        'instead of an overlay.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await MathNotesService.instance.openOverlaySettings();
                      },
                      child: const Text('Allow overlay'),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

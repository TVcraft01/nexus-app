import 'dart:io';

import 'package:workmanager/workmanager.dart';

import 'maintenance_service.dart';

/// Unique name the periodic task is registered under (WorkManager replaces on
/// the same name, so a re-launch never stacks duplicate schedules).
const String kMaintenancePeriodicId = 'nexus-maintenance-periodic';

/// Value the callback dispatcher receives for the maintenance task.
const String kMaintenanceTaskName = 'nexusBackgroundMaintenance';

/// Entry point run by WorkManager in a SEPARATE background isolate (never on
/// the UI isolate). It must be top-level and annotated so the Dart VM can look
/// it up when the OS starts the worker without launching the app normally.
@pragma('vm:entry-point')
void maintenanceCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != kMaintenanceTaskName) return false;
    try {
      // A fresh isolate means fresh singletons; everything maintenance touches
      // is persisted to SharedPreferences / the file system, so the next
      // foreground launch sees the cleaned state.
      await MaintenanceService.instance.run();
      return true;
    } catch (_) {
      // Returning false lets WorkManager apply its backoff and retry later.
      return false;
    }
  });
}

/// Starts platform-appropriate maintenance scheduling. Safe to call on every
/// app launch.
///
/// Android: registers a periodic WorkManager task constrained to idle +
/// charging + battery-not-low. WorkManager (and Doze) decide the exact
/// moment; Nexus does not fight the OS, so a run may be deferred. The first
/// run can take up to a day and only happens when those constraints hold.
///
/// Linux/desktop: there is deliberately no background service. The honest
/// equivalent is an opportunistic check — maintenance runs right now if the
/// last run was more than ~24 hours ago, and not at all while the app is
/// closed.
Future<void> startMaintenanceScheduling() async {
  if (Platform.isAndroid) {
    await Workmanager().initialize(maintenanceCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      kMaintenancePeriodicId,
      kMaintenanceTaskName,
      frequency: MaintenanceService.opportunisticInterval,
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: true,
        requiresCharging: true,
        requiresDeviceIdle: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } else {
    // Linux / desktop: no background service — run now only if it's due.
    await MaintenanceService.instance.runIfDue();
  }
}

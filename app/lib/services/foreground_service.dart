import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Wrapper um flutter_foreground_task.
///
/// Auf Android: startet einen Foreground Service mit persistenter Benachrichtigung.
/// Verhindert, dass Android den App-Prozess nach einigen Minuten im Hintergrund
/// killt — kritisch für 5h-Aufnahmen mit eingeknopetem Telefon.
///
/// Auf iOS: No-op (iOS Background Modes in Info.plist übernehmen die Funktion).
///
/// ── Android-Setup-Schritte (einmalig) ────────────────────────────────────────
/// In android/app/src/main/AndroidManifest.xml hinzufügen:
///
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
///   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
///
///   <application ...>
///     <!-- Foreground Service für flutter_foreground_task -->
///     <service
///       android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
///       android:foregroundServiceType="connectedDevice|location"
///       android:stopWithTask="true"/>
///   </application>
///
/// In iOS/Info.plist für Background BLE:
///   <key>UIBackgroundModes</key>
///   <array>
///     <string>bluetooth-central</string>
///     <string>location</string>
///   </array>
/// ─────────────────────────────────────────────────────────────────────────────

/// Callback für den Foreground-Service-Task.
/// Muss Top-Level sein (kein Klassenmethod).
@pragma('vm:entry-point')
void startForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_SurfaceSensorTaskHandler());
}

class _SurfaceSensorTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Task läuft im selben Dart-Isolate wie die App.
    // Keine eigene Logik nötig – der Service existiert nur damit Android
    // den Prozess am Leben lässt.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Wird bei repeatInterval aufgerufen.
    // Optional: Benachrichtigung mit aktuellen Messwerten aktualisieren.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class ForegroundService {
  static bool _initialized = false;

  /// Foreground-Service initialisieren (einmalig beim App-Start aufrufen).
  static void init() {
    if (!Platform.isAndroid) return;
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId:          'surface_sensor_recording',
        channelName:        'Surface Sensor Aufnahme',
        channelDescription: 'Aktive Vibrations-Aufnahme',
        channelImportance:  NotificationChannelImportance.LOW,
        priority:           NotificationPriority.LOW,
        onlyAlertOnce:      true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification:    false,
        playSound:           false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction:     ForegroundTaskEventAction.repeat(60000), // 1×/min
        autoRunOnBoot:   false,
        allowWakeLock:   true,
        allowWifiLock:   true,
      ),
    );
  }

  /// Fordert Berechtigung für Benachrichtigungen an (Android 13+).
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final result = await FlutterForegroundTask.requestNotificationPermission();
    return result == NotificationPermission.granted;
  }

  /// Startet den Foreground Service (bei Aufnahme-Start aufrufen).
  static Future<void> start({
    required String title,
    required String text,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText:  text,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceId:         256,
          notificationTitle: title,
          notificationText:  text,
          callback:          startForegroundTaskCallback,
        );
      }
    } catch (e) {
      // Foreground-Service-Fehler sind nicht kritisch – Aufnahme läuft weiter,
      // aber Android könnte den Prozess im Hintergrund killen.
      // ignore: avoid_print
      print('[ForegroundService] Start fehlgeschlagen: $e');
    }
  }

  /// Stoppt den Foreground Service (bei Aufnahme-Ende aufrufen).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  /// Aktualisiert den Benachrichtigungstext (z.B. mit aktuellen RMS-Werten).
  static Future<void> update({required String title, required String text}) async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText:  text,
        );
      }
    } catch (_) {}
  }
}

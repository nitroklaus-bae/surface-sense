import 'dart:async';
import 'dart:io';
import 'package:geolocator/geolocator.dart';
import '../models/gps_sample.dart';

class GpsService {
  final _streamCtrl = StreamController<GpsSample>.broadcast();
  StreamSubscription<Position>? _posSub;
  bool _running = false;

  Stream<GpsSample> get stream => _streamCtrl.stream;
  bool get isRunning => _running;

  /// Prüft Berechtigungen und gibt true zurück wenn GPS verfügbar ist
  static Future<bool> checkPermission() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return false;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.whileInUse || perm == LocationPermission.always;
  }

  /// Plattformspezifische LocationSettings für zuverlässige 1-Hz-Updates.
  ///
  /// Android: FusedLocationProvider benötigt explizit [intervalDuration],
  /// sonst werden Updates gebatcht und kommen nur sporadisch (z. B. nur
  /// Start + Endpunkt). [foregroundNotificationConfig] hält den WakeLock
  /// und verhindert, dass Android den GPS-Job im Hintergrund drosselt.
  ///
  /// iOS: [pauseLocationUpdatesAutomatically] muss false sein, sonst pausiert
  /// CoreLocation bei gleichmäßiger Bewegung (Radfahren = "wenig Änderung").
  /// [activityType.fitness] schaltet den Fitness-Modus ein (optimiert für
  /// Fahrrad/Laufen) und verhindert Batching durch das OS.
  static LocationSettings _buildLocationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: 'GPS-Aufzeichnung läuft',
          notificationTitle: 'Surface Sensor',
          enableWakeLock: true,
        ),
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    }
    // Fallback (Desktop / Web)
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  /// GPS-Aufzeichnung starten.
  /// Gibt false zurück wenn GPS nicht verfügbar oder nicht berechtigt.
  Future<bool> start() async {
    if (_running) return true;
    if (!await checkPermission()) return false;

    _posSub = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    ).listen(
      (pos) {
        _streamCtrl.add(GpsSample(
          timestampMs: pos.timestamp.millisecondsSinceEpoch,
          latitude:  pos.latitude,
          longitude: pos.longitude,
          altitude:  pos.altitude,
          accuracy:  pos.accuracy,
          speed:     pos.speed >= 0 ? pos.speed : null,
        ));
      },
      onError: (_) {},
    );
    _running = true;
    return true;
  }

  Future<void> stop() async {
    await _posSub?.cancel();
    _posSub = null;
    _running = false;
  }

  void dispose() {
    _posSub?.cancel();
    _streamCtrl.close();
  }
}

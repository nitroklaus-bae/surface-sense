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

  /// Checks location services and asks for foreground location permission.
  static Future<bool> checkPermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return false;

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    return perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
  }

  /// Platform-specific settings for reliable 1 Hz ride recording.
  static LocationSettings _buildLocationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        // ForegroundNotificationConfig entfernt — flutter_foreground_task
        // verwaltet bereits den Android-Foreground-Service mit Notification.
        // Ein zweiter würde zu Konflikt/doppelter Notification führen.
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

    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  /// Starts GPS recording.
  /// Returns false when location services or permissions are unavailable.
  Future<bool> start() async {
    if (_running) return true;
    if (!await checkPermission()) return false;

    _posSub = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    ).listen(
      (pos) {
        _streamCtrl.add(GpsSample(
          timestampMs: pos.timestamp.millisecondsSinceEpoch,
          latitude: pos.latitude,
          longitude: pos.longitude,
          altitude: pos.altitude,
          accuracy: pos.accuracy,
          speed: pos.speed >= 0 ? pos.speed : null,
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

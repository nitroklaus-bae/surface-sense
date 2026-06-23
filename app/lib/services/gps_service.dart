import 'dart:async';
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

  /// GPS-Aufzeichnung starten.
  /// Gibt false zurück wenn GPS nicht verfügbar oder nicht berechtigt.
  Future<bool> start() async {
    if (_running) return true;
    if (!await checkPermission()) return false;

    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,         // alle Positionen
        // timeLimit: Duration(seconds: 1),  // zu eng für manche Geräte
      ),
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

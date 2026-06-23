import 'dart:async';
import 'dart:math' show sqrt, pow;
import 'package:sensors_plus/sensors_plus.dart';
import '../models/sensor_sample.dart';
import '../models/surface_sample.dart';

/// Handy-IMU als Drop-In-Ersatz für den BLE-Sensor.
///
/// Liefert dieselben Streams wie BleService ([sampleStream], [surfaceStream]),
/// sodass RecordingProvider ohne Änderungen im Test-Modus funktioniert.
///
/// Datenpipeline:
///   accelerometerEventStream (sensors_plus, ~50 Hz)
///   → m/s² ÷ 9.80665 → g
///   → SensorSample (timestampMs, ax, ay, az)
///   → 1-Hz-Fenster: RMS / VDV / Peak accumulation
///   → SurfaceSample (identisches Format zur Firmware)
///
/// Achsen des Handy-IMU (Android, Gerät hochkant):
///   +X = rechts, +Y = oben, +Z = aus dem Display heraus
///   → Vertikal-Achse = +Y (≈ +1g bei aufrechtem Gerät)
///   → RMS/VDV werden aus der Y-Komponente (minus 1g Schwerkraft) berechnet
///
/// Hinweis: Die Samplerate des Handy-IMU ist gerätespezifisch (typisch 50–200 Hz).
/// Im Test-Modus wird die angezeigte Frequenz auf den tatsächlich gemessenen
/// Wert aktualisiert (ca. 1× pro Sekunde).
class PhoneSensorService {
  static const _g = 9.80665; // m/s² pro g

  final _sampleCtrl  = StreamController<SensorSample>.broadcast();
  final _surfaceCtrl = StreamController<SurfaceSample>.broadcast();
  final _rateCtrl    = StreamController<int>.broadcast();

  Stream<SensorSample>  get sampleStream  => _sampleCtrl.stream;
  Stream<SurfaceSample> get surfaceStream => _surfaceCtrl.stream;
  /// Aktuell gemessene Samplerate des Handy-IMU in Hz.
  Stream<int>           get rateStream    => _rateCtrl.stream;

  StreamSubscription? _accelSub;
  Timer?              _windowTimer;

  // 1-Hz-Akku für Surface-Kennwerte
  double _sumAz2    = 0; // Σ(az_dyn²) für RMS
  double _sumAz4    = 0; // Σ(az_dyn⁴) für VDV
  double _peakAz    = 0; // max |az_dyn|
  int    _winCount  = 0; // Samples in diesem Fenster
  int    _winStart  = 0; // Fensterbeginn in ms

  bool _running = false;

  // ── Public API ──────────────────────────────────────────────────────────────

  void start() {
    if (_running) return;
    _running = true;
    _resetAccum();
    _winStart = DateTime.now().millisecondsSinceEpoch;

    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval, // ~50 Hz
    ).listen(_onAccel, onError: (_) {});

    // 1-Hz-Fenster-Timer
    _windowTimer = Timer.periodic(const Duration(seconds: 1), (_) => _emitSurface());
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _accelSub?.cancel();
    _windowTimer?.cancel();
    _accelSub    = null;
    _windowTimer = null;
    _resetAccum();
  }

  void dispose() {
    stop();
    _sampleCtrl.close();
    _surfaceCtrl.close();
    _rateCtrl.close();
  }

  // ── Interne Logik ───────────────────────────────────────────────────────────

  void _onAccel(AccelerometerEvent e) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ax = e.x / _g;
    final ay = e.y / _g;
    final az = e.z / _g;

    if (!_sampleCtrl.isClosed) {
      _sampleCtrl.add(SensorSample(timestampMs: ts, ax: ax, ay: ay, az: az));
    }

    // Vertikal-Achse des hochkant gehaltenen Handys = +Y (≈ +1g)
    // Dynamischer Anteil = ay - 1.0 (Schwerkraft subtrahiert)
    final ayDyn = ay - 1.0;
    _sumAz2  += ayDyn * ayDyn;
    _sumAz4  += ayDyn * ayDyn * ayDyn * ayDyn;
    if (ayDyn.abs() > _peakAz) _peakAz = ayDyn.abs();
    _winCount++;
  }

  void _emitSurface() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final n   = _winCount;

    if (n < 5) {
      _resetAccum();
      _winStart = now;
      return;
    }

    // Samplerate aus tatsächlicher Fensterbreite schätzen
    final windowSec = (now - _winStart) / 1000.0;
    final rate      = (n / windowSec).round().clamp(1, 4000);
    if (!_rateCtrl.isClosed) _rateCtrl.add(rate);

    // RMS = sqrt(Σaz² / N)
    final rms = sqrt(_sumAz2 / n);

    // VDV = (Σaz⁴ × Δt)^0.25  mit Δt = windowSec/N = 1/rate
    final vdv = pow(_sumAz4 / rate, 0.25).toDouble();

    if (!_surfaceCtrl.isClosed) {
      _surfaceCtrl.add(SurfaceSample(
        timestampMs: now,
        rmsG:  rms,
        vdvG:  vdv,
        peakG: _peakAz,
      ));
    }

    _resetAccum();
    _winStart = now;
  }

  void _resetAccum() {
    _sumAz2   = 0;
    _sumAz4   = 0;
    _peakAz   = 0;
    _winCount = 0;
  }
}

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' show sqrt;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/gps_sample.dart';
import '../models/orientation_calibration.dart';
import '../models/sensor_sample.dart';
import '../models/surface_sample.dart';
import '../services/ble_service.dart';
import '../services/gps_service.dart';
import '../services/fit_writer.dart';
import '../services/foreground_service.dart';
import '../services/phone_sensor_service.dart';
import '../services/relay_service.dart';
import '../services/supabase_service.dart';
import '../utils/signal_analysis.dart';
export '../services/relay_service.dart' show RelayService, RelayState;
export '../services/ble_service.dart' show CalibrationResult, CalStatus, BleState;
export '../models/orientation_calibration.dart'
    show OrientationCalibration, OrientCalStatus, ForwardAxis, BikeFrameCalibration;

// ── Ringpuffer-Dimensionierung ────────────────────────────────────────────────
// 100 000 Roh-Samples ≈ 60 s bei 1666 Hz, ~16 min bei 104 Hz, ~6 MB RAM.
// Surface- und GPS-Samples (je 1×/s) werden vollständig für 5 h gespeichert.
const int _kRawBufferMax = 100000;

// ── FIT-Export im Hintergrund-Isolate ────────────────────────────────────────
// Verhindert UI-Freeze bei 18 000 GPS × 18 000 Surface-Einträgen.
class _FitIsolateParams {
  final String path;
  final List<GpsSample>     gpsSamples;
  final List<SurfaceSample> surfaceSamples;
  final int sessionStart;
  final int sessionEnd;
  const _FitIsolateParams({
    required this.path,
    required this.gpsSamples,
    required this.surfaceSamples,
    required this.sessionStart,
    required this.sessionEnd,
  });
}

// Top-Level-Funktion erforderlich für compute()
Future<void> _fitIsolateEntry(_FitIsolateParams p) => FitWriter.write(
  path:           p.path,
  gpsSamples:     p.gpsSamples,
  surfaceSamples: p.surfaceSamples,
  sessionStart:   p.sessionStart,
  sessionEnd:     p.sessionEnd,
);

// ── Montagepunkte ─────────────────────────────────────────────────────────────
const kMountPoints = ['Lenker', 'Sattelstütze', 'Gabel', 'Rahmen'];

class RecordingProvider extends ChangeNotifier {
  final BleService _ble;
  final GpsService _gps = GpsService();

  RecordingProvider(this._ble) {
    _sampleSub  = _ble.sampleStream.listen(_onSample);
    _surfaceSub = _ble.surfaceStream.listen(_onSurface);
    _stateSub   = _ble.stateStream.listen((s) {
      _bleState = s;
      if (s == BleState.disconnected) {
        _isRecording   = false;
        _isCalibrating = false;
        // CSV sichern falls Aufnahme durch Verbindungsverlust unterbrochen
        _closeCsvSink();
      }
      notifyListeners();
    });
    _errorSub = _ble.errorStream.listen((e) { _lastError = e; notifyListeners(); });
    _calSub   = _ble.calibrationStream.listen((r) {
      _lastCalibration = r;
      _isCalibrating   = r.status == CalStatus.inProgress;
      notifyListeners();
    });
    _orientCalSub = _ble.orientationCalStream.listen((r) {
      _lastOrientCal       = r;
      _isOrientCalibrating = r.status == OrientCalStatus.inProgress;
      notifyListeners();
    });
    _tempSub = _ble.temperatureStream.listen((_) => notifyListeners());
    _gpsSub = _gps.stream.listen(_onGps);
  }

  // ── State ────────────────────────────────────────────────────────────────────
  BleState _bleState    = BleState.disconnected;
  bool     _isRecording = false;
  int      _frequencyHz = 104;
  int      _fsIndex     = 1;
  String   _mountPoint  = kMountPoints[0];

  // Roh-Samples: Ringpuffer
  final _sampleQueue = ListQueue<SensorSample>(_kRawBufferMax);
  int _totalSamplesReceived = 0;

  // GPS + Oberfläche: vollständige Aufnahme
  final List<GpsSample>     _gpsSamples     = [];
  final List<SurfaceSample> _surfaceSamples = [];

  // Timestamp-Rekonstruktion: erster millis()-Wert der Surface-Samples
  // → erlaubt App-seitige Näherungsrekonstruktion wenn TSYNC nicht verfügbar.
  int? _firstSurfaceMillis;

  int _sessionStart = 0;
  int _sessionEnd   = 0;

  String? _lastSavedPath;
  String? _lastSurfaceCsvPath;
  String? _lastFitPath;
  String? _lastError;

  bool               _isCalibrating  = false;
  CalibrationResult? _lastCalibration;

  bool                    _isOrientCalibrating = false;
  OrientationCalibration? _lastOrientCal;

  /// Welche Sensorachse zeigt in Fahrtrichtung (physisch markiert oder per Bremsmanöver erkannt).
  ForwardAxis _forwardAxis = ForwardAxis.plusX;

  // Test-Modus: Handy-IMU statt BLE-Sensor
  bool               _testMode         = false;
  PhoneSensorService? _phoneSensor;
  StreamSubscription? _phoneSampleSub;
  StreamSubscription? _phoneSurfSub;
  StreamSubscription? _phoneRateSub;
  int                _phoneSampleRate  = 0; // gemessene Hz des Handy-IMU

  // Brems-Kalibrierung: erkennt Fahrtrichtung automatisch per Bremsmanöver
  bool _isBrakeCalibrating  = false;
  int  _brakeCalSecondsLeft = 0;
  final List<SensorSample> _brakeCalBuffer = [];
  Timer? _brakeCalCountdown;

  // UI-Throttle: max. 30 Rebuilds/s
  Timer? _uiTimer;
  bool   _uiDirty = false;

  // Relay-Modus: Phone leitet 1-Hz-Surface-Daten per BLE-Peripheral an Garmin weiter
  bool _relayMode = false;
  final RelayService _relay = RelayService.instance;

  // Stream-CSV Surface: IOSink bleibt während der Aufnahme offen → kein Datenverlust
  IOSink? _csvSink;
  File?   _csvFile;

  // Stream-CSV Rohdaten: parallel zu _csvSink — schreibt jeden IMU-Sample
  IOSink? _rawCsvSink;
  File?   _rawCsvFile;
  String? _lastRawCsvPath;

  // ── Getter ───────────────────────────────────────────────────────────────────
  BleState get bleState          => _bleState;
  bool get isConnected           => _bleState == BleState.connected;
  bool get isScanning            => _bleState == BleState.scanning || _bleState == BleState.connecting;
  bool get isRecording           => _isRecording;
  int  get frequencyHz           => _frequencyHz;
  int  get fsIndex               => _fsIndex;
  String  get mountPoint         => _mountPoint;
  String?  get lastError         => _lastError;
  String?  get lastSavedPath     => _lastSavedPath;
  int  get sampleCount           => _totalSamplesReceived;
  int  get bufferedSamples       => _sampleQueue.length;
  bool get isCalibrating              => _isCalibrating;
  CalibrationResult? get lastCalibration => _lastCalibration;
  bool get isOrientCalibrating        => _isOrientCalibrating;
  OrientationCalibration? get lastOrientCal => _lastOrientCal;
  bool get hasOrientCal               => _lastOrientCal?.isValid ?? false;
  bool get supportsOrientationCal     => _ble.supportsOrientationCal;
  ForwardAxis get forwardAxis         => _forwardAxis;
  bool get isBrakeCalibrating         => _isBrakeCalibrating;
  int  get brakeCalSecondsLeft        => _brakeCalSecondsLeft;
  bool get isTestMode                 => _testMode;
  int  get phoneSampleRate            => _phoneSampleRate;
  bool get relayMode                  => _relayMode;
  RelayState get relayState           => _relay.state;

  /// Vollständiges Bike-Koordinatensystem (vertikal / longitudinal / lateral).
  /// Nur verfügbar wenn Orientierungskalibrierung abgeschlossen.
  /// Neu berechnet bei jedem Zugriff (lazy, kein Cache — selten aufgerufen).
  BikeFrameCalibration? get bikeFrame =>
      _lastOrientCal != null
          ? BikeFrameCalibration.compute(_lastOrientCal!, _forwardAxis)
          : null;
  bool get hasGps                     => _gpsSamples.isNotEmpty;

  List<SensorSample>  get samples        => _sampleQueue.toList(growable: false);
  List<GpsSample>     get gpsSamples     => List.unmodifiable(_gpsSamples);
  List<SurfaceSample> get surfaceSamples => List.unmodifiable(_surfaceSamples);

  SurfaceSample? get lastSurface =>
      _surfaceSamples.isNotEmpty ? _surfaceSamples.last : null;

  /// Letzte gemessene IMU-Temperatur [°C]. NaN wenn noch keine Firmware v6-Verbindung.
  double get imuTemperatureC => _ble.lastTemperatureC;

  List<SensorSample> recentSamples({int n = 200}) {
    final len = _sampleQueue.length;
    if (len <= n) return _sampleQueue.toList(growable: false);
    return _sampleQueue.skip(len - n).toList(growable: false);
  }

  StreamSubscription? _sampleSub, _surfaceSub, _stateSub, _errorSub, _calSub, _gpsSub, _orientCalSub, _tempSub;

  // ── BLE-Aktionen ──────────────────────────────────────────────────────────────

  Future<void> connect()    async { _lastError = null; notifyListeners(); await _ble.scanAndConnect(); }
  Future<void> disconnect() async { await stopRecording(); await _ble.disconnect(); }

  Future<void> setFrequency(int hz) async {
    _frequencyHz = hz; notifyListeners();
    if (isConnected) await _ble.sendFrequency(hz);
  }

  Future<void> setFullScale(int idx) async {
    if (idx < 0 || idx >= kFsG.length) return;
    _fsIndex = idx; notifyListeners();
    if (isConnected) await _ble.sendFullScale(idx);
  }

  Future<void> setMountPoint(String point) {
    _mountPoint = point;
    notifyListeners();
    return Future.value();
  }

  /// Fahrtrichtungs-Achse manuell setzen (welche Sensorachse zeigt vorwärts).
  void setForwardAxis(ForwardAxis axis) {
    _forwardAxis = axis;
    notifyListeners();
  }

  // ── Relay-Modus ───────────────────────────────────────────────────────────────

  /// Relay-Modus ein-/ausschalten.
  ///
  /// EIN: Phone advertist als "SurfaceSensor" (gleiche UUID wie Sensor).
  ///      Garmin findet das Phone statt des Sensors (Sensor hört auf zu
  ///      advertisen sobald Phone verbunden ist).
  ///      Jedes 1-Hz-Surface-Sample wird per BLE-Notify an den Garmin gesendet.
  ///
  /// AUS: Advertisement stoppt, Garmin-Verbindung trennt sich.
  ///      Phone arbeitet normal als alleiniger Client des Sensors.
  Future<void> setRelayMode(bool value) async {
    if (_relayMode == value) return;
    _relayMode = value;
    if (value) {
      await _relay.start();
      // Relay-State-Änderungen (Garmin verbunden/getrennt) ans UI weiterleiten
      _relay.stateStream.listen((_) => notifyListeners());
    } else {
      await _relay.stop();
    }
    notifyListeners();
  }

  // ── Test-Modus ────────────────────────────────────────────────────────────────

  /// Test-Modus aktivieren: Handy-IMU ersetzt den BLE-Sensor.
  /// Kein BLE nötig — alle Analyse-Funktionen (FFT, RMS, VDV, CSV, FIT) bleiben aktiv.
  void enableTestMode() {
    if (_testMode || _isRecording) return;
    _testMode = true;
    _phoneSensor ??= PhoneSensorService();
    // Rate-Updates empfangen und im UI anzeigen
    _phoneRateSub?.cancel();
    _phoneRateSub = _phoneSensor!.rateStream.listen((r) {
      _phoneSampleRate = r;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Test-Modus deaktivieren.
  void disableTestMode() {
    if (!_testMode || _isRecording) return;
    _phoneRateSub?.cancel();
    _phoneRateSub = null;
    _testMode        = false;
    _phoneSampleRate = 0;
    notifyListeners();
  }

  void _stopPhoneSensor() {
    _phoneSampleSub?.cancel(); _phoneSampleSub = null;
    _phoneSurfSub?.cancel();   _phoneSurfSub   = null;
    _phoneSensor?.stop();
  }

  /// Fahrtrichtungs-Erkennung per Bremsmanöver starten.
  /// Orientierungskalibrierung muss abgeschlossen sein (g_hat bekannt).
  /// Nutzer fährt an und bremst kräftig innerhalb von 5 Sekunden.
  /// Die Achse mit dem größten horizontalen Verzögerungspeak wird als Vorwärts gesetzt.
  void startBrakeCalibration() {
    if (!hasOrientCal || _isBrakeCalibrating || _isRecording) return;
    _brakeCalBuffer.clear();
    _isBrakeCalibrating   = true;
    _brakeCalSecondsLeft  = 5;
    notifyListeners();

    _brakeCalCountdown?.cancel();
    _brakeCalCountdown = Timer.periodic(const Duration(seconds: 1), (t) {
      _brakeCalSecondsLeft--;
      if (_brakeCalSecondsLeft <= 0) {
        t.cancel();
        _finalizeBrakeCalibration();
      } else {
        notifyListeners();
      }
    });
  }

  /// Brems-Kalibrierung abbrechen ohne Ergebnis.
  void cancelBrakeCalibration() {
    _brakeCalCountdown?.cancel();
    _isBrakeCalibrating   = false;
    _brakeCalSecondsLeft  = 0;
    _brakeCalBuffer.clear();
    notifyListeners();
  }

  void _finalizeBrakeCalibration() {
    final detected = _detectForwardAxisFromBrake(_brakeCalBuffer, _lastOrientCal!);
    _isBrakeCalibrating   = false;
    _brakeCalSecondsLeft  = 0;
    if (detected != null) _forwardAxis = detected;
    _brakeCalBuffer.clear();
    notifyListeners();
  }

  /// Analysiert Samples aus dem Bremsmanöver und gibt die erkannte Vorwärts-Achse zurück.
  ///
  /// Algorithmus:
  ///   1. Baseline aus den ersten ~5 % der Samples (stationär vor dem Bremsen)
  ///   2. Dynamikvektor = Sample - Baseline, dann Gravitationsanteil via g_hat entfernen
  ///   3. Peak der horizontalen Magnitude finden → das ist die Rückwärtsrichtung
  ///   4. Vorwärts = entgegengesetzt, auf nächste Sensor-Achse snappen
  ///
  /// Gibt null zurück wenn kein ausreichendes Bremsmanöver erkannt wurde (< 0.15 g).
  ForwardAxis? _detectForwardAxisFromBrake(
      List<SensorSample> samples, OrientationCalibration orientCal) {
    if (samples.length < 20) return null;

    final gx = orientCal.gx, gy = orientCal.gy, gz = orientCal.gz;

    // Baseline: Mittelwert der ersten 5 % (max. 50 Samples)
    final baseN = (samples.length * 0.05).round().clamp(5, 50);
    double bax = 0, bay = 0, baz = 0;
    for (int i = 0; i < baseN; i++) {
      bax += samples[i].ax; bay += samples[i].ay; baz += samples[i].az;
    }
    bax /= baseN; bay /= baseN; baz /= baseN;

    // Peak der horizontalen Dynamikkomponente finden
    double peakHx = 0, peakHy = 0, peakHz = 0, peakMag = 0;
    for (final s in samples) {
      final dx = s.ax - bax, dy = s.ay - bay, dz = s.az - baz;
      // Vertikalanteil entfernen → horizontale Ebene
      final v  = dx*gx + dy*gy + dz*gz;
      final hx = dx - v*gx, hy = dy - v*gy, hz = dz - v*gz;
      final mag = sqrt(hx*hx + hy*hy + hz*hz);
      if (mag > peakMag) {
        peakMag = mag; peakHx = hx; peakHy = hy; peakHz = hz;
      }
    }

    // Mindest-Bremsmanöver: 0.15 g horizontal
    if (peakMag < 0.15) return null;

    // Bremspeak zeigt rückwärts → Vorwärts ist die entgegengesetzte Richtung
    // Snap auf nächste Sensor-Achse (größte Komponente bestimmt die Achse)
    final absx = peakHx.abs(), absy = peakHy.abs(), absz = peakHz.abs();
    if (absx >= absy && absx >= absz) {
      // Peak entlang X: positiver Peak = Verzögerung nach +X = Fahrt war in −X-Richtung
      return peakHx > 0 ? ForwardAxis.minusX : ForwardAxis.plusX;
    } else if (absy >= absx && absy >= absz) {
      return peakHy > 0 ? ForwardAxis.minusY : ForwardAxis.plusY;
    } else {
      return peakHz > 0 ? ForwardAxis.minusZ : ForwardAxis.plusZ;
    }
  }

  Future<void> calibrate() async {
    if (!isConnected || _isRecording || _isCalibrating) return;
    _isCalibrating = true; notifyListeners();
    await _ble.triggerCalibration();
  }

  /// Orientierungskalibrierung auslösen.
  /// Fahrrad muss aufrecht auf ebenem Boden stehen und ruhig sein.
  /// Ergebnis kommt asynchron über [lastOrientCal].
  Future<void> calibrateOrientation() async {
    if (!isConnected || _isRecording || _isOrientCalibrating) return;
    _isOrientCalibrating = true; notifyListeners();
    await _ble.triggerOrientationCalibration();
  }

  // ── Aufnahme-Steuerung ────────────────────────────────────────────────────────

  Future<void> startRecording() async {
    if (_isRecording) return;
    if (!_testMode && !isConnected) return;

    _sampleQueue.clear();
    _totalSamplesReceived  = 0;
    _firstSurfaceMillis    = null;
    _gpsSamples.clear();
    _surfaceSamples.clear();
    _lastSavedPath = null;
    _lastSurfaceCsvPath = null;
    _lastFitPath = null;
    _lastRawCsvPath = null;
    _lastError     = null;
    _sessionStart  = DateTime.now().millisecondsSinceEpoch;

    if (_testMode) {
      // ── Test-Modus: Handy-IMU ───────────────────────────────────────────
      _phoneSensor ??= PhoneSensorService();
      _phoneSampleSub = _phoneSensor!.sampleStream.listen(_onSample);
      _phoneSurfSub   = _phoneSensor!.surfaceStream.listen(_onSurface);
      _phoneSensor!.start();
    } else {
      // ── BLE-Modus: externer Sensor ──────────────────────────────────────
      await _ble.sendFrequency(_frequencyHz);
      await _ble.sendFullScale(_fsIndex);
      await _ble.sendTimeSync(_sessionStart);
      await _ble.sendControl(true);
    }

    // CSV + GPS + UI-Timer + Foreground Service (in beiden Modi)
    await _openCsvSink();
    _isRecording = true;
    notifyListeners();

    await ForegroundService.start(
      title: _testMode ? 'Surface Sensor - Test-Modus' : 'Surface Sensor - Aufnahme laeuft',
      text:  _testMode
          ? 'Handy-IMU - $_mountPoint'
          : '$_frequencyHz Hz - +/-${kFsG[_fsIndex]}g - $_mountPoint',
    );
    try {
      final gpsOk = await _gps.start();
      if (!gpsOk) _lastError = 'GPS nicht verfügbar – Standort-Berechtigung prüfen';
    } catch (e) { _lastError = 'GPS-Fehler: $e'; }

    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_uiDirty) { _uiDirty = false; notifyListeners(); }
    });

    _isRecording = true;
    notifyListeners();

    await ForegroundService.start(
      title: _testMode ? 'Surface Sensor – Test-Modus' : 'Surface Sensor – Aufnahme läuft',
      text:  _testMode
          ? 'Handy-IMU · $_mountPoint'
          : '$_frequencyHz Hz · ±${kFsG[_fsIndex]}g · $_mountPoint',
    );
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    _uiTimer?.cancel();
    _uiTimer = null;
    _uiDirty = false;

    if (_testMode) {
      _stopPhoneSensor();
    } else {
      await _ble.sendControl(false);
    }

    try { await _gps.stop(); } catch (_) {}
    _sessionEnd  = DateTime.now().millisecondsSinceEpoch;
    _isRecording = false;

    await _closeCsvSink();
    await ForegroundService.stop();
    notifyListeners();

    // Supabase-Upload im Hintergrund (nur wenn eingeloggt)
    _uploadToSupabase();
  }

  /// Lädt Ride-Daten asynchron zu Supabase hoch.
  /// Fehler werden als _lastError angezeigt, blockieren aber nicht die App.
  Future<void> _uploadToSupabase() async {
    final supa = SupabaseService();
    if (!supa.isSignedIn) return;
    if (_surfaceSamples.isEmpty) return;

    try {
      final startedAt = DateTime.fromMillisecondsSinceEpoch(_sessionStart);
      final endedAt   = DateTime.fromMillisecondsSinceEpoch(_sessionEnd);

      final rideId = await supa.createRide(
        startedAt:  startedAt,
        endedAt:    endedAt,
        samples:    _surfaceSamples,
        gpsSamples: _gpsSamples,
        mountPoint: _mountPoint,
      );

      await supa.uploadSurfaceSamples(rideId, _surfaceSamples, _gpsSamples);

      // FIT-Datei hochladen: fuer den Dashboard-Reifenmodus muss das wirklich
      // ein FIT sein, nicht der zuletzt gespeicherte Exportpfad.
      final fitPath = await _ensureFitFileForUpload();
      if (fitPath != null) {
        final fitFile = File(fitPath);
        if (await fitFile.exists()) {
          await supa.uploadFitFile(rideId, fitFile);
        }
      }
      // Surface-CSV hochladen falls vorhanden
      if (_lastSurfaceCsvPath != null) {
        final csvFile = File(_lastSurfaceCsvPath!);
        if (await csvFile.exists()) {
          await supa.uploadCsvFile(rideId, csvFile);
        }
      }
      // Rohdaten-CSV hochladen falls vorhanden
      if (_lastRawCsvPath != null) {
        final rawFile = File(_lastRawCsvPath!);
        if (await rawFile.exists()) {
          await supa.uploadRawCsvFile(rideId, rawFile);
        }
      }
    } catch (e) {
      _lastError = 'Supabase-Upload fehlgeschlagen: $e';
      notifyListeners();
    }
  }

  Future<String?> _ensureFitFileForUpload() async {
    if (_lastFitPath != null) return _lastFitPath;
    if (_gpsSamples.isEmpty) return null;

    try {
      final dir  = await getApplicationDocumentsDirectory();
      final ts   = _isoTimestamp();
      final path = '${dir.path}/surface_${kFsG[_fsIndex]}g_${_mountPoint}_$ts.fit';

      await compute(
        _fitIsolateEntry,
        _FitIsolateParams(
          path:           path,
          gpsSamples:     List.from(_gpsSamples),
          surfaceSamples: List.from(_surfaceSamples),
          sessionStart:   _sessionStart > 0 ? _sessionStart : DateTime.now().millisecondsSinceEpoch,
          sessionEnd:     _sessionEnd   > 0 ? _sessionEnd   : DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _lastFitPath = path;
      return path;
    } catch (e) {
      _lastError = 'FIT-Erzeugung fuer Upload fehlgeschlagen: $e';
      notifyListeners();
      return null;
    }
  }

  void _onSample(SensorSample s) {
    // Brems-Kalibrierung sammelt Samples auch außerhalb der Aufnahme
    if (_isBrakeCalibrating && _brakeCalBuffer.length < 8500) {
      _brakeCalBuffer.add(s);
    }

    if (!_isRecording) return;
    _sampleQueue.addLast(s);
    _totalSamplesReceived++;
    if (_sampleQueue.length > _kRawBufferMax) _sampleQueue.removeFirst();

    // Rohdaten-CSV: IOSink ist gepuffert → kein messbarer Overhead im Hot-Path
    _rawCsvSink?.writeln(s.toCsvRow(_sessionStart));

    _uiDirty = true;
  }

  void _onGps(GpsSample g) {
    if (!_isRecording) return;
    _gpsSamples.add(g);
  }

  void _onSurface(SurfaceSample s) {
    if (!_isRecording) return;

    // Timestamp-Rekonstruktion (Fallback wenn TSYNC nicht verfügbar):
    // Firmware ohne TSYNC sendet millis()-Werte statt Unix-ms.
    // App rekonstruiert: unix_ms ≈ sessionStart + (millis - firstMillis).
    var adjusted = _adjustTimestamp(s);

    // IRI aus RMS + letzter GPS-Geschwindigkeit berechnen
    final lastSpeed = _gpsSamples.isNotEmpty ? _gpsSamples.last.speed : null;
    final speedKmh  = (lastSpeed != null && lastSpeed >= 0)
        ? lastSpeed * 3.6  // m/s → km/h
        : null;
    final iri = SignalAnalysis.iriFromRms(adjusted.rmsG, speedKmh: speedKmh);
    adjusted = adjusted.copyWith(iriMKm: iri);

    _firstSurfaceMillis ??= s.timestampMs;
    _surfaceSamples.add(adjusted);

    // Sofort in CSV schreiben → kein Datenverlust bei Absturz
    _csvSink?.writeln(adjusted.toCsvRow(_sessionStart));

    // Im Relay-Modus: Surface-Daten an Garmin weiterleiten
    if (_relayMode) _relay.publishSurface(adjusted);

    // Foreground-Service-Benachrichtigung mit Live-Werten aktualisieren
    ForegroundService.update(
      title: 'Surface Sensor – Aufnahme läuft',
      text: 'RMS ${(adjusted.rmsG * 1000).toStringAsFixed(1)} mg'
            ' · VDV ${adjusted.vdvG.toStringAsFixed(3)}'
            ' · ${_surfaceSamples.length} Punkte',
    );

    notifyListeners();
  }

  /// Passt Firmware-Timestamps an Unix-ms an.
  /// Mit TSYNC (Firmware ≥ v5.1): Timestamp ist bereits unix_ms als uint32.
  /// Ohne TSYNC (ältere Firmware): millis()-basiert, Näherungsrekonstruktion.
  SurfaceSample _adjustTimestamp(SurfaceSample s) {
    if (_ble.supportsTimeSync) {
      // TSYNC aktiv: Firmware sendet (millis + offset) als uint32.
      // Rekonstruiere vollen uint64 aus den oberen Bits von sessionStart.
      final highBits = _sessionStart - (_sessionStart % 0x100000000);
      var full = highBits + s.timestampMs;
      // Überlauf-Korrektur: falls rekonstruierter Wert > 30 min vor Start → +2^32
      if (full < _sessionStart - 1800000) full += 0x100000000;
      return s.copyWith(timestampMs: full);
    } else {
      // Kein TSYNC: Näherungsrekonstruktion über Session-Start-Offset
      final offset = _sessionStart - (_firstSurfaceMillis ?? s.timestampMs);
      return s.copyWith(timestampMs: s.timestampMs + offset);
    }
  }

  // ── Stream-CSV ────────────────────────────────────────────────────────────────

  Future<void> _openCsvSink() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts  = _isoTimestamp();
      _csvFile = File('${dir.path}/surface_analysis_${kFsG[_fsIndex]}g_${_mountPoint}_$ts.csv');
      _csvSink = _csvFile!.openWrite();
      _csvSink!.writeln(SurfaceSample.csvHeader());

      // Rohdaten-CSV parallel öffnen
      _rawCsvFile = File('${dir.path}/raw_imu_${kFsG[_fsIndex]}g_${_mountPoint}_$ts.csv');
      _rawCsvSink = _rawCsvFile!.openWrite();
      _rawCsvSink!.writeln(SensorSample.csvHeader());
    } catch (e) {
      _lastError = 'CSV konnte nicht geöffnet werden: $e';
    }
  }

  Future<void> _closeCsvSink() async {
    // Surface-CSV schließen
    if (_csvSink != null) {
      try {
        await _csvSink!.flush();
        await _csvSink!.close();
        _lastSurfaceCsvPath = _csvFile?.path;
        _lastSavedPath = _lastSurfaceCsvPath;
        notifyListeners();
      } catch (e) {
        _lastError = 'CSV-Abschluss fehlgeschlagen: $e';
      } finally {
        _csvSink = null;
        _csvFile = null;
      }
    }

    // Rohdaten-CSV schließen
    if (_rawCsvSink != null) {
      try {
        await _rawCsvSink!.flush();
        await _rawCsvSink!.close();
        _lastRawCsvPath = _rawCsvFile?.path;
      } catch (e) {
        _lastError = 'Raw-CSV-Abschluss fehlgeschlagen: $e';
      } finally {
        _rawCsvSink = null;
        _rawCsvFile = null;
      }
    }
  }

  // ── Export ────────────────────────────────────────────────────────────────────

  Future<String?> exportCsv() async {
    // CSV wurde bereits beim Stop gespeichert; gibt gespeicherten Pfad zurück
    if (_lastSurfaceCsvPath != null) return _lastSurfaceCsvPath;
    // Fallback: neu schreiben wenn kein Pfad vorhanden
    if (_surfaceSamples.isEmpty) return null;
    await _openCsvSink();
    for (final s in _surfaceSamples) {
      _csvSink?.writeln(s.toCsvRow(_sessionStart));
    }
    await _closeCsvSink();
    return _lastSurfaceCsvPath;
  }

  Future<String?> exportRawCsv() async {
    if (_sampleQueue.isEmpty) return null;
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final ts   = _isoTimestamp();
      final file = File('${dir.path}/surface_raw_${kFsG[_fsIndex]}g_$ts.csv');
      final sink = file.openWrite();
      sink.writeln(SensorSample.csvHeader());
      for (final s in _sampleQueue) {
        sink.writeln(s.toCsvRow(_sessionStart));
      }
      await sink.flush();
      await sink.close();
      _lastSavedPath = file.path;
      notifyListeners();
      return file.path;
    } catch (e) {
      _lastError = 'Raw-CSV fehlgeschlagen: $e';
      notifyListeners();
      return null;
    }
  }

  /// FIT-Export im Hintergrund-Isolate (verhindert UI-Freeze bei großen Sessions).
  Future<String?> exportFit() async {
    if (_surfaceSamples.isEmpty && _gpsSamples.isEmpty) return null;
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final ts   = _isoTimestamp();
      final path = '${dir.path}/surface_${kFsG[_fsIndex]}g_${_mountPoint}_$ts.fit';

      await compute(
        _fitIsolateEntry,
        _FitIsolateParams(
          path:           path,
          gpsSamples:     List.from(_gpsSamples),
          surfaceSamples: List.from(_surfaceSamples),
          sessionStart:   _sessionStart > 0 ? _sessionStart : DateTime.now().millisecondsSinceEpoch,
          sessionEnd:     _sessionEnd   > 0 ? _sessionEnd   : DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _lastFitPath = path;
      _lastSavedPath = path;
      notifyListeners();
      return path;
    } catch (e) {
      _lastError = 'FIT-Export fehlgeschlagen: $e';
      notifyListeners();
      return null;
    }
  }

  Future<void> shareFile(String path) async {
    await Share.shareXFiles([XFile(path)], subject: 'Surface Sensor – $_mountPoint');
  }

  String _isoTimestamp() =>
      DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);

  @override
  void dispose() {
    _uiTimer?.cancel();
    _brakeCalCountdown?.cancel();
    _stopPhoneSensor();
    _phoneRateSub?.cancel();
    _phoneSensor?.dispose();
    _csvSink?.close();
    _rawCsvSink?.close();
    _sampleSub?.cancel();
    _surfaceSub?.cancel();
    _stateSub?.cancel();
    _errorSub?.cancel();
    _calSub?.cancel();
    _orientCalSub?.cancel();
    _tempSub?.cancel();
    _gpsSub?.cancel();
    _ble.dispose();
    _gps.dispose();
    super.dispose();
  }

  BleService get ble => _ble;
}

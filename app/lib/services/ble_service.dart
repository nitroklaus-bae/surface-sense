import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/sensor_sample.dart';
import '../models/surface_sample.dart';
import '../models/orientation_calibration.dart';

// ── BLE UUIDs (müssen mit Firmware übereinstimmen) ───────────────────────────
const _svcUuid    = '19b10000-e8f2-537e-4f6c-d104768a1214';
const _dataUuid   = '19b10001-e8f2-537e-4f6c-d104768a1214';
const _ctrlUuid   = '19b10002-e8f2-537e-4f6c-d104768a1214';
const _freqUuid   = '19b10003-e8f2-537e-4f6c-d104768a1214';
const _confUuid   = '19b10004-e8f2-537e-4f6c-d104768a1214';
const _calUuid    = '19b10005-e8f2-537e-4f6c-d104768a1214';
const _surfUuid   = '19b10006-e8f2-537e-4f6c-d104768a1214';
const _tsyncUuid  = '19b10007-e8f2-537e-4f6c-d104768a1214';  // Zeit-Sync
const _orientUuid = '19b10008-e8f2-537e-4f6c-d104768a1214';  // Orientierungskalibrierung
const _tempUuid   = '19b10009-e8f2-537e-4f6c-d104768a1214';  // Temperatur float32 °C

enum BleState { disconnected, scanning, connecting, connected }

class BleService {
  final _stateCtrl   = StreamController<BleState>.broadcast();
  final _sampleCtrl  = StreamController<SensorSample>.broadcast();
  final _errorCtrl   = StreamController<String>.broadcast();
  final _surfaceCtrl = StreamController<SurfaceSample>.broadcast();

  Stream<BleState>      get stateStream   => _stateCtrl.stream;
  Stream<SensorSample>  get sampleStream  => _sampleCtrl.stream;
  Stream<String>        get errorStream   => _errorCtrl.stream;
  Stream<SurfaceSample> get surfaceStream => _surfaceCtrl.stream;

  BleState _state = BleState.disconnected;
  BleState get state => _state;

  // Kalibrierungs-Ergebnis-Stream
  final _calCtrl    = StreamController<CalibrationResult>.broadcast();
  Stream<CalibrationResult> get calibrationStream => _calCtrl.stream;

  // Orientierungskalibrierungs-Ergebnis-Stream
  final _orientCtrl = StreamController<OrientationCalibration>.broadcast();
  Stream<OrientationCalibration> get orientationCalStream => _orientCtrl.stream;

  // Temperatur-Stream (float32 °C, alle 5 Sekunden)
  final _tempCtrl = StreamController<double>.broadcast();
  Stream<double> get temperatureStream => _tempCtrl.stream;
  double _lastTemperatureC = double.nan;
  double get lastTemperatureC => _lastTemperatureC;

  BluetoothDevice?         _device;
  BluetoothDevice?         _lastDevice;    // für Auto-Reconnect
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _ctrlChar;
  BluetoothCharacteristic? _freqChar;
  BluetoothCharacteristic? _confChar;
  BluetoothCharacteristic? _calChar;
  BluetoothCharacteristic? _surfChar;
  BluetoothCharacteristic? _tSyncChar;
  BluetoothCharacteristic? _orientChar;
  BluetoothCharacteristic? _tempChar;

  StreamSubscription? _scanSub;
  StreamSubscription? _dataSub;
  StreamSubscription? _connSub;
  StreamSubscription? _calSub;
  StreamSubscription? _surfSub;
  StreamSubscription? _orientSub;
  StreamSubscription? _tempSub;

  // ── Auto-Reconnect ───────────────────────────────────────────────────────────
  static const _maxReconnectAttempts = 5;
  bool   _intentionalDisconnect = false;
  int    _reconnectAttempts     = 0;
  Timer? _reconnectTimer;

  // ── Public API ───────────────────────────────────────────────────────────────

  Future<void> scanAndConnect() async {
    if (_state != BleState.disconnected) return;
    _intentionalDisconnect = false;
    _reconnectAttempts     = 0;
    _setState(BleState.scanning);
    await FlutterBluePlus.stopScan();

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        if (r.device.platformName == 'SurfaceSensor') {
          await FlutterBluePlus.stopScan();
          _scanSub?.cancel();
          _lastDevice = r.device;
          await _connect(r.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    Future.delayed(const Duration(seconds: 11), () {
      if (_state == BleState.scanning) {
        _setState(BleState.disconnected);
        _errorCtrl.add('Gerät nicht gefunden – ist die Firmware aktiv?');
      }
    });
  }

  Future<void> _connect(BluetoothDevice device) async {
    _setState(BleState.connecting);
    _device = device;
    try {
      await device.connect(timeout: const Duration(seconds: 10));
    } catch (e) {
      _setState(BleState.disconnected);
      _errorCtrl.add('Verbindung fehlgeschlagen: $e');
      _scheduleReconnect();
      return;
    }

    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) _onDisconnected();
    });

    final services = await device.discoverServices();
    for (final svc in services) {
      if (svc.uuid.toString() == _svcUuid) {
        for (final ch in svc.characteristics) {
          final uuid = ch.uuid.toString();
          if (uuid == _dataUuid)  _dataChar  = ch;
          if (uuid == _ctrlUuid)  _ctrlChar  = ch;
          if (uuid == _freqUuid)  _freqChar  = ch;
          if (uuid == _confUuid)  _confChar  = ch;
          if (uuid == _calUuid)    _calChar    = ch;
          if (uuid == _surfUuid)   _surfChar   = ch;
          if (uuid == _tsyncUuid)  _tSyncChar  = ch;
          if (uuid == _orientUuid) _orientChar = ch;
          if (uuid == _tempUuid)   _tempChar   = ch;
        }
      }
    }

    if (_dataChar == null || _ctrlChar == null || _freqChar == null) {
      _errorCtrl.add('BLE-Service nicht vollständig – Firmware prüfen');
      await disconnect();
      return;
    }

    await _dataChar!.setNotifyValue(true);
    _dataSub = _dataChar!.onValueReceived.listen((bytes) {
      for (final s in SensorSample.parse(bytes)) _sampleCtrl.add(s);
    });

    if (_calChar != null) {
      await _calChar!.setNotifyValue(true);
      _calSub = _calChar!.onValueReceived.listen((bytes) {
        if (bytes.length >= 7) _calCtrl.add(CalibrationResult.fromBytes(bytes));
      });
    }

    if (_surfChar != null) {
      await _surfChar!.setNotifyValue(true);
      _surfSub = _surfChar!.onValueReceived.listen((bytes) {
        try { _surfaceCtrl.add(SurfaceSample.fromBytes(bytes)); } catch (_) {}
      });
    }

    if (_orientChar != null) {
      await _orientChar!.setNotifyValue(true);
      _orientSub = _orientChar!.onValueReceived.listen((bytes) {
        _orientCtrl.add(OrientationCalibration.fromBytes(bytes));
      });
    }

    if (_tempChar != null) {
      await _tempChar!.setNotifyValue(true);
      _tempSub = _tempChar!.onValueReceived.listen((bytes) {
        if (bytes.length >= 4) {
          final bd = ByteData.sublistView(Uint8List.fromList(bytes));
          final t  = bd.getFloat32(0, Endian.little);
          if (t.isFinite) {
            _lastTemperatureC = t;
            _tempCtrl.add(t);
          }
        }
      });
    }

    // Erfolgreiche Verbindung: Reconnect-Zähler zurücksetzen
    _reconnectAttempts = 0;
    _setState(BleState.connected);
  }

  void _onDisconnected() {
    _dataSub?.cancel();   _dataSub   = null;
    _connSub?.cancel();   _connSub   = null;
    _calSub?.cancel();    _calSub    = null;
    _surfSub?.cancel();   _surfSub   = null;
    _orientSub?.cancel(); _orientSub = null;
    _tempSub?.cancel();   _tempSub   = null;
    _dataChar = _ctrlChar = _freqChar = _confChar = _calChar = null;
    _surfChar = _tSyncChar = _orientChar = _tempChar = null;
    _device   = null;
    _setState(BleState.disconnected);
    _scheduleReconnect();
  }

  /// Plant den nächsten Reconnect-Versuch mit exponentiellem Backoff.
  void _scheduleReconnect() {
    if (_intentionalDisconnect || _lastDevice == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _errorCtrl.add('Verbindung nach $_maxReconnectAttempts Versuchen aufgegeben.');
      _reconnectAttempts = 0;
      return;
    }
    _reconnectAttempts++;
    final delaySec = _reconnectAttempts * 2;  // 2 s, 4 s, 6 s, 8 s, 10 s
    _errorCtrl.add('Verbindung verloren – Wiederverbindungsversuch $_reconnectAttempts/$_maxReconnectAttempts in ${delaySec}s…');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_state == BleState.disconnected && !_intentionalDisconnect && _lastDevice != null) {
        _connect(_lastDevice!);
      }
    });
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    await _device?.disconnect();
    _onDisconnected();
  }

  // ── Schreib-Operationen ───────────────────────────────────────────────────────

  /// Start (1) / Stop (0)
  Future<void> sendControl(bool start) async {
    if (_ctrlChar == null) return;
    try {
      await _ctrlChar!.write([start ? 1 : 0], withoutResponse: false);
    } catch (e) {
      _errorCtrl.add('sendControl fehlgeschlagen: $e');
    }
  }

  /// Frequenz in Hz (Firmware rundet auf nächsten ODR)
  Future<void> sendFrequency(int hz) async {
    if (_freqChar == null) return;
    try {
      final bd = ByteData(2)..setUint16(0, hz, Endian.little);
      await _freqChar!.write(bd.buffer.asUint8List(), withoutResponse: false);
    } catch (e) {
      _errorCtrl.add('sendFrequency fehlgeschlagen: $e');
    }
  }

  /// Full-Scale-Index (0=±2g, 1=±4g, 2=±8g, 3=±16g)
  Future<void> sendFullScale(int fsIndex) async {
    if (_confChar == null) return;
    try {
      await _confChar!.write([fsIndex & 0x03], withoutResponse: false);
    } catch (e) {
      _errorCtrl.add('sendFullScale fehlgeschlagen: $e');
    }
  }

  /// Offset-Kalibrierung auslösen (Sensor muss flach/still liegen).
  Future<void> triggerCalibration() async {
    if (_calChar == null) return;
    try {
      await _calChar!.write([0x01], withoutResponse: false);
    } catch (e) {
      _errorCtrl.add('triggerCalibration fehlgeschlagen: $e');
    }
  }

  /// Orientierungskalibrierung auslösen.
  /// Fahrrad muss aufrecht auf ebenem Boden stehen, Sensor still.
  /// Ergebnis kommt als OrientationCalibration über [orientationCalStream].
  Future<void> triggerOrientationCalibration() async {
    if (_orientChar == null) return;
    try {
      await _orientChar!.write([0x01], withoutResponse: false);
    } catch (e) {
      _errorCtrl.add('triggerOrientationCalibration fehlgeschlagen: $e');
    }
  }

  /// True wenn Firmware Orientierungskalibrierung unterstützt (v5.2+).
  bool get supportsOrientationCal => _orientChar != null;

  /// Zeitstempel-Sync: App schreibt aktuellen Unix-ms-Wert (8 Byte LE uint64).
  /// Firmware berechnet Offset zu millis() → Surface-Packets erhalten korrekte
  /// Unix-Timestamps für exakte GPS-Korrelation im FIT-Export.
  ///
  /// Wird beim Start jeder Aufnahme aufgerufen. Falls tSyncChar nicht vorhanden
  /// (ältere Firmware), erfolgt App-seitige Näherungsrekonstruktion.
  Future<void> sendTimeSync(int unixMs) async {
    if (_tSyncChar == null) return;
    try {
      final buf = Uint8List(8);
      for (int i = 0; i < 8; i++) {
        buf[i] = (unixMs >> (8 * i)) & 0xFF;
      }
      await _tSyncChar!.write(buf, withoutResponse: false);
    } catch (e) {
      _errorCtrl.add('sendTimeSync fehlgeschlagen: $e');
    }
  }

  /// True wenn Firmware TSYNC-Charakteristik unterstützt.
  bool get supportsTimeSync => _tSyncChar != null;

  void _setState(BleState s) { _state = s; _stateCtrl.add(s); }

  void dispose() {
    _reconnectTimer?.cancel();
    _scanSub?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    _calSub?.cancel();
    _surfSub?.cancel();
    _orientSub?.cancel();
    _tempSub?.cancel();
    _stateCtrl.close();
    _sampleCtrl.close();
    _errorCtrl.close();
    _calCtrl.close();
    _surfaceCtrl.close();
    _orientCtrl.close();
    _tempCtrl.close();
  }
}

// ── Kalibrierungs-Ergebnis ────────────────────────────────────────────────────

enum CalStatus { inProgress, done, error }

class CalibrationResult {
  final CalStatus status;
  final int axOffsetRaw;
  final int ayOffsetRaw;
  final int azOffsetRaw;

  const CalibrationResult({
    required this.status,
    required this.axOffsetRaw,
    required this.ayOffsetRaw,
    required this.azOffsetRaw,
  });

  factory CalibrationResult.fromBytes(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final s = switch (bytes[0]) {
      0x01 => CalStatus.inProgress,
      0x00 => CalStatus.done,
      _    => CalStatus.error,
    };
    return CalibrationResult(
      status:      s,
      axOffsetRaw: bd.getInt16(1, Endian.little),
      ayOffsetRaw: bd.getInt16(3, Endian.little),
      azOffsetRaw: bd.getInt16(5, Endian.little),
    );
  }

  double offsetMg(int rawOffset, int fsG) =>
      rawOffset * (fsG * 1000.0 / 32768.0);
}

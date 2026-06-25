import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../models/surface_sample.dart';

/// BLE-Peripheral-Service: Das Phone advertist als "SurfaceSensor" und
/// leitet 1-Hz-Surface-Pakete an einen verbundenen Garmin Edge weiter.
///
/// Architektur:
///   Phone (Central)    ── BLE ──▶ nRF52840 Sensor
///   Phone (Peripheral) ◀── BLE ── Garmin Edge
///
/// Der Garmin-BleManager sucht nach "SurfaceSensor" – er findet je nach
/// Modus entweder den Sensor direkt (Phone nicht verbunden) oder das Phone
/// (Sensor ist mit Phone verbunden, advertist nicht mehr).
/// Die Connect-IQ-App braucht keine Änderungen.
class RelayService {
  RelayService._();
  static final RelayService instance = RelayService._();

  // ── UUIDs (identisch mit der Firmware) ───────────────────────────────────
  static final UUID _serviceUuid =
      UUID.fromString('19b10000-e8f2-537e-4f6c-d104768a1214');
  static final UUID _surfaceCharUuid =
      UUID.fromString('19b10000-e8f2-537e-4f6c-d104768a1006');
  static final UUID _cccdUuid =
      UUID.fromString('00002902-0000-1000-8000-00805f9b34fb');

  // ── BLE Peripheral Manager ────────────────────────────────────────────────
  // PeripheralManager() ist ein factory-Singleton (kein .instance)
  final _mgr = PeripheralManager();

  GATTCharacteristic? _surfaceChar;
  StreamSubscription<GATTCharacteristicNotifyStateChangedEventArgs>? _notifySub;
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>? _stateSub;

  // Verbundene Centrals die Notify aktiviert haben (= Garmin Edge)
  final _subscribers = <Central>{};

  bool _initialized = false;
  bool _advertising = false;
  int  _publishCount = 0;

  // ── Public State ──────────────────────────────────────────────────────────
  bool get isAdvertising   => _advertising;
  bool get garminConnected => _subscribers.isNotEmpty;
  int  get publishCount    => _publishCount;

  final _stateController = StreamController<RelayState>.broadcast();
  Stream<RelayState> get stateStream => _stateController.stream;

  RelayState get state {
    if (!_advertising) return RelayState.off;
    if (_subscribers.isNotEmpty) return RelayState.garminConnected;
    return RelayState.advertising;
  }

  // ── Start / Stop ──────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_advertising) return;
    try {
      await _ensureInitialized();
      await _mgr.startAdvertising(Advertisement(
        name: 'SurfaceSensor',
        serviceUUIDs: [_serviceUuid],
      ));
      _advertising = true;
      _emit();
    } catch (e) {
      debugPrint('[RelayService] start error: $e');
    }
  }

  Future<void> stop() async {
    if (!_advertising) return;
    try {
      await _mgr.stopAdvertising();
    } catch (_) {}
    _advertising = false;
    _subscribers.clear();
    _emit();
  }

  // ── Surface-Daten weiterleiten ────────────────────────────────────────────

  /// Wird von RecordingProvider bei jedem 1-Hz-Surface-Sample aufgerufen.
  Future<void> publishSurface(SurfaceSample s) async {
    if (_subscribers.isEmpty || _surfaceChar == null) return;

    // 16-Byte-Paket identisch mit Firmware-Format (Little-Endian)
    final buf = ByteData(16);
    buf.setUint32(0,  s.timestampMs, Endian.little);
    buf.setFloat32(4, s.rmsG,        Endian.little);
    buf.setFloat32(8, s.vdvG,        Endian.little);
    buf.setFloat32(12, s.peakG,      Endian.little);
    final bytes = Uint8List.view(buf.buffer);

    final toRemove = <Central>[];
    for (final central in List.of(_subscribers)) {
      try {
        await _mgr.notifyCharacteristic(
          central,
          _surfaceChar!,
          value: bytes,
        );
        _publishCount++;
      } catch (e) {
        debugPrint('[RelayService] notify error: $e');
        toRemove.add(central);
      }
    }
    if (toRemove.isNotEmpty) {
      _subscribers.removeAll(toRemove);
      _emit();
    }
  }

  // ── Initialisierung ───────────────────────────────────────────────────────

  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    // Surface-Characteristic mit Notify-Support (mutable = dynamischer Wert)
    _surfaceChar = GATTCharacteristic.mutable(
      uuid: _surfaceCharUuid,
      properties: [
        GATTCharacteristicProperty.read,
        GATTCharacteristicProperty.notify,
      ],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [
        // CCCD – Client Characteristic Configuration Descriptor
        GATTDescriptor.mutable(
          uuid: _cccdUuid,
          permissions: [
            GATTCharacteristicPermission.read,
            GATTCharacteristicPermission.write,
          ],
        ),
      ],
    );

    final service = GATTService(
      uuid: _serviceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [_surfaceChar!],
    );

    // Ggf. alten Service entfernen (z.B. nach App-Neustart)
    try {
      await _mgr.removeAllServices();
    } catch (_) {}
    await _mgr.addService(service);

    // CCCD-Writes verfolgen → wer Notify aktiviert hat = Garmin verbunden
    _notifySub = _mgr.characteristicNotifyStateChanged.listen((ev) {
      if (ev.state) {
        _subscribers.add(ev.central);
        debugPrint('[RelayService] Garmin subscribed');
      } else {
        _subscribers.remove(ev.central);
        debugPrint('[RelayService] Garmin unsubscribed');
      }
      _emit();
    });

    // BLE-State-Änderungen (z.B. BT ausgeschaltet)
    _stateSub = _mgr.stateChanged.listen((ev) {
      if (ev.state != BluetoothLowEnergyState.poweredOn) {
        _advertising = false;
        _subscribers.clear();
        _emit();
      }
    });

    _initialized = true;
  }

  void _emit() => _stateController.add(state);

  void dispose() {
    _notifySub?.cancel();
    _stateSub?.cancel();
    stop();
    _stateController.close();
  }
}

enum RelayState {
  off,             // Relay inaktiv
  advertising,     // Advertist, Garmin noch nicht verbunden
  garminConnected, // Garmin verbunden, Daten werden weitergeleitet
}

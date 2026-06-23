# Surface Sensor Project

Vibration/surface-roughness sensor system for cycling, consisting of embedded firmware and a companion mobile app.

## Architecture

```
firmware/surface_sensor.ino   ← Arduino C++ for XIAO nRF52840 Sense
app/                          ← Flutter mobile app (iOS + Android)
  lib/
    main.dart
    models/sensor_sample.dart
    services/ble_service.dart
    providers/recording_provider.dart
    screens/sensor_screen.dart
  pubspec.yaml
SETUP.md                      ← Hardware setup + permissions guide
```

## Hardware

- **MCU:** Seeed XIAO nRF52840 Sense
- **IMU:** LSM6DS3TR-C (onboard, I²C address 0x6A)
- **IMU INT1 pin:** P0.11 (Arduino pin 11) — used for wake-on-motion
- **Arduino libraries:** ArduinoBLE, Seeed Arduino LSM6DS3

### Sensor axis layout (XIAO nRF52840 Sense, top view, USB-C at top)
```
        USB-C
          ↑ +Y
  −X ←  [board]  → +X
          ↓ −Y
     +Z out of board (≈ +1g when flat on desk)
```

### Recommended mounting (USB-C down, protected from mud/rain)
```
Bike orientation: USB-C connector pointing toward ground
App setting:      ForwardAxis = +X

Result after orientation calibration:
  Vertical  (roughness) = +Y axis  → s.ay − 1g   (g_hat ≈ [0, 1, 0])
  Forward   (longitudinal)         = +X axis  → s.ax
  Lateral   (right side)           = −Z axis  → −s.az  (snap: Z component)

BikeFrameCalibration.axisLabel → "+X vorwärts · −Z rechts"
```
Physical alignment: with USB-C down, rotate board around Y-axis until
the +X edge (opposite side from USB-C, looking from above) points forward.

## BLE Protocol

**Service UUID:** `19B10000-E8F2-537E-4F6C-D104768A1214`

| Characteristic | UUID suffix | Mode | Content |
|---|---|---|---|
| Data | `...1214` | Notify | Batch packet (see below) |
| Control | `...1215` | Write | `0x00`=Stop, `0x01`=Start |
| Frequency | `...1216` | R/W | `uint16` Hz (Little-Endian) |
| Config | `...1217` | R/W | `uint8` bits[1:0]=fsIndex |
| Surface | `...1006` | Notify | 1 Hz summary packet (see below) |
| TSync | `...1007` | Write | `uint64` Unix-ms (LE) — Zeit-Sync für GPS-Korrelation |
| Orient | `...1008` | Write+Notify | Orientierungskalibrierung (see below) |

**Surface packet format (16 bytes):**
```
Byte 0-3   uint32   timestamp_ms  (window start)
Byte 4-7   float32  rms_g         RMS Z-axis [g]
Byte 8-11  float32  vdv_g         VDV Z-axis [g·s^0.25]  (ISO 2631-1)
Byte 12-15 float32  peak_g        Peak |az| [g]
```
Crest factor computed client-side as peak/rms. Sent once per second while recording.
Accumulation: `Σaz²` (int64) for RMS; `Σaz_g⁴` (float32) for VDV; resets each window.

**Orient characteristic protocol (19B10008):**
```
Write trigger: [0x01] → start orientation calibration (bike upright, still, on flat ground)
Notify result (17 bytes):
  Byte 0      status   0x00=OK, 0x10=inProgress, 0xFE=offset-cal missing, 0xFF=error
  Byte 1-4    float32  gx  (gravity unit vector, IMU frame, LE)
  Byte 5-8    float32  gy
  Byte 9-12   float32  gz
  Byte 13-16  float32  gMagG  (measured gravity magnitude in g, quality indicator ≈1.0)
```
**On-device application:**
```
az_vertical_dynamic = dot([ax_cal, ay_cal, az_cal], [gx, gy, gz]) - g1raw
  where g1raw = 1.0 / scaleG   (recomputed per-FS-change, stored as _g1raw)
  result ≈ 0 on smooth road; increases with roughness
  independent of sensor mounting angle
```
**Flutter:** `BleService.orientationCalStream` → `RecordingProvider.lastOrientCal`;
`OrientationCalibration.verticalG(ax, ay, az)` for app-side projection (FFT etc.)
UI: `_OrientCalibrationRow` — two-step: offset cal (step 1) → orientation cal (step 2)

**Batch packet format:**
```
Byte 0-3  uint32  base_timestamp_ms   (first sample in batch)
Byte 4    uint8   count               (samples in packet, 1-20)
Byte 5    uint8   config              bits[2:0]=odrIndex, bits[4:3]=fsIndex
Byte 6+   int16 ax, int16 ay, int16 az  per sample (Little-Endian, raw)
```

**ODR table** (odrIndex → Hz): `[52, 104, 208, 416, 833, 1666]`

**Full-scale table** (fsIndex → ±g, scale factor):
```
0 → ±2g,   scale = 2.0/32768
1 → ±4g,   scale = 4.0/32768   ← default
2 → ±8g,   scale = 8.0/32768
3 → ±16g,  scale = 16.0/32768
```

**Decoding:** `acceleration_g = raw_int16 * scale[fsIndex]`

## Firmware Key Facts

- `#define DEBUG 0` — **Produktionseinstellung** (DEBUG 1 nur für Entwicklung; Serial-Output verursacht BLE-Jitter bei ODR > ~200 Hz)
- `#define BATCH_SIZE 20` — samples per BLE notification (max 40 with DLE)
- `#define SLEEP_TIMEOUT_MS 30000` — deep sleep after 30 s without connection
- Deep sleep = nRF52840 System-OFF (~2 µA), wake via LSM6DS3 INT1 motion interrupt
- IMU FIFO in stream mode — firmware reads when ≥ BATCH_SIZE samples queued
- I²C at 400 kHz; practical max ODR ≈ 1666 Hz reliable, 3332 Hz experimental
- No Serial.print() in the sampling hot path (causes BLE jitter at high ODR)

## Flutter App Key Facts

- State management: `provider` package, `RecordingProvider`
- BLE: `flutter_blue_plus` — auto-scans for device named `SurfaceSensor`; `onValueReceived` (nicht `lastValueStream`) für Notify-Streams
- Roh-Samples: `ListQueue` Ringpuffer, max. 100 000 Samples (~60 s bei 1666 Hz, ~16 min bei 104 Hz); `_totalSamplesReceived` zählt Gesamtmenge
- UI-Throttle: `Timer.periodic(33 ms)` → max. 30 `notifyListeners()`/s während Aufnahme
- Surface-Samples (1 Hz): vollständig für 5 h gespeichert (~18 000 Einträge, ~288 KB)
- CSV: `surface_analysis_*.csv` (Surface, vollständig, streaming via IOSink) — automatisch nach Stop; `surface_raw_*.csv` (Ringpuffer-Snapshot, on demand)
- FIT: `FitWriter.write()` — GPS-Track + vibration_rms/vdv aus SurfaceSamples (O(n+m) Two-Pointer)
- GPS: `geolocator` — records `GpsSample` 1×/s; GPS-Fehler in `_lastError`
- PC transfer: `share_plus` — OS share sheet (AirDrop, Drive, Email, etc.)
- Tab navigation: `HomeScreen` (NavigationBar) → SensorScreen / AnalysisScreen / MapScreen

## App File Structure

```
app/lib/
  main.dart                    ← HomeScreen (3-tab nav + export PopupMenu)
  models/
    sensor_sample.dart
    gps_sample.dart             ← GpsSample, fitTimestamp, semicircles
    surface_sample.dart         ← SurfaceSample (1 Hz: rmsG, vdvG, peakG, crestFactor, copyWith)
    orientation_calibration.dart ← OrientationCalibration (gx/gy/gz, tiltDeg, verticalG())
  services/
    ble_service.dart            ← Auto-Reconnect (5 Versuche exp. Backoff), sendTimeSync()
    gps_service.dart            ← GpsService (geolocator wrapper)
    fit_writer.dart             ← Binary FIT encoder (Protocol 2.0)
    foreground_service.dart     ← Android Foreground Service (flutter_foreground_task)
  providers/
    recording_provider.dart     ← exportCsv(), exportFit() [compute()], shareFile(), mountPoint
  screens/
    sensor_screen.dart          ← Clipping-Warnung, Montagepunkt-Auswahl
    analysis_screen.dart        ← FFT, RMS, VDV, Crest Factor, Histogram
    map_screen.dart             ← flutter_map OSM + vibration heatmap
  utils/
    signal_analysis.dart        ← FFT (Cooley-Tukey), rms, vdv, histogram
```

## Analysis Screen

- Axes: X / Y / Z / |a|  ·  Window: 1 s / 2 s / 5 s / all
- FFT: up to 4096 points, Hanning window, displayed up to 100 Hz
- Metrics: RMS [g], VDV [g·s^0.25], Crest Factor (ISO 2631-1 unweighted)

## FIT File Format

Developer fields (dev_data_index=0):
- field 0: `vibration_rms` (float32, g) — on-device RMS aus SurfaceSample, nächster ±2000 ms zum GPS-Punkt
- field 1: `vibration_vdv` (float32, g·s^0.25) — on-device VDV aus SurfaceSample
- GPS-Korrelation: O(n+m) Two-Pointer (beide Listen zeitlich sortiert)

FIT epoch offset: 631065600 s (= Dec 31, 1989 00:00:00 UTC)
Lat/Lon: `degrees * 2^31 / 180` → sint32 semicircles

## On-Device Surface Analysis

- **Architecture**: No sample storage needed — firmware accumulates `int64 Σaz²` (RMS) and `float Σaz_g⁴` (VDV) per sample in the FIFO read hot path
- **Orientation correction**: when `orientCal.valid`, hot path uses `dot(a, g_hat) - g1raw` instead of raw `az`. RMS ≈ 0 mg smooth road; correct regardless of mounting angle
- **Window**: 1 second (checked via `millis()` in the main loop, independent of FIFO interrupt)
- **Minimum samples**: ODR/2 per window (avoids edge artefacts at recording start)
- **BLE bandwidth**: ~16 bytes/s vs. ~10 KB/s for raw streaming — factor 625 reduction
- **Coexistence**: Raw data char (batch Notify) and surface char (1 Hz Notify) are independent; app subscribes to both simultaneously
- **Flutter**: `BleService.surfaceStream` → `RecordingProvider._surfaceSamples`; `lastSurface` getter for live display; `_SurfaceLiveRow` in SensorScreen shows RMS/VDV/Peak/Crest Factor color-coded

## Android Setup (einmalig nach flutter create)

AndroidManifest.xml benötigt:
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

<!-- in <application>: -->
<service
  android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
  android:foregroundServiceType="connectedDevice"
  android:stopWithTask="true"/>
```

iOS Info.plist für Background BLE:
```xml
<key>UIBackgroundModes</key>
<array><string>bluetooth-central</string></array>
```

## IRI (International Roughness Index)

- Formula: `IRI = 2.21 × RMS_g × sqrt(20 / clamp(v_kmh, 5, 60))`  — calibrated at 20 km/h reference
- Computed client-side in `RecordingProvider._onSurface()` from existing 1-Hz surface samples + GPS speed
- Stored as `SurfaceSample.iriMKm` (nullable until GPS speed available)
- Written to FIT as developer field 4 (`iri`, float32, m/km)
- Quality scale: < 2 very smooth (green) · 2–5 good (yellow) · 5–8 moderate (orange) · ≥ 8 rough (red)
- Garmin DataField: computed in `compute()` using `Activity.Info.currentSpeed`, written as FIT dev field 4

## Temperature Drift Compensation (Auto-Zero)

- **BLE characteristic:** UUID `19b10009-…1214`, float32 °C, notify every 5 s (Firmware v6+)
- **Firmware auto-zero:** 2-second rolling window; if variance < 0.0009 g² AND |mean| < 0.08 g → EMA update `drift = 0.9×drift + 0.1×mean` (alpha=0.1)
- **Gate:** auto-zero only active when `orientCal.valid` (prevents corrupting raw-az hot path)
- **Flutter:** `BleService.lastTemperatureC` / `temperatureStream` → `RecordingProvider.imuTemperatureC`
- **UI:** `_TempRow` in `sensor_screen.dart` shows temperature + "Auto-Zero aktiv" badge (only visible with Firmware v6)
- **IMU registers:** 0x20/0x21, 16 LSB/°C, 25°C zero

## Planned Features

- [ ] ISO 2631-1 Wz frequency weighting for weighted VDV
- [ ] Session history + local database

## Build Commands

```bash
# Flutter
cd app
flutter pub get
flutter analyze
flutter run

# Arduino CLI (adjust FQBN if needed)
arduino-cli compile --fqbn Seeed:mbed:xiaonRF52840Sense firmware/surface_sensor.ino
arduino-cli upload  --fqbn Seeed:mbed:xiaonRF52840Sense -p <PORT> firmware/surface_sensor.ino
```

## Android Permissions (AndroidManifest.xml)
```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

## iOS Permissions (Info.plist)
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>BLE connection to surface sensor</string>
```

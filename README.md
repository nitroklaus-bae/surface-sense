# SurfaceSense

Cycling surface-roughness measurement system. A XIAO nRF52840 Sense records accelerometer data and streams it via BLE to a Flutter companion app. A SvelteKit dashboard with Supabase backend provides fleet-wide analysis, and a Garmin Connect IQ DataField shows live roughness metrics on the bike computer.

```
┌─────────────────┐   BLE    ┌──────────────────┐   HTTPS   ┌───────────────────┐
│  XIAO nRF52840  │ ───────▶ │   Flutter App    │ ────────▶ │ Supabase Backend  │
│  LSM6DS3 IMU    │          │  iOS + Android   │           │ PostgreSQL+PostGIS │
└─────────────────┘          └──────────────────┘           └───────────────────┘
                                      │                               │
                             BLE Relay│                               │REST
                                      ▼                               ▼
                             ┌─────────────────┐          ┌────────────────────┐
                             │  Garmin Connect │          │ SvelteKit Dashboard│
                             │  IQ DataField   │          │  (Vercel)          │
                             └─────────────────┘          └────────────────────┘
```

## Repository Structure

```
firmware/
  surface_sensor.ino       Arduino C++ firmware for XIAO nRF52840 Sense
app/
  lib/
    main.dart              HomeScreen, Supabase init, auth gate
    models/                SensorSample, SurfaceSample, GpsSample, OrientationCalibration
    services/              BleService, GpsService, FitWriter, ForegroundService, SupabaseService
    providers/             RecordingProvider (state + export + upload)
    screens/               SensorScreen, AnalysisScreen, MapScreen, HistoryScreen
    utils/signal_analysis.dart   FFT, RMS, VDV, histogram
  pubspec.yaml
garmin/
  SurfaceSense/            Connect IQ DataField project (Monkey C)
    source/
      BleManager.mc        BLE peripheral scanning + surface/temp parsing
      SurfaceSenseDataField.mc   Data field UI + FIT recording
    resources/             strings, drawables, layouts, settings
    manifest.xml
dashboard/
  src/
    routes/
      +layout.svelte       Auth guard, nav bar, admin badge
      +page.svelte         Ride list, Leaflet map, detail panel
      login/+page.svelte   Email/password login
    lib/
      supabase.js          Client, auth helpers, fetch helpers
      RideChart.svelte     Chart.js dual-axis time series
  svelte.config.js
  package.json
supabase/
  migrations/
    001_initial_schema.sql    Tables, PostGIS, RLS policies, Storage bucket
    002_admin_and_user_email.sql   Admin role, user_email column
SETUP.md                   Hardware wiring + Flutter build steps
SUPABASE_SETUP.md          Supabase project setup guide
```

## Hardware

| Component | Part |
|-----------|------|
| MCU | Seeed XIAO nRF52840 Sense |
| IMU | LSM6DS3TR-C (onboard, I²C 0x6A) |
| Power | USB-C or single-cell LiPo via onboard charger |

**Recommended mounting:** USB-C connector pointing toward the ground, +X axis pointing forward.

## Firmware

The firmware runs on Arduino / Mbed OS:

- **ODR options:** 52 / 104 / 208 / 416 / 833 / 1666 Hz
- **Full-scale options:** ±2 / ±4 / ±8 / ±16 g
- **Streaming:** IMU FIFO → BLE notifications, batches of 20 samples (~6 bytes/sample)
- **On-device analysis:** 1 Hz surface packets with RMS, VDV (ISO 2631-1), peak [g]
- **Orientation calibration:** gravity vector stored in firmware; hot path projects acceleration onto vertical axis independent of mounting angle
- **Temperature drift auto-zero:** 2 s rolling window EMA (α=0.1), active when stationary
- **Deep sleep:** System-OFF (~2 µA) after 30 s without BLE connection; wakes on LSM6DS3 motion interrupt

Flash via Arduino IDE or arduino-cli:
```bash
arduino-cli compile --fqbn Seeed:mbed:xiaonRF52840Sense firmware/surface_sensor.ino
arduino-cli upload  --fqbn Seeed:mbed:xiaonRF52840Sense -p <PORT> firmware/surface_sensor.ino
```

Full setup: [SETUP.md](SETUP.md)

## BLE Protocol

**Service UUID:** `19B10000-E8F2-537E-4F6C-D104768A1214`

| Characteristic | UUID suffix | Description |
|---|---|---|
| Data | `…1214` | Notify — raw batch packet (20 samples, int16 ax/ay/az) |
| Control | `…1215` | Write — `0x01` start, `0x00` stop |
| Frequency | `…1216` | R/W — uint16 Hz (LE) |
| Config | `…1217` | R/W — bits[4:3]=fsIndex, bits[2:0]=odrIndex |
| Surface | `…1006` | Notify — 1 Hz: timestamp, RMS, VDV, peak [g] |
| TSync | `…1007` | Write — uint64 Unix-ms for GPS correlation |
| Orient | `…1008` | Write+Notify — orientation calibration trigger + gravity vector result |
| Temperature | `…1009` | Notify — float32 °C every 5 s |

## Flutter App

Built with Flutter (iOS + Android). State management via `provider`, BLE via `flutter_blue_plus`.

**Key features:**
- Auto-scan and connect to `SurfaceSensor`
- Configurable ODR and full-scale range
- Orientation calibration (two-step: offset → gravity vector)
- Real-time surface metrics: RMS, VDV, IRI, crest factor
- FFT analysis tab (up to 4096 points, Hanning window, up to 100 Hz display)
- GPS track recording (1 Hz via `geolocator`)
- OSM map with IRI color overlay
- Export: CSV (streaming, full session) + FIT (GPS + vibration developer fields)
- Android Foreground Service for 5 h+ background recordings
- Supabase upload after each session (surface samples + FIT + CSV)
- History screen with past rides

**IRI formula** (calibrated at 20 km/h):
```
IRI = 2.21 × RMS_g × √(20 / clamp(v_kmh, 5, 60))
```

```bash
cd app
flutter pub get
flutter run
```

## Garmin Connect IQ DataField

Displays live surface roughness on Garmin Edge bike computers.

**Displayed values:**
- Row 1: RMS [mg]
- Row 2: VDV [g·s^0.25]
- Row 3: IRI [m/km] with color coding (green / yellow / orange / red)

Records `vibration_rms`, `vibration_vdv`, and `iri` as FIT developer fields.

The app acts as a BLE relay: phone receives raw BLE packets → computes surface metrics → forwards 1 Hz summary packets to the Garmin via the Connect IQ BLE API.

Setup: [garmin/SETUP.md](garmin/SETUP.md)

## Backend (Supabase)

PostgreSQL + PostGIS on Supabase free tier.

**Tables:**
- `rides` — one row per session with aggregated metrics (avg/max RMS, VDV, IRI, distance, duration)
- `surface_samples` — 1 Hz rows with rms_g, vdv_g, peak_g, iri_m_km, lat, lon, geom (PostGIS)

**Storage:** `ride-files` bucket — `{user_id}/{ride_id}.fit` and `.csv`

**RLS:** Users see only their own data. Admin users (set via `app_metadata.role = 'admin'` or email list) see all.

Setup: [SUPABASE_SETUP.md](SUPABASE_SETUP.md)

## Dashboard

SvelteKit 2 + Svelte 4, deployed on Vercel. No SSR (Leaflet + Supabase Auth require browser APIs).

**Features:**
- Login with Supabase email/password auth
- Ride list with IRI progress bar
- Leaflet OSM map with IRI-colored CircleMarkers per GPS point
- Detail panel: RMS, VDV, IRI, Max IRI
- Chart.js dual-axis time series (RMS [mg] left, IRI [m/km] right, Speed dashed)
- Admin view: shows all users' rides with user email badge

```bash
cd dashboard
npm install
npm run dev        # local dev
vercel --prod      # production deploy
```

## IRI Quality Scale

| IRI [m/km] | Quality |
|---|---|
| < 2 | very smooth (green) |
| 2–5 | good (yellow) |
| 5–8 | moderate (orange) |
| ≥ 8 | rough (red) |

## Planned

- ISO 2631-1 Wz frequency weighting for weighted VDV
- Session history + local SQLite database in app
- Map comparison between two rides

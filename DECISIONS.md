# Architecture Decisions & Known Constraints

This file documents non-obvious design decisions and constraints so AI agents do not
accidentally "fix" things that were deliberately chosen or already tried and rejected.

---

## Firmware

### DEBUG must stay 0 in production
`#define DEBUG 0` in `firmware/surface_sensor.ino`. Serial.print() in the FIFO read
hot path causes BLE notification jitter at ODR > ~200 Hz. Only set DEBUG 1 when
connected via USB and not doing high-speed BLE streaming.

### IMU FIFO not polled on interrupt — polled in main loop
The LSM6DS3 INT1 pin is wired to P0.11 and used only for wake-on-motion (deep sleep
wakeup). FIFO reads happen in the main loop when sample count ≥ BATCH_SIZE. This is
intentional — interrupt-driven FIFO reads caused race conditions with BLE stack.

### Orientation calibration uses dot product, not Euler angles
`az_vertical_dynamic = dot([ax, ay, az], [gx, gy, gz]) - g1raw`
Euler angles were considered but rejected: gimbal lock near ±90° tilt and more complex
to maintain across full-scale changes. The gravity unit vector approach works at any
mounting angle.

### g1raw recomputed on every full-scale change
`_g1raw = 1.0 / scaleG` is stored as a field and recomputed whenever fsIndex changes.
It represents 1 g in raw int16 units and is subtracted in the hot path to zero out
static gravity. Do not hardcode this value.

---

## Flutter App

### flutter_blue_plus: use onValueReceived, not lastValueStream
`lastValueStream` only emits when the value changes. For continuous sensor data this
means identical consecutive packets are silently dropped. Always use `onValueReceived`.

### UI throttled to 30 notifyListeners/s during recording
`Timer.periodic(33 ms)` drives UI updates regardless of BLE packet rate (up to 1666
Hz). Calling `notifyListeners()` on every BLE packet causes frame drops. Do not remove
this throttle.

### Raw sample ring buffer capped at 100,000 samples
`ListQueue` with max 100,000 entries (~60 s at 1666 Hz, ~16 min at 104 Hz). This is
intentional — unbounded growth causes OOM on long rides. The ring buffer is for
real-time analysis; the full session data comes from the 1 Hz surface samples.

### Surface samples kept in full (not ring buffer)
`_surfaceSamples` (1 Hz) are kept for the full session (up to ~18,000 entries for a
5 h ride, ~288 KB). These are the primary data source for CSV export, FIT writing,
and Supabase upload. Do not cap this list.

### CSV written via streaming IOSink during recording
`surface_analysis_*.csv` is written incrementally using an IOSink that stays open
during the entire recording. It is flushed and closed only on stopRecording(). Do not
buffer all rows and write at the end — this causes OOM on long rides.

### FIT export runs in compute() isolate
`FitWriter.write()` is CPU-intensive (iterates GPS + surface samples with two-pointer
merge). It runs in a Flutter `compute()` isolate to avoid blocking the UI thread.
Do not move it back to the main isolate.

### Supabase anon key is hardcoded, not in .env
The Supabase anon key is a public key by design (it is safe to expose in client apps).
It is hardcoded in `app/lib/services/supabase_service.dart` and
`dashboard/src/lib/supabase.js`. Do not move it to .env unless you also set up a
proper build pipeline that injects env vars — previous attempts with SvelteKit's
`$env/static/public` failed at Vercel build time.

### Android Foreground Service type must be connectedDevice
`android:foregroundServiceType="connectedDevice"` in AndroidManifest.xml is required
for Android 14+. Using `dataSync` or omitting the type causes a crash on Android 14.

---

## Garmin Connect IQ

### App acts as BLE relay, not direct sensor connection
The Garmin DataField does not connect to the XIAO directly. The Flutter app receives
raw BLE packets, computes 1 Hz surface summaries, then re-broadcasts them as a BLE
peripheral that the Garmin Connect IQ DataField connects to. This is because the
Garmin BLE API is limited and cannot parse the raw batch packet format.

### IRI computed twice: on device and in Garmin DataField
The firmware computes a speed-independent RMS and sends it in the surface packet.
The Flutter app computes IRI using GPS speed. The Garmin DataField independently
computes a speed-corrected IRI using `Activity.Info.currentSpeed` because GPS speed
from the phone is not available in the relay packet. Both values are written to FIT
as separate developer fields.

---

## Dashboard (SvelteKit)

### SSR is disabled globally
`export const ssr = false` in `src/routes/+layout.js`. Leaflet and Supabase Auth both
require browser APIs (`window`, `localStorage`) that do not exist in Node.js SSR
context. Enabling SSR breaks the map and auth on every page. Do not remove this.

### SvelteKit 2 + Svelte 4 + Vite 5 + adapter-vercel 4
This exact combination was chosen after Svelte 5 + Vite 8 caused build failures on
Vercel. Do not upgrade these without testing the full build pipeline:
`svelte-kit sync && vite build`.

### node_modules must be excluded from git
`dashboard/node_modules/` is in `.gitignore`. The directory is large (~150 MB) and
must not be committed. Vercel runs `npm install` during build.

### Admin detection uses email allowlist, not JWT app_metadata
JWT `app_metadata.role` was attempted first but the claim was not reliably present
in the client-side session after `raw_app_meta_data` was updated in Supabase.
The current approach checks `session.user.email` against a hardcoded list in
`ADMIN_EMAILS` in `supabase.js`. To add an admin, add their email to that array
and redeploy.

---

## Supabase

### spatial_ref_sys RLS error is a false positive
Running the SQL migration produces an error `must be owner of table spatial_ref_sys`.
This is a PostGIS system table owned by the Supabase service role. The error is
harmless — the policy on that table is not needed and the migration succeeds otherwise.

### Supabase pauses free-tier projects after 7 days of inactivity
If the app or dashboard shows connection errors after a period of no use, log in to
supabase.com and click "Restore project". The project resumes in ~30 seconds.

### surface_samples geom column is auto-filled by trigger
A PostgreSQL trigger (`set_geom`) fills `geom` from `lat`/`lon` on every insert.
Do not manually set the `geom` column from the Flutter app or dashboard — it will
be overwritten by the trigger anyway.

---

## Deployment

### Vercel deployment URL
Production URL is set via `vercel --prod` from the `dashboard/` directory.
The preview URLs (containing a hash like `8kb897h4p`) are ephemeral per-commit
deployments and should not be used as permanent links.

### GitHub token rotation
A GitHub PAT was used to set up the repository. Rotate it immediately at:
github.com → Settings → Developer settings → Personal access tokens

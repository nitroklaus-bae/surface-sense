# SurfaceSense ↔ ROLLEX_POC Integration

## Goal

Replace the static OSM-tag IRI values in ROLLEX_POC's CRR model with real
measured IRI from the SurfaceSense vibration sensor. Long-term: every ride
contributes to a shared surface database keyed by OSM way ID, so CRR
calculations improve with each sensor ride.

---

## Architecture Overview

```
┌─────────────────────────────┐      ┌──────────────────────────────┐
│  SurfaceSense Flutter App   │      │     ROLLEX_POC (React/TS)    │
│                             │      │                              │
│  XIAO nRF52840              │      │  GPX / FIT import            │
│   → IMU @ 1–1666 Hz         │      │  Overpass OSM query          │
│   → surface RMS/VDV/IRI     │      │  HMM map matching            │
│   → GPS 1 Hz                │      │  CRR model                   │
│   → FIT export (dev fields) │──A──▶│   iri = measuredIri ??       │
│                             │      │         surface.iri           │
│   Supabase upload           │──B──▶│  fetchOsmIri(wayIds)         │
│    osm_iri_contributions    │      │   → getIriForSegments()      │
└─────────────────────────────┘      └──────────────────────────────┘
              │                                     │
              └──────────── Supabase ───────────────┘
                         osm_iri_segments
                         (crowd-sourced IRI
                          per OSM way ID)
```

---

## IRI Priority Order (CRR Model)

| Priority | Source | When available |
|---|---|---|
| 1 | FIT dev field 4 (per GPS point) | SurfaceSense FIT imported into ROLLEX_POC |
| 2 | Supabase crowd aggregate (`osm_iri_segments`) | After running migration 004 + at least 1 ride |
| 3 | Static OSM surface category (`SURFACE_PROPS[cat].iri`) | Always (fallback) |

Priority 1 is per-point, per-second data from this exact ride.
Priority 2 is a distance-weighted mean over all past rides on that OSM way.
Priority 3 is the existing ROLLEX_POC behaviour (unchanged when sensor data absent).

---

## Phase 1 — FIT Import (implemented)

**What was changed:**

- `types/index.ts`: `TrackPoint.iri?: number` — measured IRI at each GPS point
- `types/index.ts`: `SurfaceSegment.measuredIri?: number` + `iriSampleCount?: number`
- `trackParser.ts`: reads FIT Protocol 2.0 dev fields. Parses `dev_data_index=0,
  fieldNumber=4` (IRI, float32) into `TrackPoint.iri`. Interpolates across
  densified points via `lerpPoint`.
- `surfaceAnalyzer.ts`: `segmentsFromMatchedWayIds()` aggregates per-point IRI
  into `SurfaceSegment.measuredIri` using a distance-weighted mean.
- `routeProfile.ts`: `buildRouteProfile()` uses `seg.measuredIri ?? seg.surface.iri`
  for all IRI values fed into the CRR model.

**How to use:** Export a ride from the SurfaceSense app as a FIT file → import
into ROLLEX_POC. The CRR model automatically uses measured roughness.

---

## Phase 2 — Supabase API (implemented, needs migration)

**New files:**
- `src/modules/surfaceSenseApi.ts` — Supabase client
- `supabase/migrations/004_osm_iri_layer.sql` — DB schema

**Run the migration:** Supabase Dashboard → SQL Editor → paste
`supabase/migrations/004_osm_iri_layer.sql` → Run.

**API surface:**

```typescript
import { getIriForSegments, pushIriContributions } from './surfaceSenseApi'

// After analyzeSurfaces() — fills measuredIri from community data:
const enrichedSegs = await getIriForSegments(segments)

// After a SurfaceSense FIT ride — contribute back to community:
await pushIriContributions(enrichedSegs, supabaseAccessToken, rideId)
```

**Supabase schema:**
- `osm_iri_contributions` — raw per-ride per-way IRI rows (auditable)
- `osm_iri_segments` — running distance-weighted aggregate per OSM way ID
- `osm_iri_summary` — view for the SvelteKit dashboard
- RPC `get_iri_for_osm_ways(way_ids)` — batch read (anonymous, public)
- RPC `upsert_iri_contributions(contributions)` — batch write (authenticated)

---

## Phase 3 — Auto-Contribute from Flutter App (planned)

The SurfaceSense Flutter app already computes IRI at 1 Hz (`RecordingProvider._onSurface()`)
and stores GPS samples. To auto-contribute to the community layer:

1. After each ride, run client-side map matching (reuse ROLLEX_POC's HMM logic,
   ported to Dart, or call it via a Supabase Edge Function).
2. Call Supabase RPC `upsert_iri_contributions` with the per-way aggregates.

Alternative (simpler): upload GPS+IRI pairs raw, run map matching server-side
via a Supabase Edge Function (Node.js) that shares the TypeScript map matcher.

---

## CRR Formula Reference

The IRI slot used in the three-term model (default) and physical model:

```typescript
// rollingResistance.ts — crrComponents()
const iriExcess = Math.max(0, Math.pow(iri, GAMMA) - Math.pow(IRI_SMOOTH, GAMMA))
const impedance = iriExcess > 0
  ? K_IMP * iriExcess * Math.pow(pressureBar / P_REF, DELTA) * Math.pow(W0 / widthMm, EPS_W)
  : 0
```

With measured IRI from the sensor, this term reflects the actual road surface
the rider encountered rather than the category average. On smooth chip-seal
(OSM says `rough_asphalt`, IRI_OSM=3.5) that was actually repaved (IRI=1.8),
CRR drops noticeably and the tire recommendation shifts toward higher pressure.

---

## Key Constraints for AI Agents

- **Do not change the `crrComponents()` signature** — IRI flows in through
  `routeProfile.ts` → `RouteBin.iri`. The function itself is unchanged.
- **ROLLEX_POC is a pure client-side app** — no server-side rendering. All
  Supabase calls use the anon key + REST; no JWT requirement for reads.
- **Supabase anon key is public** — it's the same key as in `dashboard/static/raw/`.
  Write operations require an authenticated session token.
- **measuredIri is always optional** — every code path falls back to OSM IRI.
  The integration never breaks existing GPX/non-sensor FIT imports.
- **IRI unit is m/km throughout** — SurfaceSense, ROLLEX_POC, and the DB all
  use the same unit. No conversion needed.

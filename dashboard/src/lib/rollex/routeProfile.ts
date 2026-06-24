import type { SurfaceCategory, SurfaceProperties, SurfaceSegment, TrackSegment } from './types'
import { SURFACE_PROPS } from './surfaceAnalyzer'

// ══════════════════════════════════════════════════════════════════════════════
// ROUTE PROFILE — grade × surface distribution
//
// The route is reduced to bins keyed by (grade rounded to 1 % × surface category).
// Each bin sums the proportional distance that falls into that combination. Speed
// and time are then integrated over the bins, so the grade DISTRIBUTION matters
// (a 50/50 split of +3 %/−3 % is not the same as flat, because the power→speed
// relation is non-linear on climbs). Surface sets the Crr, grade sets the gravity
// term. When a FIT file carries power data, each bin also stores the real average
// power ridden on those sections, so the speed reflects how hard the rider
// actually went there rather than a flat average.
// ══════════════════════════════════════════════════════════════════════════════

export interface RouteBin {
  gradePct: number          // integer grade in % (−20…+20)
  category: SurfaceCategory
  iri: number
  distanceMeters: number
  fraction: number          // share of total distance
  avgPowerW?: number        // real average power on these sections (FIT power only)
}

export interface RouteProfile {
  bins: RouteBin[]
  totalDistanceM: number
  hasPower: boolean
}

// Centered moving average of elevation over ±windowM (m) to suppress GPS noise
// before differentiating into grade.
function smoothElevation(ele: number[], dist: number[], windowM: number): number[] {
  const n = ele.length
  const out = new Array<number>(n)
  for (let i = 0; i < n; i++) {
    let sum = ele[i], count = 1
    for (let j = i - 1; j >= 0 && dist[i] - dist[j] <= windowM; j--) { sum += ele[j]; count++ }
    for (let j = i + 1; j < n && dist[j] - dist[i] <= windowM; j++) { sum += ele[j]; count++ }
    out[i] = sum / count
  }
  return out
}

// Build the (grade × surface) profile from the track + classified surfaces.
export function buildRouteProfile(
  track: TrackSegment | undefined,
  surfaces: SurfaceSegment[],
  useRealPower: boolean,
): RouteProfile {
  // Degenerate fallback (no geometry): one flat bin per surface segment.
  if (!track || track.points.length < 2) {
    const total = surfaces.reduce((s, seg) => s + Math.max(0, seg.distanceMeters), 0) || 1
    const bins = surfaces
      .filter(seg => seg.distanceMeters > 0)
      .map(seg => ({
        gradePct: 0,
        category: seg.surface.category,
        // Prefer measured IRI from sensor over static OSM value
        iri: seg.measuredIri ?? seg.surface.iri,
        distanceMeters: seg.distanceMeters,
        fraction: seg.distanceMeters / total,
      }))
    return { bins, totalDistanceM: total, hasPower: false }
  }

  const pts = track.points
  const n = pts.length
  const dist = pts.map(p => p.distance ?? 0)
  const ele = pts.map(p => p.elevation)
  const smooth = smoothElevation(ele, dist, 50)   // ±50 m window

  // Per-point surface lookup from the segments (O(n) build, O(1) access).
  const surfAt = new Array<SurfaceProperties>(n)
  // Also store the segment reference so we can read measuredIri per point.
  const segAt = new Array<(typeof surfaces)[number] | undefined>(n)
  for (const seg of surfaces) {
    for (let i = seg.startIdx; i <= seg.endIdx && i < n; i++) {
      surfAt[i] = seg.surface
      segAt[i] = seg
    }
  }

  const bins = new Map<string, RouteBin & { powSum: number; powDist: number }>()
  let total = 0
  for (let i = 1; i < n; i++) {
    const d = dist[i] - dist[i - 1]
    if (d <= 0) continue
    const grade = (smooth[i] - smooth[i - 1]) / d
    const gradePct = Math.max(-20, Math.min(20, Math.round(grade * 100)))
    const sp = surfAt[i] ?? surfAt[i - 1] ?? SURFACE_PROPS.unknown
    const key = `${gradePct}|${sp.category}`
    let b = bins.get(key)
    // Prefer measured IRI from sensor over static OSM category IRI
    const iri = (segAt[i] ?? segAt[i - 1])?.measuredIri ?? sp.iri
    if (!b) {
      b = { gradePct, category: sp.category, iri, distanceMeters: 0, fraction: 0, powSum: 0, powDist: 0 }
      bins.set(key, b)
    }
    b.distanceMeters += d
    total += d
    if (useRealPower) {
      const p0 = pts[i - 1].power, p1 = pts[i].power
      if (p0 !== undefined && p1 !== undefined) { b.powSum += ((p0 + p1) / 2) * d; b.powDist += d }
    }
  }

  const totalSafe = total || 1
  const out: RouteBin[] = [...bins.values()]
    .map(b => ({
      gradePct: b.gradePct,
      category: b.category,
      iri: b.iri,
      distanceMeters: b.distanceMeters,
      fraction: b.distanceMeters / totalSafe,
      avgPowerW: useRealPower && b.powDist > 0 ? b.powSum / b.powDist : undefined,
    }))
    .sort((a, b) => b.distanceMeters - a.distanceMeters)

  return { bins: out, totalDistanceM: total, hasPower: useRealPower }
}

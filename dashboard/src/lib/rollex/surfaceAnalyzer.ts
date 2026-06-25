import type { LatLon, SurfaceCategory, SurfaceProperties, SurfaceSegment, TrackSegment } from './types'
import { osmCacheGet, osmCacheSet } from './osmCache'

// ── Surface catalog ──────────────────────────────────────────────────
// One profile per RrClass. IRI drives the impedance term, the per-category
// sinkage S lives in rollingResistance.ts. The (IRI,S) pairs for Cat 1–3 are the
// Karrasch-validated ones; Cat 4 / sand-mud / technical-trail are estimates beyond
// the measured range. Note: gravel_coarse = Cat 2, dirt = Cat 3 (dirt rougher than
// loose gravel), matching the Flutter surface→SILCA mapping.
export const SURFACE_PROPS: Record<SurfaceCategory, SurfaceProperties> = {
  track: {
    category: 'track', label: 'Bahn / glatter Beton',
    iri: 0.8, color: '#06b6d4',
    punctureRiskFactor: 1.0, handlingRiskFactor: 1.0,
  },
  smooth_asphalt: {
    category: 'smooth_asphalt', label: 'Glatter Asphalt',
    iri: 1.5, color: '#1d4ed8',
    punctureRiskFactor: 1.0, handlingRiskFactor: 1.0,
  },
  rough_asphalt: {
    category: 'rough_asphalt', label: 'Rauer Asphalt',
    iri: 3.5, color: '#6366f1',
    punctureRiskFactor: 1.2, handlingRiskFactor: 1.1,
  },
  cobblestone: {
    category: 'cobblestone', label: 'Kopfsteinpflaster',
    // IRI 11.0: pavé vibration far harsher than gravel (Roubaix-class).
    iri: 11.0, color: '#d97706',
    punctureRiskFactor: 2.0, handlingRiskFactor: 2.5,
  },
  gravel_fine: {
    category: 'gravel_fine', label: 'Feiner Schotter (Cat 1)',
    // IRI 3.5: packed fine gravel rolls smoothly; resistance is mostly sinkage.
    iri: 3.5, color: '#84cc16',
    punctureRiskFactor: 1.8, handlingRiskFactor: 1.8,
  },
  gravel_coarse: {
    category: 'gravel_coarse', label: 'Loser Schotter (Cat 2)',
    // Cat 2 pair (Karrasch-calibrated): IRI 6.0 / S 0.01091.
    iri: 6.0, color: '#f59e0b',
    punctureRiskFactor: 2.2, handlingRiskFactor: 2.4,
  },
  dirt: {
    category: 'dirt', label: 'Naturboden / grob (Cat 3)',
    // Cat 3 pair (Karrasch-calibrated): IRI 6.5 / S 0.02139.
    iri: 6.5, color: '#78350f',
    punctureRiskFactor: 2.5, handlingRiskFactor: 2.6,
  },
  grass_soft: {
    category: 'grass_soft', label: 'Gras / weicher Boden (Cat 4)',
    // Beyond Karrasch range — estimate: softer than Cat 3, high sinkage.
    iri: 7.5, color: '#4d7c0f',
    punctureRiskFactor: 1.8, handlingRiskFactor: 2.4,
  },
  sand_mud: {
    category: 'sand_mud', label: 'Sand / Schlamm',
    // Estimate: very soft/loose, highest sinkage.
    iri: 9.0, color: '#a16207',
    punctureRiskFactor: 2.0, handlingRiskFactor: 3.0,
  },
  technical_trail: {
    category: 'technical_trail', label: 'Technischer Trail (MTB)',
    // Estimate: very rough (high impedance), moderately loose.
    iri: 10.0, color: '#7f1d1d',
    punctureRiskFactor: 3.0, handlingRiskFactor: 3.0,
  },
  unknown: {
    category: 'unknown', label: 'Unbekannt',
    iri: 4.0, color: '#9ca3af',
    punctureRiskFactor: 1.3, handlingRiskFactor: 1.2,
  },
}

// ══════════════════════════════════════════════════════════════════════════════
// OSM SURFACE CLASSIFICATION
// Ported from the Flutter app (cycling-tire-and-pressure-selector/lib/main.dart,
// `classifyOsmSurface`). A 10-class roughness taxonomy (RrClass) with a priority
// chain — surface → tracktype → paved/unpaved defaults → highway fallback — then
// roughened by mtb:scale(/uphill/imba), sac_scale and trail_visibility, with a
// smoothness-based smooth/rough split. The RrClass is finally mapped onto this
// app's calibrated SurfaceCategory taxonomy.
// ══════════════════════════════════════════════════════════════════════════════

type RrClass =
  | 'r0SmoothHard' | 'r1Pavement' | 'r2RoughPavement' | 'r3CobblePavers'
  | 'r4Hardpack' | 'r5LooseGravel' | 'r6DirtGround' | 'r7GrassSoftGround'
  | 'r8SandMud' | 'r9TechnicalTrail' | 'unknown'

// Roughness rank per class (from the Flutter rrClassBaseFactors); note cobbles
// (0.78) rank rougher than most gravel — used so "roughen" never downgrades them.
const RR_ROUGHNESS: Record<RrClass, number> = {
  r0SmoothHard: 0.03, r1Pavement: 0.08, r2RoughPavement: 0.24, r3CobblePavers: 0.78,
  r4Hardpack: 0.32, r5LooseGravel: 0.50, r6DirtGround: 0.66, r7GrassSoftGround: 0.72,
  r8SandMud: 0.75, r9TechnicalTrail: 0.90, unknown: 0.35,
}

function rougherRrClass(current: RrClass, candidate: RrClass): RrClass {
  if (candidate === 'unknown') return current
  if (current === 'unknown') return candidate
  return RR_ROUGHNESS[candidate] > RR_ROUGHNESS[current] ? candidate : current
}

function rrClassFromSurface(surface?: string): RrClass {
  switch (surface) {
    case 'asphalt': case 'concrete': case 'paved': return 'r1Pavement'
    case 'chipseal': case 'concrete:lanes': case 'concrete:plates': return 'r2RoughPavement'
    case 'paving_stones': case 'paving_stones:lanes': case 'sett': case 'cobblestone':
    case 'cobblestone:flattened': case 'unhewn_cobblestone': case 'bricks': return 'r3CobblePavers'
    case 'compacted': case 'fine_gravel': return 'r4Hardpack'
    case 'gravel': case 'pebblestone': case 'shells': return 'r5LooseGravel'
    case 'ground': case 'earth': case 'dirt': return 'r6DirtGround'
    case 'grass': case 'woodchips': return 'r7GrassSoftGround'
    case 'sand': case 'mud': return 'r8SandMud'
    case 'rock': case 'stone': case 'bare_rock': return 'r9TechnicalTrail'
    case 'wood': case 'metal': case 'metal_grid': case 'tiles': return 'r2RoughPavement'
    default: return 'unknown'   // includes 'unpaved' and missing
  }
}

function rrClassFromTracktype(tracktype?: string): RrClass | null {
  switch (tracktype) {
    case 'grade1': return 'r1Pavement'
    case 'grade2': return 'r4Hardpack'
    case 'grade3': return 'r5LooseGravel'
    case 'grade4': return 'r6DirtGround'
    case 'grade5': return 'r7GrassSoftGround'
    default: return null
  }
}

function rrClassFromHighwayFallback(highway?: string): RrClass {
  switch (highway) {
    case 'motorway': case 'trunk': case 'primary': case 'secondary': case 'tertiary':
    case 'residential': case 'service': case 'cycleway': return 'r1Pavement'
    case 'track': return 'r5LooseGravel'
    case 'path': case 'bridleway': return 'r6DirtGround'
    case 'footway': return 'r2RoughPavement'
    default: return 'unknown'
  }
}

function isTrailLikeHighway(highway?: string): boolean {
  return highway === 'path' || highway === 'track' || highway === 'bridleway'
    || highway === 'footway' || highway === 'cycleway'
}

function parseMtbScale(value?: string): number | null {
  if (!value) return null
  const m = /^\d+/.exec(value)
  return m ? parseInt(m[0], 10) : null
}

function rrClassFromMtbScaleValue(s: number): RrClass {
  if (s <= 0) return 'r4Hardpack'
  if (s === 1) return 'r5LooseGravel'
  if (s === 2) return 'r6DirtGround'
  if (s === 3) return 'r7GrassSoftGround'
  return 'r9TechnicalTrail'
}
function rrClassFromMtbUphillScaleValue(s: number): RrClass {
  if (s <= 0) return 'unknown'
  if (s === 1) return 'r5LooseGravel'
  if (s === 2) return 'r6DirtGround'
  if (s === 3) return 'r7GrassSoftGround'
  return 'r9TechnicalTrail'
}
function rrClassFromTrailVisibility(v?: string): RrClass | null {
  switch (v) {
    case 'excellent': case 'good': return null
    case 'intermediate': return 'r5LooseGravel'
    case 'bad': return 'r6DirtGround'
    case 'horrible': return 'r7GrassSoftGround'
    case 'no': return 'r8SandMud'
    default: return null
  }
}

function rrClassFromMtbTags(
  mtbScale: number | null, mtbUphill: number | null, mtbImba: number | null,
  trailVisibility: string | undefined, trailLike: boolean,
): { rrClass: RrClass; confidence: number } | null {
  let rr: RrClass = 'unknown'
  let conf = 0
  if (mtbScale !== null) {
    rr = rougherRrClass(rr, rrClassFromMtbScaleValue(mtbScale))
    conf = Math.max(conf, mtbScale >= 4 ? 0.82 : 0.76)
  }
  if (mtbUphill !== null) {
    rr = rougherRrClass(rr, rrClassFromMtbUphillScaleValue(mtbUphill))
    conf = Math.max(conf, mtbUphill >= 3 ? 0.72 : 0.64)
  }
  if (mtbImba !== null) {
    rr = rougherRrClass(rr, rrClassFromMtbScaleValue(mtbImba))   // imba uses same ladder
    conf = Math.max(conf, mtbImba >= 4 ? 0.78 : 0.68)
  }
  const vis = rrClassFromTrailVisibility(trailVisibility)
  if (trailLike && vis) { rr = rougherRrClass(rr, vis); conf = Math.max(conf, 0.55) }
  return rr === 'unknown' ? null : { rrClass: rr, confidence: conf }
}

function rrClassFromSacScale(sac: string | undefined, highway: string | undefined):
  { rrClass: RrClass; confidence: number } | null {
  if (!sac || !isTrailLikeHighway(highway)) return null
  switch (sac) {
    case 'hiking': return { rrClass: 'r5LooseGravel', confidence: 0.52 }
    case 'mountain_hiking': return { rrClass: 'r6DirtGround', confidence: 0.58 }
    case 'demanding_mountain_hiking': return { rrClass: 'r7GrassSoftGround', confidence: 0.62 }
    case 'alpine_hiking': case 'demanding_alpine_hiking': case 'difficult_alpine_hiking':
      return { rrClass: 'r9TechnicalTrail', confidence: 0.70 }
    default: return { rrClass: 'r6DirtGround', confidence: 0.55 }
  }
}

// Smoothness values that mark a paved surface as "rough" in this app's taxonomy.
const ROUGH_SMOOTHNESS = new Set([
  'intermediate', 'bad', 'very_bad', 'horrible', 'very_horrible', 'impassable',
])

// Map the Flutter RrClass 1:1 onto this app's SurfaceCategory taxonomy.
function rrClassToCategory(rr: RrClass, smoothness?: string): SurfaceCategory {
  switch (rr) {
    case 'r0SmoothHard': return 'track'
    case 'r1Pavement':
      return smoothness && ROUGH_SMOOTHNESS.has(smoothness) ? 'rough_asphalt' : 'smooth_asphalt'
    case 'r2RoughPavement': return 'rough_asphalt'
    case 'r3CobblePavers': return 'cobblestone'
    case 'r4Hardpack': return 'gravel_fine'        // Category 1 gravel (packed)
    case 'r5LooseGravel': return 'gravel_coarse'   // Category 2 gravel (loose)
    case 'r6DirtGround': return 'dirt'             // Category 3 (rough natural ground)
    case 'r7GrassSoftGround': return 'grass_soft'  // Category 4
    case 'r8SandMud': return 'sand_mud'
    case 'r9TechnicalTrail': return 'technical_trail'
    default: return 'unknown'
  }
}

// Full classifier: OSM tags → RrClass with confidence (faithful to the Flutter port).
function classifyRrClass(tags: Record<string, string | undefined>):
  { rrClass: RrClass; confidence: number } {
  // normalise (lowercase/trim)
  const n: Record<string, string> = {}
  for (const k in tags) {
    const v = tags[k]?.trim().toLowerCase()
    if (v) n[k.trim().toLowerCase()] = v
  }
  const surface = n['surface']
  const tracktype = n['tracktype']
  const highway = n['highway']

  let rrClass = rrClassFromSurface(surface)
  let confidence = surface == null ? 0.35 : 0.85

  if (rrClass === 'unknown' || !surface || surface === 'unpaved' || surface === 'paved') {
    const fallback = rrClassFromTracktype(tracktype)
    if (fallback) { rrClass = fallback; confidence = !surface ? 0.60 : 0.70 }
    else if (surface === 'paved') { rrClass = 'r1Pavement'; confidence = 0.55 }
    else if (surface === 'unpaved') { rrClass = 'r6DirtGround'; confidence = 0.45 }
    else { rrClass = rrClassFromHighwayFallback(highway); confidence = 0.35 }
  }

  const trailLike = isTrailLikeHighway(highway)
  const mtb = rrClassFromMtbTags(
    parseMtbScale(n['mtb:scale']), parseMtbScale(n['mtb:scale:uphill']),
    parseMtbScale(n['mtb:scale:imba']), n['trail_visibility'], trailLike)
  if (mtb) { rrClass = rougherRrClass(rrClass, mtb.rrClass); confidence = Math.max(confidence, mtb.confidence) }

  const sac = rrClassFromSacScale(n['sac_scale'], highway)
  if (sac) { rrClass = rougherRrClass(rrClass, sac.rrClass); confidence = Math.max(confidence, sac.confidence) }

  return { rrClass, confidence }
}

// Classify OSM tags into the app's SurfaceCategory (+ confidence).
export function classifyOsmCategory(tags: Record<string, string | undefined>):
  { category: SurfaceCategory; confidence: number } {
  const { rrClass, confidence } = classifyRrClass(tags)
  return { category: rrClassToCategory(rrClass, tags['smoothness']?.toLowerCase()), confidence }
}

// ── Tunable category banding ──────────────────────────────────────────────────
// Each segment gets a continuous roughness ∈ [0,1] (RrClass rank + smoothness),
// and a hard/soft flag. The display category is then assigned by threshold bands
// the user can move with sliders. Defaults reproduce the discrete RrClass→category
// mapping (thresholds at the midpoints between the classes' roughness ranks).

const SMOOTHNESS_ROUGHNESS_DELTA: Record<string, number> = {
  excellent: -0.10, good: -0.05, intermediate: 0.0, bad: 0.10,
  very_bad: 0.20, horrible: 0.30, very_horrible: 0.40, impassable: 0.50,
}
const HARD_RR = new Set<RrClass>(['r0SmoothHard', 'r1Pavement', 'r2RoughPavement', 'r3CobblePavers'])

// OSM tags → continuous roughness + hard flag (+ confidence).
export function classifyOsmRoughness(tags: Record<string, string | undefined>):
  { roughness: number; hard: boolean; confidence: number } {
  const { rrClass, confidence } = classifyRrClass(tags)
  const sm = tags['smoothness']?.trim().toLowerCase()
  const delta = sm && sm in SMOOTHNESS_ROUGHNESS_DELTA ? SMOOTHNESS_ROUGHNESS_DELTA[sm] : 0
  const roughness = Math.max(0, Math.min(1, RR_ROUGHNESS[rrClass] + delta))
  return { roughness, hard: HARD_RR.has(rrClass), confidence }
}

export interface ClassThresholds {
  // hard (paved) roughness boundaries, ascending
  smoothRough: number   // smooth_asphalt | rough_asphalt
  roughCobble: number   // rough_asphalt | cobblestone
  // soft (unpaved) roughness boundaries, ascending
  fineCoarse: number    // gravel_fine (Cat1) | gravel_coarse (Cat2)
  coarseDirt: number    // gravel_coarse (Cat2) | dirt (Cat3)
  dirtGrass: number     // dirt (Cat3) | grass_soft (Cat4)
  grassSand: number     // grass_soft (Cat4) | sand_mud
  sandTech: number      // sand_mud | technical_trail
}

// Midpoints between the RrClass roughness ranks → reproduces the discrete mapping.
export const DEFAULT_CLASS_THRESHOLDS: ClassThresholds = {
  smoothRough: 0.16, roughCobble: 0.51,
  fineCoarse: 0.41, coarseDirt: 0.58, dirtGrass: 0.69, grassSand: 0.735, sandTech: 0.825,
}

// Continuous roughness + hard flag → SurfaceCategory, using the given thresholds.
export function categoryFromRoughness(
  roughness: number, hard: boolean, t: ClassThresholds,
): SurfaceCategory {
  if (roughness < 0) return 'unknown'
  if (hard) {
    if (roughness < t.smoothRough) return 'smooth_asphalt'
    if (roughness < t.roughCobble) return 'rough_asphalt'
    return 'cobblestone'
  }
  if (roughness < t.fineCoarse) return 'gravel_fine'
  if (roughness < t.coarseDirt) return 'gravel_coarse'
  if (roughness < t.dirtGrass)  return 'dirt'
  if (roughness < t.grassSand)  return 'grass_soft'
  if (roughness < t.sandTech)   return 'sand_mud'
  return 'technical_trail'
}

// Re-derive each segment's surface from its stored roughness + thresholds (cheap,
// no re-fetch). Returns a new array so React re-renders.
export function applySurfaceThresholds(
  segments: SurfaceSegment[], t: ClassThresholds,
): SurfaceSegment[] {
  return segments.map((seg) => {
    if (seg.roughness === undefined) return seg
    const cat = categoryFromRoughness(seg.roughness, seg.hard ?? false, t)
    return { ...seg, surface: SURFACE_PROPS[cat] }
  })
}

// ── Overpass API query ───────────────────────────────────────────────
interface OverpassElement {
  type: string; id: number
  tags?: Record<string, string>
  geometry?: Array<{ lat: number; lon: number }>
}


// ── Overpass bbox query with adaptive tiling ─────────────────────────────────
//
// Strategy (ROLLEX_POC basis + adaptive tiling):
//   1. Compute track bbox + 0.0025° padding.
//   2. Split into tiles of ≤ TILE_DEG × TILE_DEG (≈ 11 km × 8 km at 45°N).
//      Small bboxes → 1 tile; long/wide routes → several tiles in parallel.
//   3. Each tile uses a highway-type filter to limit returned ways
//      (avoids fetching motorway_junctions, construction, etc.).
//   4. Results are deduplicated by way ID and cached by the full bbox key.
//
// Why tiling fixes the 504: Overpass's gateway itself times out before the
// [timeout:N] hint fires for large bboxes. Tiles of 0.12° never hit that limit.

const TILE_DEG      = 0.12   // ≈ 13 km lat × 9 km lon — safe Overpass tile size
const TILE_PARALLEL = 4      // max concurrent tile requests

// Regex filter keeps only highway types relevant to cycling.
// Excluding: motorway_junction, construction, proposed, platform, …
const HW_FILTER =
  '["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|' +
  'residential|living_street|service|track|path|cycleway|footway|bridleway|road)$"]'

function bboxCacheKey(bbox: [number, number, number, number]): string {
  return 'osm:v1:' + bbox.map(v => v.toFixed(3)).join(',')
}

/** Fetch one tile via the SvelteKit proxy (overpass-api.de → kumi.systems fallback).
 *  Direct Overpass POST is intentionally skipped — browsers block cross-origin
 *  requests to overpass-api.de (no CORS headers), so the try/catch always falls
 *  through and only adds latency.
 */
async function fetchTile(tile: [number, number, number, number]): Promise<OverpassElement[]> {
  const [s, w, n, e] = tile
  const query = `[out:json][timeout:30];\nway${HW_FILTER}(${s},${w},${n},${e});\nout geom;`

  const res = await fetch('/api/osm/overpass', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query }),
  })
  if (!res.ok) {
    const text = await res.text()
    let msg = `Overpass API Fehler: ${res.status}`
    try { msg = JSON.parse(text)?.message ?? msg } catch {}
    throw new Error(msg)
  }
  return ((await res.json()) as { elements: OverpassElement[] }).elements ?? []
}

/**
 * Fetch all OSM highway ways within the track bbox.
 * Auto-tiles large bboxes into TILE_DEG chunks and queries them in parallel.
 * Result is deduplicated by way ID and cached in IndexedDB by bbox.
 */
async function queryOverpass(
  bbox: [number, number, number, number],
  onProgress?: ProgressFn,
): Promise<OverpassElement[]> {
  const key = bboxCacheKey(bbox)
  const cached = await osmCacheGet<OverpassElement[]>(key)
  if (cached) {
    onProgress?.('OSM-Daten aus Cache geladen', 50)
    return cached
  }

  // Build tile grid
  const [s, w, n, e] = bbox
  const latSpan = n - s, lonSpan = e - w
  const rows = Math.max(1, Math.ceil(latSpan / TILE_DEG))
  const cols = Math.max(1, Math.ceil(lonSpan / TILE_DEG))
  const tiles: Array<[number, number, number, number]> = []
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      tiles.push([
        s + latSpan * r / rows,       w + lonSpan * c / cols,
        s + latSpan * (r + 1) / rows, w + lonSpan * (c + 1) / cols,
      ])
    }
  }

  const elementMap = new Map<number, OverpassElement>()
  for (let i = 0; i < tiles.length; i += TILE_PARALLEL) {
    const batch = tiles.slice(i, i + TILE_PARALLEL)
    const done = Math.min(i + TILE_PARALLEL, tiles.length)
    onProgress?.(
      tiles.length === 1
        ? 'OSM-Daten werden geladen'
        : `OSM-Daten werden geladen (${done}/${tiles.length})`,
      25 + Math.round(25 * done / tiles.length),
    )
    const results = await Promise.all(batch.map(fetchTile))
    for (const els of results) for (const el of els) elementMap.set(el.id, el)
  }

  const elements = [...elementMap.values()]
  await osmCacheSet(key, elements)
  return elements
}

// ══════════════════════════════════════════════════════════════════════════════
// MAP-MATCHING (HMM / Viterbi)
//
// Problem: matching each GPS point independently to its nearest OSM way lets GPS
// jitter snap short stretches onto parallel/crossing ways with a different surface
// tag → spurious mis-categorized segments.
//
// Fix: find the most likely *coherent sequence* of way IDs for the whole track
// (Newson & Krumm 2009 HMM map-matching — the approach behind Valhalla/OSRM).
//   • Emission cost   = how far the point is from a candidate way (Gaussian).
//   • Transition cost = 0 to stay on the same way, small to step onto a CONNECTED
//                       way (shares an OSM node = a real junction), large to jump
//                       to a disconnected parallel way.
// A 1–2 point GPS excursion can't overcome the jump penalty, so it is ignored;
// a sustained real divergence still switches. The chosen way ID per point then
// drives the surface category.
// ══════════════════════════════════════════════════════════════════════════════

const MM = {
  SIGMA_M:        18,   // GPS noise scale (m) for emission cost
  RADIUS_M:       40,   // max point→way distance to be a candidate (m)
  UNKNOWN_DIST_M: 55,   // effective distance of the "off-network" state (m)
  T_SAME:         0,    // stay on same way id
  T_CONNECTED:    1.5,  // move to a way sharing a node (junction)
  T_JUMP:         7.0,  // jump to a disconnected way (parallel road) — expensive
  T_UNKNOWN:      3.5,  // enter/leave the off-network state
  MIN_SEG_M:      12,   // absorb slivers shorter than this into neighbours
}

interface Pt2 { x: number; y: number }
interface ProjWay {
  id: number
  tags: Record<string, string>
  pts: Pt2[]
}

// Local equirectangular projection to metres (accurate for a single ride bbox).
function makeProjector(meanLat: number, meanLon: number) {
  const mPerDegLat = 111320
  const mPerDegLon = 111320 * Math.cos((meanLat * Math.PI) / 180)
  return (lat: number, lon: number): Pt2 => ({
    x: (lon - meanLon) * mPerDegLon,
    y: (lat - meanLat) * mPerDegLat,
  })
}

// Distance (m) from point to segment a→b, plus nothing else needed.
function ptSegMeters(p: Pt2, a: Pt2, b: Pt2): number {
  const dx = b.x - a.x, dy = b.y - a.y
  if (dx === 0 && dy === 0) return Math.hypot(p.x - a.x, p.y - a.y)
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// Min distance (m) from a point to a whole way polyline.
function ptWayMeters(p: Pt2, way: ProjWay): number {
  let best = Infinity
  for (let i = 0; i < way.pts.length - 1; i++) {
    const d = ptSegMeters(p, way.pts[i], way.pts[i + 1])
    if (d < best) best = d
  }
  return best
}

// ── Spatial grid index ────────────────────────────────────────────────────────
// Partition projWays into a 2-D grid of GRID_M × GRID_M metre cells.
// For each GPS point we look up only the 3 × 3 neighbourhood (~9 cells) instead
// of all ways → candidate search drops from O(W) to O(local_ways) per point.
const GRID_M = 100   // cell size in metres

interface SpatialGrid {
  cells: Map<string, number[]>   // encoded cell key → [wayIndex, ...]
  originX: number
  originY: number
}

function buildSpatialGrid(projWays: ProjWay[]): SpatialGrid {
  let minX = Infinity, minY = Infinity
  for (const w of projWays) for (const p of w.pts) {
    if (p.x < minX) minX = p.x
    if (p.y < minY) minY = p.y
  }
  const originX = minX - GRID_M
  const originY = minY - GRID_M

  const cells = new Map<number, number[]>()
  const encode = (cx: number, cy: number) => `${cx},${cy}`

  for (let wi = 0; wi < projWays.length; wi++) {
    const w = projWays[wi]
    let wMinX = Infinity, wMinY = Infinity, wMaxX = -Infinity, wMaxY = -Infinity
    for (const p of w.pts) {
      if (p.x < wMinX) wMinX = p.x; if (p.x > wMaxX) wMaxX = p.x
      if (p.y < wMinY) wMinY = p.y; if (p.y > wMaxY) wMaxY = p.y
    }
    // Expand bbox by RADIUS_M so a point in cell C finds all ways that could be
    // within RADIUS_M of any point in that cell.
    const r = MM.RADIUS_M
    const cx0 = Math.floor((wMinX - r - originX) / GRID_M)
    const cx1 = Math.floor((wMaxX + r - originX) / GRID_M)
    const cy0 = Math.floor((wMinY - r - originY) / GRID_M)
    const cy1 = Math.floor((wMaxY + r - originY) / GRID_M)
    for (let cx = cx0; cx <= cx1; cx++) {
      for (let cy = cy0; cy <= cy1; cy++) {
        const k = encode(cx, cy)
        const arr = cells.get(k)
        if (arr) arr.push(wi)
        else cells.set(k, [wi])
      }
    }
  }
  return { cells, originX, originY }
}

/** Return all projWay indices whose cells overlap the point's cell. */
function nearbyWayIndices(p: Pt2, grid: SpatialGrid): number[] {
  const cx = Math.floor((p.x - grid.originX) / GRID_M)
  const cy = Math.floor((p.y - grid.originY) / GRID_M)
  // single-cell lookup: the bbox expansion in buildSpatialGrid already ensures
  // every way within RADIUS_M is in this cell.
  const k = `${cx},${cy}`
  return grid.cells.get(k) ?? []
}

// Build way connectivity from shared OSM nodes. Overpass `out geom` gives each
// node's lat/lon; ways that meet at a junction share byte-identical coordinates,
// so hashing rounded coordinates recovers the graph without needing node IDs.
export function buildAdjacency(ways: OverpassElement[]): Map<number, Set<number>> {
  const coordToWays = new Map<string, number[]>()
  for (const w of ways) {
    if (!w.geometry) continue
    for (const g of w.geometry) {
      const key = `${g.lat.toFixed(7)},${g.lon.toFixed(7)}`
      const arr = coordToWays.get(key)
      if (arr) { if (!arr.includes(w.id)) arr.push(w.id) }
      else coordToWays.set(key, [w.id])
    }
  }
  const adj = new Map<number, Set<number>>()
  for (const ids of coordToWays.values()) {
    if (ids.length < 2) continue
    for (const a of ids) {
      let set = adj.get(a)
      if (!set) { set = new Set(); adj.set(a, set) }
      for (const b of ids) if (b !== a) set.add(b)
    }
  }
  return adj
}

// One Viterbi candidate (a way near the point, or the off-network state id=-1).
interface Cand { wayId: number; emit: number }

// Run HMM map-matching. Returns the matched way id per track point (-1 = none).
export function mapMatch(
  pts: LatLon[],
  ways: OverpassElement[],
  adj: Map<number, Set<number>>,
): number[] {
  if (pts.length === 0) return []
  const meanLat = pts.reduce((s, p) => s + p.lat, 0) / pts.length
  const meanLon = pts.reduce((s, p) => s + p.lon, 0) / pts.length
  const proj = makeProjector(meanLat, meanLon)

  const projWays: ProjWay[] = ways
    .filter(w => w.geometry && w.geometry.length >= 2)
    .map(w => ({
      id: w.id,
      tags: w.tags ?? {},
      pts: w.geometry!.map(g => proj(g.lat, g.lon)),
    }))

  const UNK_EMIT = 0.5 * (MM.UNKNOWN_DIST_M / MM.SIGMA_M) ** 2

  // Build spatial grid for fast candidate lookup (replaces O(W) linear scan).
  const grid = buildSpatialGrid(projWays)

  // Candidate ways per point — only ways in the local grid cell, not all ways.
  const candsPerPt: Cand[][] = pts.map((pt) => {
    const p = proj(pt.lat, pt.lon)
    const cands: Cand[] = []
    const seen = new Set<number>()
    for (const wi of nearbyWayIndices(p, grid)) {
      if (seen.has(wi)) continue
      seen.add(wi)
      const w = projWays[wi]
      const d = ptWayMeters(p, w)
      if (d <= MM.RADIUS_M) cands.push({ wayId: w.id, emit: 0.5 * (d / MM.SIGMA_M) ** 2 })
    }
    cands.push({ wayId: -1, emit: UNK_EMIT })   // off-network fallback
    return cands
  })

  const transition = (from: number, to: number): number => {
    if (from === -1 || to === -1) return MM.T_UNKNOWN
    if (from === to) return MM.T_SAME
    return adj.get(from)?.has(to) ? MM.T_CONNECTED : MM.T_JUMP
  }

  // Viterbi forward pass with backpointers
  const N = pts.length
  let prevCost: number[] = candsPerPt[0].map(c => c.emit)
  const back: number[][] = [candsPerPt[0].map(() => -1)]

  for (let i = 1; i < N; i++) {
    const cands = candsPerPt[i]
    const prevCands = candsPerPt[i - 1]
    const cost: number[] = new Array(cands.length).fill(Infinity)
    const bp: number[] = new Array(cands.length).fill(0)
    for (let j = 0; j < cands.length; j++) {
      let bestK = 0, bestC = Infinity
      for (let k = 0; k < prevCands.length; k++) {
        const c = prevCost[k] + transition(prevCands[k].wayId, cands[j].wayId)
        if (c < bestC) { bestC = c; bestK = k }
      }
      cost[j] = bestC + cands[j].emit
      bp[j] = bestK
    }
    prevCost = cost
    back.push(bp)
  }

  // Backtrack
  let j = 0, bestC = Infinity
  for (let k = 0; k < prevCost.length; k++) if (prevCost[k] < bestC) { bestC = prevCost[k]; j = k }
  const out: number[] = new Array(N)
  for (let i = N - 1; i >= 0; i--) {
    out[i] = candsPerPt[i][j].wayId
    j = back[i][j]
  }
  return out
}

function segmentsFromMatchedWayIds(
  pts: TrackSegment['points'],
  matchedWayIds: number[],
  wayById: Map<number, OverpassElement>,
): SurfaceSegment[] {
  const classCache = new Map<number, { roughness: number; hard: boolean; confidence: number }>()
  const classify = (id: number) => {
    let c = classCache.get(id)
    if (!c) {
      const way = id >= 0 ? wayById.get(id) : undefined
      c = way ? classifyOsmRoughness(way.tags ?? {})
              : { roughness: -1, hard: false, confidence: 0.1 }
      classCache.set(id, c)
    }
    return c
  }

  // Aggregate measured IRI from per-point sensor readings over a segment.
  // Returns undefined when no points in the range carry an IRI value.
  const aggregateIri = (startIdx: number, endIdx: number):
    { measuredIri: number; iriSampleCount: number } | undefined => {
    let wSum = 0, wDist = 0
    for (let i = startIdx; i <= endIdx; i++) {
      const pt = pts[i]
      if (pt.iri === undefined) continue
      // Weight each reading by its share of cumulative distance
      const segDist = i > 0 ? (pt.distance ?? 0) - (pts[i - 1].distance ?? 0) : 0
      const w = Math.max(segDist, 0.5)  // floor at 0.5 m so isolated readings count
      wSum += pt.iri * w
      wDist += w
    }
    if (wDist < 0.5) return undefined
    return { measuredIri: wSum / wDist, iriSampleCount: Math.round(wDist) }
  }

  const segOf = (startIdx: number, endIdx: number): SurfaceSegment => {
    const id = matchedWayIds[startIdx]
    const cls = classify(id)
    const way = id >= 0 ? wayById.get(id) : undefined
    const iriAgg = aggregateIri(startIdx, endIdx)
    return {
      startIdx, endIdx,
      distanceMeters: Math.max(1, (pts[endIdx].distance ?? 0) - (pts[startIdx].distance ?? 0)),
      surface: SURFACE_PROPS.unknown,
      roughness: cls.roughness,
      hard: cls.hard,
      osmConfidence: Math.max(0.05, Math.min(1, cls.confidence)),
      osmWayId: way?.id,
      osmHighway: way?.tags?.['highway'],
      measuredIri: iriAgg?.measuredIri,
      iriSampleCount: iriAgg?.iriSampleCount,
    }
  }

  const segments: SurfaceSegment[] = []
  let segStart = 0
  for (let i = 1; i <= pts.length; i++) {
    if (i === pts.length || matchedWayIds[i] !== matchedWayIds[segStart]) {
      segments.push(segOf(segStart, i - 1))
      segStart = i
    }
  }
  return segments
}

// ── Main export ──────────────────────────────────────────────────────
export type ProgressFn = (phase: string, pct: number) => void

export async function analyzeSurfaces(
  track: TrackSegment,
  onProgress?: ProgressFn,
): Promise<SurfaceSegment[]> {
  const pts = track.points
  onProgress?.('Strecke wird vorbereitet', 10)

  const lats = pts.map(p => p.lat)
  const lons = pts.map(p => p.lon)
  const bbox: [number, number, number, number] = [
    Math.min(...lats) - 0.0025,
    Math.min(...lons) - 0.0025,
    Math.max(...lats) + 0.0025,
    Math.max(...lons) + 0.0025,
  ]

  onProgress?.('OSM-Oberflächendaten werden geladen', 25)
  const ways = await queryOverpass(bbox, onProgress)
  const wayById = new Map<number, OverpassElement>(ways.map(w => [w.id, w]))

  onProgress?.('Wegenetz wird aufgebaut', 55)
  const adj = buildAdjacency(ways)

  onProgress?.('GPS-Track wird auf Wege gematcht', 70)
  const matchedWayIds = mapMatch(pts, ways, adj)

  onProgress?.('Oberflächen-Segmente werden gebildet', 90)
  let segments = segmentsFromMatchedWayIds(pts, matchedWayIds, wayById)
  segments = mergeSlivers(segments, pts)
  segments = fillShortUnknownGaps(segments, pts)
  segments = applySurfaceThresholds(segments, DEFAULT_CLASS_THRESHOLDS)
  onProgress?.('Fertig', 100)
  return segments
}

// Merge way-segments shorter than MIN_SEG_M into the longer adjacent segment
// (extending its index range), eliminating few-metre slivers from residual jitter.
function mergeSlivers(segs: SurfaceSegment[], pts: TrackSegment['points']): SurfaceSegment[] {
  let changed = true
  while (changed && segs.length > 1) {
    changed = false
    for (let i = 0; i < segs.length; i++) {
      if (segs[i].distanceMeters >= MM.MIN_SEG_M) continue
      const prev = i > 0 ? segs[i - 1] : null
      const next = i < segs.length - 1 ? segs[i + 1] : null
      if (!prev && !next) break
      const intoPrev = !!prev && (!next || prev.distanceMeters >= next.distanceMeters)
      const target = intoPrev ? prev! : next!
      if (intoPrev) target.endIdx = segs[i].endIdx
      else target.startIdx = segs[i].startIdx
      target.distanceMeters = Math.max(1,
        (pts[target.endIdx].distance ?? 0) - (pts[target.startIdx].distance ?? 0))
      segs.splice(i, 1)
      changed = true
      break
    }
  }
  return segs
}

function fillShortUnknownGaps(segs: SurfaceSegment[], pts: TrackSegment['points']): SurfaceSegment[] {
  const MAX_UNKNOWN_GAP_M = 60
  const out = segs.map(seg => ({ ...seg }))
  for (let i = 1; i < out.length - 1; i++) {
    const seg = out[i]
    if (seg.roughness !== undefined && seg.roughness >= 0) continue
    if (seg.distanceMeters > MAX_UNKNOWN_GAP_M) continue

    const prev = out[i - 1]
    const next = out[i + 1]
    const compatibleNeighbours =
      prev.roughness !== undefined && prev.roughness >= 0 &&
      next.roughness !== undefined && next.roughness >= 0 &&
      (prev.surface.category === next.surface.category || prev.osmWayId === next.osmWayId)

    if (!compatibleNeighbours) continue

    seg.roughness = (prev.roughness! + next.roughness!) / 2
    seg.hard = prev.hard === next.hard ? prev.hard : prev.hard
    seg.osmConfidence = Math.min(0.45, prev.osmConfidence ?? 0.45, next.osmConfidence ?? 0.45)
    seg.osmHighway = prev.osmHighway ?? next.osmHighway
    seg.osmWayId = prev.osmWayId ?? next.osmWayId
    seg.distanceMeters = Math.max(1,
      (pts[seg.endIdx].distance ?? 0) - (pts[seg.startIdx].distance ?? 0))
  }
  return out
}

// ── Summary helper ───────────────────────────────────────────────────
export function buildSurfaceSummary(segments: SurfaceSegment[]) {
  const summary: Partial<Record<SurfaceCategory, number>> = {}
  for (const seg of segments) {
    const cat = seg.surface.category
    summary[cat] = (summary[cat] ?? 0) + seg.distanceMeters
  }
  return summary as Record<SurfaceCategory, number>
}

// ══════════════════════════════════════════════════════════════════════════════
// PERFORMANCE PREDICTOR — Physics engine
//
// Core model:  P_wheel = F_roll·v + F_grav·v + F_aero·v³
//   F_roll = Crr · m · g · cos θ
//   F_grav = m · g · sin θ        (positive = uphill)
//   F_aero = ½ · ρ · CdA · v²
//
// Power→Speed via bisection (robust on steep descents, unlike Newton-Raphson
// which can collapse when the linear term goes negative).
// ══════════════════════════════════════════════════════════════════════════════

import type {
  PacingIntensity,
  PacingPlan,
  PacingPlanPoint,
  PacingPoint,
  SurfaceCategory,
  SurfaceSegment,
  TrackSegment,
} from './types'

const G              = 9.81
const DRIVETRAIN_EFF = 0.975      // crank → wheel power
const MAX_SPEED_MS   = 70 / 3.6  // cap at 70 km/h (riders brake on descents)
const ZONE_BOUNDS    = [0.55, 0.75, 0.90, 1.05, 1.20]

// ── Core solver ───────────────────────────────────────────────────────────────

/**
 * Given crank power [W] and road grade, returns steady-state speed [m/s].
 * Uses bisection — unconditionally robust on negative-slope descents.
 */
export function speedForPower(
  powerW    : number,
  gradeRatio: number,  // e.g. 0.05 = 5 % uphill, −0.08 = 8 % descent
  crrEff    : number,  // effective rolling-resistance coefficient
  totalMassKg: number,
  cdA       : number,  // m²
  rhoAir    : number,  // kg/m³
): number {
  const wheelW   = Math.max(1, powerW * DRIVETRAIN_EFF)
  const required = (v: number) =>
    crrEff * totalMassKg * G * v
    + totalMassKg * G * gradeRatio * v
    + 0.5 * cdA * rhoAir * v ** 3
  let lo = 0.2, hi = MAX_SPEED_MS
  for (let i = 0; i < 50; i++) {
    const mid = (lo + hi) / 2
    if (required(mid) <= wheelW) lo = mid; else hi = mid
  }
  return lo
}

// ── Geometry helpers ──────────────────────────────────────────────────────────

function haversineM(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R  = 6_371_000
  const φ1 = lat1 * Math.PI / 180, φ2 = lat2 * Math.PI / 180
  const Δφ = (lat2 - lat1) * Math.PI / 180
  const Δλ = (lon2 - lon1) * Math.PI / 180
  const a  = Math.sin(Δφ / 2) ** 2 + Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) ** 2
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

/** Centered moving average over ±half elements (simple GPS-noise smoother). */
export function smooth(arr: number[], windowSize: number): number[] {
  const half = Math.floor(windowSize / 2)
  return arr.map((_, i) => {
    let s = 0, n = 0
    for (let j = Math.max(0, i - half); j <= Math.min(arr.length - 1, i + half); j++) {
      s += arr[j]; n++
    }
    return s / n
  })
}

/**
 * Build per-segment grade array from a TrackSegment.
 * Returns n−1 values (one per consecutive point pair), smoothed over ~15 samples
 * to suppress GPS elevation noise.
 */
export function buildGrades(track: TrackSegment): { grades: number[]; cumDists: number[] } {
  const pts = track.points
  const cumDists: number[] = [0]
  const rawGrades: number[] = []

  for (let i = 1; i < pts.length; i++) {
    const d     = haversineM(pts[i-1].lat, pts[i-1].lon, pts[i].lat, pts[i].lon)
    const dElev = (pts[i].elevation ?? 0) - (pts[i-1].elevation ?? 0)
    cumDists.push(cumDists[i-1] + d)
    rawGrades.push(d > 0.5 ? Math.max(-0.5, Math.min(0.5, dElev / d)) : 0)
  }

  return { grades: smooth(rawGrades, 15), cumDists }
}

// ── Simulation types ──────────────────────────────────────────────────────────

export interface PhysicsParams {
  totalMassKg: number
  cdA        : number   // m²
  crrEff     : number   // effective Crr (route-averaged or preset)
  rhoAir     : number   // kg/m³ (use computeAirDensity() for altitude/temp)
}

export interface SimPoint {
  distKm    : number   // cumulative distance [km]
  elevM     : number   // elevation [m]
  gradePct  : number   // gradient [%]
  powerW    : number   // applied crank power [W]
  speedKmh  : number
  cumTimeSec: number   // cumulative time [s]
}

export interface SimResult {
  points        : SimPoint[]
  totalTimeSec  : number
  totalDistKm   : number
  totalElevGainM: number
  avgSpeedKmh   : number
  avgPowerW     : number
  maxPowerW     : number
  maxSpeedKmh   : number
  minSpeedKmh   : number
}

// ── Core simulation ───────────────────────────────────────────────────────────

/**
 * Run the performance simulation.
 * `powers` must have length = track.points.length − 1 (one per segment).
 */
export function simulate(
  track  : TrackSegment,
  powers : number[],
  params : PhysicsParams,
): SimResult {
  const pts = track.points
  if (pts.length < 2) throw new Error('Track enthält zu wenig GPS-Punkte')

  const { grades, cumDists } = buildGrades(track)

  const simPoints: SimPoint[] = []
  let cumTime = 0, totalElevGain = 0, sumPower = 0
  let maxPower = 0, maxSpeed = 0, minSpeed = Infinity

  for (let i = 0; i < grades.length; i++) {
    const grade  = grades[i]
    const dist   = cumDists[i+1] - cumDists[i]
    const powerW = powers[i] ?? powers[powers.length - 1] ?? 200
    const v      = speedForPower(powerW, grade, params.crrEff, params.totalMassKg, params.cdA, params.rhoAir)
    const timeS  = dist > 0 ? dist / v : 0

    cumTime      += timeS
    sumPower     += powerW
    if (powerW > maxPower)  maxPower = powerW
    if (v * 3.6 > maxSpeed) maxSpeed = v * 3.6
    if (v * 3.6 < minSpeed) minSpeed = v * 3.6

    const dElev = (pts[i+1].elevation ?? 0) - (pts[i].elevation ?? 0)
    if (dElev > 0) totalElevGain += dElev

    simPoints.push({
      distKm    : cumDists[i+1] / 1000,
      elevM     : pts[i+1].elevation ?? 0,
      gradePct  : grade * 100,
      powerW,
      speedKmh  : v * 3.6,
      cumTimeSec: cumTime,
    })
  }

  const totalDistKm = cumDists[cumDists.length - 1] / 1000
  const avgSpeed    = cumTime > 0 ? (totalDistKm * 1000) / cumTime * 3.6 : 0

  return {
    points        : simPoints,
    totalTimeSec  : cumTime,
    totalDistKm,
    totalElevGainM: totalElevGain,
    avgSpeedKmh   : avgSpeed,
    avgPowerW     : simPoints.length > 0 ? sumPower / simPoints.length : 0,
    maxPowerW     : maxPower,
    maxSpeedKmh   : maxSpeed,
    minSpeedKmh   : minSpeed === Infinity ? 0 : minSpeed,
  }
}

// ── Power profiles ────────────────────────────────────────────────────────────

/** Constant power for all segments */
export function constantPower(n: number, watts: number): number[] {
  return new Array(n).fill(watts)
}

export type StrategyType = 'constant' | 'mountain' | 'negative_split'

/**
 * Strategy-based pacing. Normalises so the mean equals `avgWatts`.
 * • constant       — flat power everywhere
 * • mountain       — +2.5× gradient boost on climbs, −35 % on descents
 * • negative_split — first half at 94 %, second half at 106 %
 */
export function strategyPower(
  grades  : number[],
  avgWatts: number,
  strategy: StrategyType,
): number[] {
  if (strategy === 'constant') return grades.map(() => avgWatts)

  let raw: number[]

  if (strategy === 'mountain') {
    raw = grades.map(g => {
      if (g > 0.02)  return avgWatts * (1 + 2.5 * Math.min(g, 0.10)) // max +25 %
      if (g < -0.02) return avgWatts * 0.65                           // descents: recover
      return avgWatts
    })
  } else {
    const half = Math.floor(grades.length / 2)
    raw = grades.map((_, i) => i < half ? avgWatts * 0.94 : avgWatts * 1.06)
  }

  // Normalise so mean exactly equals avgWatts
  const mean = raw.reduce((a, b) => a + b, 0) / raw.length
  if (mean < 1) return grades.map(() => avgWatts)
  return raw.map(p => Math.max(20, (p / mean) * avgWatts))
}

/**
 * Interpolate power from a reference FIT file onto the target track's distance axis.
 * FIT power is scaled by `scaleFactor` (e.g. 0.9 = ride at 90 % of reference effort).
 * Distance scaling: entire FIT distance → entire target distance (proportional mapping).
 */
export function fitInterpolatedPower(
  fitTrack   : TrackSegment,
  targetTrack: TrackSegment,
  scaleFactor= 1.0,
): number[] {
  // Extract (cumDist, power) pairs from FIT
  const fitPts = fitTrack.points
  const pairs: Array<{ d: number; p: number }> = []
  let cumD = 0
  for (let i = 0; i < fitPts.length; i++) {
    if (i > 0) cumD += haversineM(fitPts[i-1].lat, fitPts[i-1].lon, fitPts[i].lat, fitPts[i].lon)
    // Use stored distance if available, otherwise accumulated haversine
    const d = fitPts[i].distance ?? cumD
    if (fitPts[i].power != null) pairs.push({ d, p: fitPts[i].power! })
  }
  if (pairs.length < 2) return new Array(targetTrack.points.length - 1).fill(200 * scaleFactor)

  const fitTotalDist    = pairs[pairs.length - 1].d
  const { cumDists }    = buildGrades(targetTrack)
  const targetTotalDist = cumDists[cumDists.length - 1]
  const distRatio       = fitTotalDist / Math.max(targetTotalDist, 1)

  let fi = 0
  const result: number[] = []
  for (let i = 0; i < cumDists.length - 1; i++) {
    const midDist = (cumDists[i] + cumDists[i+1]) / 2
    const fitD    = midDist * distRatio
    while (fi + 1 < pairs.length - 1 && pairs[fi + 1].d < fitD) fi++
    const a = pairs[fi], b = pairs[Math.min(fi + 1, pairs.length - 1)]
    const t = b.d > a.d ? (fitD - a.d) / (b.d - a.d) : 0
    result.push(Math.max(0, (a.p + t * (b.p - a.p)) * scaleFactor))
  }
  return result
}

// ── Utilities ────────────────────────────────────────────────────────────────

export function formatDuration(totalS: number): string {
  if (!isFinite(totalS) || totalS <= 0) return '–'
  const h   = Math.floor(totalS / 3600)
  const m   = Math.floor((totalS % 3600) / 60)
  const s   = Math.floor(totalS % 60)
  return h > 0
    ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
    : `${m}:${String(s).padStart(2, '0')}`
}

/** Thin an array to at most maxN evenly-spaced elements. */
export function downsample<T>(arr: T[], maxN: number): T[] {
  if (arr.length <= maxN) return arr
  const step = arr.length / maxN
  return Array.from({ length: maxN }, (_, i) => arr[Math.round(i * step)])
}

/** Find significant climbs (≥ 50 m gain, avg grade ≥ 3 %). */
export interface Climb {
  startKm : number
  endKm   : number
  gainM   : number
  distKm  : number
  avgGradePct: number
  timeSec : number
  avgSpeedKmh: number
}

export function detectClimbs(pts: SimPoint[], minGainM = 50, minGradePct = 3): Climb[] {
  const climbs: Climb[] = []
  let inClimb = false
  let startIdx = 0

  for (let i = 0; i < pts.length; i++) {
    const grad = pts[i].gradePct
    if (!inClimb && grad >= minGradePct) { inClimb = true; startIdx = i }
    if (inClimb && (grad < 0.5 || i === pts.length - 1)) {
      const end = i - 1
      if (end > startIdx) {
        const gainM    = Math.max(0, pts[end].elevM - pts[startIdx].elevM)
        const distKm   = pts[end].distKm - pts[startIdx].distKm
        const timeSec  = pts[end].cumTimeSec - pts[startIdx].cumTimeSec
        const avgGrade = distKm > 0 ? (gainM / (distKm * 1000)) * 100 : 0
        if (gainM >= minGainM && avgGrade >= minGradePct) {
          climbs.push({
            startKm    : pts[startIdx].distKm,
            endKm      : pts[end].distKm,
            gainM,
            distKm,
            avgGradePct: avgGrade,
            timeSec,
            avgSpeedKmh: distKm > 0 && timeSec > 0 ? distKm / (timeSec / 3600) : 0,
          })
        }
      }
      inClimb = false
    }
  }

  return climbs.sort((a, b) => b.gainM - a.gainM).slice(0, 6)
}

function average(arr: number[]): number | undefined {
  if (arr.length === 0) return undefined
  return arr.reduce((a, b) => a + b, 0) / arr.length
}

export function estimateCdA(track: TrackSegment): number {
  const pts = track.points.filter(p => p.power !== undefined && (p.speed ?? 0) > 2)
  if (pts.length < 20) return 0.32

  const samples = pts.map(p => {
    const v = p.speed!
    return (p.power! * DRIVETRAIN_EFF) / (0.5 * 1.225 * v ** 3)
  }).filter(x => x > 0.1 && x < 2.0)

  if (samples.length === 0) return 0.32
  samples.sort((a, b) => a - b)
  return samples[Math.floor(samples.length / 2)]
}

export function buildPacingData(track: TrackSegment, sampleEveryM = 500): PacingPoint[] {
  const points: PacingPoint[] = []
  const pts = track.points
  let nextSampleDist = 0

  for (let i = 1; i < pts.length; i++) {
    const dist = pts[i].distance ?? 0
    if (dist < nextSampleDist && i !== pts.length - 1) continue
    nextSampleDist += sampleEveryM

    const prevPts = pts.slice(Math.max(0, i - 5), i + 1)
    const avgPower = average(prevPts.map(p => p.power).filter((p): p is number => typeof p === 'number'))

    points.push({
      distanceKm: dist / 1000,
      powerW: avgPower ?? 0,
      speedKmh: (pts[i].speed ?? 0) * 3.6,
      elevationM: pts[i].elevation,
    })
  }

  return points
}

export function computeOptimalPacing(
  track: TrackSegment,
  targetAvgPowerW: number,
  crrEff: number,
  totalMassKg: number,
  cdA: number,
  rhoAir = 1.225,
): PacingPoint[] {
  const pts = track.points
  const pacing: PacingPoint[] = []

  for (let i = 1; i < pts.length; i++) {
    const dist = pts[i].distance ?? 0
    if (dist % 500 > 100 && i !== pts.length - 1) continue

    const segDist = haversineM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon)
    const grade = segDist > 0 ? (pts[i].elevation - pts[i - 1].elevation) / segDist : 0
    const gradeBonus = -grade * 200
    const optPower = Math.max(50, Math.min(targetAvgPowerW * 1.8, targetAvgPowerW + gradeBonus))
    const optSpeed = speedForPower(optPower, grade, crrEff, totalMassKg, cdA, rhoAir)

    pacing.push({
      distanceKm: dist / 1000,
      powerW: pts[i].power ?? 0,
      speedKmh: (pts[i].speed ?? 0) * 3.6,
      elevationM: pts[i].elevation,
      optimalPowerW: Math.round(optPower),
      optimalSpeedKmh: Math.round(optSpeed * 36) / 10,
    })
  }

  return pacing
}

export function powerZone(pctFtp: number): number {
  let zone = 1
  for (const bound of ZONE_BOUNDS) {
    if (pctFtp >= bound) zone++
    else break
  }
  return zone
}

interface PacingSeg {
  distM: number
  cumDistM: number
  elevM: number
  grade: number
  crr: number
}

export function buildPacingSegments(
  track: TrackSegment,
  surfaces: SurfaceSegment[] | null,
  crrForSurface: (category: SurfaceCategory, iri: number) => number,
): PacingSeg[] {
  const pts = track.points
  const n = pts.length
  if (n < 2) return []

  const dist = pts.map(p => p.distance ?? 0)
  const ele = pts.map(p => p.elevation)
  const smoothEle = ele.map((_, i) => {
    let sum = ele[i], count = 1
    for (let j = i - 1; j >= 0 && dist[i] - dist[j] <= 50; j--) { sum += ele[j]; count++ }
    for (let j = i + 1; j < n && dist[j] - dist[i] <= 50; j++) { sum += ele[j]; count++ }
    return sum / count
  })

  const catAt = new Array<SurfaceCategory>(n).fill('unknown')
  const iriAt = new Array<number>(n).fill(3)
  if (surfaces) {
    for (const seg of surfaces) {
      for (let i = seg.startIdx; i <= seg.endIdx && i < n; i++) {
        catAt[i] = seg.surface.category
        iriAt[i] = seg.measuredIri ?? seg.surface.iri
      }
    }
  }

  const segs: PacingSeg[] = []
  for (let i = 1; i < n; i++) {
    const d = dist[i] - dist[i - 1]
    if (d <= 0) continue
    const grade = Math.max(-0.25, Math.min(0.25, (smoothEle[i] - smoothEle[i - 1]) / d))
    segs.push({ distM: d, cumDistM: dist[i], elevM: pts[i].elevation, grade, crr: crrForSurface(catAt[i], iriAt[i]) })
  }
  return segs
}

function intensityFactor(intensity: PacingIntensity, estHours: number): number {
  switch (intensity) {
    case 'race': return 0.88
    case 'long': return 0.80
    case 'endurance': return 0.68
    default: return Math.max(0.62, Math.min(0.95, 0.95 - 0.11 * Math.log2(Math.max(1, estHours))))
  }
}

export interface PlanOpts {
  ftpW: number
  wPrimeJ: number
  intensity: PacingIntensity
  massKg: number
  cdA: number
  rhoAir?: number
  maxChartPoints?: number
}

export function planPhysioPacing(segs: PacingSeg[], opts: PlanOpts): PacingPlan | null {
  if (segs.length === 0) return null
  const { ftpW: ftp, wPrimeJ: wPrime, intensity, massKg, cdA } = opts
  const rhoAir = opts.rhoAir ?? 1.225
  const totalDist = segs.reduce((sum, seg) => sum + seg.distM, 0)
  const crrAvg = segs.reduce((sum, seg) => sum + seg.crr * seg.distM, 0) / Math.max(1, totalDist)
  const vFlat = speedForPower(0.8 * ftp, 0, crrAvg, massKg, cdA, rhoAir)
  const estHours = totalDist / Math.max(2, vFlat) / 3600
  const targetIF = intensityFactor(intensity, estHours)
  const targetNp = targetIF * ftp
  const pMax = ftp * 1.5

  const mod = segs.map(seg => {
    const value = 1 + 0.10 * (seg.grade * 100) + 0.45 * (seg.crr / crrAvg - 1)
    return Math.max(0, Math.min(1.6, value))
  })

  const speeds = new Array<number>(segs.length)
  const powers = new Array<number>(segs.length)
  const times = new Array<number>(segs.length)
  let plan: PacingPlan | null = null

  for (let attempt = 0; attempt < 7; attempt++) {
    const amplitude = Math.pow(0.8, attempt)
    let scale = 1

    for (let it = 0; it < 4; it++) {
      for (let i = 0; i < segs.length; i++) {
        const p = Math.max(0, Math.min(pMax, targetNp * (1 + amplitude * (mod[i] - 1)) * scale))
        powers[i] = p
        speeds[i] = Math.min(MAX_SPEED_MS, speedForPower(p, segs[i].grade, segs[i].crr, massKg, cdA, rhoAir))
        times[i] = segs[i].distM / Math.max(0.5, speeds[i])
      }
      const totalTime = times.reduce((sum, t) => sum + t, 0)
      const np = Math.pow(times.reduce((sum, t, i) => sum + Math.pow(powers[i], 4) * t, 0) / Math.max(1, totalTime), 0.25)
      scale *= targetNp / Math.max(1, np)
    }

    let wBal = wPrime
    let minWBal = wPrime
    const wBalAt = new Array<number>(segs.length)
    for (let i = 0; i < segs.length; i++) {
      const dt = times[i]
      if (powers[i] > ftp) {
        wBal -= (powers[i] - ftp) * dt
      } else {
        const tau = 546 * Math.exp(-0.01 * (ftp - powers[i])) + 316
        wBal += (wPrime - wBal) * (1 - Math.exp(-dt / tau))
      }
      if (wBal > wPrime) wBal = wPrime
      wBalAt[i] = wBal
      if (wBal < minWBal) minWBal = wBal
    }

    const feasible = minWBal >= 0
    if (feasible || attempt === 6) {
      const totalTime = times.reduce((sum, t) => sum + t, 0)
      const zoneSeconds = [0, 0, 0, 0, 0, 0]
      const allPoints: PacingPlanPoint[] = segs.map((seg, i) => {
        const pct = powers[i] / ftp
        const zone = powerZone(pct)
        zoneSeconds[zone - 1] += times[i]
        return {
          distanceKm: seg.cumDistM / 1000,
          elevationM: seg.elevM,
          gradePct: Math.round(seg.grade * 100),
          powerW: Math.round(powers[i]),
          pctFtp: Math.round(pct * 100),
          speedKmh: Math.round(speeds[i] * 36) / 10,
          wBalKj: Math.round((wBalAt[i] / 1000) * 10) / 10,
          zone,
        }
      })
      const maxPts = opts.maxChartPoints ?? 300
      const stepN = Math.max(1, Math.floor(allPoints.length / maxPts))
      const points = allPoints.filter((_, i) => i % stepN === 0 || i === allPoints.length - 1)
      const avgPowerW = powers.reduce((sum, p, i) => sum + p * times[i], 0) / Math.max(1, totalTime)
      plan = {
        points,
        ftpW: ftp,
        wPrimeKj: Math.round(wPrime / 100) / 10,
        targetIF: Math.round(targetIF * 100) / 100,
        targetNpW: Math.round(targetNp),
        estimatedTimeSec: totalTime,
        avgPowerW: Math.round(avgPowerW),
        minWBalKj: Math.round((minWBal / 1000) * 10) / 10,
        feasible,
        zoneSeconds: zoneSeconds.map(s => Math.round(s)),
      }
      break
    }
  }

  return plan
}

export function normalizedPower(powers: number[]): number {
  if (powers.length < 30) return average(powers) ?? 0
  const rolling: number[] = []
  for (let i = 29; i < powers.length; i++) {
    const slice = powers.slice(i - 29, i + 1)
    const avg = average(slice) ?? 0
    rolling.push(avg ** 4)
  }
  return (average(rolling) ?? 0) ** 0.25
}

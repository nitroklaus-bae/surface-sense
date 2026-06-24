import { TIRE_DATABASE } from './tires'
import type { RiderProfile, SurfaceSegment, TireSetup, TrackSegment } from './types'
import { computeTirePairSetup, interpolateCrr, routePressureInfo, effectiveCrr } from './rollingResistance'
import { buildRouteProfile } from './routeProfile'

// ── Priority weighting for ranking ───────────────────────────────────
export interface ScoreWeights { speed: number; puncture: number; handling: number }
export const DEFAULT_WEIGHTS: ScoreWeights = { speed: 0.6, puncture: 0.25, handling: 0.15 }

// Two-phase approach: rank each wheel position independently first (cheap, single-wheel
// Crr + puncture pre-score), then evaluate only the top-N×top-N pairs with the full
// physics model. Reduces candidate pairs from ~19 600 to 100 without meaningful loss
// in result quality — the pre-score correlates strongly with the final overall score.
const TOP_WHEEL_CANDIDATES = 10

// Weighted 0–100 score for a setup under given priorities (weights need not sum to 1).
export function weightedScore(s: TireSetup, w: ScoreWeights): number {
  const sum = w.speed + w.puncture + w.handling || 1
  return Math.round(
    (w.speed * s.speedScore + w.puncture * s.punctureRiskScore + w.handling * s.handlingRiskScore) / sum,
  )
}

// Re-rank a candidate list by weights, returning a new sorted array.
export function rankByWeights(setups: TireSetup[], w: ScoreWeights): TireSetup[] {
  return [...setups]
    .map(s => ({ ...s, overallScore: weightedScore(s, w) }))
    .sort((a, b) => b.overallScore - a.overallScore || a.totalTimeSec - b.totalTimeSec)
}

// ── Main optimizer: returns the ranked candidate list ────────────────
// Returns up to `topN` candidates (default 50) so the UI can re-weight and
// build a comparison table without re-running the model.
export function optimizeTires(
  rider: RiderProfile,
  surfaces: SurfaceSegment[],
  totalDistanceM: number,
  topN = 50,
  track?: TrackSegment,
  weights: ScoreWeights = DEFAULT_WEIGHTS,
): TireSetup[] {
  const candidates: TireSetup[] = []
  const frontCandidates = buildWheelCandidates(rider, surfaces, totalDistanceM, false, weights)
  const rearCandidates = buildWheelCandidates(rider, surfaces, totalDistanceM, true, weights)

  // Build the (grade × surface) route profile once; reused for every candidate.
  // Uses real per-section power when the FIT file carried power data.
  const routeProfile = buildRouteProfile(track, surfaces, !!track?.hasPowerData)

  for (const front of frontCandidates) {
    for (const rear of rearCandidates) {
      const setup = computeTirePairSetup(
        front.tire,
        front.widthMm,
        rear.tire,
        rear.widthMm,
        rider,
        surfaces,
        totalDistanceM,
        { track, routeProfile },
      )
      if (setup) {
        // Ranking has no explicit drivetrain penalty for mixed brands/models; real-world
        // compatibility is tire-size/rim dependent and belongs in a later fitment model.
        candidates.push(setup)
      }
    }
  }

  if (candidates.length === 0) return []

  // Sort by totalTimeSec ascending (fastest first)
  candidates.sort((a, b) => a.totalTimeSec - b.totalTimeSec)

  const bestTime = candidates[0].totalTimeSec
  const worstTime = candidates[candidates.length - 1].totalTimeSec
  const timeSpan = Math.max(1e-6, worstTime - bestTime)
  for (const c of candidates) {
    c.timeSavingVsWorstSec = worstTime - c.totalTimeSec
    // Speed score normalised across the candidate set (fastest = 100).
    c.speedScore = Math.round(100 * (worstTime - c.totalTimeSec) / timeSpan)
  }

  return candidates.slice(0, topN)
}

interface WheelCandidate { tire: (typeof TIRE_DATABASE)[number]; widthMm: number; preScore: number }

// Pre-ranks each wheel position independently using a cheap single-tire score that
// correlates with the final weighted score. The preScore is a cost (lower = better):
//   • Speed term (Crr): route-weighted Crr at optimal pressure + casing quality signal
//   • Puncture term: credit for higher protection, weighted by user priorities
//   • Weight penalty: heavier tires cost fractionally more rolling resistance
// Weights are normalised so the balance between speed and puncture reflects the
// user's slider settings before we spend cycles on the full pair model.
function buildWheelCandidates(
  rider: RiderProfile,
  surfaces: SurfaceSegment[],
  totalDistanceM: number,
  isRear: boolean,
  weights: ScoreWeights,
): WheelCandidate[] {
  const totalMassKg = rider.riderWeightKg + rider.bikeWeightKg
  const totalDist = surfaces.reduce((s, seg) => s + Math.max(0, seg.distanceMeters), 0) || Math.max(1, totalDistanceM)
  const minW = isRear
    ? (rider.minRearTireWidthMm ?? rider.minTireWidthMm)
    : (rider.minFrontTireWidthMm ?? rider.minTireWidthMm)
  const maxW = isRear
    ? (rider.maxRearTireWidthMm ?? rider.maxTireWidthMm)
    : (rider.maxFrontTireWidthMm ?? rider.maxTireWidthMm)

  // Normalised weight fractions (speed + puncture only; handling has no single-tire proxy).
  const wSum = (weights.speed + weights.puncture) || 1
  const wSpeed = weights.speed / wSum
  const wPuncture = weights.puncture / wSum

  const out: WheelCandidate[] = []
  for (const tire of TIRE_DATABASE) {
    if (rider.hasTubeless && !tire.tubeless) continue
    for (const widthMm of tire.widths) {
      if (widthMm < minW || widthMm > maxW) continue
      const pressure = routePressureInfo(
        totalMassKg,
        widthMm,
        isRear,
        tire.tubeless,
        surfaces,
        totalDistanceM,
        tire.minPressureBar,
        tire.maxPressureBar,
      ).pressure
      const tireAge  = rider.tireAgeKm ?? 0
      const temp     = rider.ambientTempCelsius ?? 20
      const model    = rider.crrModel ?? 'physical'
      const loadKg   = totalMassKg * (isRear ? 0.55 : 0.45)
      const weightedCrr = surfaces.reduce((sum, seg) => (
        sum + effectiveCrr(tire, widthMm, pressure, seg.surface.category, seg.surface.iri, tireAge, temp, model, loadKg)
          * (seg.distanceMeters / totalDist)
      ), 0)
      const crrBase = interpolateCrr(tire.crr, widthMm)
      const weightPenalty = (tire.weightGrams / 1000) * 0.00004
      // protectionCredit scaled to Crr units: protection 1–5 → 0.0001–0.0005
      const protectionCredit = tire.punctureProtection * 0.00010
      out.push({
        tire,
        widthMm,
        preScore: wSpeed * (weightedCrr + crrBase * 0.25 + weightPenalty)
                - wPuncture * protectionCredit,
      })
    }
  }

  return out
    .sort((a, b) => a.preScore - b.preScore)
    .slice(0, TOP_WHEEL_CANDIDATES)
}

// ── Format helpers ───────────────────────────────────────────────────
export function formatTime(seconds: number): string {
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = Math.floor(seconds % 60)
  if (h > 0) return `${h}h ${m.toString().padStart(2, '0')}m`
  return `${m}m ${s.toString().padStart(2, '0')}s`
}

export function formatDistance(meters: number): string {
  if (meters >= 1000) return `${(meters / 1000).toFixed(1)} km`
  return `${Math.round(meters)} m`
}

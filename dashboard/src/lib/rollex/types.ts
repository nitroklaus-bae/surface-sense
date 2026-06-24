// ── Core geo types ──────────────────────────────────────────────────
export interface LatLon { lat: number; lon: number }

export interface TrackPoint extends LatLon {
  elevation: number        // meters
  time?: Date
  power?: number           // watts
  heartRate?: number       // bpm
  cadence?: number         // rpm
  speed?: number           // m/s from device
  distance?: number        // cumulative meters
  iri?: number             // measured IRI (m/km) from SurfaceSense FIT dev field 4
}

export interface TrackSegment {
  points: TrackPoint[]
  totalDistance: number    // meters
  totalElevGain: number    // meters
  totalElevLoss: number    // meters
  durationSeconds?: number
  avgPower?: number        // watts
  hasPowerData: boolean
}

// ── Surface types ────────────────────────────────────────────────────
// Full roughness taxonomy, mirroring the Flutter app's RrClass (r0…r9 + unknown).
export type SurfaceCategory =
  | 'track'            // r0 SmoothHard — velodrome / sealed track concrete
  | 'smooth_asphalt'   // r1 Pavement
  | 'rough_asphalt'    // r2 RoughPavement / chipseal
  | 'cobblestone'      // r3 CobblePavers
  | 'gravel_fine'      // r4 Hardpack        (SILCA/Karrasch Cat 1)
  | 'gravel_coarse'    // r5 LooseGravel      (Cat 2)
  | 'dirt'             // r6 DirtGround       (Cat 3)
  | 'grass_soft'       // r7 GrassSoftGround  (Cat 4)
  | 'sand_mud'         // r8 SandMud
  | 'technical_trail'  // r9 TechnicalTrail (MTB)
  | 'unknown'

export interface SurfaceProperties {
  category: SurfaceCategory
  label: string
  iri: number              // International Roughness Index (m/km), lower = smoother
  color: string            // hex for map display
  punctureRiskFactor: number  // multiplier 1.0 – 3.0
  handlingRiskFactor: number  // multiplier 1.0 – 3.0
}

export interface SurfaceSegment {
  startIdx: number
  endIdx: number
  distanceMeters: number
  surface: SurfaceProperties
  osmWayId?: number
  osmHighway?: string
  osmConfidence?: number   // 0–1 classification confidence (OSM tag completeness)
  roughness?: number       // 0–1 continuous roughness (for tunable category banding)
  hard?: boolean           // paved/hard surface (vs loose) — selects the band set
  // Sensor-measured IRI — overrides static OSM IRI when present
  measuredIri?: number     // distance-weighted mean of per-point sensor IRI (m/km)
  iriSampleCount?: number  // how many sensor readings averaged into measuredIri
}

// ── Tire types ───────────────────────────────────────────────────────
export interface Tire {
  id: string
  brand: string
  model: string
  widths: number[]         // available widths in mm
  crr: Record<number, number>  // width_mm → Crr at reference pressure (6 bar)
  weightGrams: number
  tpi: number              // threads per inch
  punctureProtection: 1 | 2 | 3 | 4 | 5  // 1=none, 5=max
  compound: 'racing' | 'endurance' | 'touring' | 'gravel' | 'training'
  tubeless: boolean
  maxPressureBar: number
  minPressureBar: number
  priceEur?: number
  url?: string
}

export interface PressureInfo {
  pressure: number   // recommended (bar, rounded to 0.05)
  min: number        // safe lower bound (structural / tire min, bar)
  max: number        // tire max pressure (bar)
  clamped: boolean   // true if the Crr-optimum sits below the safe minimum
}

export interface TireSetup {
  frontTire: Tire
  rearTire: Tire
  frontWidthMm: number
  rearWidthMm: number
  tire: Tire
  widthMm: number
  pressureFrontBar: number
  pressureRearBar: number
  pressureFrontInfo: PressureInfo
  pressureRearInfo: PressureInfo
  dominantSurface: SurfaceCategory  // surface used for pressure optimisation
  avgIri: number                    // distance-weighted route IRI
  crrEffective: number     // weighted Crr over whole route
  cdA: number              // aerodynamic drag area (m²) used for this setup
  totalTimeSec: number     // estimated total time
  timeSavingVsWorstSec: number
  speedScore: number          // 0-100, normalised across candidate set (set in optimizer)
  punctureRiskScore: number   // 0-100 (100 = safest)
  handlingRiskScore: number   // 0-100 (100 = best handling)
  overallScore: number        // 0-100 (default weighting; UI may re-weight)
  powerBreakdown: {
    rollingResistanceW: number
    aerodynamicW: number
    gravityW: number
  }
}

// Aerodynamic inputs
export type RidingPosition = 'hoods' | 'drops' | 'aero' | 'tt'
export type WheelAero = 'shallow' | 'aero' | 'deep'

// Rolling-resistance model:
//  • physical      — most physically-grounded: BRR casing + γ=2 capped impedance +
//                    Bekker sinkage (calibrate_physical.py); passes all lit. phenomena
//  • three-term    — calibrated physics (casing + impedance(linear IRI) + sinkage)
//  • iso8608       — Flutter "optimized BRR/Karrasch" vibration model (IRI²·stiffness)
//  • karrasch      — pure per-category measured INCREMENT (additive, pressure-dependent)
//  • karrasch-table— Flutter "karraschTable": per-category measured Crr as a
//                    multiplicative ratio over the smooth base, pressure-independent
export type CrrModel = 'physical' | 'three-term' | 'iso8608' | 'karrasch' | 'karrasch-table'

// ── Rider profile ────────────────────────────────────────────────────
export interface RiderProfile {
  riderWeightKg: number
  bikeWeightKg: number
  avgPowerW: number
  minTireWidthMm: number
  maxTireWidthMm: number
  minFrontTireWidthMm?: number
  maxFrontTireWidthMm?: number
  minRearTireWidthMm?: number
  maxRearTireWidthMm?: number
  hasTubeless: boolean
  // Aerodynamics
  riderHeightCm?: number        // for frontal-area estimate (default 175)
  ridingPosition?: RidingPosition  // default 'drops'
  wheelAero?: WheelAero         // rim depth bucket (default 'aero')
  // Pacing / physiology
  ftpW?: number                 // functional threshold power (default 220)
  wPrimeJ?: number              // anaerobic work capacity W' in joules (default 20000)
  pacingIntensity?: PacingIntensity  // target effort (default 'auto')
  // Pressure corrections
  ambientTempCelsius?: number   // ambient temperature when riding (default 20°C)
  inflateTempCelsius?: number   // temperature at inflation (default 20°C)
  sealantGrams?: number         // tubeless sealant weight per tire in grams (default 40)
  // Tire condition
  tireAgeKm?: number            // estimated km on current tires (0 = new)
  // Environment
  airPressureHPa?: number       // atmospheric pressure (default 1013 hPa)
  humidityPct?: number          // relative humidity 0–100 % (default 45)
  // Crr model
  crrModel?: CrrModel
}

// ── Analysis results ─────────────────────────────────────────────────
export interface RouteAnalysis {
  track: TrackSegment
  surfaces: SurfaceSegment[]
  surfaceSummary: Record<SurfaceCategory, number>  // category → meters
  top3Setups: TireSetup[]
}

export interface PacingPoint {
  distanceKm: number
  powerW: number
  speedKmh: number
  elevationM: number
  optimalPowerW?: number
  optimalSpeedKmh?: number
}

// ── FTP-based physiological pacing plan ──────────────────────────────
export type PacingIntensity = 'auto' | 'race' | 'long' | 'endurance'

export interface PacingPlanPoint {
  distanceKm: number
  elevationM: number
  gradePct: number
  powerW: number      // recommended power
  pctFtp: number      // power as % of FTP
  speedKmh: number
  wBalKj: number      // remaining anaerobic reserve W'
  zone: number        // 1..6 power zone
}

export interface PacingPlan {
  points: PacingPlanPoint[]
  ftpW: number
  wPrimeKj: number
  targetIF: number
  targetNpW: number          // target normalized power = IF × FTP
  estimatedTimeSec: number
  avgPowerW: number
  minWBalKj: number          // lowest reserve reached (≥0 = feasible)
  feasible: boolean
  zoneSeconds: number[]      // time per zone (length 6)
}

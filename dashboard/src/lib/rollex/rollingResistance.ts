import type { CrrModel, PressureInfo, RiderProfile, RidingPosition, SurfaceCategory, SurfaceSegment, Tire, TireSetup, TrackSegment, WheelAero } from './types'
import { buildRouteProfile, type RouteProfile } from './routeProfile'

// ── Physical constants ───────────────────────────────────────────────
const G = 9.81            // m/s²
const RHO_AIR_REF = 1.225 // kg/m³ at sea level, 15°C — fallback only
const DEFAULT_CDA = 0.32  // m² fallback – typical road bike + rider in drops
const P_REF = 5.0         // bar – BRR reference pressure for all Crr values in DB
// Drivetrain efficiency: power meters / FIT files report CRANK power; ~2.5% is lost
// in the chain/derailleur before the wheel. wheel_power = crank_power × η.
const DRIVETRAIN_EFF = 0.975
const MAX_SPEED_MS = 70 / 3.6   // cap modeled descent speed (riders brake/coast)

// ── Air density (temperature + humidity + altitude) ──────────────────────────
// Magnus formula for saturation vapour pressure; dry-air/water-vapour mixture law.
// Bounds prevent unphysical values from out-of-range inputs.
export function computeAirDensity(
  tempCelsius: number,
  pressureHPa = 1013.25,
  humidityPct = 45,
): number {
  const T_K  = tempCelsius + 273.15
  const P_Pa = Math.max(500, pressureHPa) * 100
  const RH   = Math.max(0, Math.min(1, humidityPct / 100))
  const P_sat_hPa = 6.112 * Math.exp(17.67 * tempCelsius / (tempCelsius + 243.5))
  const P_vap_Pa  = P_sat_hPa * RH * 100
  const P_dry_Pa  = Math.max(0, P_Pa - P_vap_Pa)
  const rho = P_dry_Pa / (287.05 * T_K) + P_vap_Pa / (461.495 * T_K)
  return Math.max(0.75, Math.min(1.45, rho))
}

// ══════════════════════════════════════════════════════════════════════════════
// AERODYNAMIC DRAG MODEL  (CdA, m²)
//
//   F_aero = 0.5 · ρ · CdA · v²    →    P_aero = F_aero · v = 0.5 · ρ · CdA · v³
//
// CdA = CdA_body + CdA_bike + CdA_tire_front + CdA_tire_rear
//
//  • Body: projected frontal area from anthropometrics (Bassett et al. 1999,
//    A = 0.0293·H^0.725·M^0.425 + 0.0604, H[m], M[kg]) × a position drag
//    coefficient (hoods → tt). This makes height & weight real inputs.
//  • Bike: frame + wheels baseline at the 25 mm reference tire, adjusted by rim
//    depth (shallow/aero/deep).
//  • Tires: incremental drag per mm of width ABOVE 25 mm, applied separately to
//    front and rear. The front tire sits in clean air and dominates; the rear is
//    shielded by frame/rider, so its width costs ~40 % as much
//    (k_front 0.00025, k_rear 0.00010 m²/mm — consistent with published tire
//    aero tests: ~0.6–1.3 W per 3–4 mm at 45 km/h on the front wheel).
// ══════════════════════════════════════════════════════════════════════════════

const POSITION_CD: Record<RidingPosition, number> = {
  hoods: 0.74,   // hands on the hoods, fairly upright
  drops: 0.625,  // in the drops
  aero:  0.55,   // low aero tuck
  tt:    0.46,   // TT / aerobars
}
const WHEEL_CDA_DELTA: Record<WheelAero, number> = {
  shallow: 0.012,  // box-section / shallow rims
  aero:    0.000,  // mid-depth aero rims (reference)
  deep:   -0.012,  // deep-section rims
}
const CDA_BIKE_BASE = 0.085  // frame + wheels at 25 mm tires (rider excluded)
const CDA_TIRE_W_REF = 25    // mm — width at which tire increment is zero
const CDA_K_FRONT = 0.00025  // m² per mm extra width, front (clean air)
const CDA_K_REAR  = 0.00010  // m² per mm extra width, rear (shielded)

// Projected frontal area of the rider (m²), Bassett et al. 1999 regression.
function riderFrontalArea(heightCm: number, weightKg: number): number {
  const H = heightCm / 100
  return 0.0293 * Math.pow(H, 0.725) * Math.pow(weightKg, 0.425) + 0.0604
}

// Full CdA for a rider on a given front/rear tire width.
export function computeCdA(rider: RiderProfile, frontWidthMm: number, rearWidthMm: number): number {
  const position = rider.ridingPosition ?? 'drops'
  const heightCm = rider.riderHeightCm ?? 175
  const wheel = rider.wheelAero ?? 'aero'
  const body = POSITION_CD[position] * riderFrontalArea(heightCm, rider.riderWeightKg)
  const bike = CDA_BIKE_BASE + WHEEL_CDA_DELTA[wheel]
  const tires = CDA_K_FRONT * (frontWidthMm - CDA_TIRE_W_REF)
              + CDA_K_REAR  * (rearWidthMm  - CDA_TIRE_W_REF)
  return Math.max(0.15, body + bike + tires)
}

// ── Crr width interpolation ──────────────────────────────────────────────────
export function interpolateCrr(crr: Record<number, number>, widthMm: number): number {
  const keys = Object.keys(crr).map(Number).sort((a, b) => a - b)
  if (keys.length === 0) return 0.005
  if (crr[widthMm] !== undefined) return crr[widthMm]
  const lowerKeys = keys.filter(k => k <= widthMm)
  const lo = lowerKeys.length > 0 ? lowerKeys[lowerKeys.length - 1] : undefined
  const hi = keys.find(k => k > widthMm)
  if (lo === undefined) return crr[keys[0]] * Math.pow(keys[0] / widthMm, 0.15)
  if (hi === undefined) {
    const lastKey = keys[keys.length - 1]
    return crr[lastKey] * Math.pow(lastKey / widthMm, 0.15)
  }
  const t = (widthMm - lo) / (hi - lo)
  return crr[lo] + t * (crr[hi] - crr[lo])
}

// ══════════════════════════════════════════════════════════════════════════════
// PHYSICS MODEL: Three-component rolling resistance
// Calibrated June 2026 on measured tire data (see calibration/fit_final.py):
//   • 1708 BRR drum pressure-curve points (427 tires × 4 pressures) → casing α(w)
//   • 215 Karrasch Virtual-Elevation real-road points (52 tires × surfaces) → sinkage
// External physics references verified:
//   • SILCA Part 4B (impedance): casing falls with P; impedance rises with P.
//   • Bekker–Wong terramechanics: on soft ground higher P → higher contact pressure
//     → deeper sinkage → MORE resistance (the "air-down for gravel/sand" rule).
//     This REVERSED the earlier wrong sinkage sign (was Crr_sin ∝ 1/P).
//
// Crr_total(P) = Crr_casing(P) + Crr_impedance(P,IRI,w) + Crr_sinkage(P,surface,w)
//
// 1. CASING — viscoelastic hysteresis of the carcass.
//    Crr_cas = Crr_BRR × (P_ref/P)^α(w)
//    Crr_BRR = per-tire reference at P_ref = 5.0 bar (preserves tire ranking).
//    α(w) = clamp(0.6043 − 0.00446·w, 0.36, 0.52)   [fit: 1708 BRR points]
//      25mm:0.49  35mm:0.45  45mm:0.40  55mm:0.36 — narrower tires are more
//      pressure-sensitive. (The old fixed 0.35 underestimated this.)
//    → Decreases with pressure.
//
// 2. IMPEDANCE — vibration energy lost to rider/frame on rough surfaces.
//    Crr_imp = K_IMP × (IRI^γ − IRI_smooth^γ) × (P/P_ref)^δ × (W0/w)^ε
//    K_IMP=0.000622, γ=1.0, δ=0.4, ε=0.3, IRI_smooth=1.5, W0=40.
//    Increment over smooth asphalt (crrBase already = smooth → no double-count).
//    Amplitude anchored to the chipseal penalty (+0.0013 Crr, 30mm @ 4.5 bar).
//    → Increases with pressure & roughness; wider tires absorb more. Produces the
//      road/cobblestone breakpoint (e.g. 28mm on pavé ≈ 3.3 bar optimum).
//
// 3. SINKAGE — energy deforming loose surface (Bekker compaction/bulldozing).
//    Crr_sin = S[surface] × (P/P_ref)^φ × (W0/w)^ψ        φ=0.8, ψ=0.6
//    S fit from Karrasch (impedance held fixed): gravel_fine 0.0067,
//      dirt 0.0109, gravel_coarse 0.0214; hard surfaces 0.
//    → INCREASES with pressure (smaller patch ⇒ higher ground pressure ⇒ deeper
//      sinkage); decreases for wider tires. On gravel sinkage is ~85% of the
//      surface penalty, so optimum pressure is "as low as structurally safe".
//
// OPTIMAL PRESSURE: argmin_P Crr_total(P) via golden-section search, bounded
//   below by the structural (pinch-flat) minimum.
//
// Validation on Karrasch real-road data: per-category bias < 2.1%,
//   MAE 3.6% (Cat3) … 8.1% (Cat1).
// ══════════════════════════════════════════════════════════════════════════════

const W0     = 40.0      // reference width (mm)
const K_IMP  = 0.000622  // impedance amplitude
const GAMMA  = 1.0       // impedance IRI exponent
const DELTA  = 0.4       // impedance pressure exponent (> 0)
const EPS_W  = 0.3       // impedance width exponent
const IRI_SMOOTH = 1.5   // smooth-asphalt baseline IRI (m/km)
const PHI    = 0.8       // sinkage pressure exponent (> 0 — higher P, more sinkage)
const PSI    = 0.6       // sinkage width exponent
// ── Casing temperature coefficient ────────────────────────────────────
// Rubber viscoelastic hysteresis (loss modulus) increases when cold.
// Only the CASING term is temperature-sensitive; impedance (frame/road vibration)
// and sinkage (soil deformation) are mechanical and independent of rubber temp.
// Calibration: BRR tests at T_REF=20°C; reported ~5–8% higher Crr at 0–5°C
// (Michelin/Silca compound data); fitted coefficient k_T = 0.006 /°C produces
// +12% casing at 0°C and +6% at 10°C, consistent with the published range.
const T_REF_C  = 20     // BRR reference temperature (°C)
const K_TEMP   = 0.006  // casing Crr change per °C below/above T_REF

// Casing pressure exponent α(w), fit from 1708 BRR drum pressure points.
function casingAlpha(widthMm: number): number {
  return Math.min(0.52, Math.max(0.36, 0.6043 - 0.00446 * widthMm))
}

// ══════════════════════════════════════════════════════════════════════════════
// ISO 8608 ROUGHNESS MODEL (alternative to three-term; selectable via crrModel)
// Ported from the Flutter cycling app (OptimizedBRRKarraschCrrModel).
//
// Physical basis: ISO 8608 vibration energy. A tyre rolling over a rough road
// acts as a spring–damper; the energy lost is proportional to the road power
// spectral density × tyre stiffness × contact-force variance.
//
//   C_rough = (ISO_K × ISO_R × k_B × IRI²) / (wheelLoad_N)
//   k_B     = K_B0 × (p/P0_ISO)^(2/3) × (W0_ISO/w)^0.7
//
// Key differences vs three-term:
//   • IRI²  — quadratic roughness penalty (not linear); rough-surface penalty
//             grows 4× faster, matching empirical observation on cobbles/gravel.
//   • Mass  — heavier riders pay LESS C_rough (more load = lower Crr unit value)
//             but MORE force (absolute losses still rise).
//   • No sinkage term — Karrasch calibration corrections absorb sinkage.
//   • S_tex — surface texture factor corrects BRR drum Crr to real-road casing
//             hysteresis. BRR drum ≈ 1.03 reference.
//
// Karrasch real-road calibration corrections (additive to C_rough, per category):
//   Asphalt −0.00145, Cat1 +0.00096, Cat2 +0.00112, Cat3 +0.00267, Cat4 +0.00345
//
// VALIDATION (calibration/validate_models.py + fit_unified.py, 123 Karrasch
// real-road points): on the measured loose-surface INCREMENTS this ISO form is
// WORSE than the calibrated 3-term model — MAE 17.1% vs 12.4%, and it under-
// predicts fine gravel (Cat1) by −24%. When the IRI²-stiffness term is fit
// freely against the data its gain collapses to ~0 (calibration/fit_unified.py
// Model D), i.e. loose-surface losses are dominated by terramechanics SINKAGE,
// not casing vibration. The ISO model therefore stays an EXPERIMENTAL option for
// hard rough surfaces (cobbles, where vibration physics dominates and no Crr data
// exists to contradict it); the 3-term model remains the calibrated default.
// ══════════════════════════════════════════════════════════════════════════════
const ISO_K       = 2.04e-6   // ISO 8608 constant
const ISO_R       = 0.52      // road roughness correction factor
const K_B0        = 80_000    // reference tyre stiffness (N/m)
const P0_ISO      = 3.0       // bar — stiffness reference pressure
const W0_ISO      = 53.0      // mm — stiffness reference width
const LOAD_REF_KG = 42.5      // kg — BRR reference wheel load

const KARRASCH_ISO: Record<SurfaceCategory, number> = {
  track:           -0.001445,
  smooth_asphalt:  -0.001445,
  rough_asphalt:   -0.000700,
  cobblestone:      0.000000,  // high impedance; not in Karrasch road-bike data set
  gravel_fine:      0.000960,  // Cat 1
  gravel_coarse:    0.001124,  // Cat 2
  dirt:             0.002674,  // Cat 3
  grass_soft:       0.003449,  // Cat 4
  sand_mud:         0.004200,  // extrapolated beyond Cat 4
  technical_trail:  0.003000,  // rough-hard; between Cat 3 and Cat 4
  unknown:          0.000500,
}

// Surface texture factor S_tex / S_tex_BRR (BRR drum ≈ 1.03).
// Derived from roughness/looseness/softness coefficients of the Flutter app:
//   S_tex = 0.98 + 0.18R + 0.06L + 0.12S  (+ cobblestone/trail bonus)
//   tex_factor = S_tex / 1.03
const SURFACE_TEX: Record<SurfaceCategory, number> = {
  track:           0.958,
  smooth_asphalt:  0.968,
  rough_asphalt:   1.002,
  cobblestone:     1.339,
  gravel_fine:     1.042,
  gravel_coarse:   1.126,
  dirt:            1.145,
  grass_soft:      1.179,
  sand_mud:        1.234,
  technical_trail: 1.379,
  unknown:         1.062,
}

// ISO 8608 Crr — casing (load + temp + texture) + rough (IRI²) with Karrasch offset.
// wheelLoadKg: actual load on this wheel (totalMass × 0.45 front / 0.55 rear).
export function crrComponentsISO8608(
  crrBase: number,
  widthMm: number,
  pressureBar: number,
  iri: number,
  surface: SurfaceCategory,
  wheelLoadKg: number,
  tempCelsius = T_REF_C,
): { casing: number; rough: number; total: number } {
  // Casing: BRR × (Pref/P)^α × temperature × load × surface texture
  const alpha      = casingAlpha(widthMm)
  const tempFactor = 1 + K_TEMP * (T_REF_C - tempCelsius)
  const loadFactor = Math.pow(wheelLoadKg / LOAD_REF_KG, 0.06)
  const texFactor  = SURFACE_TEX[surface]
  const casing = crrBase * Math.pow(P_REF / pressureBar, alpha) * tempFactor * loadFactor * texFactor

  // Rough (ISO 8608): ∝ tire stiffness × IRI² / wheel weight
  const kB      = K_B0 * Math.pow(pressureBar / P0_ISO, 2/3) * Math.pow(W0_ISO / widthMm, 0.7)
  const roughRaw = (ISO_K * ISO_R * kB * iri * iri) / (wheelLoadKg * G)
  const rough    = Math.max(0, roughRaw + KARRASCH_ISO[surface])

  return { casing, rough, total: casing + rough }
}

// ══════════════════════════════════════════════════════════════════════════════
// PURE KARRASCH MODEL (selectable via crrModel='karrasch')
//
// Most data-faithful option: bypasses the IRI proxy entirely and uses the measured
// real-road increment PER SURFACE CATEGORY directly, with no impedance/sinkage
// physics split. Fit in calibration/fit_unified.py (Model E) against the 123
// Karrasch increments with runtime-safe Bekker exponents (ψ=0.6 width, φ=0.8
// pressure) — IRI cannot separate Cat2 (IRI 6.0) from Cat3 (IRI 6.5) which differ
// ~70% in Crr, so a per-category amplitude is required (a single IRI law under-
// predicts Cat3 by −27%, see fit_unified Model K).
//
//   Crr = casing(crrBase,p,w,T) + KARRASCH_INC[surface]·(W0/w)^ψ·(p/P_REF)^φ
//
// Validation (loose-surface increments): MAE 14%, bias −3%. Cat1/2/3 amplitudes
// are FIT to measurement; hard surfaces (cobble, rough_asphalt) and Cat4+ are
// estimates (Karrasch's road-bike data set does not cover them).
// ══════════════════════════════════════════════════════════════════════════════
const KARRASCH_INC: Record<SurfaceCategory, number> = {
  track:           0.00000,
  smooth_asphalt:  0.00000,   // baseline (crrBase already = smooth real-road)
  rough_asphalt:   0.00150,   // estimate (chipseal; not in Karrasch road set)
  cobblestone:     0.01200,   // estimate (pavé; impedance-dominated, no data)
  gravel_fine:     0.00843,   // Cat 1 — FIT to measured Karrasch increment
  gravel_coarse:   0.01514,   // Cat 2 — FIT to measured
  dirt:            0.02633,   // Cat 3 — FIT to measured
  grass_soft:      0.03200,   // Cat 4 estimate (> Cat 3)
  sand_mud:        0.05000,   // estimate (very soft)
  technical_trail: 0.02000,   // estimate (rough hard/loose mix)
  unknown:         0.00800,   // estimate
}

// ══════════════════════════════════════════════════════════════════════════════
// KARRASCH TABLE MODEL (selectable via crrModel='karrasch-table')
//
// Faithful port of the Flutter app's `karraschTable` mode: each tire's real-road
// Crr per surface category, used DIRECTLY (no impedance/sinkage/pressure formula).
// Flutter stores measured crrCat1/2/3(/4) per tire; for tires without measured
// values it fills via category-to-base ratios and width-class factors. Our DB has
// one smooth-asphalt base per width, so we apply the SAME aggregate ratios derived
// from the Karrasch data (calibration/fit_unified.py + ratio scan):
//   Cat1/base 1.90 · Cat2/base 2.43 · Cat3/base 3.23 · Cat4 = Cat3×1.258 ≈ 4.06.
// Flutter surface mapping: all hard pavement → smooth (×1.0); cobblestone & MTB
// trail → Cat4. PRESSURE-INDEPENDENT by design (matches the Flutter table mode).
// ══════════════════════════════════════════════════════════════════════════════
const KARRASCH_TABLE_RATIO: Record<SurfaceCategory, number> = {
  track:           1.00,
  smooth_asphalt:  1.00,   // base = smooth real-road
  rough_asphalt:   1.00,   // Flutter table: chipseal/worn/poor pavement → smooth
  cobblestone:     4.06,   // Flutter maps cobblestone → Cat 4
  gravel_fine:     1.90,   // Cat 1 (measured ratio)
  gravel_coarse:   2.43,   // Cat 2 (measured ratio)
  dirt:            3.23,   // Cat 3 (measured ratio)
  grass_soft:      4.06,   // Cat 4 = Cat 3 × 1.258
  sand_mud:        5.30,   // beyond Cat 4 (estimate)
  technical_trail: 4.06,   // Cat 4 / MTB trail
  unknown:         2.43,   // Cat 2 fallback
}

// Karrasch table Crr: tire's smooth base × measured per-category ratio.
// crrBase must already include the age factor. Pressure/temperature have no effect.
export function crrComponentsKarraschTable(
  crrBase: number,
  surface: SurfaceCategory,
): { casing: number; surface: number; total: number } {
  const total = crrBase * KARRASCH_TABLE_RATIO[surface]
  return { casing: crrBase, surface: total - crrBase, total }
}

// Pure-Karrasch Crr: per-category measured increment (no IRI term).
export function crrComponentsKarrasch(
  crrBase: number,
  widthMm: number,
  pressureBar: number,
  surface: SurfaceCategory,
  tempCelsius = T_REF_C,
): { casing: number; surface: number; total: number } {
  const alpha      = casingAlpha(widthMm)
  const tempFactor = 1 + K_TEMP * (T_REF_C - tempCelsius)
  const casing     = crrBase * Math.pow(P_REF / pressureBar, alpha) * tempFactor
  const inc = KARRASCH_INC[surface] > 0
    ? KARRASCH_INC[surface] * Math.pow(W0 / widthMm, PSI) * Math.pow(pressureBar / P_REF, PHI)
    : 0
  return { casing, surface: inc, total: casing + inc }
}

// ══════════════════════════════════════════════════════════════════════════════
// PHYSICAL MODEL (crrModel='physical') — the most physically-grounded synthesis.
// Each mechanism derived from first principles, anchored to published data; passes
// every documented phenomenon (calibration/physics_fidelity.py). Calibrated in
// calibration/calibrate_physical.py. See [[crr-external-validation]].
//
//   Crr = casing(BRR,w,p,T,load) + impedance(p,w,IRI) + sinkage(p,w,surface)
//
// 1. CASING — carcass viscoelastic hysteresis, anchored to the published per-tire
//    BRR Crr. Crr_cas = Crr_BRR·(P_ref/p)^α(w)·f_T·f_load. Hysteresis ∝ deflection×
//    loss-tangent, deflection ∝ Load/(p·w); α(w) (1708 BRR points) is the net
//    empirical exponent. f_load=(N/42.5)^0.06 (Grappe 1999 / BRR load sensitivity).
// 2. IMPEDANCE — suspension/vibration loss on hard rough ground. Vibration ENERGY
//    ∝ amplitude² → roughness as IRI² (γ=2, physical); scales with tyre vertical
//    stiffness (∝ p^0.5, weakly with width). A finite rider-absorption CAP (tanh)
//    prevents the unphysical ISO overshoot (raw ISO → cobble Crr 0.066; here ≈0.02).
//    K2 anchored to the Silca chipseal figure (+0.0013 @ rough asphalt 30mm/4.5bar).
// 3. SINKAGE — Bekker-Wong soil compaction. Contact pressure ≈ inflation pressure,
//    so higher p → deeper sinkage → MORE resistance. φ=0.8 ψ=0.6 (Bekker); S fit to
//    the Karrasch loose increments WITH the γ=2 impedance present (MAE 12.3%).
// ══════════════════════════════════════════════════════════════════════════════
const PHYS_K2      = 1.257015e-4  // impedance amplitude (anchored to chipseal)
const PHYS_IMP_CAP = 0.020        // finite rider-absorption ceiling on impedance
const PHYS_SINKAGE: Record<SurfaceCategory, number> = {
  track:           0.00000,
  smooth_asphalt:  0.00000,
  rough_asphalt:   0.00000,   // hard — penalty is impedance, not sinkage
  cobblestone:     0.00000,   // hard rough — impedance only
  gravel_fine:     0.00676,   // Cat 1 — fit (with γ=2 impedance present)
  gravel_coarse:   0.00935,   // Cat 2 — fit
  dirt:            0.01908,   // Cat 3 — fit
  grass_soft:      0.02800,   // Cat 4 estimate
  sand_mud:        0.05000,   // estimate (very soft)
  technical_trail: 0.01600,   // estimate
  unknown:         0.00400,
}

export function crrComponentsPhysical(
  crrBase: number,
  widthMm: number,
  pressureBar: number,
  iri: number,
  surface: SurfaceCategory,
  wheelLoadKg: number,
  tempCelsius = T_REF_C,
): { casing: number; impedance: number; sinkage: number; total: number } {
  const alpha      = casingAlpha(widthMm)
  const tempFactor = 1 + K_TEMP * (T_REF_C - tempCelsius)
  const loadFactor = Math.pow(wheelLoadKg / LOAD_REF_KG, 0.06)
  const casing = crrBase * Math.pow(P_REF / pressureBar, alpha) * tempFactor * loadFactor

  // Vibration energy ∝ IRI²; stiffness ∝ p^0.5, width via (W0/w)^0.3; tanh-capped.
  const iriExcess2 = Math.max(0, iri * iri - IRI_SMOOTH * IRI_SMOOTH)
  const impRaw = PHYS_K2 * iriExcess2 * Math.pow(pressureBar / P_REF, 0.5) * Math.pow(W0 / widthMm, 0.3)
  const impedance = PHYS_IMP_CAP * Math.tanh(impRaw / PHYS_IMP_CAP)

  const S = PHYS_SINKAGE[surface]
  const sinkage = S > 0 ? S * Math.pow(pressureBar / P_REF, PHI) * Math.pow(W0 / widthMm, PSI) : 0

  return { casing, impedance, sinkage, total: casing + impedance + sinkage }
}

// Sinkage amplitude S per surface (dimensionless, at w = W0 reference).
// Hard surfaces = 0 (no soil deformation). Cat 1–3 fit from Karrasch real-road
// data; Cat 4 / sand-mud / technical-trail are estimates beyond the measured range.
// (gravel_coarse = Cat 2, dirt = Cat 3 — paired with their IRI in SURFACE_PROPS.)
const SURFACE_SINKAGE: Record<SurfaceCategory, number> = {
  track:          0.0000,
  smooth_asphalt: 0.0000,
  rough_asphalt:  0.0000,
  cobblestone:    0.0000,   // hard — its penalty is impedance, not sinkage
  gravel_fine:    0.00668,  // Karrasch Cat 1 (packed gravel)
  gravel_coarse:  0.01091,  // Karrasch Cat 2 (loose gravel)
  dirt:           0.02139,  // Karrasch Cat 3 (rough natural ground)
  grass_soft:     0.03000,  // Cat 4 estimate (soft, high sinkage)
  sand_mud:       0.05500,  // estimate (very soft/loose)
  technical_trail:0.01800,  // estimate (rough → impedance-driven, moderate sinkage)
  unknown:        0.00400,  // mild loose default
}

// ── Three-component Crr model ────────────────────────────────────────────────
export function crrComponents(
  crrBase: number,     // BRR Crr at P_REF = 5.0 bar, smooth asphalt
  widthMm: number,
  pressureBar: number,
  iri: number,
  surface: SurfaceCategory,
  tempCelsius = T_REF_C,
): { casing: number; impedance: number; sinkage: number; total: number } {
  const alpha = casingAlpha(widthMm)
  // Temperature correction on casing only — rubber stiffens when cold.
  const tempFactor = 1 + K_TEMP * (T_REF_C - tempCelsius)
  const casing = crrBase * Math.pow(P_REF / pressureBar, alpha) * tempFactor

  const iriExcess = Math.max(0, Math.pow(iri, GAMMA) - Math.pow(IRI_SMOOTH, GAMMA))
  const impedance = iriExcess > 0
    ? K_IMP * iriExcess * Math.pow(pressureBar / P_REF, DELTA) * Math.pow(W0 / widthMm, EPS_W)
    : 0

  const ksin = SURFACE_SINKAGE[surface]
  const sinkage = ksin > 0
    ? ksin * Math.pow(pressureBar / P_REF, PHI) * Math.pow(W0 / widthMm, PSI)
    : 0

  return { casing, impedance, sinkage, total: casing + impedance + sinkage }
}

// Structural (pinch-flat) minimum pressure P = k_struct × wheel-load / width.
// Prevents rim strikes; k_struct = 1.3 bar·mm/kg tubeless, 1.5 tubed.
export function structuralMinPressure(
  totalWeightKg: number,
  widthMm: number,
  isRear: boolean,
  tubeless: boolean,
): number {
  const wheelLoadKg = totalWeightKg * (isRear ? 0.55 : 0.45)
  const kStruct = tubeless ? 1.3 : 1.5
  return kStruct * wheelLoadKg / widthMm
}

// ══════════════════════════════════════════════════════════════════════════════
// RECOMMENDED PRESSURE — Silca-calibrated
//
// A pure Crr-minimum is load-INDEPENDENT in this model (Crr(P) has no weight term),
// so it can't reproduce Silca's core weight→pressure behaviour. Instead the
// recommendation uses a formula fitted to real Silca Pro Calculator outputs:
//
//   P_rear  = C[surface] · (M / 85) · (40 / w)^1.79
//   P_front = 0.975 · P_rear
//
// fitted to (85 kg system, tubeless): 32mm smooth 4.5/4.6 · 40mm Cat2 2.6/2.65 ·
// 53mm Cat2 1.55/1.6 · 53mm Cat3 ≈1.4. C[surface] = rear bar for a 40 mm tire at
// 85 kg; weight scales ~linearly, width via exponent 1.79 (from the Cat2 40↔53
// pair), front ≈ 0.975·rear (from the measured F/R ratios). The 3-term Crr model
// is still used to score tires and estimate time AT this pressure.
// ══════════════════════════════════════════════════════════════════════════════

const SILCA_REF_KG = 85
const SILCA_W_EXP = 1.79
const SILCA_FRONT_FACTOR = 0.975
// Rear bar @ 40 mm, 85 kg. Measured: smooth_asphalt 3.07, gravel_coarse(Cat2) 2.65,
// dirt(Cat3) 2.32. Others interpolated by roughness/softness (estimates).
const SILCA_C: Record<SurfaceCategory, number> = {
  track:           3.30,
  smooth_asphalt:  3.07,  // measured (32 mm → 4.6 rear)
  rough_asphalt:   2.90,
  cobblestone:     2.45,
  gravel_fine:     2.78,  // Cat 1
  gravel_coarse:   2.65,  // measured (Cat 2)
  dirt:            2.32,  // measured (Cat 3)
  grass_soft:      2.10,  // Cat 4
  technical_trail: 2.20,
  sand_mud:        1.85,
  unknown:         2.60,
}

// Silca-style recommended pressure (bar) before safety clamping.
export function silcaPressure(
  widthMm: number, surface: SurfaceCategory, totalWeightKg: number, isRear: boolean,
): number {
  const rear = SILCA_C[surface] * (totalWeightKg / SILCA_REF_KG) * Math.pow(40 / widthMm, SILCA_W_EXP)
  return isRear ? rear : rear * SILCA_FRONT_FACTOR
}

// Roughness sensitivity of the optimal pressure: Silca's recommended pressure drops
// as a surface gets rougher (lower breakpoint). Fitted to Silca's own HARD-surface
// pressures across IRI (track 0.8→C3.30, smooth 1.5→3.07, rough 3.5→2.90,
// cobble 11→2.45 ⇒ C ∝ IRI^−0.115). The per-surface SILCA_C already captures the
// looseness drop; this exponent adds the within-surface roughness trend.
const SILCA_ROUGH_EXP = 0.111

// Silca-calibrated optimal pressure as a function of road ROUGHNESS (IRI). Equals
// silcaPressure() exactly at the surface's nominal IRI and decreases for rougher IRI.
// Used by the 3D plot to draw an optimal-pressure ridge that varies with roughness
// instead of a single flat value. Verify: calibration/test_optimal_pressure.mjs.
export function silcaPressureForIri(
  widthMm: number, surface: SurfaceCategory, nominalIri: number, iri: number,
  totalWeightKg: number, isRear: boolean,
): number {
  const base = silcaPressure(widthMm, surface, totalWeightKg, isRear)
  const ratio = Math.pow(Math.max(0.5, nominalIri) / Math.max(0.5, iri), SILCA_ROUGH_EXP)
  return base * ratio
}

function routeDistance(surfaces: SurfaceSegment[], fallbackM: number): number {
  return surfaces.reduce((s, seg) => s + Math.max(0, seg.distanceMeters), 0) || Math.max(1, fallbackM)
}

function dominantSurface(surfaces: SurfaceSegment[]): SurfaceCategory {
  return surfaces.reduce(
    (best, seg) => seg.distanceMeters > best.distanceMeters ? seg : best,
    surfaces[0] ?? { surface: { category: 'unknown' as SurfaceCategory }, distanceMeters: 0 },
  ).surface.category
}

function routeAvgIri(surfaces: SurfaceSegment[], totalDist: number): number {
  if (surfaces.length === 0) return 4.0
  return surfaces.reduce((s, seg) => s + seg.surface.iri * (seg.distanceMeters / totalDist), 0)
}

// Route pressure is a geometric distance-weighted compromise of the Silca-calibrated
// surface pressures. Geometric weighting avoids asphalt sections pulling mixed
// gravel routes too high, while still preserving the calibrated per-surface values.
function routeSilcaPressure(
  widthMm: number,
  surfaces: SurfaceSegment[],
  totalDistanceM: number,
  totalWeightKg: number,
  isRear: boolean,
): number {
  if (surfaces.length === 0) return silcaPressure(widthMm, 'unknown', totalWeightKg, isRear)
  const totalDist = routeDistance(surfaces, totalDistanceM)
  const logP = surfaces.reduce((s, seg) => {
    const frac = Math.max(0, seg.distanceMeters) / totalDist
    const p = Math.max(0.5, silcaPressure(widthMm, seg.surface.category, totalWeightKg, isRear))
    return s + frac * Math.log(p)
  }, 0)
  return Math.exp(logP)
}

// Recommended pressure with safety bounds. `iri`/`crrBase` are unused (kept for
// call-site compatibility); the Crr model still consumes them elsewhere.
export function optimalPressureInfo(
  totalWeightKg: number,
  widthMm: number,
  iri: number,
  isRear: boolean,
  tubeless: boolean,
  crrBase: number,
  surface: SurfaceCategory,
  pMin: number,
  pMax: number,
): PressureInfo {
  void iri; void crrBase
  const pStructMin = structuralMinPressure(totalWeightKg, widthMm, isRear, tubeless)
  const safeMin = Math.max(pMin, pStructMin, 0.8)
  const hi = Math.min(pMax, 12.0)
  const round = (p: number) => Math.round(p * 20) / 20

  const rec = silcaPressure(widthMm, surface, totalWeightKg, isRear)
  const clamped = rec < safeMin
  const pressure = Math.min(hi, Math.max(safeMin, rec))
  return { pressure: round(pressure), min: round(safeMin), max: round(Math.max(hi, pressure)), clamped }
}

export function routePressureInfo(
  totalWeightKg: number,
  widthMm: number,
  isRear: boolean,
  tubeless: boolean,
  surfaces: SurfaceSegment[],
  totalDistanceM: number,
  pMin: number,
  pMax: number,
): PressureInfo {
  const pStructMin = structuralMinPressure(totalWeightKg, widthMm, isRear, tubeless)
  const safeMin = Math.max(pMin, pStructMin, 0.8)
  const hi = Math.min(pMax, 12.0)
  const round = (p: number) => Math.round(p * 20) / 20
  const rec = routeSilcaPressure(widthMm, surfaces, totalDistanceM, totalWeightKg, isRear)
  const clamped = rec < safeMin
  const pressure = Math.min(hi, Math.max(safeMin, rec))
  return { pressure: round(pressure), min: round(safeMin), max: round(Math.max(hi, pressure)), clamped }
}

// Thin wrapper kept for existing callers.
export function optimalPressure(
  totalWeightKg: number,
  widthMm: number,
  iri: number,
  isRear: boolean,
  tubeless: boolean,
  crrBase: number,
  surface: SurfaceCategory,
  pMin: number,
  pMax: number,
): number {
  return optimalPressureInfo(
    totalWeightKg, widthMm, iri, isRear, tubeless, crrBase, surface, pMin, pMax,
  ).pressure
}

// ── Tire age → Crr degradation factor ───────────────────────────────────────
// Silca/BRR anecdotal: GP5000 Crr ~+15% over ~4000 km (compound glazing + casing
// fatigue). Linear approximation, capped at 4000 km.
export function crrAgeFactor(tireAgeKm: number): number {
  return 1 + 0.15 * Math.min(Math.max(0, tireAgeKm), 4000) / 4000
}

// ── Temperature correction for tire pressure ────────────────────────────────
// Sealed tire: ideal gas law P ∝ T (K). If inflated at T_inflate and ridden at
// T_ambient, actual pressure ≠ set pressure.
// Returns multiplicative correction factor (< 1 if colder than inflation temp).
export function pressureTempFactor(ambientCelsius: number, inflateCelsius: number): number {
  const T_amb = 273.15 + ambientCelsius
  const T_inf = 273.15 + inflateCelsius
  return T_amb / T_inf
}

// ── Model dispatch: total Crr for one tire on a surface under the chosen model ─
// crrBase must already include any age factor. wheelLoadKg is only used by ISO 8608.
export function crrTotal(
  crrModel: CrrModel,
  crrBase: number,
  widthMm: number,
  pressureBar: number,
  iri: number,
  surface: SurfaceCategory,
  wheelLoadKg: number,
  tempCelsius: number,
): number {
  switch (crrModel) {
    case 'physical':
      return crrComponentsPhysical(crrBase, widthMm, pressureBar, iri, surface, wheelLoadKg, tempCelsius).total
    case 'iso8608':
      return crrComponentsISO8608(crrBase, widthMm, pressureBar, iri, surface, wheelLoadKg, tempCelsius).total
    case 'karrasch':
      return crrComponentsKarrasch(crrBase, widthMm, pressureBar, surface, tempCelsius).total
    case 'karrasch-table':
      return crrComponentsKarraschTable(crrBase, surface).total
    default:
      return crrComponents(crrBase, widthMm, pressureBar, iri, surface, tempCelsius).total
  }
}

// ── Effective Crr for a tire/pressure on a surface (public API) ──────────────
export function effectiveCrr(
  tire: Tire,
  widthMm: number,
  pressureBar: number,
  surface: SurfaceCategory,
  iri: number,
  tireAgeKm = 0,
  tempCelsius = T_REF_C,
  crrModel: CrrModel = 'three-term',
  wheelLoadKg = LOAD_REF_KG,
): number {
  const crrBase = interpolateCrr(tire.crr, widthMm) * crrAgeFactor(tireAgeKm)
  return crrTotal(crrModel, crrBase, widthMm, pressureBar, iri, surface, wheelLoadKg, tempCelsius)
}

export function effectiveSystemCrr(
  tire: Tire,
  widthMm: number,
  pressureFrontBar: number,
  pressureRearBar: number,
  surface: SurfaceCategory,
  iri: number,
  tireAgeKm = 0,
  tempCelsius = T_REF_C,
  crrModel: CrrModel = 'three-term',
  totalMassKg = 85,
): number {
  const crrBase = interpolateCrr(tire.crr, widthMm) * crrAgeFactor(tireAgeKm)
  const front = crrTotal(crrModel, crrBase, widthMm, pressureFrontBar, iri, surface, totalMassKg * 0.45, tempCelsius)
  const rear  = crrTotal(crrModel, crrBase, widthMm, pressureRearBar,  iri, surface, totalMassKg * 0.55, tempCelsius)
  return front * 0.45 + rear * 0.55
}

export function effectivePairCrr(
  frontTire: Tire,
  frontWidthMm: number,
  pressureFrontBar: number,
  rearTire: Tire,
  rearWidthMm: number,
  pressureRearBar: number,
  surface: SurfaceCategory,
  iri: number,
  tireAgeKm = 0,
  tempCelsius = T_REF_C,
  crrModel: CrrModel = 'three-term',
  totalMassKg = 85,
): number {
  const age = crrAgeFactor(tireAgeKm)
  const frontBase = interpolateCrr(frontTire.crr, frontWidthMm) * age
  const rearBase  = interpolateCrr(rearTire.crr, rearWidthMm)  * age
  const front = crrTotal(crrModel, frontBase, frontWidthMm, pressureFrontBar, iri, surface, totalMassKg * 0.45, tempCelsius)
  const rear  = crrTotal(crrModel, rearBase,  rearWidthMm,  pressureRearBar,  iri, surface, totalMassKg * 0.55, tempCelsius)
  return front * 0.45 + rear * 0.55
}

// ── Power breakdown at given speed ───────────────────────────────────
export function powerBreakdown(
  speedMs: number,
  gradeRatio: number,
  crrEff: number,
  totalMassKg: number,
  cdA: number = DEFAULT_CDA,
  rhoAir: number = RHO_AIR_REF,
): { rr: number; aero: number; gravity: number } {
  const rr      = crrEff * totalMassKg * G * speedMs
  const aero    = 0.5 * cdA * rhoAir * speedMs ** 3
  const gravity = totalMassKg * G * gradeRatio * speedMs
  return { rr, aero, gravity }
}

// ── Estimate speed from power via bisection ──────────────────────────
// The required-power curve required(v) = (Crr·m·g + m·g·grade)·v + ½·ρ·CdA·v³ is
// NOT monotonic on descents (the linear term goes negative), so Newton-Raphson can
// collapse to the lower bound and return ~0 on steep downhills (catastrophic time
// inflation). Bisection on [0, MAX_SPEED] is unconditionally robust: it finds the
// highest v whose required wheel power ≤ available wheel power. Mirrors the Flutter
// solver. `powerW` is crank power; DRIVETRAIN_EFF converts it to wheel power.
function estimateSpeed(
  powerW: number,
  gradeRatio: number,
  crrEff: number,
  totalMassKg: number,
  cdA: number = DEFAULT_CDA,
  rhoAir: number = RHO_AIR_REF,
): number {
  const availWheelW = Math.max(1, powerW * DRIVETRAIN_EFF)
  const requiredW = (v: number) =>
    crrEff * totalMassKg * G * v + totalMassKg * G * gradeRatio * v + 0.5 * cdA * rhoAir * v ** 3
  let lo = 0.2, hi = MAX_SPEED_MS
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2
    if (requiredW(mid) <= availWheelW) lo = mid
    else hi = mid
  }
  return lo
}

function segmentGrade(track: TrackSegment | undefined, seg: SurfaceSegment): number {
  if (!track || track.points.length < 2) return 0
  const start = track.points[Math.max(0, Math.min(seg.startIdx, track.points.length - 1))]
  const end = track.points[Math.max(0, Math.min(seg.endIdx, track.points.length - 1))]
  const dist = Math.max(5, seg.distanceMeters)
  const raw = (end.elevation - start.elevation) / dist
  return Math.max(-0.20, Math.min(0.20, raw))
}

// ── Compute TireSetup for a given tire + width + rider ───────────────
export function computeTireSetup(
  tire: Tire,
  widthMm: number,
  rider: RiderProfile,
  surfaces: SurfaceSegment[],
  totalDistanceM: number,
  opts?: { fixedPressureBar?: number; ignoreWidthFilter?: boolean; track?: TrackSegment },
): TireSetup | null {
  return computeTirePairSetup(tire, widthMm, tire, widthMm, rider, surfaces, totalDistanceM, opts)
}

export function computeTirePairSetup(
  frontTire: Tire,
  frontWidthMm: number,
  rearTire: Tire,
  rearWidthMm: number,
  rider: RiderProfile,
  surfaces: SurfaceSegment[],
  totalDistanceM: number,
  opts?: { fixedPressureBar?: number; fixedFrontPressureBar?: number; fixedRearPressureBar?: number; ignoreWidthFilter?: boolean; track?: TrackSegment; routeProfile?: RouteProfile },
): TireSetup | null {
  if (!frontTire.widths.includes(frontWidthMm) || !rearTire.widths.includes(rearWidthMm)) return null
  if (!opts?.ignoreWidthFilter) {
    const minFront = rider.minFrontTireWidthMm ?? rider.minTireWidthMm
    const maxFront = rider.maxFrontTireWidthMm ?? rider.maxTireWidthMm
    const minRear = rider.minRearTireWidthMm ?? rider.minTireWidthMm
    const maxRear = rider.maxRearTireWidthMm ?? rider.maxTireWidthMm
    if (frontWidthMm < minFront || frontWidthMm > maxFront) return null
    if (rearWidthMm < minRear || rearWidthMm > maxRear) return null
  }

  // System mass includes sealant (2 tires × sealantGrams) when tubeless.
  const sealantKg = (rider.hasTubeless && (rider.sealantGrams ?? 0) > 0)
    ? 2 * (rider.sealantGrams ?? 0) / 1000
    : 0
  const totalMassKg = rider.riderWeightKg + rider.bikeWeightKg + sealantKg

  const tireAgeKm  = rider.tireAgeKm ?? 0
  const tempCelsius = rider.ambientTempCelsius ?? T_REF_C
  const crrModel    = rider.crrModel ?? 'physical'
  const rhoAir      = computeAirDensity(tempCelsius, rider.airPressureHPa ?? 1013.25, rider.humidityPct ?? 45)

  const totalDist = routeDistance(surfaces, totalDistanceM)
  const avgIRI = routeAvgIri(surfaces, totalDist)
  const domSurface = dominantSurface(surfaces)

  const fixedFront = opts?.fixedFrontPressureBar ?? opts?.fixedPressureBar
  const fixedRear = opts?.fixedRearPressureBar ?? opts?.fixedPressureBar
  const frontInfo = fixedFront !== undefined
    ? { pressure: fixedFront, min: fixedFront, max: fixedFront, clamped: false }
    : routePressureInfo(totalMassKg, frontWidthMm, false,
        frontTire.tubeless, surfaces, totalDistanceM, frontTire.minPressureBar, frontTire.maxPressureBar)
  const rearInfo = fixedRear !== undefined
    ? { pressure: fixedRear, min: fixedRear, max: fixedRear, clamped: false }
    : routePressureInfo(totalMassKg, rearWidthMm, true,
        rearTire.tubeless, surfaces, totalDistanceM, rearTire.minPressureBar, rearTire.maxPressureBar)
  const pFront = frontInfo.pressure
  const pRear  = rearInfo.pressure

  // Aerodynamic drag for this setup (depends on rider + front/rear tire widths)
  const cdA = computeCdA(rider, frontWidthMm, rearWidthMm)

  // Speed & time are integrated over the (grade × surface) route profile, using
  // the real per-section power when a FIT file provided it, else the rider's
  // average power. Built once per analysis; rebuilt here only for direct calls.
  const profile = opts?.routeProfile
    ?? buildRouteProfile(opts?.track, surfaces, !!opts?.track?.hasPowerData)
  const profTotal = profile.totalDistanceM || totalDist

  let totalTimeSec = 0
  let sumRR = 0, sumAero = 0, sumGravity = 0
  let crrWeighted = 0

  for (const bin of profile.bins) {
    if (bin.distanceMeters <= 0) continue
    const frac = bin.distanceMeters / profTotal
    const grade = bin.gradePct / 100
    const power = bin.avgPowerW ?? rider.avgPowerW
    const crrEff = effectivePairCrr(
      frontTire, frontWidthMm, pFront,
      rearTire, rearWidthMm, pRear,
      bin.category, bin.iri, tireAgeKm, tempCelsius, crrModel, totalMassKg,
    )
    const speedMs = estimateSpeed(power, grade, crrEff, totalMassKg, cdA, rhoAir)
    totalTimeSec += bin.distanceMeters / speedMs

    const pb = powerBreakdown(speedMs, grade, crrEff, totalMassKg, cdA, rhoAir)
    sumRR      += pb.rr      * frac
    sumAero    += pb.aero    * frac
    sumGravity += pb.gravity * frac
    crrWeighted += crrEff * frac
  }

  // Puncture / handling risk are distance-weighted over the surface segments.
  let sumPunctureRisk = 0, sumHandlingRisk = 0
  for (const seg of surfaces) {
    if (seg.distanceMeters <= 0) continue
    const frac = seg.distanceMeters / totalDist
    sumPunctureRisk += seg.surface.punctureRiskFactor * frac
    sumHandlingRisk += seg.surface.handlingRiskFactor * frac
  }

  const protection = frontTire.punctureProtection * 0.45 + rearTire.punctureProtection * 0.55
  const tubelessFactor = (frontTire.tubeless ? 0.45 : 0) + (rearTire.tubeless ? 0.55 : 0)
  const punctureRiskScore = Math.round(100 - ((sumPunctureRisk - 1.0) / 2.0) * 100 *
    (1 / protection) * (1 - tubelessFactor * 0.15))
  const widthImbalancePenalty = Math.max(0, rearWidthMm - frontWidthMm - 4) * 1.5
  const handlingRiskScore = Math.round(100 - ((sumHandlingRisk - 1.0) / 2.0) * 80 - widthImbalancePenalty)

  const overallScore = Math.round(0.6 * Math.min(100, (3600 / totalTimeSec) * 50)
    + 0.25 * punctureRiskScore
    + 0.15 * handlingRiskScore)

  return {
    frontTire,
    rearTire,
    frontWidthMm,
    rearWidthMm,
    tire: rearTire,
    widthMm: rearWidthMm,
    pressureFrontBar: pFront,
    pressureRearBar:  pRear,
    pressureFrontInfo: frontInfo,
    pressureRearInfo:  rearInfo,
    dominantSurface:   domSurface,
    avgIri:            avgIRI,
    crrEffective:     crrWeighted,
    cdA,
    totalTimeSec,
    timeSavingVsWorstSec: 0,
    speedScore: 0,   // filled by optimizer (relative to candidate set)
    punctureRiskScore: Math.max(0, Math.min(100, punctureRiskScore)),
    handlingRiskScore: Math.max(0, Math.min(100, handlingRiskScore)),
    overallScore:      Math.max(0, Math.min(100, overallScore)),
    powerBreakdown: { rollingResistanceW: sumRR, aerodynamicW: sumAero, gravityW: sumGravity },
  }
}

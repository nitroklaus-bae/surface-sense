import type { TireSetup } from './types'
import type { Units } from './units'
import { formatDistance, formatTime } from './tireOptimizer'
import { fmtPressure, pressureUnitLabel } from './units'
import { SURFACE_PROPS } from './surfaceAnalyzer'

export interface SetupMeta {
  fileName: string | null
  distanceM: number
  elevGainM: number
  units: Units
}

export function setupSummaryText(s: TireSetup, m: SetupMeta): string {
  const unit = pressureUnitLabel(m.units)
  return [
    'SurfaceSense - Reifenempfehlung',
    m.fileName ? `Strecke: ${m.fileName}` : null,
    `Distanz: ${formatDistance(m.distanceM)} | +${Math.round(m.elevGainM)} m | ueberwiegend ${SURFACE_PROPS[s.dominantSurface].label}`,
    '',
    `Vorderreifen: ${s.frontTire.brand} ${s.frontTire.model} (${s.frontWidthMm} mm, ${s.frontTire.tubeless ? 'Tubeless' : 'Clincher'})`,
    `Hinterreifen: ${s.rearTire.brand} ${s.rearTire.model} (${s.rearWidthMm} mm, ${s.rearTire.tubeless ? 'Tubeless' : 'Clincher'})`,
    `Druck vorn: ${fmtPressure(s.pressureFrontInfo.pressure, m.units)} ${unit} (Bereich ${fmtPressure(s.pressureFrontInfo.min, m.units)}-${fmtPressure(s.pressureFrontInfo.max, m.units)})`,
    `Druck hinten: ${fmtPressure(s.pressureRearInfo.pressure, m.units)} ${unit} (Bereich ${fmtPressure(s.pressureRearInfo.min, m.units)}-${fmtPressure(s.pressureRearInfo.max, m.units)})`,
    `Crr effektiv: ${(s.crrEffective * 1000).toFixed(2)} x10^-3`,
    `Geschaetzte Zeit: ${formatTime(s.totalTimeSec)}`,
    `Pannenschutz: ${s.punctureRiskScore}/100 | Handling: ${s.handlingRiskScore}/100`,
  ].filter(Boolean).join('\n')
}

export async function copySetupSummary(s: TireSetup, m: SetupMeta): Promise<boolean> {
  const text = setupSummaryText(s, m)
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    return false
  }
}

export function downloadSetupPng(s: TireSetup, m: SetupMeta): void {
  const W = 900
  const H = 560
  const dpr = 2
  const canvas = document.createElement('canvas')
  canvas.width = W * dpr
  canvas.height = H * dpr
  const ctx = canvas.getContext('2d')
  if (!ctx) return
  ctx.scale(dpr, dpr)
  const unit = pressureUnitLabel(m.units)

  ctx.fillStyle = '#0f172a'
  ctx.fillRect(0, 0, W, H)
  ctx.fillStyle = '#1e293b'
  roundRect(ctx, 24, 24, W - 48, H - 48, 20)
  ctx.fill()

  ctx.fillStyle = '#f8fafc'
  ctx.font = 'bold 30px system-ui, sans-serif'
  ctx.fillText('SurfaceSense Reifenempfehlung', 56, 78)
  ctx.fillStyle = '#94a3b8'
  ctx.font = '15px system-ui, sans-serif'
  ctx.fillText(`${m.fileName ?? 'Strecke'} | ${formatDistance(m.distanceM)} | +${Math.round(m.elevGainM)} m | ${SURFACE_PROPS[s.dominantSurface].label}`, 56, 104)

  drawTire(ctx, 56, 154, 'VORDERREIFEN', s.frontTire.brand, s.frontTire.model, s.frontWidthMm, s.frontTire.tubeless, s.frontTire.weightGrams)
  drawTire(ctx, 56, 252, 'HINTERREIFEN', s.rearTire.brand, s.rearTire.model, s.rearWidthMm, s.rearTire.tubeless, s.rearTire.weightGrams)

  const cardY = 346
  const cardH = 112
  const gap = 20
  const cardW = (W - 112 - 2 * gap) / 3
  const cards: [string, string, string][] = [
    ['Druck vorn', fmtPressure(s.pressureFrontInfo.pressure, m.units), unit],
    ['Druck hinten', fmtPressure(s.pressureRearInfo.pressure, m.units), unit],
    ['Zeit', formatTime(s.totalTimeSec), ''],
  ]

  cards.forEach(([label, value, cardUnit], i) => {
    const x = 56 + i * (cardW + gap)
    ctx.fillStyle = '#0f172a'
    roundRect(ctx, x, cardY, cardW, cardH, 14)
    ctx.fill()
    ctx.fillStyle = '#94a3b8'
    ctx.font = '14px system-ui, sans-serif'
    ctx.fillText(label, x + 18, cardY + 30)
    ctx.fillStyle = '#f8fafc'
    ctx.font = 'bold 34px system-ui, sans-serif'
    ctx.fillText(value, x + 18, cardY + 76)
    if (cardUnit) {
      ctx.fillStyle = '#64748b'
      ctx.font = '15px system-ui, sans-serif'
      ctx.fillText(cardUnit, x + 18, cardY + 98)
    }
  })

  ctx.fillStyle = '#94a3b8'
  ctx.font = '14px system-ui, sans-serif'
  ctx.fillText(`Crr ${(s.crrEffective * 1000).toFixed(2)} x10^-3 | Panne ${s.punctureRiskScore}/100 | Handling ${s.handlingRiskScore}/100`, 56, 500)
  ctx.fillStyle = '#475569'
  ctx.font = '12px system-ui, sans-serif'
  ctx.fillText('SurfaceSense Dashboard | Front/Rear getrennt berechnet', 56, H - 34)

  canvas.toBlob((blob) => {
    if (!blob) return
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `surfacesense-${s.frontTire.model.replace(/\s+/g, '-').toLowerCase()}-${s.rearTire.model.replace(/\s+/g, '-').toLowerCase()}.png`
    a.click()
    URL.revokeObjectURL(url)
  }, 'image/png')
}

function drawTire(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  label: string,
  brand: string,
  model: string,
  widthMm: number,
  tubeless: boolean,
  weightGrams: number,
) {
  ctx.fillStyle = '#67e8f9'
  ctx.font = 'bold 13px system-ui, sans-serif'
  ctx.fillText(label, x, y)
  ctx.fillStyle = '#f8fafc'
  ctx.font = 'bold 28px system-ui, sans-serif'
  ctx.fillText(`${brand} ${model}`, x, y + 34)
  ctx.fillStyle = '#cbd5e1'
  ctx.font = '16px system-ui, sans-serif'
  ctx.fillText(`${widthMm} mm | ${tubeless ? 'Tubeless' : 'Clincher'} | ${weightGrams} g`, x, y + 60)
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.arcTo(x + w, y, x + w, y + h, r)
  ctx.arcTo(x + w, y + h, x, y + h, r)
  ctx.arcTo(x, y + h, x, y, r)
  ctx.arcTo(x, y, x + w, y, r)
  ctx.closePath()
}

export type Units = 'bar' | 'psi'

export const BAR_TO_PSI = 14.5038

export function fmtPressure(bar: number, units: Units): string {
  return units === 'psi'
    ? `${Math.round(bar * BAR_TO_PSI)}`
    : `${bar.toFixed(1)}`
}

export function pressureUnitLabel(units: Units): string {
  return units === 'psi' ? 'psi' : 'bar'
}

import type { TrackPoint, TrackSegment } from './types'

const R = 6371000 // Earth radius in meters

export function haversineDistance(a: TrackPoint, b: TrackPoint): number {
  const φ1 = (a.lat * Math.PI) / 180
  const φ2 = (b.lat * Math.PI) / 180
  const Δφ = ((b.lat - a.lat) * Math.PI) / 180
  const Δλ = ((b.lon - a.lon) * Math.PI) / 180
  const x = Math.sin(Δφ / 2) ** 2 + Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) ** 2
  return 2 * R * Math.asin(Math.sqrt(x))
}

// ── GPX Parser ──────────────────────────────────────────────────────
export function parseGPX(text: string): TrackSegment {
  const parser = new DOMParser()
  const doc = parser.parseFromString(text, 'application/xml')

  const trkpts = Array.from(doc.querySelectorAll('trkpt'))
  if (trkpts.length === 0) throw new Error('Keine Trackpunkte in GPX-Datei gefunden.')

  const points: TrackPoint[] = trkpts.map((pt) => {
    const lat = parseFloat(pt.getAttribute('lat') ?? '0')
    const lon = parseFloat(pt.getAttribute('lon') ?? '0')
    const ele = parseFloat(pt.querySelector('ele')?.textContent ?? '0')
    const timeStr = pt.querySelector('time')?.textContent
    const power = parseFloat(pt.querySelector('power')?.textContent ?? 'NaN')
    const hr = parseFloat(
      (pt.querySelector('hr') ?? pt.querySelector('heartrate') ?? pt.querySelector('HeartRateBpm Value'))
        ?.textContent ?? 'NaN'
    )
    return {
      lat, lon,
      elevation: isNaN(ele) ? 0 : ele,
      time: timeStr ? new Date(timeStr) : undefined,
      power: isNaN(power) ? undefined : power,
      heartRate: isNaN(hr) ? undefined : hr,
    }
  })

  return buildSegment(points)
}

// ── FIT Parser (binary) ─────────────────────────────────────────────
// Handles FIT Protocol 1.0 + 2.0 (developer fields) + compressed timestamps.
// Standard FIT record field numbers (global msg 20):
//   0=position_lat  1=position_long  2=altitude  3=heart_rate  4=cadence
//   5=distance      6=speed          7=power     253=timestamp
// SurfaceSense developer field: dev_data_index=0, fieldNumber=4 → IRI float32
export function parseFIT(buffer: ArrayBuffer): TrackSegment {
  const view = new DataView(buffer)
  const points: TrackPoint[] = []

  if (buffer.byteLength < 12) throw new Error('FIT-Datei zu klein.')
  const headerSize = view.getUint8(0)
  const dataSize   = view.getUint32(4, true)
  const magic      = String.fromCharCode(view.getUint8(8), view.getUint8(9), view.getUint8(10), view.getUint8(11))
  if (magic !== '.FIT') throw new Error('Ungültiges FIT-Format.')

  // MsgDef stores fields + total byte size so we can safely skip unknown data records.
  interface MsgDef {
    fields:     FitFieldDef[]
    recordSize: number               // sum of all field sizes (standard + dev)
    devFields?: FitDevFieldDef[]
  }
  const localMsgDefs: Record<number, MsgDef> = {}

  let pos = headerSize
  const end = Math.min(headerSize + dataSize, buffer.byteLength)

  while (pos < end) {
    if (pos + 1 > end) break
    const recordHeader = view.getUint8(pos); pos++

    // ── Compressed timestamp record (bit 7 = 1) ─────────────────────
    // Bit 7=1, bits 5-4 = local msg type (0-3), bits 3-0 = time offset.
    // MUST be checked before the isDefinition test because local-msg-type ≥ 1
    // sets bit 6, which would be misread as a definition header otherwise.
    if (recordHeader & 0x80) {
      const localMsgType = (recordHeader >> 5) & 0x03
      const def = localMsgDefs[localMsgType]
      if (!def) continue  // haven't seen a definition yet — skip byte
      if (pos + def.recordSize > end) break
      pos = readDataRecord(view, pos, end, def, points)
      continue
    }

    const isDefinition = (recordHeader & 0x40) !== 0
    const hasDevFields = (recordHeader & 0x20) !== 0
    const localMsgType = recordHeader & 0x0f

    if (isDefinition) {
      // ── Definition message ───────────────────────────────────────
      if (pos + 5 > end) break
      pos++  // reserved byte
      const arch       = view.getUint8(pos); pos++
      const le         = arch === 0
      /* globalMsgNum */ le ? view.getUint16(pos, true) : view.getUint16(pos, false); pos += 2
      const numFields  = view.getUint8(pos); pos++
      if (pos + numFields * 3 > end) break
      const fields: FitFieldDef[] = []
      let recordSize = 0
      for (let i = 0; i < numFields; i++) {
        const fieldDef = view.getUint8(pos); pos++
        const size     = view.getUint8(pos); pos++
        pos++  // base type
        fields.push({ fieldDef, size })
        recordSize += size
      }
      let devFields: FitDevFieldDef[] | undefined
      if (hasDevFields && pos < end) {
        const numDev = view.getUint8(pos); pos++
        devFields = []
        for (let i = 0; i < numDev; i++) {
          if (pos + 3 > end) break
          const fieldNumber  = view.getUint8(pos); pos++
          const size         = view.getUint8(pos); pos++
          const devDataIndex = view.getUint8(pos); pos++
          devFields.push({ fieldNumber, size, devDataIndex })
          recordSize += size
        }
      }
      localMsgDefs[localMsgType] = { fields, recordSize, devFields }

    } else {
      // ── Data record ──────────────────────────────────────────────
      const def = localMsgDefs[localMsgType]
      if (!def) continue  // unknown type, can't skip safely; try next byte
      if (pos + def.recordSize > end) break
      pos = readDataRecord(view, pos, end, def, points)
    }
  }

  if (points.length === 0) throw new Error('Keine GPS-Punkte im FIT-File gefunden.')
  return buildSegment(points)
}

/** Process one data record, push a TrackPoint if lat+lon are valid, return new pos. */
function readDataRecord(
  view: DataView,
  pos: number,
  end: number,
  def: { fields: { fieldDef: number; size: number }[]; recordSize: number; devFields?: FitDevFieldDef[] },
  points: TrackPoint[],
): number {
  let lat: number | undefined, lon: number | undefined, ele: number | undefined
  let power: number | undefined, hr: number | undefined, cad: number | undefined
  let speed: number | undefined, dist: number | undefined, timestamp: number | undefined

  for (const field of def.fields) {
    if (pos + field.size > end) { pos += field.size; continue }
    switch (field.fieldDef) {
      // Standard FIT record message fields (global msg 20)
      case 253: if (field.size === 4) timestamp = view.getUint32(pos, true);               break // timestamp
      case 0:   if (field.size === 4) lat   = view.getInt32(pos,  true) * (180 / 2 ** 31); break // position_lat
      case 1:   if (field.size === 4) lon   = view.getInt32(pos,  true) * (180 / 2 ** 31); break // position_long
      case 2:   if (field.size === 2) ele   = (view.getUint16(pos, true) / 5) - 500;       break // altitude
      case 3:   if (field.size === 1) hr    = view.getUint8(pos);                           break // heart_rate
      case 4:   if (field.size === 1) cad   = view.getUint8(pos);                           break // cadence
      case 5:   if (field.size === 4) dist  = view.getUint32(pos, true) / 100;             break // distance (cm→m)
      case 6:   if (field.size === 2) speed = view.getUint16(pos, true) / 1000;            break // speed (mm/s→m/s)
      case 7:   if (field.size === 2) power = view.getUint16(pos, true);                   break // power
    }
    pos += field.size
  }

  // Developer fields — SurfaceSense IRI (dev_data_index=0, fieldNumber=4, float32)
  let iri: number | undefined
  if (def.devFields) {
    for (const df of def.devFields) {
      if (pos + df.size > end) { pos += df.size; continue }
      if (df.devDataIndex === 0 && df.fieldNumber === 4 && df.size === 4) {
        const raw = view.getFloat32(pos, true)
        if (!isNaN(raw) && raw > 0 && raw < 50) iri = raw
      }
      pos += df.size
    }
  }

  // lat=0 AND lon=0 is "Null Island" — almost certainly an invalid GPS fix, skip it.
  const nullIsland = lat === 0 && lon === 0
  if (lat !== undefined && lon !== undefined && Math.abs(lat) < 90 && Math.abs(lon) < 180 && !nullIsland) {
    points.push({
      lat, lon,
      elevation: ele ?? 0,
      time: timestamp !== undefined ? new Date((timestamp + 631065600) * 1000) : undefined,
      power:     power     !== undefined && power     < 65535 ? power     : undefined,
      heartRate: hr        !== undefined && hr        <   255 ? hr        : undefined,
      cadence:   cad       !== undefined && cad       <   255 ? cad       : undefined,
      speed:     speed     !== undefined && speed     <   655 ? speed     : undefined,
      distance:  dist,
      iri,
    })
  }
  return pos
}

interface FitFieldDef    { fieldDef: number; size: number }
interface FitDevFieldDef { fieldNumber: number; size: number; devDataIndex: number }

// ── Track densification ─────────────────────────────────────────────
// Surface resolution is bounded by GPS point spacing: a way transition can only
// be detected where there's a sample. We up-sample so consecutive points are
// ≤ ~20 m apart (linear interpolation), placing surface boundaries to ~20 m.
// Up-sample only — densely-recorded tracks (≤20 m already) are left untouched,
// so power/pacing metrics on real FIT files are unaffected.
const MAX_POINT_SPACING_M = 20

function lerpPoint(a: TrackPoint, b: TrackPoint, t: number): TrackPoint {
  const mix = (x?: number, y?: number) =>
    x !== undefined && y !== undefined ? x + (y - x) * t : undefined
  return {
    lat: a.lat + (b.lat - a.lat) * t,
    lon: a.lon + (b.lon - a.lon) * t,
    elevation: a.elevation + (b.elevation - a.elevation) * t,
    power: mix(a.power, b.power),
    heartRate: mix(a.heartRate, b.heartRate),
    cadence: mix(a.cadence, b.cadence),
    speed: mix(a.speed, b.speed),
    iri: mix(a.iri, b.iri),  // interpolate measured IRI between GPS points
    time: a.time && b.time
      ? new Date(a.time.getTime() + (b.time.getTime() - a.time.getTime()) * t)
      : undefined,
  }
}

export function densifyTrack(points: TrackPoint[], maxSpacingM = MAX_POINT_SPACING_M): TrackPoint[] {
  if (points.length < 2) return points
  const out: TrackPoint[] = [points[0]]
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], b = points[i]
    const d = haversineDistance(a, b)
    // Skip densification for large gaps (> 500 m = GPS dropout or invalid jump).
    // Without this cap, a single bad coordinate causes millions of inserts.
    if (d > maxSpacingM && d <= 500) {
      const inserts = Math.ceil(d / maxSpacingM) - 1
      for (let k = 1; k <= inserts; k++) out.push(lerpPoint(a, b, k / (inserts + 1)))
    }
    out.push(b)
  }
  return out
}

// ── Common segment builder ──────────────────────────────────────────
function buildSegment(rawPoints: TrackPoint[]): TrackSegment {
  const points = densifyTrack(rawPoints)
  let totalDistance = 0
  let totalElevGain = 0
  let totalElevLoss = 0
  let powerSum = 0
  let powerCount = 0

  for (let i = 1; i < points.length; i++) {
    const d = haversineDistance(points[i - 1], points[i])
    totalDistance += d
    points[i].distance = totalDistance

    const Δe = points[i].elevation - points[i - 1].elevation
    if (Δe > 0) totalElevGain += Δe
    else totalElevLoss += Math.abs(Δe)

    if (points[i].power !== undefined) {
      powerSum += points[i].power!
      powerCount++
    }
  }

  const first = points[0]
  const last = points[points.length - 1]
  const durationSeconds =
    first.time && last.time
      ? (last.time.getTime() - first.time.getTime()) / 1000
      : undefined

  return {
    points,
    totalDistance,
    totalElevGain,
    totalElevLoss,
    durationSeconds,
    avgPower: powerCount > 0 ? powerSum / powerCount : undefined,
    hasPowerData: powerCount > 10,
  }
}

// ── File dispatcher ─────────────────────────────────────────────────
export async function parseTrackFile(file: File): Promise<TrackSegment> {
  const ext = file.name.split('.').pop()?.toLowerCase()

  if (ext === 'gpx') {
    const text = await file.text()
    return parseGPX(text)
  }

  if (ext === 'fit') {
    const buffer = await file.arrayBuffer()
    return parseFIT(buffer)
  }

  throw new Error(`Nicht unterstütztes Dateiformat: .${ext}. Bitte GPX oder FIT hochladen.`)
}

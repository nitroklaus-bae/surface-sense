import type { TrackPoint, TrackSegment } from './types'
import { haversineDistance } from './trackParser'

export interface StravaStreams {
  latlng?:   { data: [number, number][] }
  altitude?: { data: number[] }
  time?:     { data: number[] }
  distance?: { data: number[] }
  watts?:    { data: number[] }
}

/** Convert Strava activity streams (key_by_type=true) to a TrackSegment. */
export function stravaStreamsToTrack(
  streams: StravaStreams,
  startTime?: Date,
): TrackSegment {
  const latlng  = streams.latlng?.data  ?? []
  if (latlng.length === 0)
    throw new Error('Keine GPS-Punkte in der Strava-Aktivität gefunden.')

  const alt    = streams.altitude?.data  ?? []
  const times  = streams.time?.data      ?? []
  const distArr = streams.distance?.data ?? []
  const wattsArr = streams.watts?.data   ?? []

  const points: TrackPoint[] = latlng.map(([lat, lon], i) => ({
    lat,
    lon,
    elevation: alt[i] ?? 0,
    time:      startTime && times[i] !== undefined
               ? new Date(startTime.getTime() + times[i] * 1000)
               : undefined,
    power:     (wattsArr[i] ?? 0) > 0 ? wattsArr[i] : undefined,
    distance:  distArr[i] ?? undefined,
  }))

  // Recompute distances if not provided by Strava
  if (distArr.length === 0 && points.length > 1) {
    points[0].distance = 0
    for (let i = 1; i < points.length; i++) {
      points[i].distance = (points[i - 1].distance ?? 0) + haversineDistance(points[i - 1], points[i])
    }
  }

  let totalDistance  = distArr.length > 0 ? (distArr[distArr.length - 1] ?? 0) : (points[points.length - 1].distance ?? 0)
  let totalElevGain  = 0
  let powerCount     = 0

  for (let i = 1; i < points.length; i++) {
    const de = points[i].elevation - points[i - 1].elevation
    if (de > 0) totalElevGain += de
    if (points[i].power !== undefined) powerCount++
  }

  return {
    points,
    totalDistance,
    totalElevGain,
    hasPowerData: powerCount > points.length * 0.05,
  }
}

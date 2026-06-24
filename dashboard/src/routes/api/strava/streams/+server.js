import { json, error } from '@sveltejs/kit'

// Proxy for Strava activity streams (GPS + power + elevation).
export async function GET({ url }) {
  const token = url.searchParams.get('token')
  const id    = url.searchParams.get('id')
  if (!token || !id) throw error(400, 'token and id required')

  const keys = 'latlng,altitude,time,distance,watts'
  let res
  try {
    res = await fetch(
      `https://www.strava.com/api/v3/activities/${id}/streams?keys=${keys}&key_by_type=true`,
      { headers: { Authorization: `Bearer ${token}` } }
    )
  } catch {
    throw error(502, 'Strava nicht erreichbar')
  }

  if (!res.ok) {
    const data = await res.json().catch(() => ({}))
    throw error(res.status, data.message ?? 'Strava streams error')
  }
  return json(await res.json())
}

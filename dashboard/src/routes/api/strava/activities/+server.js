import { json, error } from '@sveltejs/kit'

// Proxy for Strava athlete activities list.
export async function GET({ url }) {
  const token = url.searchParams.get('token')
  const page  = url.searchParams.get('page') ?? '1'
  if (!token) throw error(401, 'token required')

  let res
  try {
    res = await fetch(
      `https://www.strava.com/api/v3/athlete/activities?per_page=30&page=${page}`,
      { headers: { Authorization: `Bearer ${token}` } }
    )
  } catch {
    throw error(502, 'Strava nicht erreichbar')
  }

  if (!res.ok) {
    const data = await res.json().catch(() => ({}))
    throw error(res.status, data.message ?? 'Strava API error')
  }
  return json(await res.json())
}

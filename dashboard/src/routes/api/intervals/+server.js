import { json, error } from '@sveltejs/kit'

// Proxy for intervals.icu activities list — avoids CORS issues in browser.
export async function GET({ url }) {
  const athleteId = url.searchParams.get('athleteId')
  const apiKey    = url.searchParams.get('apiKey')
  if (!athleteId || !apiKey) throw error(400, 'athleteId and apiKey required')

  const oldest = url.searchParams.get('oldest')
    ?? new Date(Date.now() - 90 * 86400_000).toISOString().split('T')[0]
  const newest = new Date().toISOString().split('T')[0]

  const auth = Buffer.from(`API_KEY:${apiKey}`).toString('base64')
  let res
  try {
    res = await fetch(
      `https://intervals.icu/api/v1/athlete/${athleteId}/activities` +
      `?oldest=${oldest}&newest=${newest}&limit=60`,
      { headers: { Authorization: `Basic ${auth}` } }
    )
  } catch (e) {
    throw error(502, 'intervals.icu nicht erreichbar')
  }

  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw error(res.status, `intervals.icu: ${text.slice(0, 200)}`)
  }
  return json(await res.json())
}

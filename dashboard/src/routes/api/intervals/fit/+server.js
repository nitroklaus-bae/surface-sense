import { error } from '@sveltejs/kit'
import { gunzipSync } from 'zlib'

// Proxy FIT download from intervals.icu.
// Correct endpoint (per intervals.icu API cookbook):
//   GET /api/v1/activity/{id}/fit-file  — always returns a FIT, gzip-compressed
// Activity IDs look like "i55751783" (from the activities list).
export async function GET({ url }) {
  const athleteId = url.searchParams.get('athleteId')   // needed for auth only
  const apiKey    = url.searchParams.get('apiKey')
  const id        = url.searchParams.get('id')           // e.g. "i55751783"
  if (!apiKey || !id) throw error(400, 'apiKey and id required')

  const auth = Buffer.from(`API_KEY:${apiKey}`).toString('base64')

  let res
  try {
    res = await fetch(
      `https://intervals.icu/api/v1/activity/${id}/fit-file`,
      {
        headers: {
          Authorization: `Basic ${auth}`,
          Accept: '*/*',
        },
        redirect: 'follow',
      }
    )
  } catch (e) {
    throw error(502, `intervals.icu nicht erreichbar: ${e?.message ?? e}`)
  }

  if (!res.ok) {
    const text = await res.text().catch(() => '')
    let msg = text
    try { msg = JSON.parse(text)?.message ?? text } catch {}
    throw error(res.status, `FIT-Download fehlgeschlagen (${res.status}): ${msg.slice(0, 300)}`)
  }

  // Response body is gzip-compressed — decompress before sending to client.
  const compressed = Buffer.from(await res.arrayBuffer())
  let fitBuffer
  try {
    fitBuffer = gunzipSync(compressed)
  } catch {
    // Not gzip — maybe already raw FIT (some endpoints skip compression)
    fitBuffer = compressed
  }

  if (fitBuffer.byteLength < 12) {
    throw error(502, `FIT-Datei zu klein nach Dekompression (${fitBuffer.byteLength} Bytes)`)
  }

  const magic = String.fromCharCode(fitBuffer[8], fitBuffer[9], fitBuffer[10], fitBuffer[11])
  if (magic !== '.FIT') {
    const preview = fitBuffer.slice(0, 200).toString('utf-8')
    throw error(502, `Kein gültiges FIT (magic="${magic}"): ${preview}`)
  }

  return new Response(fitBuffer, {
    headers: { 'Content-Type': 'application/octet-stream' }
  })
}

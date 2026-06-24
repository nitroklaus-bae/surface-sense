import { redirect, error } from '@sveltejs/kit'

// Strava OAuth callback — exchanges code for access token, redirects to /crr with token in hash.
export async function GET({ url }) {
  const clientId     = process.env.STRAVA_CLIENT_ID
  const clientSecret = process.env.STRAVA_CLIENT_SECRET

  const code    = url.searchParams.get('code')
  const errCode = url.searchParams.get('error')

  if (errCode || !code) {
    throw redirect(302, `/crr?strava_error=${encodeURIComponent(errCode ?? 'access_denied')}`)
  }

  let res
  try {
    res = await fetch('https://www.strava.com/oauth/token', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ client_id: clientId, client_secret: clientSecret, code, grant_type: 'authorization_code' }),
    })
  } catch {
    throw redirect(302, '/crr?strava_error=network_error')
  }

  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    throw redirect(302, `/crr?strava_error=${encodeURIComponent(data.message ?? 'auth_failed')}`)
  }

  const { access_token, expires_at, athlete } = data
  const athletePayload = encodeURIComponent(JSON.stringify({
    id:   athlete?.id,
    name: `${athlete?.firstname ?? ''} ${athlete?.lastname ?? ''}`.trim(),
  }))

  // Pass token via URL fragment — not sent to server on subsequent requests.
  throw redirect(302,
    `/crr#strava_token=${access_token}&strava_expires=${expires_at}&strava_athlete=${athletePayload}`
  )
}

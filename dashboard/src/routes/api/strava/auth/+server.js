import { redirect, error } from '@sveltejs/kit'

// Start Strava OAuth flow — redirects to Strava authorization page.
export async function GET({ url }) {
  const clientId = process.env.STRAVA_CLIENT_ID
  if (!clientId) throw error(503, 'STRAVA_CLIENT_ID nicht konfiguriert. Bitte in Vercel-Umgebungsvariablen setzen.')

  const redirectUri  = `${url.origin}/api/strava/callback`
  const state        = Math.random().toString(36).slice(2, 10)
  const authUrl      = new URL('https://www.strava.com/oauth/authorize')
  authUrl.searchParams.set('client_id',     clientId)
  authUrl.searchParams.set('redirect_uri',  redirectUri)
  authUrl.searchParams.set('response_type', 'code')
  authUrl.searchParams.set('scope',         'activity:read_all')
  authUrl.searchParams.set('state',         state)

  throw redirect(302, authUrl.toString())
}

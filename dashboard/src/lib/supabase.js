import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL  = 'https://cpxdxchlyvdbnsewicbq.supabase.co';
const SUPABASE_ANON = 'sb_publishable_RPToUB4fonmTaGfdC3WZ2w_bOYdSGcc';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON);

// ── Auth-Helpers ──────────────────────────────────────────────────────────────

export async function getSession() {
  const { data: { session } } = await supabase.auth.getSession();
  return session;
}

export async function signIn(email, password) {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

export async function signOut() {
  await supabase.auth.signOut();
}

/** E-Mail-Adressen mit Admin-Zugriff */
const ADMIN_EMAILS = ['nikolaus.baetge@gmx.de'];

/** Gibt true zurück, wenn der aktuelle User Admin ist. */
export async function isAdmin() {
  const { data: { session } } = await supabase.auth.getSession();
  return ADMIN_EMAILS.includes(session?.user?.email ?? '');
}

// ── Daten-Helpers ─────────────────────────────────────────────────────────────

/** Lädt Fahrten. Admins sehen alle User, normale User nur ihre eigenen. */
export async function fetchRides() {
  const admin = await isAdmin();
  let q = supabase
    .from('rides')
    .select(admin ? '*, user_email' : '*')
    .order('started_at', { ascending: false });

  const { data, error } = await q;
  if (error) throw error;
  return { rides: data, admin };
}

export async function fetchSamples(rideId) {
  const { data, error } = await supabase
    .from('surface_samples')
    .select('ts_ms, rms_g, vdv_g, iri_m_km, lat, lon, speed_kmh')
    .eq('ride_id', rideId)
    .order('ts_ms');
  if (error) throw error;
  return data;
}

export async function deleteRide(rideId, fitPath, csvPath) {
  const paths = [fitPath, csvPath].filter(Boolean);
  if (paths.length) await supabase.storage.from('ride-files').remove(paths);
  const { error } = await supabase.from('rides').delete().eq('id', rideId);
  if (error) throw error;
}

// ── Formatierungs-Helpers ─────────────────────────────────────────────────────

export function fmtDuration(s) {
  if (!s) return '—';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}h ${m}min` : `${m}min`;
}

export function fmtDistance(m) {
  if (!m || m <= 0) return '—';
  return m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`;
}

export function fmtDate(iso) {
  const d = new Date(iso);
  return d.toLocaleDateString('de-DE', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

export function iriColor(iri) {
  if (iri == null) return '#6b7280';
  if (iri < 2)    return '#4ade80';   // grün
  if (iri < 5)    return '#facc15';   // gelb
  if (iri < 8)    return '#f97316';   // orange
  return '#f87171';                    // rot
}

export function iriLabel(iri) {
  if (iri == null) return '—';
  if (iri < 2)    return 'sehr glatt';
  if (iri < 5)    return 'gut';
  if (iri < 8)    return 'mäßig';
  return 'rau';
}

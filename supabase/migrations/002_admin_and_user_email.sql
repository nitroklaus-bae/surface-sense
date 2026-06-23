-- ============================================================
-- Migration 002: Admin-Rolle + user_email in rides
-- Run in: Supabase Dashboard → SQL Editor → Run
-- ============================================================

-- ── user_email Spalte in rides ────────────────────────────────────────────────
ALTER TABLE rides ADD COLUMN IF NOT EXISTS user_email TEXT;

-- ── Admin-User setzen (deine E-Mail) ─────────────────────────────────────────
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data || '{"role": "admin"}'
WHERE email = 'nikolaus.baetge@gmx.de';

-- ── Admin-Policies: Admins sehen und verwalten alle Daten ────────────────────
DROP POLICY IF EXISTS "rides: admin full access" ON rides;
CREATE POLICY "rides: admin full access" ON rides
  FOR ALL USING (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  )
  WITH CHECK (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  );

DROP POLICY IF EXISTS "surface_samples: admin full access" ON surface_samples;
CREATE POLICY "surface_samples: admin full access" ON surface_samples
  FOR ALL USING (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  )
  WITH CHECK (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  );

-- ── Admin-View: alle Fahrten aller User ──────────────────────────────────────
CREATE OR REPLACE VIEW admin_rides AS
SELECT
    r.*,
    CASE
        WHEN r.avg_iri < 2  THEN 'sehr glatt'
        WHEN r.avg_iri < 5  THEN 'gut'
        WHEN r.avg_iri < 8  THEN 'mäßig'
        ELSE                     'rau'
    END AS surface_quality
FROM rides r;

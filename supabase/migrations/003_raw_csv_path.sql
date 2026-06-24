-- ============================================================
-- Migration 003: raw_csv_path in rides
-- Run in: Supabase Dashboard → SQL Editor → Run
-- ============================================================

-- Speicherpfad der Rohdaten-CSV in Supabase Storage
-- Schema: {user_id}/{ride_id}_raw.csv  (Bucket: ride-files)
ALTER TABLE rides ADD COLUMN IF NOT EXISTS raw_csv_path TEXT;

-- Views erst droppen (CREATE OR REPLACE schlägt fehl wenn Spaltenreihenfolge sich ändert)
DROP VIEW IF EXISTS ride_summary;
DROP VIEW IF EXISTS admin_rides;

CREATE VIEW ride_summary AS
SELECT
    r.*,
    CASE
        WHEN r.avg_iri < 2  THEN 'sehr glatt'
        WHEN r.avg_iri < 5  THEN 'gut'
        WHEN r.avg_iri < 8  THEN 'mäßig'
        ELSE                     'rau'
    END AS surface_quality
FROM rides r;

CREATE VIEW admin_rides AS
SELECT
    r.*,
    CASE
        WHEN r.avg_iri < 2  THEN 'sehr glatt'
        WHEN r.avg_iri < 5  THEN 'gut'
        WHEN r.avg_iri < 8  THEN 'mäßig'
        ELSE                      'rau'
    END AS surface_quality
FROM rides r;

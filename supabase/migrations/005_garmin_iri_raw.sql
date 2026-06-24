-- ============================================================
-- Migration 005: Garmin DataField → Supabase IRI-Ingest
-- Run in: Supabase Dashboard → SQL Editor → Run
--
-- Empfängt rohe GPS+IRI-Punkte direkt vom Garmin Edge DataField
-- via Communications.makeWebRequest() → /rest/v1/rpc/ingest_garmin_iri
--
-- Kein Auth erforderlich (anon key reicht) — SECURITY DEFINER
-- überspringt RLS; Plausibilitätschecks in der Funktion.
-- ============================================================

-- ── 1. Rohdaten-Tabelle ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS garmin_iri_raw (
    id         BIGSERIAL   PRIMARY KEY,
    lat        FLOAT4      NOT NULL CHECK (lat  BETWEEN -90  AND 90),
    lon        FLOAT4      NOT NULL CHECK (lon  BETWEEN -180 AND 180),
    iri        FLOAT4      NOT NULL CHECK (iri  > 0 AND iri < 50),
    speed_kmh  FLOAT4      CHECK (speed_kmh >= 0 AND speed_kmh < 200),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Spatial Index für spätere OSM-Zuordnung (PostGIS)
CREATE INDEX IF NOT EXISTS garmin_iri_raw_geom_idx
    ON garmin_iri_raw
    USING GIST (ST_SetSRID(ST_MakePoint(lon::DOUBLE PRECISION, lat::DOUBLE PRECISION), 4326));

-- Zeitindex für Abfragen nach Datum
CREATE INDEX IF NOT EXISTS garmin_iri_raw_created_idx
    ON garmin_iri_raw (created_at DESC);

-- ── 2. RPC: Batch-Ingest vom Garmin DataField ─────────────────────────────────
-- Aufruf: POST /rest/v1/rpc/ingest_garmin_iri
-- Body:   {"points": [{"lat":48.1,"lon":11.5,"iri":3.5,"speed_kmh":25.0}, ...]}
--
-- Garmin sendet alle 60 s einen Batch von ~60 Punkten.
-- SECURITY DEFINER: läuft als Postgres-Superuser → umgeht RLS.
-- Plausibilitätschecks filtern fehlerhafte GPS/IRI-Werte.

CREATE OR REPLACE FUNCTION ingest_garmin_iri(points JSONB)
RETURNS INT                 -- Anzahl erfolgreich eingefügter Punkte
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    inserted INT;
BEGIN
    INSERT INTO garmin_iri_raw (lat, lon, iri, speed_kmh)
    SELECT
        (p->>'lat')::FLOAT4,
        (p->>'lon')::FLOAT4,
        (p->>'iri')::FLOAT4,
        NULLIF(p->>'speed_kmh', '')::FLOAT4
    FROM jsonb_array_elements(points) p
    WHERE
        -- Koordinaten plausibel
        (p->>'lat')::FLOAT4 BETWEEN -90  AND 90
        AND (p->>'lon')::FLOAT4 BETWEEN -180 AND 180
        -- IRI im sinnvollen Bereich (0–50 m/km)
        AND (p->>'iri')::FLOAT4 > 0
        AND (p->>'iri')::FLOAT4 < 50
        -- Nicht am Stillstand gemessen (< 3 km/h → unzuverlässig)
        AND (
            p->>'speed_kmh' IS NULL
            OR (p->>'speed_kmh')::FLOAT4 >= 3
        );

    GET DIAGNOSTICS inserted = ROW_COUNT;
    RETURN inserted;
END;
$$;

-- ── 3. Row-Level-Security ─────────────────────────────────────────────────────
ALTER TABLE garmin_iri_raw ENABLE ROW LEVEL SECURITY;

-- Jeder darf lesen (Community-Layer)
CREATE POLICY "garmin_iri_raw: public read"
    ON garmin_iri_raw FOR SELECT USING (true);

-- Schreiben nur über die SECURITY DEFINER Funktion → keine direkte INSERT-Policy

-- ── 4. Summary-View für Dashboard ────────────────────────────────────────────
DROP VIEW IF EXISTS garmin_iri_summary;
CREATE VIEW garmin_iri_summary AS
SELECT
    -- Geohash-Bucket ~150 m für schnelle Kartenvisualisierung
    round(lat::NUMERIC, 3)  AS lat_bucket,
    round(lon::NUMERIC, 3)  AS lon_bucket,
    avg(iri)::FLOAT4        AS iri_mean,
    count(*)::INT           AS sample_count,
    max(created_at)         AS last_seen,
    CASE
        WHEN avg(iri) < 2  THEN 'sehr glatt'
        WHEN avg(iri) < 5  THEN 'gut'
        WHEN avg(iri) < 8  THEN 'mäßig'
        ELSE                    'rau'
    END AS surface_quality
FROM garmin_iri_raw
GROUP BY lat_bucket, lon_bucket;

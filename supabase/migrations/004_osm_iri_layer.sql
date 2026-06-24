-- ============================================================
-- Migration 004: Community IRI layer
-- Run in: Supabase Dashboard → SQL Editor → Run
--
-- Creates the shared surface database that links measured IRI
-- values (from SurfaceSense rides) to OSM way IDs so that
-- ROLLEX_POC can query crowd-sourced roughness instead of
-- relying solely on static OSM surface tags.
-- ============================================================

-- ── 1. Contributions table ────────────────────────────────────────────
-- One row per (ride, osm_way_id): the distance-weighted mean IRI
-- measured by the SurfaceSense sensor on that OSM segment during
-- that specific ride. Kept raw so the aggregate can be re-computed.

CREATE TABLE IF NOT EXISTS osm_iri_contributions (
    id             BIGSERIAL PRIMARY KEY,
    osm_way_id     BIGINT    NOT NULL,
    ride_id        UUID      REFERENCES rides(id) ON DELETE CASCADE,
    iri_value      FLOAT4    NOT NULL CHECK (iri_value > 0 AND iri_value < 50),
    distance_m     FLOAT4    NOT NULL CHECK (distance_m > 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS osm_iri_contrib_way_idx ON osm_iri_contributions (osm_way_id);
CREATE INDEX IF NOT EXISTS osm_iri_contrib_ride_idx ON osm_iri_contributions (ride_id);

-- ── 2. Aggregate table ────────────────────────────────────────────────
-- Maintained by the upsert function below. Stores running
-- distance-weighted mean IRI per OSM way so reads are O(1).

CREATE TABLE IF NOT EXISTS osm_iri_segments (
    osm_way_id     BIGINT    PRIMARY KEY,
    iri_mean       FLOAT4    NOT NULL,  -- distance-weighted mean IRI (m/km)
    iri_stddev     FLOAT4,              -- stddev across rides (NULL if < 2 rides)
    sample_count   INT       NOT NULL DEFAULT 0,
    total_distance_m FLOAT4 NOT NULL DEFAULT 0,
    last_seen      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 3. RPC: batch upsert from ROLLEX_POC / SurfaceSense app ──────────
-- Called by surfaceSenseApi.ts → pushIriContributions().
-- Accepts an array of {osm_way_id, iri_value, distance_m, ride_id}
-- and updates the running aggregate using an incremental weighted mean.

CREATE OR REPLACE FUNCTION upsert_iri_contributions(
    contributions JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    item JSONB;
BEGIN
    FOR item IN SELECT * FROM jsonb_array_elements(contributions)
    LOOP
        -- Insert raw contribution row
        INSERT INTO osm_iri_contributions (osm_way_id, ride_id, iri_value, distance_m)
        VALUES (
            (item->>'osm_way_id')::BIGINT,
            NULLIF(item->>'ride_id', '')::UUID,
            (item->>'iri_value')::FLOAT4,
            (item->>'distance_m')::FLOAT4
        )
        ON CONFLICT DO NOTHING;

        -- Upsert aggregate: incremental distance-weighted mean
        --   new_mean = (old_mean * old_dist + iri * dist) / (old_dist + dist)
        INSERT INTO osm_iri_segments (osm_way_id, iri_mean, sample_count, total_distance_m, last_seen, updated_at)
        VALUES (
            (item->>'osm_way_id')::BIGINT,
            (item->>'iri_value')::FLOAT4,
            1,
            (item->>'distance_m')::FLOAT4,
            NOW(),
            NOW()
        )
        ON CONFLICT (osm_way_id) DO UPDATE SET
            iri_mean = (
                osm_iri_segments.iri_mean * osm_iri_segments.total_distance_m
                + EXCLUDED.iri_mean * EXCLUDED.total_distance_m
            ) / NULLIF(osm_iri_segments.total_distance_m + EXCLUDED.total_distance_m, 0),
            sample_count   = osm_iri_segments.sample_count + 1,
            total_distance_m = osm_iri_segments.total_distance_m + EXCLUDED.total_distance_m,
            last_seen      = NOW(),
            updated_at     = NOW();
    END LOOP;
END;
$$;

-- ── 4. RPC: batch read by way IDs (ROLLEX_POC query) ─────────────────
-- Called by surfaceSenseApi.ts → fetchOsmIri().
-- Public (anon-readable); no auth needed for reads.

CREATE OR REPLACE FUNCTION get_iri_for_osm_ways(
    way_ids BIGINT[]
)
RETURNS TABLE (
    osm_way_id    BIGINT,
    iri_mean      FLOAT4,
    sample_count  INT,
    last_seen     TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT osm_way_id, iri_mean, sample_count, last_seen
    FROM   osm_iri_segments
    WHERE  osm_way_id = ANY(way_ids)
      AND  sample_count >= 1;   -- require at least 1 ride before exposing
$$;

-- ── 5. Row-level security ─────────────────────────────────────────────
ALTER TABLE osm_iri_contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE osm_iri_segments      ENABLE ROW LEVEL SECURITY;

-- Anyone can read the aggregate layer (needed by ROLLEX_POC anonymous users)
CREATE POLICY "osm_iri_segments: public read"
    ON osm_iri_segments FOR SELECT USING (true);

-- Authenticated users can insert their own contributions
CREATE POLICY "osm_iri_contributions: authenticated insert"
    ON osm_iri_contributions FOR INSERT
    WITH CHECK (auth.role() = 'authenticated');

-- Users can only read their own raw contributions
CREATE POLICY "osm_iri_contributions: own rows"
    ON osm_iri_contributions FOR SELECT
    USING (
        ride_id IN (SELECT id FROM rides WHERE user_id = auth.uid())
    );

-- ── 6. Summary view for the SvelteKit dashboard ──────────────────────
DROP VIEW IF EXISTS osm_iri_summary;
CREATE VIEW osm_iri_summary AS
SELECT
    s.osm_way_id,
    s.iri_mean,
    s.sample_count,
    s.total_distance_m,
    s.last_seen,
    CASE
        WHEN s.iri_mean < 2  THEN 'sehr glatt'
        WHEN s.iri_mean < 5  THEN 'gut'
        WHEN s.iri_mean < 8  THEN 'mäßig'
        ELSE                      'rau'
    END AS surface_quality
FROM osm_iri_segments s
WHERE s.sample_count >= 1;

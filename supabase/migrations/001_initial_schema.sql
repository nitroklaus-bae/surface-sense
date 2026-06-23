-- ============================================================
-- Surface Sensor – Supabase Initial Schema
-- Run this in: Supabase Dashboard → SQL Editor → Run
-- ============================================================

-- ── Extensions ───────────────────────────────────────────────
-- PostGIS für Geo-Queries (Heatmaps, Bounding-Box-Suche)
CREATE EXTENSION IF NOT EXISTS postgis;

-- ── Tabellen ─────────────────────────────────────────────────

-- Fahrten (eine Zeile pro Aufnahme)
CREATE TABLE rides (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name          TEXT,                          -- optionaler Titel (z.B. "Morgenrunde Isar")
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ NOT NULL,
    duration_s    INTEGER,                       -- Aufnahmedauer in Sekunden
    distance_m    REAL,                          -- GPS-Streckenlänge [m]
    sample_count  INTEGER,                       -- Anzahl Surface-Samples (1 Hz)
    avg_rms_g     REAL,                          -- Ø Vibrations-RMS [g]
    avg_vdv_g     REAL,                          -- Ø VDV [g·s^0.25]
    avg_iri       REAL,                          -- Ø IRI [m/km]
    max_iri       REAL,                          -- Max-IRI [m/km]
    fit_path      TEXT,                          -- Supabase-Storage-Pfad der FIT-Datei
    csv_path      TEXT,                          -- Supabase-Storage-Pfad der CSV-Datei
    fw_version    TEXT,                          -- Firmware-Version (aus BLE-Name)
    mount_point   TEXT,                          -- Montagepunkt (stem/seatpost/…)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 1-Hz Surface-Samples (RMS, VDV, Peak, IRI, GPS)
-- Für eine 3-stündige Fahrt: ~10 800 Zeilen × ~80 Byte ≈ 860 KB
CREATE TABLE surface_samples (
    id            BIGSERIAL   PRIMARY KEY,
    ride_id       UUID        NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    ts_ms         BIGINT      NOT NULL,          -- Unix-Timestamp [ms]
    rms_g         REAL        NOT NULL,
    vdv_g         REAL        NOT NULL,
    peak_g        REAL        NOT NULL,
    crest_factor  REAL,
    iri_m_km      REAL,
    lat           REAL,
    lon           REAL,
    speed_kmh     REAL,
    -- PostGIS-Punkt (automatisch aus lat/lon befüllt via Trigger)
    geom          GEOMETRY(Point, 4326)
);

-- Index für schnelle Abfragen pro Fahrt (chronologisch)
CREATE INDEX idx_surface_samples_ride_ts ON surface_samples(ride_id, ts_ms);
-- Spatial Index für Geo-Queries
CREATE INDEX idx_surface_samples_geom ON surface_samples USING GIST(geom);

-- ── Trigger: lat/lon → PostGIS-Punkt ─────────────────────────
CREATE OR REPLACE FUNCTION surface_samples_set_geom()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.lat IS NOT NULL AND NEW.lon IS NOT NULL THEN
        NEW.geom = ST_SetSRID(ST_MakePoint(NEW.lon, NEW.lat), 4326);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_surface_samples_geom
    BEFORE INSERT OR UPDATE ON surface_samples
    FOR EACH ROW EXECUTE FUNCTION surface_samples_set_geom();

-- ── Row-Level-Security ────────────────────────────────────────
ALTER TABLE rides           ENABLE ROW LEVEL SECURITY;
ALTER TABLE surface_samples ENABLE ROW LEVEL SECURITY;

-- Nutzer sieht und verwaltet nur eigene Fahrten
CREATE POLICY "rides: own data" ON rides
    FOR ALL USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Surface-Samples gehören zum Eigentümer der Fahrt
CREATE POLICY "surface_samples: own data" ON surface_samples
    FOR ALL USING (
        ride_id IN (SELECT id FROM rides WHERE user_id = auth.uid())
    )
    WITH CHECK (
        ride_id IN (SELECT id FROM rides WHERE user_id = auth.uid())
    );

-- ── Storage-Bucket ────────────────────────────────────────────
-- Manuell anlegen: Supabase Dashboard → Storage → New Bucket
-- Name: "ride-files"   Private: true (kein öffentlicher Zugriff)
--
-- Anschließend diese Policy ausführen:
INSERT INTO storage.buckets (id, name, public)
VALUES ('ride-files', 'ride-files', false)
ON CONFLICT DO NOTHING;

CREATE POLICY "ride-files: own data" ON storage.objects
    FOR ALL USING (
        bucket_id = 'ride-files'
        AND auth.uid()::text = (storage.foldername(name))[1]
    )
    WITH CHECK (
        bucket_id = 'ride-files'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ── Hilfs-View: Ride-Übersicht ────────────────────────────────
-- Liefert pro Fahrt eine Übersicht inkl. IRI-Qualitätsstufe
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

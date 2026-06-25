import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.FitContributor;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
import Toybox.Math;
import Toybox.Communications;
import Toybox.Time;

//
// SurfaceSenseDataField  v4.0
//
// Connect IQ Data Field für Garmin Edge-Radcomputer.
//
// Datenquellen (priorisiert):
//   1. BLE-Sensor "SurfaceSensor" (XIAO nRF52840) — hohe Qualität, 1666 Hz
//   2. Garmin-interner Beschleunigungssensor (Fallback) — ~40 Hz
//
// Anzeige:
//   BLE verbunden  → Label "BLE" (blau)
//   Intern aktiv   → Label "INT" (orange)
//   Kein Signal    → "Suche..." Bildschirm
//
// FIT Developer Fields:
//   0  vibration_rms   [g]          – mittlere Vibrationsintensität
//   1  vibration_vdv   [g·s^0.25]   – Vibrationsdosisfaktor (ISO 2631-1)
//   2  vibration_peak  [g]          – Spitzenbeschleunigung
//   3  crest_factor    [-]          – Peak / RMS (Stoßcharakter)
//   4  iri             [m/km]       – International Roughness Index
//
// IRI-Berechnung (vereinfacht, Referenz 20 km/h):
//   IRI = 2.21 × RMS_g × sqrt(20 / max(speed_kmh, 5))
//

// ── Supabase-Konfiguration ────────────────────────────────────────────────────
// Anon-Key ist öffentlich (nur Lesen + ingest_garmin_iri RPC erlaubt)
const SUPABASE_RPC_URL = "https://cpxdxchlyvdbnsewicbq.supabase.co/rest/v1/rpc/ingest_garmin_iri";
const SUPABASE_ANON_KEY = "sb_publishable_RPToUB4fonmTaGfdC3WZ2w_bOYdSGcc";

// Wie viele Sekunden zwischen zwei Uploads (60 s = 1 Minute)
const UPLOAD_INTERVAL_S = 60;
// Maximale Puffergröße (bei Überschreitung wird sofort gesendet)
const BUFFER_MAX = 60;

// Datenquellen-Konstanten
const SRC_BLE    = 0;  // Externer BLE-Sensor
const SRC_INTERN = 1;  // Garmin-interner Beschleunigungssensor

class SurfaceSenseDataField extends WatchUi.DataField {

    // ── FIT-Felder ────────────────────────────────────────────────────────────
    private var _fitRms   as FitContributor.Field;
    private var _fitVdv   as FitContributor.Field;
    private var _fitPeak  as FitContributor.Field;
    private var _fitCrest as FitContributor.Field;
    private var _fitIri   as FitContributor.Field;

    // ── Sensoren ──────────────────────────────────────────────────────────────
    private var _ble    as BleManager;
    private var _garmin as GarminAccelSensor;

    // ── Anzeige-State ─────────────────────────────────────────────────────────
    private var _rms            as Float   = 0.0f;
    private var _vdv            as Float   = 0.0f;
    private var _iri            as Float   = 0.0f;
    private var _dataAge        as Number  = 99;
    private var _source         as Number  = SRC_BLE;   // aktive Datenquelle
    private var _wasBleConnected as Boolean = false;

    // ── Supabase Upload ───────────────────────────────────────────────────────
    private var _iriBuffer    as Array        = [];
    private var _uploadToSend as Array or Null = null;
    private var _lastUploadS  as Number        = 0;
    private var _uploading    as Boolean       = false;
    private var _uploadOk     as Number        = 0;
    private var _uploadErr    as Number        = 0;

    // ── Initialisierung ───────────────────────────────────────────────────────

    function initialize() {
        DataField.initialize();

        // FIT Developer Fields anlegen
        _fitRms = createField(
            "vibration_rms", 0,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "g" }
        );
        _fitVdv = createField(
            "vibration_vdv", 1,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "g*s^0.25" }
        );
        _fitPeak = createField(
            "vibration_peak", 2,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "g" }
        );
        _fitCrest = createField(
            "crest_factor", 3,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "" }
        );
        _fitIri = createField(
            "iri", 4,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/km" }
        );

        // BLE-Sensor initialisieren
        _ble = new BleManager(method(:onSurfaceData));

        // Garmin-internen Sensor als Fallback initialisieren
        _garmin = new GarminAccelSensor(method(:onGarminData));

        _lastUploadS = Time.now().value();
    }

    // ── BLE-Callback (1-Hz-Paket vom XIAO-Sensor) ────────────────────────────

    function onSurfaceData(
        rms   as Float,
        vdv   as Float,
        peak  as Float,
        crest as Float,
        iri   as Float
    ) as Void {
        _rms     = rms;
        _vdv     = vdv;
        _iri     = iri;
        _dataAge = 0;
        _source  = SRC_BLE;

        _fitRms.setData(rms);
        _fitVdv.setData(vdv);
        _fitPeak.setData(peak);
        _fitCrest.setData(crest);
        _fitIri.setData(iri);
    }

    // ── Garmin-Intern-Callback (1-Hz-Fenster vom onboard-Sensor) ─────────────
    //
    // Wird nur dann übernommen, wenn kein BLE-Sensor aktiv ist.
    // IRI wird in compute() mit der aktuellen GPS-Geschwindigkeit berechnet.

    function onGarminData(
        rms  as Float,
        vdv  as Float,
        peak as Float
    ) as Void {
        if (_ble.connected) { return; }  // BLE hat Vorrang

        _rms     = rms;
        _vdv     = vdv;
        _dataAge = 0;
        _source  = SRC_INTERN;

        var crest = (rms > 0.001f) ? (peak / rms) : 0.0f;
        _fitRms.setData(rms);
        _fitVdv.setData(vdv);
        _fitPeak.setData(peak);
        _fitCrest.setData(crest);
        // _iri und _fitIri werden in compute() mit GPS-Geschwindigkeit gesetzt
    }

    // ── compute(): vom Gerät jede Sekunde aufgerufen ──────────────────────────

    function compute(info as Activity.Info) as Lang.Object or Null {
        if (_dataAge < 99) { _dataAge++; }

        // Reconnect-Erkennung: _dataAge zurücksetzen bei BLE-Wiederverbindung
        var nowConnected = _ble.connected;
        if (nowConnected && !_wasBleConnected) {
            _dataAge = 0;
            _source  = SRC_BLE;
        }
        _wasBleConnected = nowConnected;

        // Quelle auf Intern setzen wenn BLE weg aber Garmin-Daten frisch
        if (!nowConnected && _garmin.dataAge < 3) {
            _source = SRC_INTERN;
        }

        // Aktuelle GPS-Geschwindigkeit → IRI nachberechnen
        var speedKmh = 0.0f;
        if (info has :currentSpeed && info.currentSpeed != null) {
            var speedMs = info.currentSpeed as Float;
            speedKmh = speedMs * 3.6f;

            if (speedKmh > 2.0f && _rms > 0.0f) {
                var vClamped    = (speedKmh < 5.0f) ? 5.0f : speedKmh;
                var speedFactor = Math.sqrt(20.0f / vClamped).toFloat();
                _iri = 2.21f * _rms * speedFactor;
                _fitIri.setData(_iri);
            }
        }

        // ── GPS + IRI in Puffer schreiben ─────────────────────────────────────
        // Bedingung: frische Daten vorhanden (BLE oder Intern), IRI > 0, Fahrt läuft
        var dataFresh = (_dataAge < 3);
        if (
            dataFresh
            && _iri > 0.0f
            && speedKmh >= 3.0f
            && info has :currentLocation
            && info.currentLocation != null
        ) {
            var loc = info.currentLocation.toDegrees();
            _iriBuffer.add({
                "lat"       => loc[0].toFloat(),
                "lon"       => loc[1].toFloat(),
                "iri"       => _iri,
                "speed_kmh" => speedKmh
            });
        }

        // ── Upload-Check ──────────────────────────────────────────────────────
        var nowS        = Time.now().value();
        var bufferFull  = (_iriBuffer.size() >= BUFFER_MAX);
        var timeReached = (nowS - _lastUploadS >= UPLOAD_INTERVAL_S);

        if (!_uploading && _iriBuffer.size() > 0 && (bufferFull || timeReached)) {
            _uploadBuffer();
        }

        return _rms;
    }

    // ── Supabase Upload ───────────────────────────────────────────────────────

    private function _uploadBuffer() as Void {
        if (_uploading || _iriBuffer.size() == 0) { return; }

        _uploading    = true;
        _lastUploadS  = Time.now().value();
        _uploadToSend = _iriBuffer;
        var toSend    = _iriBuffer;
        _iriBuffer    = [];

        Communications.makeWebRequest(
            SUPABASE_RPC_URL,
            { "points" => toSend },
            {
                :method       => Communications.HTTP_REQUEST_METHOD_POST,
                :headers      => {
                    "Content-Type"  => "application/json",
                    "apikey"        => SUPABASE_ANON_KEY,
                    "Authorization" => "Bearer " + SUPABASE_ANON_KEY
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onUploadResponse)
        );
    }

    function onUploadResponse(responseCode as Number, data as Dictionary?) as Void {
        _uploading = false;
        if (responseCode == 200 || responseCode == 204) {
            _uploadOk++;
        } else {
            _uploadErr++;
            System.println("[SurfaceSense] Upload failed: HTTP " + responseCode);
            if (_uploadToSend != null) {
                var restored = _uploadToSend as Array;
                restored.addAll(_iriBuffer);
                _iriBuffer    = restored;
                _uploadToSend = null;
            }
        }
    }

    // ── onLayout(): einmalig beim Aufbau ──────────────────────────────────────

    function onLayout(dc as Graphics.Dc) as Void {
    }

    // ── onUpdate(): Bildschirm zeichnen ───────────────────────────────────────

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_BLACK)
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_BLACK;

        dc.setColor(fg, bg);
        dc.clear();

        var bleOk    = _ble.connected;
        var internOk = _garmin.available() && _dataAge < 5;

        // ── Kein Signal ───────────────────────────────────────────────────────
        if (!bleOk && !internOk) {
            _drawCentered(dc, w, h / 3,     Graphics.FONT_XTINY, "Surface",  fg);
            _drawCentered(dc, w, h / 2,     Graphics.FONT_XTINY, "Sense",    fg);
            _drawCentered(dc, w, h * 2 / 3, Graphics.FONT_XTINY,
                _garmin.available() ? "INT start..." : "Suche...",
                Graphics.COLOR_LT_GRAY);
            return;
        }

        // ── 3-Zeilen-Datenlayout ──────────────────────────────────────────────
        // Quell-Farbe: Blau für BLE, Orange für Intern
        var srcColor = (_source == SRC_BLE)
            ? Graphics.COLOR_BLUE
            : Graphics.COLOR_ORANGE;

        // Daten veraltet (> 3 s kein Paket)?
        var valueColor = (_dataAge > 3) ? Graphics.COLOR_YELLOW : fg;

        var rowH      = h / 3;
        var labelX    = 4;
        var valueX    = w - 4;
        var labelFont = Graphics.FONT_XTINY;
        var valueFont = Graphics.FONT_SMALL;

        // Trennlinien
        dc.setColor(Graphics.COLOR_LT_GRAY, bg);
        dc.drawLine(0, rowH,     w, rowH);
        dc.drawLine(0, rowH * 2, w, rowH * 2);

        // Upload-Indikator: kleiner Punkt oben rechts
        var dotColor = Graphics.COLOR_LT_GRAY;
        if (_uploadOk > 0 && _uploadErr == 0) {
            dotColor = Graphics.COLOR_GREEN;
        } else if (_uploadErr > 0) {
            dotColor = (_uploadOk > 0) ? Graphics.COLOR_YELLOW : Graphics.COLOR_RED;
        }
        dc.setColor(dotColor, bg);
        dc.fillCircle(w - 6, 6, 4);

        // Quellen-Badge: "BLE" oder "INT" oben links (Quelle-Farbe)
        dc.setColor(srcColor, bg);
        dc.drawText(labelX, 6, Graphics.FONT_XTINY,
            (_source == SRC_BLE) ? "BLE" : "INT",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Zeile 1 – RMS [mg]
        dc.setColor(srcColor, bg);
        dc.drawText(labelX, rowH * 0 + rowH / 2, labelFont,
            "RMS mg", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(valueColor, bg);
        dc.drawText(valueX, rowH * 0 + rowH / 2, valueFont,
            (_rms * 1000.0f).format("%.1f"),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Zeile 2 – VDV [g·s^0.25]
        dc.setColor(srcColor, bg);
        dc.drawText(labelX, rowH * 1 + rowH / 2, labelFont,
            "VDV", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(valueColor, bg);
        dc.drawText(valueX, rowH * 1 + rowH / 2, valueFont,
            _vdv.format("%.4f"),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Zeile 3 – IRI [m/km]
        dc.setColor(srcColor, bg);
        dc.drawText(labelX, rowH * 2 + rowH / 2, labelFont,
            "IRI m/km", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var iriColor;
        if (_iri < 2.0f)      { iriColor = Graphics.COLOR_GREEN; }
        else if (_iri < 5.0f) { iriColor = Graphics.COLOR_YELLOW; }
        else if (_iri < 8.0f) { iriColor = Graphics.COLOR_ORANGE; }
        else                   { iriColor = Graphics.COLOR_RED; }
        dc.setColor((_dataAge > 3) ? Graphics.COLOR_YELLOW : iriColor, bg);
        dc.drawText(valueX, rowH * 2 + rowH / 2, valueFont,
            _iri.format("%.2f"),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Hilfsfunktion: Text zentriert zeichnen ────────────────────────────────

    private function _drawCentered(
        dc    as Graphics.Dc,
        w     as Number,
        y     as Number,
        font  as Graphics.FontType,
        text  as String,
        color as Graphics.ColorType
    ) as Void {
        dc.setColor(color, -1);
        dc.drawText(w / 2, y, font, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

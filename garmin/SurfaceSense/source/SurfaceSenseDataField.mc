import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.FitContributor;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
import Toybox.Math;

//
// SurfaceSenseDataField  v2.0
//
// Connect IQ Data Field für Garmin Edge-Radcomputer.
//
// Funktion:
//   - Verbindet sich per BLE mit dem XIAO nRF52840-Sensor ("SurfaceSensor")
//   - Empfängt 1-Hz Surface-Pakete (RMS, VDV, Peak in g)
//   - Berechnet IRI (International Roughness Index) aus RMS + Fahrgeschwindigkeit
//   - Schreibt Vibrationsdaten als Developer Fields in die FIT-Datei
//   - Zeigt RMS / VDV / IRI live auf dem Display
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
class SurfaceSenseDataField extends WatchUi.DataField {

    // ── FIT-Felder ────────────────────────────────────────────────────────────
    private var _fitRms   as FitContributor.Field;
    private var _fitVdv   as FitContributor.Field;
    private var _fitPeak  as FitContributor.Field;
    private var _fitCrest as FitContributor.Field;
    private var _fitIri   as FitContributor.Field;

    // ── BLE-Manager ───────────────────────────────────────────────────────────
    private var _ble as BleManager;

    // ── Anzeige-State ─────────────────────────────────────────────────────────
    private var _rms     as Float  = 0.0f;
    private var _vdv     as Float  = 0.0f;
    private var _iri     as Float  = 0.0f;
    private var _dataAge as Number = 99;   // Sekunden seit letztem Paket

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

        // BLE initialisieren und Scan starten
        _ble = new BleManager(method(:onSurfaceData));
    }

    // ── BLE-Callback (aufgerufen wenn neues 1-Hz-Paket eintrifft) ────────────

    function onSurfaceData(
        rms   as Float,
        vdv   as Float,
        peak  as Float,
        crest as Float,
        iri   as Float
    ) as Void {
        _rms   = rms;
        _vdv   = vdv;
        _iri   = iri;
        _dataAge = 0;

        // Sofort in FIT schreiben (nicht auf compute() warten)
        _fitRms.setData(rms);
        _fitVdv.setData(vdv);
        _fitPeak.setData(peak);
        _fitCrest.setData(crest);
        _fitIri.setData(iri);
    }

    // ── compute(): vom Gerät jede Sekunde aufgerufen ──────────────────────────

    function compute(info as Activity.Info) as Lang.Object or Null {
        if (_dataAge < 99) { _dataAge++; }

        // IRI mit aktueller GPS-Geschwindigkeit nachberechnen (falls vorhanden)
        if (info has :currentSpeed && info.currentSpeed != null) {
            var speedMs  = info.currentSpeed as Float;
            var speedKmh = speedMs * 3.6f;
            if (speedKmh > 2.0f) {
                var vClamped = (speedKmh < 5.0f) ? 5.0f : speedKmh;
                var speedFactor = Math.sqrt(20.0f / vClamped).toFloat();
                _iri = 2.21f * _rms * speedFactor;
                _fitIri.setData(_iri);
            }
        }

        return _rms;
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

        // ── Kein Sensor verbunden ─────────────────────────────────────────────
        if (!_ble.connected) {
            _drawCentered(dc, w, h / 3,     Graphics.FONT_XTINY, "Surface",  fg);
            _drawCentered(dc, w, h / 2,     Graphics.FONT_XTINY, "Sense",    fg);
            _drawCentered(dc, w, h * 2 / 3, Graphics.FONT_XTINY, "Suche...", Graphics.COLOR_LT_GRAY);
            return;
        }

        // ── Daten veraltet (> 3 s kein Paket) ────────────────────────────────
        var valueColor = (_dataAge > 3) ? Graphics.COLOR_YELLOW : fg;

        // ── 3-Zeilen-Layout ───────────────────────────────────────────────────
        // Zeile 1: RMS [mg]
        // Zeile 2: VDV [g·s^0.25]
        // Zeile 3: IRI [m/km]  (International Roughness Index)
        var rowH      = h / 3;
        var labelX    = 4;
        var valueX    = w - 4;
        var labelFont = Graphics.FONT_XTINY;
        var valueFont = Graphics.FONT_SMALL;

        // Trennlinien
        dc.setColor(Graphics.COLOR_LT_GRAY, bg);
        dc.drawLine(0, rowH,     w, rowH);
        dc.drawLine(0, rowH * 2, w, rowH * 2);

        // Zeile 1 – RMS [mg] (in mg für bessere Lesbarkeit auf kleinem Display)
        dc.setColor(Graphics.COLOR_BLUE, bg);
        dc.drawText(labelX, rowH * 0 + rowH / 2, labelFont,
            "RMS mg", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(valueColor, bg);
        dc.drawText(valueX, rowH * 0 + rowH / 2, valueFont,
            (_rms * 1000.0f).format("%.1f"),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Zeile 2 – VDV [g·s^0.25]
        dc.setColor(Graphics.COLOR_BLUE, bg);
        dc.drawText(labelX, rowH * 1 + rowH / 2, labelFont,
            "VDV", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(valueColor, bg);
        dc.drawText(valueX, rowH * 1 + rowH / 2, valueFont,
            _vdv.format("%.4f"),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Zeile 3 – IRI [m/km] (Farbe je nach Qualitätsstufe)
        dc.setColor(Graphics.COLOR_BLUE, bg);
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

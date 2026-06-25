import Toybox.Sensor;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//
// GarminAccelSensor  v1.2
//
// Nutzt den eingebauten Beschleunigungssensor des Garmin Edge.
//
// Architektur (wie XIAO-Firmware, aber im DataField):
//   Raw-Samples bei bis zu 200 Hz einlesen
//   → RMS / VDV / Peak pro Fenster selbst berechnen
//   → DataField schreibt Ergebnis 1×/s ins FIT (FIT-Rate ist device-fix)
//
// Fensterrate: WINDOW_PERIOD_S (Standard 1.0 s, alternativ 0.5 s möglich).
// FIT-Record wird immer bei compute() = 1×/s gesetzt, daher ist 0.5 s-Fenster
// nur sinnvoll wenn man zwei Fenster pro Sekunde mitteln will.
//
// Das Gerät liefert stillschweigend die max. unterstützte Rate
// (Edge 530 praktisch ~100 Hz, API-Limit = 200 Hz).
//
// Berechnet pro 1-Sekunden-Fenster:
//   RMS  = sqrt( mean( (az − mean_az)² ) )             [g]
//   VDV  ≈ ( mean( (az − mean_az)⁴ ) × 1s )^0.25      [g·s^0.25]
//   Peak = max| az − mean_az |                         [g]
//
// Die Fenstermittelwert-Subtraktion entfernt den Gravitationsanteil ohne
// Orientierungskalibrierung — geeignet für Straßenrauigkeitsschätzung.
//
// Callback-Signatur: function(rms as Float, vdv as Float, peak as Float)
//
class GarminAccelSensor {

    private var _callback  as Method;
    private var _available as Boolean = false;

    // Sample-Puffer für aktuelles 1-Sekunden-Fenster (Float, in g)
    private var _buf as Array = [];

    // Öffentliche Ergebnisse (letztes abgeschlossenes Fenster)
    public var rms     as Float  = 0.0f;
    public var vdv     as Float  = 0.0f;
    public var peak    as Float  = 0.0f;
    public var dataAge as Number = 99;

    // ── Initialisierung ───────────────────────────────────────────────────────

    function initialize(callback as Method) as Void {
        _callback = callback;
        _setup();
    }

    private function _setup() as Void {
        try {
            Sensor.setEnabledSensors([Sensor.SENSOR_ACCEL]);
            Sensor.registerSensorDataCallback(
                method(:onSensorData),
                {
                    :period        => 1,     // Callback einmal pro Sekunde
                    :accelerometer => {
                        :enabled        => true,
                        :samplingPeriod => 5   // 5 ms → 200 Hz (Gerät liefert max. unterstützte Rate)
                    }
                }
            );
            _available = true;
            System.println("[GarminAccel] OK (angefordert: 200 Hz)");
        } catch (e instanceof Lang.Exception) {
            System.println("[GarminAccel] Nicht verfügbar: " + e.getErrorMessage());
            _available = false;
        }
    }

    // ── Sensor-Callback (1× pro Sekunde, liefert ~40 Samples) ────────────────

    function onSensorData(sensorData as Sensor.SensorData) as Void {
        if (sensorData.accelerometerData == null) { return; }
        var accel = sensorData.accelerometerData;

        var n    = accel.sampleCount;
        var zArr = accel.z;
        if (n <= 0 || zArr == null) { return; }

        // Z-Samples in Puffer laden: milli-g → g
        for (var i = 0; i < n; i++) {
            _buf.add(zArr[i] / 1000.0f);
        }

        // Fenster auswerten (period=1 → Callback einmal pro Sekunde)
        _flushWindow();
    }

    // ── Fensterauswertung ─────────────────────────────────────────────────────

    private function _flushWindow() as Void {
        var n = _buf.size();
        if (n < 5) { _buf = []; return; }  // Zu wenig Samples → verwerfen

        // Pass 1: Fenstermittelwert (= statischer Gravitationsanteil entlang Z)
        var sumAz = 0.0f;
        for (var i = 0; i < n; i++) { sumAz += _buf[i]; }
        var mean = sumAz / n.toFloat();

        // Pass 2: Dynamische Kennwerte (Gravitationsanteil abgezogen)
        var sumAz2 = 0.0f;
        var sumAz4 = 0.0f;
        var pk     = 0.0f;
        for (var i = 0; i < n; i++) {
            var dyn  = _buf[i] - mean;
            var dyn2 = dyn * dyn;
            sumAz2 += dyn2;
            sumAz4 += dyn2 * dyn2;
            var absDyn = (dyn < 0.0f) ? -dyn : dyn;
            if (absDyn > pk) { pk = absDyn; }
        }

        var rmsVal = Math.sqrt(sumAz2 / n.toFloat()).toFloat();
        // VDV nach ISO 2631-1: (∫a⁴ dt)^0.25 ≈ (mean(a⁴) × T)^0.25, T=1 s
        var vdvVal = Math.pow((sumAz4 / n.toFloat()).toDouble(), 0.25d).toFloat();

        rms     = rmsVal;
        vdv     = vdvVal;
        peak    = pk;
        dataAge = 0;
        _buf    = [];

        _callback.invoke(rmsVal, vdvVal, pk);
    }

    // ── Getter ────────────────────────────────────────────────────────────────

    function available() as Boolean { return _available; }
}

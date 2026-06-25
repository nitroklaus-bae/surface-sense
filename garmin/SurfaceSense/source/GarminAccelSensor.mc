import Toybox.Sensor;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//
// GarminAccelSensor  v2.0
//
// Nutzt den eingebauten Beschleunigungssensor des Garmin Edge via
// Sensor.enableSensorEvents → Sensor.Info.accel.
//
// Hinweis Edge 530:
//   registerSensorDataCallback (100-200 Hz) ist auf Radcomputern NICHT
//   verfügbar — das ist eine Watch-API (Fenix, Forerunner etc.).
//   enableSensorEvents liefert accel-Daten falls das Gerät sie exponiert;
//   auf dem Edge 530 ist Sensor.Info.accel wahrscheinlich null → _available = false.
//
//   Für High-Freq-Accel auf dem Edge 530 → externen XIAO-Sensor per BLE nutzen.
//
// Auf Geräten mit accel-Support (Fenix, Vivoactive…):
//   Samples kommen mit Sensor-Update-Rate (~1 Hz aus enableSensorEvents).
//   Fensterauswertung: RMS / VDV / Peak (Gravitationsanteil subtrahiert).
//
// Callback-Signatur: function(rms as Float, vdv as Float, peak as Float)
//
class GarminAccelSensor {

    private var _callback  as Method;
    private var _available as Boolean = false;

    // Sample-Puffer für aktuelles Fenster
    private var _buf as Array = [];

    // Letztes abgeschlossenes Fenster
    public var rms     as Float  = 0.0f;
    public var vdv     as Float  = 0.0f;
    public var peak    as Float  = 0.0f;
    public var dataAge as Number = 99;

    // Sekunden-Zähler für 1-Sekunden-Flush
    private var _lastFlushS as Number = 0;

    // ── Initialisierung ───────────────────────────────────────────────────────

    function initialize(callback as Method) {
        _callback = callback;
        // _setup() wird NICHT im Konstruktor aufgerufen — erst wenn BLE nicht
        // verbunden ist (lazy). Verhindert Crash im DataField-Initialize.
    }

    /// Einmalig aufrufen wenn BLE nicht verfügbar ist.
    function tryStart() as Void {
        if (_tried) { return; }
        _tried = true;
        try {
            Sensor.enableSensorEvents(method(:onSensorInfo));
            System.println("[GarminAccel] enableSensorEvents OK");
        } catch (e instanceof Lang.Exception) {
            System.println("[GarminAccel] n/a: " + e.getErrorMessage());
            _available = false;
        }
    }

    private var _tried as Boolean = false;

    // ── Sensor-Callback ───────────────────────────────────────────────────────

    function onSensorInfo(info as Sensor.Info) as Void {
        // Kein Beschleunigungssensor auf diesem Gerät (z.B. Edge 530)
        if (info.accel == null) {
            if (_available) {
                _available = false;
                System.println("[GarminAccel] accel = null → nicht verfügbar");
            }
            return;
        }

        // Erstes accel-Paket → Sensor als verfügbar markieren
        if (!_available) {
            _available = true;
            System.println("[GarminAccel] accel verfügbar");
        }

        // info.accel = [x, y, z] in milli-g
        var accel = info.accel;
        var z = (accel[2] as Lang.Number) / 1000.0f;  // milli-g → g
        _buf.add(z);

        // 1-Sekunden-Fenster abschließen
        var nowS = System.getTimer() / 1000;
        if (nowS - _lastFlushS >= 1) {
            _lastFlushS = nowS;
            _flushWindow();
        }
    }

    // ── Fensterauswertung ─────────────────────────────────────────────────────

    private function _flushWindow() as Void {
        var n = _buf.size();
        if (n < 1) { _buf = []; return; }

        // Pass 1: Fenstermittelwert (Gravitationsanteil)
        var sumAz = 0.0f;
        for (var i = 0; i < n; i++) { sumAz += _buf[i]; }
        var mean = sumAz / n.toFloat();

        // Pass 2: Dynamische Kennwerte
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

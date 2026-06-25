import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

// ── UUIDs (müssen mit der Firmware übereinstimmen) ────────────────────────────
// Die Firmware variiert das ERSTE Segment der Basis-UUID:
//   Service:     19B10000-E8F2-537E-4F6C-D104768A1214  (Basis)
//   Surface:     19B10006-E8F2-537E-4F6C-D104768A1214  (erstes Segment = 19B10006)
//   Temperatur:  19B10009-E8F2-537E-4F6C-D104768A1214  (erstes Segment = 19B10009)
const SURFACE_SVC_UUID  = BluetoothLowEnergy.stringToUuid("19b10000-e8f2-537e-4f6c-d104768a1214");
const SURFACE_CHAR_UUID = BluetoothLowEnergy.stringToUuid("19b10006-e8f2-537e-4f6c-d104768a1214");
const TEMP_CHAR_UUID    = BluetoothLowEnergy.stringToUuid("19b10009-e8f2-537e-4f6c-d104768a1214");

// Sensor-Gerätename (muss mit BLE-Advertising-Name übereinstimmen)
const SENSOR_NAME = "SurfaceSensor";

//
// BleManager  v2.0 – verwaltet Scan, Verbindung und Datenempfang.
//
// Erbt von BleDelegate → empfängt alle BLE-Callbacks.
// Nach erfolgreicher Verbindung werden Surface-Char (1 Hz) und
// Temp-Char (5 s, optional Firmware v6+) via CCCD abonniert.
//
class BleManager extends BluetoothLowEnergy.BleDelegate {

    // Callback-Typ: function(rms, vdv, peak, crest, iri)
    private var _callback as Method;

    private var _device    as BluetoothLowEnergy.Device? = null;
    private var _scanning  as Boolean                    = false;
    private var _connected as Boolean                    = false;

    // Zuletzt empfangene Werte
    public var rms   as Float   = 0.0f;
    public var vdv   as Float   = 0.0f;
    public var peak  as Float   = 0.0f;
    public var crest as Float   = 0.0f;
    public var iri   as Float   = 0.0f;
    public var tempC as Float   = 25.0f;   // IMU-Temperatur (alle 5 s, Firmware v6+)
    public var connected as Boolean = false;

    // ── Initialisierung ───────────────────────────────────────────────────────

    function initialize(callback as Method) {
        BleDelegate.initialize();
        _callback = callback;

        // Profil einmalig registrieren (teilt dem System mit, welche
        // Services/Characteristics uns interessieren)
        _registerProfile();

        // Als BLE-Delegate anmelden
        BluetoothLowEnergy.setDelegate(self);

        // Scan starten
        startScan();
    }

    private function _registerProfile() as Void {
        try {
            BluetoothLowEnergy.registerProfile({
                :uuid            => SURFACE_SVC_UUID,
                :characteristics => [
                    {
                        :uuid        => SURFACE_CHAR_UUID,
                        :descriptors => [BluetoothLowEnergy.cccdUuid()]
                    },
                    {
                        :uuid        => TEMP_CHAR_UUID,
                        :descriptors => [BluetoothLowEnergy.cccdUuid()]
                    }
                ]
            });
        } catch (e instanceof Lang.Exception) {
            // Profil bereits registriert — kein Fehler, Scan trotzdem starten
            System.println("[BleManager] registerProfile: " + e.getErrorMessage());
        }
    }

    // ── Scan ─────────────────────────────────────────────────────────────────

    function startScan() as Void {
        if (_connected || _scanning) { return; }
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
        _scanning = true;
    }

    function stopScan() as Void {
        if (!_scanning) { return; }
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        _scanning = false;
    }

    // ── BleDelegate-Callbacks ─────────────────────────────────────────────────

    // Scan-Ergebnis: suche nach "SurfaceSensor"
    // Parameter ist BluetoothLowEnergy.Iterator — kein Typ annotiert
    function onScanResults(scanResults) as Void {
        var item = scanResults.next();
        while (item != null) {
            var result = item as BluetoothLowEnergy.ScanResult;
            var name = result.getDeviceName();
            if (name != null && name.equals(SENSOR_NAME)) {
                BluetoothLowEnergy.pairDevice(result);
                stopScan();
                return;
            }
            item = scanResults.next();
        }
    }

    // Verbindungsstatus geändert
    function onConnectedStateChanged(
        device as BluetoothLowEnergy.Device,
        state  as BluetoothLowEnergy.ConnectionState
    ) as Void {
        if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _device    = device;
            _connected = true;
            connected  = true;
            _subscribeCharacteristics();
        } else {
            _device    = null;
            _connected = false;
            connected  = false;
            // Automatisch neu scannen
            startScan();
        }
    }

    // CCCD-Write abgeschlossen (Notify aktiviert/deaktiviert)
    function onDescriptorWrite(
        descriptor as BluetoothLowEnergy.Descriptor,
        status     as BluetoothLowEnergy.Status
    ) as Void {
        // Status ignorieren — bei Fehler kommen einfach keine Notifications
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            System.println("CCCD write failed: " + status);
        }
    }

    // Characteristic-Notification empfangen
    function onCharacteristicChanged(
        char  as BluetoothLowEnergy.Characteristic,
        value as Lang.ByteArray
    ) as Void {
        var uuid = char.getUuid();

        // ── Surface-Paket (16 Byte) ───────────────────────────────────────────
        // [0-3] uint32 timestamp_ms (ignoriert)
        // [4-7] float32 rms_g  [8-11] float32 vdv_g  [12-15] float32 peak_g
        if (uuid.equals(SURFACE_CHAR_UUID)) {
            if (value.size() < 16) { return; }
            rms   = _f32LE(value, 4);
            vdv   = _f32LE(value, 8);
            peak  = _f32LE(value, 12);
            crest = (rms > 0.001f) ? (peak / rms) : 0.0f;
            // Unkorriegierter IRI (ohne GPS-Geschwindigkeit); DataField korrigiert in compute()
            iri   = 2.21f * rms;
            _callback.invoke(rms, vdv, peak, crest, iri);
            return;
        }

        // ── Temperatur-Paket (4 Byte float32 °C, Firmware v6+) ───────────────
        if (uuid.equals(TEMP_CHAR_UUID)) {
            if (value.size() < 4) { return; }
            var t = _f32LE(value, 0);
            // Plausibilitätscheck: LSM6DS3 Betriebstemperatur -40…+85 °C
            if (t > -40.0f && t < 85.0f) { tempC = t; }
        }
    }

    // ── Interne Hilfsfunktionen ───────────────────────────────────────────────

    // Notify auf Surface- und Temp-Characteristic aktivieren
    private function _subscribeCharacteristics() as Void {
        if (_device == null) { return; }
        var svc = _device.getService(SURFACE_SVC_UUID);
        if (svc == null) { return; }

        // Surface-Char (obligatorisch)
        var surfCh = svc.getCharacteristic(SURFACE_CHAR_UUID);
        if (surfCh != null) {
            var desc = surfCh.getDescriptor(BluetoothLowEnergy.cccdUuid());
            if (desc != null) { desc.requestWrite([0x01, 0x00]b); }
        }

        // Temp-Char (optional – nur Firmware v6+; kein Fehler wenn nicht vorhanden)
        var tempCh = svc.getCharacteristic(TEMP_CHAR_UUID);
        if (tempCh != null) {
            var desc = tempCh.getDescriptor(BluetoothLowEnergy.cccdUuid());
            if (desc != null) { desc.requestWrite([0x01, 0x00]b); }
        }
    }

    // IEEE 754 float32 aus 4 Bytes (Little-Endian) rekonstruieren.
    // Monkey C kennt kein direktes Casting von int-Bits → float,
    // daher manuelle Dekodierung über Vorzeichen/Exponent/Mantisse.
    private function _f32LE(data as Lang.ByteArray, off as Number) as Float {
        // Bytes als unsigned Long zusammensetzen (vermeidet Vorzeichenfehler
        // bei b3 ≥ 0x80 wenn man mit Number (32-bit signed) arbeitet)
        var b0 = (data[off]     & 0xFF).toLong();
        var b1 = (data[off + 1] & 0xFF).toLong();
        var b2 = (data[off + 2] & 0xFF).toLong();
        var b3 = (data[off + 3] & 0xFF).toLong();
        var bits = b0 | (b1 << 8l) | (b2 << 16l) | (b3 << 24l);

        // ±0
        if (bits == 0l || bits == 0x80000000l) { return 0.0f; }

        // Infinity / NaN → 0 zurückgeben
        var rawExp = (bits >> 23l) & 0xFFl;
        if (rawExp == 0xFFl) { return 0.0f; }

        var sign     = (bits >> 31l) & 1l;
        var exponent = rawExp.toNumber() - 127;
        // Mantisse mit implizierter führender 1
        var mantissa = ((bits & 0x7FFFFFl) | 0x800000l).toFloat();

        var result = (mantissa * Math.pow(2.0d, (exponent - 23).toDouble())).toFloat();
        return (sign == 0l) ? result : -result;
    }
}

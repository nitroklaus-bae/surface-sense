# Connect IQ DataField: SurfaceSense

Zeigt Vibrations-Kennwerte (RMS, VDV, Crest Factor) live auf dem Garmin Edge-Computer
und schreibt sie als Developer Fields in jede FIT-Aufnahme.

## Kompatible Geräte

Edge 530 · 830 · 1030 Plus · 1040 · 1040 Solar · 840 · 540
(alle mit BLE und Connect IQ ≥ 3.2.0)

## Voraussetzungen

1. [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) installieren
2. VS Code + [Monkey C Extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c) installieren
3. Gerätezertifikat für Sideload erzeugen (einmalig):
   ```
   App Store → Mein Entwicklerkonto → Developer Keys
   ```
   oder über den SDK-Manager: `connectiq keygen SurfaceSense`

## Bauen & Auf Gerät laden

```bash
cd garmin/SurfaceSense

# Für Simulator
connectiq build --device edge830 monkey.jungle
connectiq sim

# Für echtes Gerät (USB)
connectiq build --device edge830 monkey.jungle --release
# → erzeugt SurfaceSense.prg
# → via Garmin Connect Mobile → Aktivitäten-Profile → Datenfelder laden
```

Oder in VS Code: `Cmd/Ctrl+Shift+B` → Build, dann `Run` für Simulator.

## Am Garmin Edge einrichten

1. **SurfaceSense.prg** per USB auf das Gerät kopieren:
   `GARMIN/Apps/`
2. Am Edge: **Menü → Einstellungen → Aktivitäten & Apps → [Aktivität] → Datenbildschirme**
3. Einen Datenbildschirm mit 3 Feldern wählen → eines der Felder auf **SurfaceSense** setzen

## Anzeige

```
RMS g  │  0.0234
───────────────
VDV    │  0.0089
───────────────
CF     │  2.8
```

- **Gelb** = Sensor verbunden, aber kein Paket in den letzten 3 s
- **"Suche..."** = kein Sensor in Reichweite

## FIT Developer Fields

Nach der Aufnahme sind in der FIT-Datei folgende Developer Fields enthalten:

| Field           | Einheit      | Beschreibung                              |
|-----------------|--------------|-------------------------------------------|
| vibration_rms   | g            | Mittlere Vibrationsintensität (ISO 2631)  |
| vibration_vdv   | g·s^0.25     | Vibrationsdosisfaktor                     |
| vibration_peak  | g            | Spitzenbeschleunigung                     |
| crest_factor    | –            | Peak / RMS (Stoßcharakter)                |

Sichtbar in Garmin Connect, GoldenCheetah, oder per `fitdump` CLI.

## BLE-Protokoll (Referenz)

Der Sensor muss als "SurfaceSensor" advertisen.

Surface Characteristic (Notify, 1 Hz):
```
Byte 0-3   uint32   timestamp_ms  (ignoriert)
Byte 4-7   float32  rms_g         (Little-Endian)
Byte 8-11  float32  vdv_g         (Little-Endian)
Byte 12-15 float32  peak_g        (Little-Endian)
```

Service UUID:   `19B10000-E8F2-537E-4F6C-D104768A1214`
Char UUID:      `19B10000-E8F2-537E-4F6C-D104768A1006`

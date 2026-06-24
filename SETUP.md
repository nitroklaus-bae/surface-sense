# Surface Sensor – Setup-Anleitung

## Hardware
- Seeed XIAO nRF52840 Sense
- USB-C Kabel für Flashen

---

## 1. Firmware flashen

### Arduino IDE einrichten
1. Boardmanager-URL hinzufügen:  
   `https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json`
2. Board installieren: **Seeed nRF52 Boards** → `Seeed XIAO nRF52840 Sense`
3. Libraries installieren (Library Manager):
   - `ArduinoBLE`
   - `Seeed Arduino LSM6DS3`

### Flashen
1. Datei `firmware/surface_sensor.ino` in der Arduino IDE öffnen
2. Board: **Seeed XIAO nRF52840 Sense** auswählen
3. Upload → fertig

---

## 2. Flutter App

### Voraussetzungen
- Flutter SDK ≥ 3.3  
  [docs.flutter.dev/get-started/install](https://docs.flutter.dev/get-started/install)
- Xcode (iOS) bzw. Android Studio (Android)

### Bauen & Starten

```bash
cd app
flutter pub get
flutter run
```

### Android – AndroidManifest.xml Ergänzungen
Füge in `android/app/src/main/AndroidManifest.xml` ein (vor `<application>`):

```xml
<!-- BLE -->
<uses-permission android:name="android.permission.BLUETOOTH"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<!-- GPS (Karte + geolocator) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
<uses-feature android:name="android.hardware.location.gps"/>
```

### iOS – Info.plist Ergänzungen
Füge in `ios/Runner/Info.plist` ein:

```xml
<!-- BLE -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Für die BLE-Verbindung zum Sensor</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Für die BLE-Verbindung zum Sensor</string>
<!-- GPS -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>GPS-Aufzeichnung für Strecken-Korrelation der Vibrationsdaten</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>GPS-Aufzeichnung während der Fahrt</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>location</string>
</array>
```

---

## 3. Bedienung

1. XIAO per USB mit Strom versorgen (oder Akku)
2. App starten → **"Gerät suchen"** tippen
3. App verbindet automatisch mit `SurfaceSensor`
4. Frequenz wählen (10 / 25 / 50 / 100 / 200 Hz)
5. **"Aufnahme starten"** → Daten werden aufgezeichnet
6. **"Aufnahme stoppen"** → CSV wird automatisch gespeichert

### CSV-Format
```
timestamp_ms,ax_g,ay_g,az_g
1234,0.012,-0.005,1.001
...
```
Dateien liegen unter: App Documents-Ordner (`surface_YYYY-MM-DDTHH-MM-SS.csv`)

---

## 4. BLE-Protokoll (für spätere Erweiterungen)

| UUID (Suffix) | Art | Beschreibung |
|---|---|---|
| `...1214` | Service | SurfaceSensor Service |
| `...1215` | Notify | Daten: `uint32 ts_ms \| float ax \| float ay \| float az` (16 Byte) |
| `...1216` | Write | Control: `0x00` = Stop, `0x01` = Start |
| `...1217` | R/W | Frequenz: `uint16 Hz` (Little Endian, 1–200) |

---

## 5. Export & PC-Übertragung

Nach dem Stoppen der Aufnahme erscheint im AppBar ein Export-Icon (↑).

| Format | Inhalt | Verwendung |
|--------|--------|------------|
| **CSV** | Rohdaten (timestamp, ax, ay, az) | Excel, Python, Matlab |
| **FIT** | GPS-Track + Vibrations-RMS als Developer-Field | Garmin Connect Import |

Nach dem Export öffnet sich das OS-Share-Sheet:
- **iOS**: AirDrop, iCloud, Dateien, E-Mail, …
- **Android**: Drive, Bluetooth, Nearby Share, E-Mail, …

### FIT-Datei in Garmin Connect importieren
1. FIT-Datei auf PC übertragen (AirDrop / E-Mail / USB)
2. Garmin Connect → Aktivitäten → "Aktivität importieren"
3. FIT-Datei auswählen → Developer-Fields "vibration_rms" und "vibration_vdv" erscheinen in der Aktivitätsdetailansicht

---

## 6. Nächste Schritte

- [ ] Garmin-Integration via Connect IQ SDK (live ~1/s Oberflächenindex)
- [ ] ISO 2631-1 Frequenzgewichtung (Wz-Filter) für gewichtetes VDV
- [ ] Session-Verlauf + Datenbank (lokal)
- [ ] IRI (International Roughness Index) Berechnung

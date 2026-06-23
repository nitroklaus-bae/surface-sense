/**
 * Surface Sensor Firmware  v6.0
 * Hardware: Seeed XIAO nRF52840 Sense  /  IMU: LSM6DS3TR-C (I²C 0x6A)
 *
 * ── Neu in v5 ─────────────────────────────────────────────────────────────────
 *  Interrupt-gesteuerte FIFO-Reads + CPU-Sleep
 *    • INT1 des LSM6DS3 wird während der Aufnahme als FIFO-Watermark-Interrupt
 *      genutzt (INT1_CTRL 0x0D Bit 3 = INT1_FTH).
 *    • Watermark-Schwelle = BATCH_SIZE * 3 Words (ein Word pro Achse).
 *    • ISR setzt nur ein Flag (fifoReady). Der Haupt-Loop prüft dieses Flag
 *      und schläft mit delay(1) wenn kein Batch bereit ist.
 *    • delay(1) = Mbed-RTOS rtos::ThisThread::sleep_for(1ms) → CPU in WFI
 *      (Wait For Interrupt), SoftDevice-kompatibel.
 *    • Doppelnutzung INT1: während Aufnahme = FIFO-Watermark,
 *      im Tiefsschlaf = Bewegungs-Wake-Up (MD1_CFG). Kein Konflikt –
 *      beide Zustände schließen sich gegenseitig aus.
 *
 *  ODR-abhängiges BLE Connection Interval
 *    • BLE.setConnectionInterval() wird je nach ODR angepasst:
 *        ≤ 208 Hz → 50–100 ms   (Radio-Duty-Cycle ↓↓)
 *        ≤ 416 Hz → 25–50 ms
 *        > 416 Hz → 15–25 ms    (hoch genug für 83 Notif/s bei 1666 Hz)
 *    • Wird bei Aufnahme-Start und nach ODR-Wechsel gesetzt.
 *
 *  Energieeinsparung (grob, gegenüber v4 Busy-Wait):
 *    ODR 104 Hz → ~12 mA → ~3–4 mA  (Faktor 3)
 *    ODR 416 Hz → ~12 mA → ~4–5 mA  (Faktor 2.5)
 *    ODR 833 Hz → ~12 mA → ~6–7 mA  (Faktor 1.8)
 *    Tiefsschlaf: unverändert ~2 µA
 *
 * ── Paketformat ───────────────────────────────────────────────────────────────
 *  Byte 0-3  uint32  timestamp_ms   (IMU-Timer-basiert)
 *  Byte 4    uint8   count
 *  Byte 5    uint8   config         bits[2:0]=odrIndex, bits[4:3]=fsIndex
 *  Byte 6+   int16 ax, ay, az       kalibriert, Little-Endian
 *
 * ── BLE UUIDs ────────────────────────────────────────────────────────────────
 *  Service:  19B10000-E8F2-537E-4F6C-D104768A1214
 *  Data:     19B10001  Notify
 *  Control:  19B10002  Write  (0=Stop, 1=Start)
 *  Freq:     19B10003  R/W    uint16 Hz
 *  Config:   19B10004  R/W    uint8 fsIndex
 *  Cal:      19B10005  R/W+Notify
 *  TSync:    19B10007  Write  uint64 Unix-ms (LE) – Zeit-Sync für GPS-Korrelation
 *
 * ── Libraries ────────────────────────────────────────────────────────────────
 *  ArduinoBLE  |  Seeed Arduino LSM6DS3
 */

#include <ArduinoBLE.h>
#include <LSM6DS3.h>
#include <Wire.h>
#include <nrf_power.h>

// ── Debug ─────────────────────────────────────────────────────────────────────
// 0 = kein Serial (Pflicht bei ODR > ~200 Hz)
// 1 = Serial aktiv (nur Entwicklung)
#define DEBUG 0
#if DEBUG
  #define DBG(x)   Serial.print(x)
  #define DBGLN(x) Serial.println(x)
#else
  #define DBG(x)
  #define DBGLN(x)
#endif

// ── Konfiguration ─────────────────────────────────────────────────────────────
#define BATCH_SIZE        20
#define SLEEP_TIMEOUT_MS  30000UL
#define IMU_INT_PIN       11
#define WAKEUP_THRESHOLD  3
#define CAL_SAMPLES       200

// ── ODR-Tabelle ───────────────────────────────────────────────────────────────
struct OdrEntry { uint16_t hz; uint8_t ctrl1Odr; uint8_t fifoOdr; };
static const OdrEntry ODR_TABLE[] = {
  {  52, 0x30, 0x03 }, { 104, 0x40, 0x04 }, { 208, 0x50, 0x05 },
  { 416, 0x60, 0x06 }, { 833, 0x70, 0x07 }, {1666, 0x80, 0x08 },
};
static const uint8_t ODR_COUNT = sizeof(ODR_TABLE) / sizeof(OdrEntry);

// ── Full-Scale-Tabelle ────────────────────────────────────────────────────────
struct FsEntry { uint8_t g; uint8_t ctrl1Bits; float scaleG; };
static const FsEntry FS_TABLE[] = {
  {  2, 0x00,  2.0f/32768.0f },
  {  4, 0x08,  4.0f/32768.0f },
  {  8, 0x0C,  8.0f/32768.0f },
  { 16, 0x04, 16.0f/32768.0f },
};
static const uint8_t FS_COUNT = sizeof(FS_TABLE) / sizeof(FsEntry);

// ── BLE ───────────────────────────────────────────────────────────────────────
#define SVC_UUID  "19B10000-E8F2-537E-4F6C-D104768A1214"
#define DATA_UUID "19B10001-E8F2-537E-4F6C-D104768A1214"
#define CTRL_UUID "19B10002-E8F2-537E-4F6C-D104768A1214"
#define FREQ_UUID "19B10003-E8F2-537E-4F6C-D104768A1214"
#define CONF_UUID "19B10004-E8F2-537E-4F6C-D104768A1214"
#define CAL_UUID  "19B10005-E8F2-537E-4F6C-D104768A1214"
#define SURF_UUID   "19B10006-E8F2-537E-4F6C-D104768A1214"  // 1 Hz Oberflächenanalyse
#define TSYNC_UUID  "19B10007-E8F2-537E-4F6C-D104768A1214"  // Zeit-Sync (Unix-ms, 8 Byte)
#define ORIENT_UUID "19B10008-E8F2-537E-4F6C-D104768A1214"  // Orientierungskalibrierung
#define TEMP_UUID   "19B10009-E8F2-537E-4F6C-D104768A1214"  // Temperatur [float32 °C, 5s]

// Surface-Paket (16 Byte):
//   [0-3]  uint32  timestamp_ms  (Fensterbeginn)
//   [4-7]  float32 rms_g         RMS Z-Achse [g]
//   [8-11] float32 vdv_g         VDV Z-Achse [g·s^0.25]
//   [12-15] float32 peak_g       Peak |az| [g]
#define SURF_PKT_SIZE 16

#define PKT_HEADER 6
#define PKT_SIZE   (PKT_HEADER + BATCH_SIZE * 6)

BLEService             sensorService(SVC_UUID);
BLECharacteristic      dataChar(DATA_UUID,  BLERead | BLENotify, PKT_SIZE);
BLEByteCharacteristic  ctrlChar(CTRL_UUID,  BLERead | BLEWrite);
BLECharacteristic      freqChar(FREQ_UUID,  BLERead | BLEWrite, 2);
BLEByteCharacteristic  confChar(CONF_UUID,  BLERead | BLEWrite);
BLECharacteristic      calChar (CAL_UUID,   BLERead | BLEWrite | BLENotify, 7);
BLECharacteristic      surfChar(SURF_UUID,  BLERead | BLENotify, SURF_PKT_SIZE);
BLECharacteristic      tSyncChar(TSYNC_UUID, BLEWrite, 8);   // App schreibt Unix-ms
BLECharacteristic      orientChar(ORIENT_UUID, BLEWrite | BLENotify, 17); // Orientierungskalibrierung
BLECharacteristic      tempChar(TEMP_UUID, BLERead | BLENotify, 4);       // Temperatur float32 °C

// ── State ─────────────────────────────────────────────────────────────────────
LSM6DS3 imu(I2C_MODE, 0x6A);
bool          recording      = false;
uint8_t       odrIndex       = 1;   // 104 Hz default
uint8_t       fsIndex        = 1;   // ±4g default
uint32_t      lastActivityMs = 0;

static uint8_t pktBuf[PKT_SIZE];

// FIFO-Interrupt-Flag (gesetzt durch ISR, gelesen im Loop)
volatile bool fifoReady = false;

// ── Zeit-Sync (TSYNC) ─────────────────────────────────────────────────────────
// App schreibt Unix-ms beim Aufnahmestart → exakte GPS-Timestamp-Korrelation.
// _tSyncOffset = unix_ms - millis() bei TSYNC-Empfang.
// Surface-Packet-Timestamp = millis() + _tSyncOffset ≈ Unix-ms des Fensters.
static int64_t  _tSyncOffset = 0;  // Addiert auf millis() für Unix-ms

// ── Kalibrierung ──────────────────────────────────────────────────────────────
struct Calibration {
  bool    valid = false;
  int16_t axOff = 0;
  int16_t ayOff = 0;
  int16_t azOff = 0;
};
static Calibration cal;

// ── Orientierungskalibrierung ─────────────────────────────────────────────────
// Ermittelt den Schwerkraftvektor im IMU-Frame (aufrechtes Fahrrad, ebener Boden).
// gx/gy/gz: Einheitsvektor der Schwerkraftrichtung (dimensionslos, FS-unabhängig).
// Nach Kalibrierung: az_vertikal = dot([ax_cal, ay_cal, az_cal], g_hat) - g1raw
//   wobei g1raw = 1.0f / scaleG (1g in raw counts) → dynamischer Vertikalanteil ≈ 0
//   auf glatter Fläche, steigt mit Rauheit.
struct OrientCalibration {
  bool  valid = false;
  float gx    = 0.0f;  // Schwerkraft-Einheitsvektor x (IMU-Frame)
  float gy    = 0.0f;  // Schwerkraft-Einheitsvektor y
  float gz    = 1.0f;  // Schwerkraft-Einheitsvektor z (default: Z nach oben)
};
static OrientCalibration orientCal;

// Vorberechneter 1g-Wert in raw counts für aktuellen FS-Bereich.
// Wird bei FS-Wechsel aktualisiert. FS-Standardwert: ±4g → 32768/4 = 8192.
static float _g1raw = 8192.0f;

// ── Auto-Zero (Temperatur-Drift-Kompensation) ─────────────────────────────────
// Erkennt Ruhephasen (Bike steht still) und führt den Offset per EMA nach.
// Nur aktiv wenn Orientierungskalibrierung gültig (azForSurf ≈ 0 im Ruhezustand).
// EMA-Alpha = 0.1 → langsame Nachführung (~10 Samples / Konvergenz ≈ 20 s Ruhepause).
static float    _azAutoSumG   = 0.0f;  // Σ az_vertikal [g] im Detektionsfenster
static float    _azAutoSum2G  = 0.0f;  // Σ az_vertikal² [g²]
static uint32_t _azAutoN      = 0;     // Sample-Zähler im Detektionsfenster
static float    _azAutoDriftG = 0.0f;  // geschätzter Drift-Offset [g]
static float    _lastTempC    = 25.0f; // letzter Temperaturmesswert [°C]
static uint32_t _lastTempMs   = 0;     // Zeitstempel letzte Temp-Messung

// ── Oberflächenanalyse-Akkumulator (1-Hz-Fenster) ────────────────────────────
// Alle Berechnungen in integer (RMS) bzw. float32 (VDV) ohne Sample-Speicherung.
// Maximale int64-Auslastung bei 1666 Hz + ±16g:
//   sumAz2 = 1666 × 32768² ≈ 1.8 × 10¹²  → weit unter INT64_MAX (9.2 × 10¹⁸)
struct SurfaceAccum {
  int64_t  sumAz2     = 0;  // Σ azRaw²    für RMS
  float    sumAz4g    = 0;  // Σ az_g⁴     für VDV (ISO 2631-1)
  int16_t  peakAzRaw  = 0;  // max(|azRaw|) für Peak
  uint32_t n          = 0;  // Sample-Zähler im Fenster
  uint32_t windowStart= 0;  // millis() bei Fensterbeginn
};
static SurfaceAccum surf;

// Akkumulator zurücksetzen und Fenster neu starten
inline void surfaceAccumReset() {
  surf.sumAz2      = 0;
  surf.sumAz4g     = 0.0f;
  surf.peakAzRaw   = 0;
  surf.n           = 0;
  surf.windowStart = millis();
}

// Pro Sample aufrufen (inline → kein Funktionsaufruf-Overhead im Hot Path)
inline void surfaceAccumUpdate(int16_t azCal) {
  surf.sumAz2 += (int64_t)azCal * azCal;
  float azG    = (float)azCal * FS_TABLE[fsIndex].scaleG;
  float az2g   = azG * azG;
  surf.sumAz4g += az2g * az2g;
  int16_t azAbs = azCal < 0 ? -azCal : azCal;
  if (azAbs > surf.peakAzRaw) surf.peakAzRaw = azAbs;
  surf.n++;
}

// ── IMU-Timer (Zeitstempel) ───────────────────────────────────────────────────
static uint32_t _imuTicksHigh  = 0;
static uint32_t _imuTicksLast  = 0;
static uint32_t _recStartMs    = 0;
static uint32_t _recStartTicks = 0;

// ═══════════════════════════════════════════════════════════════════════════════
//  INTERRUPT SERVICE ROUTINE
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * ISR für FIFO-Watermark-Interrupt (INT1, RISING).
 * Feuert wenn FIFO-Füllstand ≥ Watermark-Schwelle (BATCH_SIZE * 3 Words).
 * Minimale ISR: nur Flag setzen, keine I²C-Zugriffe.
 */
void imuFifoIsrHandler() {
  fifoReady = true;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  IMU-REGISTER-ZUGRIFF
// ═══════════════════════════════════════════════════════════════════════════════
inline void imuWrite(uint8_t reg, uint8_t val) { imu.writeRegister(reg, val); }
inline uint8_t imuRead(uint8_t reg) { uint8_t v=0; imu.readRegister(&v,reg); return v; }

// ── ODR + FS in CTRL1_XL schreiben ───────────────────────────────────────────
void imuApplyConfig() {
  imuWrite(0x10, ODR_TABLE[odrIndex].ctrl1Odr | FS_TABLE[fsIndex].ctrl1Bits);
  imuWrite(0x0A, (ODR_TABLE[odrIndex].fifoOdr << 3) | 0x06);  // FIFO Stream-Mode
}

// ── IMU-Timer aktivieren ──────────────────────────────────────────────────────
void imuEnableTimer() {
  imuWrite(0x19, imuRead(0x19) | 0x20);  // CTRL10_C: TIMER_EN = Bit 5
  _imuTicksHigh = 0;
  _imuTicksLast = 0;
}

uint32_t imuReadTicks() {
  uint8_t t[3];
  imu.readRegisterRegion(t, 0x40, 3);
  uint32_t raw = (uint32_t)t[0] | ((uint32_t)t[1] << 8) | ((uint32_t)t[2] << 16);
  if (raw < _imuTicksLast && (_imuTicksLast - raw) > (1UL << 23))
    _imuTicksHigh += (1UL << 24);
  _imuTicksLast = raw;
  return _imuTicksHigh + raw;
}

uint32_t imuTicksToMs(uint32_t ticks) {
  uint64_t elapsed = (uint64_t)(ticks - _recStartTicks) * 25ULL;
  return _recStartMs + (uint32_t)(elapsed / 1000ULL);
}

// ── FIFO ─────────────────────────────────────────────────────────────────────

/**
 * FIFO initialisieren: Bypass → Stream, Watermark-Schwelle setzen,
 * FIFO-Threshold-Interrupt auf INT1 routen.
 *
 * Watermark = BATCH_SIZE * 3 Words (3 Words pro Sample: X, Y, Z).
 * Wenn FIFO ≥ Watermark Samples enthält, geht INT1 HIGH → ISR feuert.
 */
void imuFifoInit() {
  imuWrite(0x0A, 0x00); delay(5);  // Bypass-Mode (FIFO leeren)

  // Watermark-Schwelle
  const uint16_t wm = BATCH_SIZE * 3;  // 60 Words bei BATCH_SIZE=20
  imuWrite(0x06, wm & 0xFF);           // FIFO_CTRL1: FTH[7:0]
  imuWrite(0x07, (wm >> 8) & 0x07);   // FIFO_CTRL2: FTH[10:8]

  imuWrite(0x08, 0x01);  // FIFO_CTRL3: XL no decimation
  imuWrite(0x09, 0x00);  // FIFO_CTRL4: G no decimation

  // INT1_CTRL (0x0D): INT1_FTH = Bit 3 → FIFO-Watermark-Interrupt auf INT1
  imuWrite(0x0D, 0x08);

  imuApplyConfig();      // CTRL1_XL + FIFO_CTRL5 (ODR + Stream-Mode)
}

void imuFifoStop() {
  imuWrite(0x0A, 0x00);  // FIFO_CTRL5: Bypass-Mode
  imuWrite(0x0D, 0x00);  // INT1_CTRL: alle INT1-Quellen deaktivieren
}

inline uint16_t imuFifoWordCount() {
  return (uint16_t)(imuRead(0x3B) & 0x0F) << 8 | imuRead(0x3A);
}

inline int16_t imuFifoReadWord() {
  uint8_t b[2];
  imu.readRegisterRegion(b, 0x3E, 2);
  return (int16_t)((uint16_t)b[0] | (uint16_t)b[1] << 8);
}

/**
 * FIFO-Batch lesen und in pktBuf schreiben.
 * Kalibrierungs-Offsets werden in Integer-Arithmetik subtrahiert.
 * KEIN Serial – Hot Path.
 */
uint8_t imuFifoReadBatch() {
  // ── FIFO-Overflow erkennen (FIFO_STATUS2 Bit 6 = OVER_RUN) ───────────────
  if (imuRead(0x3B) & 0x40) {
    DBGLN("[WARN] FIFO OVER_RUN – leere FIFO, sende Gap-Marker");
    // FIFO vollständig neu initialisieren
    detachInterrupt(digitalPinToInterrupt(IMU_INT_PIN));
    imuFifoStop(); delay(1); imuFifoInit();
    fifoReady = false;
    surfaceAccumReset();
    attachInterrupt(digitalPinToInterrupt(IMU_INT_PIN), imuFifoIsrHandler, RISING);
    // Gap-Marker (count=0): App erkennt Datenlücke und kann sie markieren
    uint32_t gapTs = (_tSyncOffset != 0)
      ? (uint32_t)((int64_t)millis() + _tSyncOffset)
      : (uint32_t)millis();
    memcpy(pktBuf, &gapTs, 4);
    pktBuf[4] = 0;  // count = 0 → Gap
    dataChar.writeValue(pktBuf, PKT_HEADER);
    return 0;
  }

  uint8_t avail = (uint8_t)min((uint16_t)(imuFifoWordCount() / 3),
                                (uint16_t)BATCH_SIZE);
  if (avail == 0) return 0;

  uint32_t ts = imuTicksToMs(imuReadTicks());
  pktBuf[4] = avail;
  pktBuf[5] = (uint8_t)((fsIndex & 0x03) << 3 | (odrIndex & 0x07));
  memcpy(pktBuf, &ts, 4);

  uint8_t* p = pktBuf + PKT_HEADER;
  for (uint8_t i = 0; i < avail; i++, p += 6) {
    int16_t ax = imuFifoReadWord() - cal.axOff;
    int16_t ay = imuFifoReadWord() - cal.ayOff;
    int16_t az = imuFifoReadWord() - cal.azOff;
    p[0]=(uint8_t)ax;   p[1]=(uint8_t)(ax>>8);
    p[2]=(uint8_t)ay;   p[3]=(uint8_t)(ay>>8);
    p[4]=(uint8_t)az;   p[5]=(uint8_t)(az>>8);

    // Oberflächenanalyse: wahre Vertikalbeschleunigung berechnen.
    // Mit Orientierungskalibrierung: Dot-Produkt mit Schwerkraftvektor,
    //   dann 1g subtrahieren → rein dynamischer Vertikalanteil (~0 auf glatter Straße).
    // Ohne Kalibrierung: Z-Achse direkt (enthält ~1g Bias, historisch).
    int16_t azForSurf;
    if (orientCal.valid) {
      float aVert = (float)ax * orientCal.gx
                  + (float)ay * orientCal.gy
                  + (float)az * orientCal.gz;
      azForSurf = (int16_t)roundf(aVert - _g1raw);  // 1g subtrahieren
    } else {
      azForSurf = az;
    }

    // ── Auto-Zero: Temperatur-Drift erkennen und kompensieren ────────────────
    // Nur wenn Orientierungskalibrierung aktiv (azForSurf ≈ 0 im Ruhezustand).
    if (orientCal.valid) {
      float azSurfG  = (float)azForSurf * FS_TABLE[fsIndex].scaleG;
      // Drift-Offset abziehen
      azSurfG -= _azAutoDriftG;
      azForSurf = (int16_t)roundf(azSurfG / FS_TABLE[fsIndex].scaleG);

      // Statistiken für Ruhezustand-Erkennung akkumulieren
      _azAutoSumG  += azSurfG;
      _azAutoSum2G += azSurfG * azSurfG;
      _azAutoN++;

      // Detektionsfenster: 2 Sekunden
      uint32_t windowTarget = (uint32_t)ODR_TABLE[odrIndex].hz * 2;
      if (_azAutoN >= windowTarget) {
        float meanG     = _azAutoSumG  / _azAutoN;
        float meanSqG   = _azAutoSum2G / _azAutoN;
        float varG      = meanSqG - meanG * meanG;

        // Ruhezustand: Varianz < (0.03 g)² und Mittelwert-Absolutwert < 0.08 g
        if (varG < 0.0009f && fabsf(meanG) < 0.08f) {
          // EMA alpha=0.1: langsame Nachführung → robuster gegen kurze Bewegungen
          _azAutoDriftG = 0.9f * _azAutoDriftG + 0.1f * meanG;
        }
        _azAutoSumG  = 0.0f;
        _azAutoSum2G = 0.0f;
        _azAutoN     = 0;
      }
    }

    surfaceAccumUpdate(azForSurf);
  }
  return avail;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BLE CONNECTION INTERVAL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * BLE Connection Interval an aktuelle ODR anpassen.
 * Einheit: 1.25 ms (BLE-Standard).
 *
 * Ziel: möglichst seltene Radio-Aktivität ohne Datenverlust.
 * Bei 1666 Hz: 83 Notifications/s passen in jedes Intervall ≥ 15 ms,
 * da BLE mehrere Pakete pro Connection Event schicken kann (DLE).
 */
void applyBleConnectionInterval() {
  uint16_t minCI, maxCI;
  uint16_t hz = ODR_TABLE[odrIndex].hz;

  if (hz <= 208) {
    minCI = 40; maxCI = 80;   // 50–100 ms: niedrige ODR, Radio schläft viel
  } else if (hz <= 416) {
    minCI = 20; maxCI = 40;   // 25–50 ms
  } else {
    minCI = 12; maxCI = 20;   // 15–25 ms: hohe ODR braucht schnellen TX
  }

  BLE.setConnectionInterval(minCI, maxCI);
  DBGLN("[BLE] CI: " + String(minCI * 5 / 4) + "–" + String(maxCI * 5 / 4) + " ms");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  KALIBRIERUNG
// ═══════════════════════════════════════════════════════════════════════════════
void performCalibration() {
  DBGLN("[CAL] Starte...");
  uint8_t progress[7] = {0x01, 0,0, 0,0, 0,0};
  calChar.writeValue(progress, 7);

  imuFifoStop();
  imuWrite(0x10, 0x40 | FS_TABLE[fsIndex].ctrl1Bits);  // 104 Hz + aktueller FS
  delay(100);

  int64_t sumX=0, sumY=0, sumZ=0;
  uint8_t buf[6];
  bool error = false;

  for (int i = 0; i < CAL_SAMPLES; i++) {
    delay(10);
    imu.readRegisterRegion(buf, 0x28, 6);
    sumX += (int16_t)((uint16_t)buf[0] | (uint16_t)buf[1] << 8);
    sumY += (int16_t)((uint16_t)buf[2] | (uint16_t)buf[3] << 8);
    sumZ += (int16_t)((uint16_t)buf[4] | (uint16_t)buf[5] << 8);
    if (i % 20 == 0) BLE.poll();
  }

  cal.axOff = (int16_t)(sumX / CAL_SAMPLES);
  cal.ayOff = (int16_t)(sumY / CAL_SAMPLES);
  int16_t oneGraw = (int16_t)(1.0f / FS_TABLE[fsIndex].scaleG);
  cal.azOff = (int16_t)(sumZ / CAL_SAMPLES) - oneGraw;
  cal.valid = !error;

  imuApplyConfig();
  imuFifoStop();

  DBGLN("[CAL] ax=" + String(cal.axOff) + " ay=" + String(cal.ayOff) +
        " az=" + String(cal.azOff) + " (1g=" + String(oneGraw) + ")");

  uint8_t result[7];
  result[0] = error ? 0xFF : 0x00;
  memcpy(result + 1, &cal.axOff, 2);
  memcpy(result + 3, &cal.ayOff, 2);
  memcpy(result + 5, &cal.azOff, 2);
  calChar.writeValue(result, 7);
}

// ── Orientierungskalibrierung ─────────────────────────────────────────────────
/**
 * Misst den Schwerkraftvektor in IMU-Koordinaten.
 * Voraussetzung: Fahrrad steht aufrecht auf ebener Fläche, keine Bewegung.
 * Vorab muss performCalibration() (Offset-Kalibrierung) durchgeführt worden sein.
 *
 * Ablauf:
 *   1. 200 Samples à 10 ms = 2 Sekunden Mittelwertbildung
 *   2. Mittelwert = Schwerkraftvektor in kalibriertem IMU-Frame (in raw counts)
 *   3. Normierung → Einheitsvektor g_hat (gx, gy, gz)
 *   4. Plausibilitätsprüfung: |g| muss 0.5–1.5 g sein
 *   5. Ergebnis per BLE Notify (17 Byte):
 *      [0]     status   0x00=OK, 0x10=läuft, 0xFE=Offset-Kal fehlt, 0xFF=Fehler
 *      [1-4]   float32  gx (Einheitsvektor)
 *      [5-8]   float32  gy
 *      [9-12]  float32  gz
 *      [13-16] float32  gemessene |g| in g (Qualitätsindikator, sollte ≈1.0)
 *
 * Hot-Path-Verwendung (in imuFifoReadBatch):
 *   az_vertikal_dynamic = dot([ax_cal, ay_cal, az_cal], g_hat) - g1raw
 *   → RMS/VDV aus reinem Vertikalanteil, FS-Bias und Montagewinkel kompensiert
 */
void performOrientationCalibration() {
  DBGLN("[OCAL] Starte Orientierungskalibrierung...");

  uint8_t prog[17] = {};
  prog[0] = 0x10;  // in progress
  orientChar.writeValue(prog, 17);

  // Offset-Kalibrierung muss vorhanden sein
  if (!cal.valid) {
    DBGLN("[OCAL] Fehler: Offset-Kalibrierung fehlt");
    uint8_t err[17] = {}; err[0] = 0xFE;
    orientChar.writeValue(err, 17);
    return;
  }

  // IMU auf 104 Hz setzen (FIFO stoppen)
  imuFifoStop();
  imuWrite(0x10, 0x40 | FS_TABLE[fsIndex].ctrl1Bits);
  delay(200);  // Einschwingzeit abwarten

  const int OCAL_N = 200;
  int64_t sumX = 0, sumY = 0, sumZ = 0;
  uint8_t buf[6];

  for (int i = 0; i < OCAL_N; i++) {
    delay(10);  // 100 Hz Abtastrate → 2 s Gesamtdauer
    imu.readRegisterRegion(buf, 0x28, 6);
    int16_t rawAx = (int16_t)((uint16_t)buf[0] | (uint16_t)buf[1] << 8);
    int16_t rawAy = (int16_t)((uint16_t)buf[2] | (uint16_t)buf[3] << 8);
    int16_t rawAz = (int16_t)((uint16_t)buf[4] | (uint16_t)buf[5] << 8);
    // Offset-Kalibrierung anwenden: azCal enthält ~1g als DC-Anteil (Schwerkraft)
    sumX += (int64_t)(rawAx - cal.axOff);
    sumY += (int64_t)(rawAy - cal.ayOff);
    sumZ += (int64_t)(rawAz - cal.azOff);
    if (i % 40 == 0) BLE.poll();
  }

  float meanX = (float)sumX / OCAL_N;
  float meanY = (float)sumY / OCAL_N;
  float meanZ = (float)sumZ / OCAL_N;

  // Betrag des gemessenen Schwerkraftvektors (in raw counts und in g)
  float gMagRaw = sqrtf(meanX*meanX + meanY*meanY + meanZ*meanZ);
  float gMagG   = gMagRaw * FS_TABLE[fsIndex].scaleG;

  // Plausibilitätsprüfung: sollte nahe 1g liegen (Fahrrad steht still, aufrecht)
  if (gMagG < 0.5f || gMagG > 1.5f) {
    DBGLN("[OCAL] Fehler: |g|=" + String(gMagG, 3) + "g (erwartet 0.5–1.5 g)");
    uint8_t err[17] = {}; err[0] = 0xFF;
    orientChar.writeValue(err, 17);
    imuApplyConfig(); imuFifoStop();
    return;
  }

  // Einheitsvektor normieren
  orientCal.gx    = meanX / gMagRaw;
  orientCal.gy    = meanY / gMagRaw;
  orientCal.gz    = meanZ / gMagRaw;
  orientCal.valid = true;

  DBGLN("[OCAL] OK  gx=" + String(orientCal.gx, 3) +
        "  gy=" + String(orientCal.gy, 3) +
        "  gz=" + String(orientCal.gz, 3) +
        "  |g|=" + String(gMagG, 3) + " g");

  // Ergebnis-Paket (17 Byte) per Notify senden
  uint8_t result[17] = {};
  result[0] = 0x00;  // OK
  memcpy(result + 1,  &orientCal.gx, 4);
  memcpy(result + 5,  &orientCal.gy, 4);
  memcpy(result + 9,  &orientCal.gz, 4);
  memcpy(result + 13, &gMagG,        4);  // gemessene |g| als Qualitätsindikator

  orientChar.writeValue(result, 17);

  // IMU wieder in den Betriebszustand zurücksetzen
  imuApplyConfig(); imuFifoStop();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  1-HZ OBERFLÄCHENANALYSE
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Berechnet Rauheitskennwerte aus dem 1-Sekunden-Akkumulator und sendet
 * ein 16-Byte-Paket per BLE Notify auf surfChar.
 *
 * Formeln (Z-Achse, ISO 2631-1 ungewichtet):
 *   RMS  = sqrt(Σ az²  / n) × scaleG          [g]
 *   VDV  = (Σ az_g⁴ / ODR_Hz)^0.25           [g·s^0.25]
 *   Peak = max(|az|) × scaleG                 [g]
 *
 * Wird nur gesendet wenn ≥ ODR_Hz/2 Samples vorhanden (halbe Sekunde Mindest-
 * daten, um Randeffekte beim Start zu vermeiden).
 */
void sendSurfacePacket() {
  if (surf.n < (uint32_t)(ODR_TABLE[odrIndex].hz / 2)) {
    surfaceAccumReset();
    return;
  }

  const float scaleG = FS_TABLE[fsIndex].scaleG;
  const float rmsG   = sqrtf((float)surf.sumAz2 / surf.n) * scaleG;
  const float vdvG   = powf(surf.sumAz4g / (float)ODR_TABLE[odrIndex].hz, 0.25f);
  const float peakG  = (float)surf.peakAzRaw * scaleG;

  // Timestamp: unix_ms wenn TSYNC empfangen, sonst millis()-basiert
  uint32_t ts = (_tSyncOffset != 0)
    ? (uint32_t)((int64_t)surf.windowStart + _tSyncOffset)
    : surf.windowStart;

  uint8_t buf[SURF_PKT_SIZE];
  memcpy(buf,      &ts,   4);  // timestamp_ms (unix_ms als uint32 falls TSYNC aktiv)
  memcpy(buf + 4,  &rmsG,  4);
  memcpy(buf + 8,  &vdvG,  4);
  memcpy(buf + 12, &peakG, 4);

  surfChar.writeValue(buf, SURF_PKT_SIZE);

  DBG("[SURF] RMS="); DBG(rmsG, 4);
  DBG(" VDV="); DBG(vdvG, 4);
  DBG(" Peak="); DBG(peakG, 4);
  DBG(" n="); DBGLN(surf.n);

  surfaceAccumReset();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SLEEP / WAKE
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * INT1 für Wake-Up-Interrupt konfigurieren (nur vor System-OFF).
 * Löscht vorher INT1_CTRL (FIFO-Routing) und detacht den FIFO-ISR.
 */
void imuConfigureWakeUp() {
  // Sicherheitshalber FIFO-Interrupt-ISR lösen und INT1_CTRL leeren
  detachInterrupt(digitalPinToInterrupt(IMU_INT_PIN));
  imuWrite(0x0D, 0x00);  // INT1_CTRL: alle Quellen deaktivieren

  imuWrite(0x10, 0x20);  // CTRL1_XL: 26 Hz Ultra-LP
  imuWrite(0x15, imuRead(0x15) | 0x10);  // CTRL6_C: XL_HM_MODE
  imuWrite(0x58, 0x80);  // TAP_CFG: INTERRUPTS_ENABLE
  imuWrite(0x5B, WAKEUP_THRESHOLD & 0x3F);
  imuWrite(0x5C, 0x10);  // WAKE_UP_DUR
  imuWrite(0x5E, 0x20);  // MD1_CFG: INT1_WU (Wake-Up auf INT1)
}

void enterDeepSleep() {
  DBGLN("[SLEEP] System-OFF...");
  if (DEBUG) { Serial.flush(); delay(10); }
  BLE.stopAdvertise(); BLE.end();
  recording = false;
  imuFifoStop();
  delay(5);
  imuConfigureWakeUp();  // INT1 umschalten: FIFO → Wake-Up
  delay(5);
  pinMode(IMU_INT_PIN, INPUT);
  NRF_GPIO->PIN_CNF[IMU_INT_PIN] =
    (GPIO_PIN_CNF_DIR_Input     << GPIO_PIN_CNF_DIR_Pos)   |
    (GPIO_PIN_CNF_INPUT_Connect << GPIO_PIN_CNF_INPUT_Pos) |
    (GPIO_PIN_CNF_PULL_Disabled << GPIO_PIN_CNF_PULL_Pos)  |
    (GPIO_PIN_CNF_SENSE_High    << GPIO_PIN_CNF_SENSE_Pos);
  NRF_GPIO->DETECTMODE = 0;
  NRF_POWER->SYSTEMOFF = 1;
  __DSB();
  while (true) {}
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HILFSFUNKTIONEN
// ═══════════════════════════════════════════════════════════════════════════════
void blinkLED(int pin, int n, int ms) {
  for (int i=0; i<n; i++) {
    digitalWrite(pin,LOW);  delay(ms);
    digitalWrite(pin,HIGH); delay(ms);
  }
}

uint8_t hzToOdrIndex(uint16_t hz) {
  uint8_t best=0; uint32_t bestD=UINT32_MAX;
  for (uint8_t i=0; i<ODR_COUNT; i++) {
    uint32_t d = abs((int32_t)hz - ODR_TABLE[i].hz);
    if (d < bestD) { bestD=d; best=i; }
  }
  return best;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SETUP
// ═══════════════════════════════════════════════════════════════════════════════
void setup() {
#if DEBUG
  Serial.begin(115200);
  delay(500);
#endif
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);
  pinMode(IMU_INT_PIN, INPUT);

  Wire.begin();
  Wire.setClock(400000);

  uint32_t rr = NRF_POWER->RESETREAS;
  NRF_POWER->RESETREAS = 0xFFFFFFFF;
  bool wakeFromSleep = (rr & POWER_RESETREAS_OFF_Msk) != 0;
  DBGLN(wakeFromSleep ? "[BOOT] Wakeup" : "[BOOT] Kaltstart");
  blinkLED(LED_BUILTIN, wakeFromSleep ? 3 : 2, wakeFromSleep ? 80 : 200);

  if (imu.begin() != 0) {
    DBGLN("[IMU] FEHLER");
    while (true) { blinkLED(LED_BUILTIN, 5, 100); delay(500); }
  }

  imuEnableTimer();
  imuFifoStop();
  DBGLN("[IMU] OK + Timer aktiv");

  if (!BLE.begin()) {
    DBGLN("[BLE] FEHLER");
    while (true) { blinkLED(LED_BUILTIN, 3, 100); delay(500); }
  }

  // Connection Interval für Default-ODR setzen (wirkt auf erste Verbindung)
  applyBleConnectionInterval();

  BLE.setLocalName("SurfaceSensor");
  BLE.setDeviceName("SurfaceSensor");
  BLE.setAdvertisedService(sensorService);
  sensorService.addCharacteristic(dataChar);
  sensorService.addCharacteristic(ctrlChar);
  sensorService.addCharacteristic(freqChar);
  sensorService.addCharacteristic(confChar);
  sensorService.addCharacteristic(calChar);
  sensorService.addCharacteristic(surfChar);
  sensorService.addCharacteristic(tSyncChar);
  sensorService.addCharacteristic(orientChar);
  sensorService.addCharacteristic(tempChar);
  BLE.addService(sensorService);

  ctrlChar.writeValue(0);
  uint8_t f[2] = {(uint8_t)ODR_TABLE[odrIndex].hz, (uint8_t)(ODR_TABLE[odrIndex].hz>>8)};
  freqChar.writeValue(f, 2);
  confChar.writeValue(fsIndex);

  BLE.advertise();
  DBGLN("[BLE] Advertising, ODR=" + String(ODR_TABLE[odrIndex].hz) + " Hz");
  lastActivityMs = millis();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  LOOP
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Aufnahme starten: FIFO initialisieren, Watermark-Interrupt anhängen,
 * BLE Connection Interval anpassen, Zeitbasis setzen.
 */
void startRecording() {
  imuFifoStop(); delay(2);
  imuFifoInit();                    // Watermark + INT1_FTH gesetzt
  _recStartMs    = millis();
  _recStartTicks = imuReadTicks();
  fifoReady      = false;           // stale Flag löschen
  surfaceAccumReset();              // Akkumulator neu starten
  // Auto-Zero-Akkumulator zurücksetzen (aber geschätzten Drift behalten)
  _azAutoSumG  = 0.0f;
  _azAutoSum2G = 0.0f;
  _azAutoN     = 0;
  applyBleConnectionInterval();     // Radio-Intervall an ODR anpassen
  attachInterrupt(digitalPinToInterrupt(IMU_INT_PIN), imuFifoIsrHandler, RISING);
  recording = true;
  digitalWrite(LED_BUILTIN, LOW);
  DBGLN("[REC] Start – ODR=" + String(ODR_TABLE[odrIndex].hz) +
        " Hz  FS=±" + String(FS_TABLE[fsIndex].g) + "g"
        "  AutoZeroDrift=" + String(_azAutoDriftG * 1000.0f, 1) + " mg");
}

/**
 * Aufnahme stoppen: ISR lösen, FIFO stoppen.
 */
void stopRecording() {
  recording = false;
  detachInterrupt(digitalPinToInterrupt(IMU_INT_PIN));
  imuFifoStop();                   // setzt auch INT1_CTRL auf 0
  digitalWrite(LED_BUILTIN, HIGH);
  DBGLN("[REC] Stop");
}

void loop() {
  if (SLEEP_TIMEOUT_MS > 0 && (millis() - lastActivityMs) >= SLEEP_TIMEOUT_MS)
    enterDeepSleep();

  BLEDevice central = BLE.central();
  if (!central) { delay(50); return; }

  lastActivityMs = millis();
  DBGLN("[BLE] Verbunden: " + central.address());
  blinkLED(LED_BUILTIN, 1, 300);
  recording = false;
  imuFifoStop();

  while (central.connected()) {
    lastActivityMs = millis();

    // ── Control ──────────────────────────────────────────────────────────────
    if (ctrlChar.written()) {
      uint8_t cmd = ctrlChar.value();
      if (cmd == 1 && !recording) {
        startRecording();
      } else if (cmd == 0 && recording) {
        stopRecording();
      }
    }

    // ── Frequenz ─────────────────────────────────────────────────────────────
    if (freqChar.written()) {
      uint8_t buf[2]; freqChar.readValue(buf, 2);
      odrIndex = hzToOdrIndex((uint16_t)buf[0] | (uint16_t)buf[1] << 8);
      DBGLN("[FREQ] " + String(ODR_TABLE[odrIndex].hz) + " Hz");
      if (recording) {
        // FIFO + ISR neu starten mit neuer ODR
        detachInterrupt(digitalPinToInterrupt(IMU_INT_PIN));
        imuFifoStop(); delay(2);
        imuFifoInit();
        fifoReady = false;
        surfaceAccumReset();           // Akkumulator zurücksetzen: ODR hat sich geändert
        applyBleConnectionInterval();
        attachInterrupt(digitalPinToInterrupt(IMU_INT_PIN), imuFifoIsrHandler, RISING);
      } else {
        imuApplyConfig(); imuFifoStop();
        applyBleConnectionInterval();
      }
    }

    // ── Full-Scale-Config ─────────────────────────────────────────────────────
    if (confChar.written()) {
      fsIndex = confChar.value() & 0x03;
      _g1raw  = 1.0f / FS_TABLE[fsIndex].scaleG;  // 1g in raw counts aktualisieren
      DBGLN("[FS] ±" + String(FS_TABLE[fsIndex].g) + "g  g1raw=" + String((int)_g1raw));
      if (recording) {
        detachInterrupt(digitalPinToInterrupt(IMU_INT_PIN));
        imuFifoStop(); delay(2);
        imuFifoInit();
        fifoReady = false;
        surfaceAccumReset();           // Akkumulator zurücksetzen: scaleG hat sich geändert
        attachInterrupt(digitalPinToInterrupt(IMU_INT_PIN), imuFifoIsrHandler, RISING);
      } else {
        imuApplyConfig(); imuFifoStop();
      }
    }

    // ── Zeit-Sync (TSYNC) ────────────────────────────────────────────────────
    if (tSyncChar.written()) {
      uint8_t tb[8]; tSyncChar.readValue(tb, 8);
      int64_t unixMs = 0;
      for (int i = 0; i < 8; i++) unixMs |= ((int64_t)tb[i] << (8*i));
      _tSyncOffset = unixMs - (int64_t)millis();
      DBGLN("[TSYNC] Offset=" + String((long)_tSyncOffset) + " ms");
    }

    // ── Offset-Kalibrierung ───────────────────────────────────────────────────
    if (calChar.written()) {
      uint8_t buf[1]; calChar.readValue(buf, 1);
      if (buf[0] == 0x01 && !recording) {
        performCalibration();
        // _g1raw bleibt gültig (FS ändert sich nicht während Kalibrierung)
      }
    }

    // ── Orientierungskalibrierung ─────────────────────────────────────────────
    // App schreibt 0x01 → Fahrrad muss aufrecht auf ebenem Boden stehen, still.
    // Ergebnis: 17-Byte Notify mit gx/gy/gz und gemessener |g| in g.
    if (orientChar.written()) {
      uint8_t buf[1]; orientChar.readValue(buf, 1);
      if (buf[0] == 0x01 && !recording) {
        performOrientationCalibration();
      }
    }

    // ── Sampling – Interrupt-gesteuert ────────────────────────────────────────
    //
    // fifoReady wird in der ISR gesetzt, wenn FIFO ≥ Watermark erreicht.
    // Im Idle-Zweig schläft der CPU mit delay(1) → Mbed WFI, ~0.1 mA statt 3.5 mA.
    //
    if (recording) {
      if (fifoReady) {
        fifoReady = false;
        uint8_t n = imuFifoReadBatch();          // akkumuliert pro Sample
        if (n > 0) dataChar.writeValue(pktBuf, PKT_HEADER + n * 6);
      } else {
        delay(1);
      }

      // ── 1-Hz Oberflächenanalyse ──────────────────────────────────────────
      // Sobald 1 Sekunde Akkumulationszeit vergangen: Kennwerte berechnen
      // und per surfChar senden. Läuft unabhängig vom FIFO-Interrupt.
      if ((millis() - surf.windowStart) >= 1000UL) {
        sendSurfacePacket();  // berechnet + sendet + resettet Akkumulator
      }

    } else {
      delay(1);
    }

    // ── Temperatur-Update (alle 5 Sekunden) ────────────────────────────────────
    // LSM6DS3 Temperaturregister: OUT_TEMP_L (0x20) / OUT_TEMP_H (0x21)
    // 16-bit signed, Sensitivität: 16 LSB/°C, Offset: 25 °C bei 0
    if ((millis() - _lastTempMs) >= 5000UL) {
      _lastTempMs = millis();
      uint8_t tRaw[2]; imu.readRegisterRegion(tRaw, 0x20, 2);
      int16_t rawT = (int16_t)((uint16_t)tRaw[0] | (uint16_t)tRaw[1] << 8);
      _lastTempC = 25.0f + (float)rawT / 16.0f;
      tempChar.writeValue((uint8_t*)&_lastTempC, 4);
      DBG("[TEMP] "); DBG(_lastTempC, 1); DBGLN(" °C");
      DBG("[AZERO] drift="); DBG(_azAutoDriftG * 1000.0f, 2); DBGLN(" mg");
    }
  }

  // ── Verbindung getrennt ───────────────────────────────────────────────────
  if (recording) stopRecording();
  lastActivityMs = millis();
  DBGLN("[BLE] Getrennt");
}

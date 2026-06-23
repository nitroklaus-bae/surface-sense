import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../models/gps_sample.dart';
import '../models/surface_sample.dart';

/// Minimaler FIT-Datei-Encoder für Aktivitätsdateien.
///
/// Erzeugt eine gültige FIT-Activity-Datei (Protocol 2.0) mit:
///   - GPS-Track (timestamp, lat, lon, speed)
///   - vibration_rms und vibration_vdv als Developer-Fields
///
/// Vibrationsdaten kommen aus den 1-Hz-SurfaceSamples (on-device RMS/VDV).
/// GPS-Surface-Korrelation: O(n+m) Two-Pointer — keine quadratische Schleife.
///
/// Garmin-Connect-kompatibel: https://developer.garmin.com/fit/protocol/
class FitWriter {

  // ── FIT-Zeitepoche: 31.12.1989 00:00:00 UTC ──────────────────────────────
  static const int _fitEpoch = 631065600;

  static int _toFitTs(int unixMs) => (unixMs ~/ 1000) - _fitEpoch;

  // ── CRC-16 (FIT-Algorithmus) ──────────────────────────────────────────────
  static const List<int> _crcTable = [
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
  ];

  static int _crc16(List<int> data, {int init = 0}) {
    int crc = init;
    for (final byte in data) {
      var tmp = _crcTable[crc & 0xF];
      crc = (crc >> 4) & 0x0FFF;
      crc ^= tmp ^ _crcTable[byte & 0xF];
      tmp = _crcTable[crc & 0xF];
      crc = (crc >> 4) & 0x0FFF;
      crc ^= tmp ^ _crcTable[(byte >> 4) & 0xF];
    }
    return crc;
  }

  // ── Low-Level-Schreibhelfer ───────────────────────────────────────────────

  static void _writeU8(List<int> b, int v)  => b.add(v & 0xFF);
  static void _writeU16(List<int> b, int v) { b.add(v & 0xFF); b.add((v >> 8) & 0xFF); }
  static void _writeU32(List<int> b, int v) {
    b.add(v & 0xFF); b.add((v >> 8) & 0xFF);
    b.add((v >> 16) & 0xFF); b.add((v >> 24) & 0xFF);
  }
  static void _writeI32(List<int> b, int v) => _writeU32(b, v & 0xFFFFFFFF);

  static void _writeF32(List<int> b, double v) {
    final bd = ByteData(4)..setFloat32(0, v, Endian.little);
    b.addAll(bd.buffer.asUint8List());
  }

  /// Null-terminierter String, auf [maxLen] Bytes aufgefüllt
  static void _writeString(List<int> b, String s, int maxLen) {
    final bytes = s.codeUnits;
    for (int i = 0; i < maxLen; i++) {
      b.add(i < bytes.length ? bytes[i] : 0x00);
    }
  }

  // ── Definition-Message ────────────────────────────────────────────────────
  static void _writeDef(
    List<int> b, {
    required int localNum,
    required int globalNum,
    required List<(int, int, int)> fields,
    List<(int, int, int)>? devFields,
  }) {
    final hasDev = devFields != null && devFields.isNotEmpty;
    _writeU8(b, hasDev ? (0x60 | localNum) : (0x40 | localNum));
    _writeU8(b, 0x00);
    _writeU8(b, 0x00);
    _writeU16(b, globalNum);
    _writeU8(b, fields.length);
    for (final f in fields) {
      _writeU8(b, f.$1);
      _writeU8(b, f.$2);
      _writeU8(b, f.$3);
    }
    if (hasDev) {
      _writeU8(b, devFields!.length);
      for (final f in devFields) {
        _writeU8(b, f.$1);
        _writeU8(b, f.$2);
        _writeU8(b, f.$3);
      }
    }
  }

  // ── FIT Base-Type-Konstanten ──────────────────────────────────────────────
  static const int _btEnum  = 0x00;
  static const int _btUint8 = 0x02;
  static const int _btUint16= 0x84;
  static const int _btSint32= 0x85;
  static const int _btUint32= 0x86;
  static const int _btStr   = 0x07;
  static const int _btF32   = 0x88;

  // ── FIT-Datei schreiben ───────────────────────────────────────────────────

  /// Exportiert Session-Daten als FIT-Datei nach [path].
  ///
  /// [gpsSamples]      – GPS-Punkte (zeitlich aufsteigend sortiert)
  /// [surfaceSamples]  – 1-Hz-Oberflächendaten vom Gerät (zeitlich aufsteigend)
  /// [sessionStart]    – Unix-Zeitstempel Aufnahmebeginn (ms)
  /// [sessionEnd]      – Unix-Zeitstempel Aufnahmeende (ms)
  ///
  /// GPS-Surface-Korrelation: Two-Pointer O(n+m).
  /// Jeder GPS-Punkt erhält den zeitlich nächsten SurfaceSample (≤ 2000 ms).
  static Future<File> write({
    required String path,
    required List<GpsSample>     gpsSamples,
    required List<SurfaceSample> surfaceSamples,
    required int sessionStart,
    required int sessionEnd,
  }) async {
    final data = <int>[];

    // ── Developer-Data-ID (local 0, mesg 207) ─────────────────────────────
    _writeDef(data, localNum: 0, globalNum: 207, fields: [
      (3, 1, _btUint8),
      (2, 4, _btUint32),
    ]);
    _writeU8(data, 0x00);
    _writeU8(data, 0);
    _writeU32(data, 1);

    // ── Field-Description: vibration_rms (float32, dev field 0) ──────────
    _writeDef(data, localNum: 1, globalNum: 206, fields: [
      (0, 1, _btUint8),
      (1, 1, _btUint8),
      (2, 1, _btUint8),
      (3, 16, _btStr),
      (4, 8, _btStr),
    ]);
    _writeU8(data, 0x01);
    _writeU8(data, 0);
    _writeU8(data, 0);
    _writeU8(data, 0x88);
    _writeString(data, 'vibration_rms', 16);
    _writeString(data, 'g', 8);

    // ── Field-Description: vibration_vdv (float32, dev field 1) ──────────
    _writeU8(data, 0x01);
    _writeU8(data, 0);
    _writeU8(data, 1);
    _writeU8(data, 0x88);
    _writeString(data, 'vibration_vdv', 16);
    _writeString(data, 'g*s^0.25', 8);

    // ── Field-Description: iri (float32, dev field 2) ─────────────────────
    _writeU8(data, 0x01);
    _writeU8(data, 0);
    _writeU8(data, 2);
    _writeU8(data, 0x88);
    _writeString(data, 'iri', 16);
    _writeString(data, 'm/km', 8);

    // ── FILE_ID (local 2, mesg 0) ─────────────────────────────────────────
    _writeDef(data, localNum: 2, globalNum: 0, fields: [
      (253, 4, _btUint32),
      (0,   1, _btEnum),
      (1,   2, _btUint16),
      (2,   2, _btUint16),
    ]);
    _writeU8(data, 0x02);
    _writeU32(data, _toFitTs(sessionStart));
    _writeU8(data, 4);
    _writeU16(data, 255);
    _writeU16(data, 0);

    // ── RECORD-Definition (local 3, mesg 20) mit Dev-Fields ──────────────
    _writeDef(data, localNum: 3, globalNum: 20, fields: [
      (253, 4, _btUint32),
      (0,   4, _btSint32),
      (1,   4, _btSint32),
      (6,   2, _btUint16),
    ], devFields: [
      (0, 4, 0),
      (1, 4, 0),
      (2, 4, 0),
    ]);

    // ── RECORD-Daten: O(n+m) Two-Pointer GPS×Surface ──────────────────────
    //
    // Beide Listen sind zeitlich aufsteigend sortiert (so wie sie ankamen).
    // Der Surface-Pointer si rückt nur vor, wird nie zurückgesetzt.
    // Komplexität: O(n+m) statt O(n×m).
    // Toleranz: ±2000 ms (bei 1-Hz-Surface-Daten großzügig genug).

    int si = 0;
    for (final gps in gpsSamples) {
      if (!gps.latitude.isFinite || !gps.longitude.isFinite) continue;

      // Si voranrücken solange der nächste Eintrag näher am GPS-Timestamp liegt
      while (si + 1 < surfaceSamples.length) {
        final distCurr = (surfaceSamples[si].timestampMs - gps.timestampMs).abs();
        final distNext = (surfaceSamples[si + 1].timestampMs - gps.timestampMs).abs();
        if (distNext < distCurr) {
          si++;
        } else {
          break;
        }
      }

      // Vibrationswerte nur verwenden wenn Surface-Sample zeitlich nah genug
      double rmsVal = 0.0;
      double vdvVal = 0.0;
      double iriVal = 0.0;
      if (si < surfaceSamples.length &&
          (surfaceSamples[si].timestampMs - gps.timestampMs).abs() <= 2000) {
        rmsVal = surfaceSamples[si].rmsG;
        vdvVal = surfaceSamples[si].vdvG;
        iriVal = surfaceSamples[si].iriMKm ?? 0.0;
      }

      final speedRaw = (gps.speed != null && gps.speed! >= 0)
          ? (gps.speed! * 1000).round().clamp(0, 0xFFFE)
          : 0xFFFF;

      _writeU8(data, 0x03);
      _writeU32(data, _toFitTs(gps.timestampMs));
      _writeI32(data, gps.latSemicircles());
      _writeI32(data, gps.lonSemicircles());
      _writeU16(data, speedRaw);
      _writeF32(data, rmsVal);
      _writeF32(data, vdvVal);
      _writeF32(data, iriVal);
    }

    // ── LAP (local 4, mesg 19) ────────────────────────────────────────────
    final durationS = max(1, (sessionEnd - sessionStart) ~/ 1000);
    _writeDef(data, localNum: 4, globalNum: 19, fields: [
      (253, 4, _btUint32),
      (2,   4, _btUint32),
      (7,   4, _btUint32),
      (5,   1, _btEnum),
    ]);
    _writeU8(data, 0x04);
    _writeU32(data, _toFitTs(sessionEnd));
    _writeU32(data, _toFitTs(sessionStart));
    _writeU32(data, durationS * 1000);
    _writeU8(data, 2);

    // ── SESSION (local 5, mesg 18) ────────────────────────────────────────
    _writeDef(data, localNum: 5, globalNum: 18, fields: [
      (253, 4, _btUint32),
      (2,   4, _btUint32),
      (7,   4, _btUint32),
      (5,   1, _btEnum),
      (6,   1, _btEnum),
      (9,   2, _btUint16),
    ]);
    _writeU8(data, 0x05);
    _writeU32(data, _toFitTs(sessionEnd));
    _writeU32(data, _toFitTs(sessionStart));
    _writeU32(data, durationS * 1000);
    _writeU8(data, 2);
    _writeU8(data, 0);
    _writeU16(data, 1);

    // ── ACTIVITY (local 6, mesg 34) ───────────────────────────────────────
    _writeDef(data, localNum: 6, globalNum: 34, fields: [
      (253, 4, _btUint32),
      (0,   4, _btUint32),
      (1,   2, _btUint16),
      (2,   1, _btEnum),
      (3,   1, _btEnum),
      (4,   1, _btEnum),
    ]);
    _writeU8(data, 0x06);
    _writeU32(data, _toFitTs(sessionEnd));
    _writeU32(data, durationS * 1000);
    _writeU16(data, 1);
    _writeU8(data, 0);
    _writeU8(data, 26);
    _writeU8(data, 1);

    // ── Header + CRC zusammensetzen ───────────────────────────────────────
    final dataBytes = Uint8List.fromList(data);
    final dataCrc   = _crc16(data);

    final header = <int>[
      0x0E, 0x20, 0x54, 0x08,
      dataBytes.length & 0xFF,
      (dataBytes.length >> 8)  & 0xFF,
      (dataBytes.length >> 16) & 0xFF,
      (dataBytes.length >> 24) & 0xFF,
      0x2E, 0x46, 0x49, 0x54,
    ];
    final headerCrc = _crc16(header);
    header.add(headerCrc & 0xFF);
    header.add((headerCrc >> 8) & 0xFF);

    final file = File(path);
    final out  = file.openWrite();
    out.add(header);
    out.add(dataBytes);
    out.add([dataCrc & 0xFF, (dataCrc >> 8) & 0xFF]);
    await out.close();

    return file;
  }
}

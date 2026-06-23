import 'dart:math';
import 'dart:typed_data';

/// ODR-Tabelle (Firmware-synchron)
const List<int> kOdrHz = [52, 104, 208, 416, 833, 1666];

/// Full-Scale-Tabelle: index → max g
const List<int>    kFsG     = [2, 4, 8, 16];
const List<double> kFsScale = [
  2.0  / 32768.0,   // ±2g
  4.0  / 32768.0,   // ±4g
  8.0  / 32768.0,   // ±8g
  16.0 / 32768.0,   // ±16g
];

/// Ein einzelner Messwert
class SensorSample {
  final int    timestampMs;
  final double ax;           // [g]
  final double ay;
  final double az;

  const SensorSample({
    required this.timestampMs,
    required this.ax,
    required this.ay,
    required this.az,
  });

  double get magnitude => sqrt(ax * ax + ay * ay + az * az);
  /// [baseMs] = Aufnahme-Startzeit; Zeit wird als Sekunden relativ dazu ausgegeben.
  String toCsvRow([int baseMs = 0]) {
    final t = (timestampMs - baseMs) / 1000.0;
    return '${t.toStringAsFixed(4)},${ax.toStringAsFixed(6)},${ay.toStringAsFixed(6)},${az.toStringAsFixed(6)}';
  }
  static String csvHeader() => 'time_s,ax_g,ay_g,az_g';

  // ── Batch-Parser ──────────────────────────────────────────────────────────
  //
  // Paket-Layout (v3):
  //   [0-3]  uint32 base_timestamp_ms
  //   [4]    uint8  count
  //   [5]    uint8  config: bits[2:0]=odrIndex, bits[4:3]=fsIndex
  //   [6+]   int16 ax, int16 ay, int16 az  × count
  //
  static List<SensorSample> fromBatchBytes(List<int> bytes) {
    if (bytes.length < 7) return [];

    final bd     = ByteData.sublistView(Uint8List.fromList(bytes));
    final baseTs = bd.getUint32(0, Endian.little);
    final count  = bd.getUint8(4);
    final cfg    = bd.getUint8(5);
    final odrIdx = (cfg & 0x07).clamp(0, kOdrHz.length - 1);
    final fsIdx  = ((cfg >> 3) & 0x03).clamp(0, kFsG.length - 1);

    final intervalMs = 1000.0 / kOdrHz[odrIdx];
    final scale      = kFsScale[fsIdx];

    if (bytes.length < 6 + count * 6) return [];

    final result = <SensorSample>[];
    for (int i = 0; i < count; i++) {
      final off = 6 + i * 6;
      result.add(SensorSample(
        timestampMs: baseTs + (i * intervalMs).round(),
        ax: bd.getInt16(off,     Endian.little) * scale,
        ay: bd.getInt16(off + 2, Endian.little) * scale,
        az: bd.getInt16(off + 4, Endian.little) * scale,
      ));
    }
    return result;
  }

  /// Legacy-Format v1 (16 Byte, float)
  static SensorSample? fromLegacyBytes(List<int> bytes) {
    if (bytes.length < 16) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    return SensorSample(
      timestampMs: bd.getUint32(0, Endian.little),
      ax: bd.getFloat32(4,  Endian.little),
      ay: bd.getFloat32(8,  Endian.little),
      az: bd.getFloat32(12, Endian.little),
    );
  }

  /// Automatische Erkennung: 16 Byte = Legacy, sonst Batch
  static List<SensorSample> parse(List<int> bytes) {
    if (bytes.length == 16) {
      final s = fromLegacyBytes(bytes); return s != null ? [s] : [];
    }
    return fromBatchBytes(bytes);
  }
}

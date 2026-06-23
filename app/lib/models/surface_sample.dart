import 'dart:typed_data';

/// Ein 1-Hz-Oberflächenanalyse-Datenpunkt vom Device.
///
/// Entspricht dem SURF_PKT_SIZE=16 Byte Paket der Firmware:
///   [0-3]  uint32  timestamp_ms
///   [4-7]  float32 rms_g
///   [8-11] float32 vdv_g
///   [12-15] float32 peak_g
///
/// [iriMKm] wird App-seitig aus rmsG + GPS-Geschwindigkeit berechnet
/// (SignalAnalysis.iriFromRms) — nicht vom Gerät übertragen.
class SurfaceSample {
  final int    timestampMs;
  final double rmsG;    // Root Mean Square Z-Achse [g]
  final double vdvG;    // Vibration Dose Value [g·s^0.25]
  final double peakG;   // Peak |az| [g]

  /// International Roughness Index [m/km].
  /// null solange noch kein GPS-Speed bekannt.
  final double? iriMKm;

  const SurfaceSample({
    required this.timestampMs,
    required this.rmsG,
    required this.vdvG,
    required this.peakG,
    this.iriMKm,
  });

  double get crestFactor => rmsG > 0 ? peakG / rmsG : 0;

  SurfaceSample copyWith({int? timestampMs, double? iriMKm}) => SurfaceSample(
    timestampMs: timestampMs ?? this.timestampMs,
    rmsG:   rmsG,
    vdvG:   vdvG,
    peakG:  peakG,
    iriMKm: iriMKm ?? this.iriMKm,
  );

  factory SurfaceSample.fromBytes(List<int> bytes) {
    if (bytes.length < 16) {
      throw const FormatException('Surface-Paket zu kurz (< 16 Byte)');
    }
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    return SurfaceSample(
      timestampMs: bd.getUint32(0,  Endian.little),
      rmsG:        bd.getFloat32(4,  Endian.little),
      vdvG:        bd.getFloat32(8,  Endian.little),
      peakG:       bd.getFloat32(12, Endian.little),
    );
  }

  /// [baseMs] = Aufnahme-Startzeit; Zeit wird als Sekunden relativ dazu ausgegeben.
  String toCsvRow([int baseMs = 0]) {
    final t   = (timestampMs - baseMs) / 1000.0;
    final iri = iriMKm?.toStringAsFixed(4) ?? '';
    return '${t.toStringAsFixed(3)},${rmsG.toStringAsFixed(6)},'
        '${vdvG.toStringAsFixed(6)},${peakG.toStringAsFixed(6)},'
        '${crestFactor.toStringAsFixed(4)},$iri';
  }

  static String csvHeader() =>
      'time_s,rms_g,vdv_g,peak_g,crest_factor,iri_m_km';

  @override
  String toString() =>
      'Surface(${timestampMs}ms RMS=${rmsG.toStringAsFixed(4)}g '
      'VDV=${vdvG.toStringAsFixed(4)} Peak=${peakG.toStringAsFixed(4)}g'
      '${iriMKm != null ? " IRI=${iriMKm!.toStringAsFixed(2)}" : ""})';
}

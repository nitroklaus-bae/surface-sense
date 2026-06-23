/// Ein GPS-Messpunkt mit Zeitstempel (System-Zeit in Millisekunden)
class GpsSample {
  final int    timestampMs;   // Millisekunden seit Unix-Epoche
  final double latitude;      // Dezimalgrad
  final double longitude;     // Dezimalgrad
  final double? altitude;     // Meter über NN
  final double? accuracy;     // Horizontale Genauigkeit [m]
  final double? speed;        // Geschwindigkeit [m/s]

  const GpsSample({
    required this.timestampMs,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.speed,
  });

  /// FIT-Timestamp (Sekunden seit 31.12.1989 00:00:00 UTC)
  int get fitTimestamp => (timestampMs ~/ 1000) - 631065600;

  /// Grad → Semicircles (für FIT-Format)
  int latSemicircles() => (latitude  * (1 << 31) / 180).round();
  int lonSemicircles() => (longitude * (1 << 31) / 180).round();

  @override
  String toString() => 'GPS(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}) @${timestampMs}ms';
}

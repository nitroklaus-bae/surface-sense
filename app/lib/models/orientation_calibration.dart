import 'dart:math' show sqrt, atan2;
import 'dart:typed_data';

// ── Fahrtrichtungs-Achsenauswahl ──────────────────────────────────────────────
// Nutzer markiert eine Sensorachse physisch (Aufkleber, Stift) und richtet sie
// beim Montieren in Fahrtrichtung aus.
enum ForwardAxis {
  plusX  (label: '+X', description: 'Sensor-X-Achse zeigt vorwärts'),
  minusX (label: '−X', description: 'Sensor-X-Achse zeigt rückwärts'),
  plusY  (label: '+Y', description: 'Sensor-Y-Achse zeigt vorwärts'),
  minusY (label: '−Y', description: 'Sensor-Y-Achse zeigt rückwärts'),
  plusZ  (label: '+Z', description: 'Sensor-Z-Achse zeigt vorwärts'),
  minusZ (label: '−Z', description: 'Sensor-Z-Achse zeigt rückwärts');

  const ForwardAxis({required this.label, required this.description});
  final String label;
  final String description;

  /// Rohvektor dieser Achse im IMU-Frame.
  List<double> get rawVector => switch (this) {
    ForwardAxis.plusX  => [ 1.0, 0.0, 0.0],
    ForwardAxis.minusX => [-1.0, 0.0, 0.0],
    ForwardAxis.plusY  => [ 0.0, 1.0, 0.0],
    ForwardAxis.minusY => [ 0.0,-1.0, 0.0],
    ForwardAxis.plusZ  => [ 0.0, 0.0, 1.0],
    ForwardAxis.minusZ => [ 0.0, 0.0,-1.0],
  };
}

// ── Fahrrad-Koordinatensystem ─────────────────────────────────────────────────
// Vollständige 3-Achsen-Drehmatrix: vertikal / longitudinal (vorwärts) / lateral (rechts).
// Berechnet aus OrientationCalibration (g_hat) + ForwardAxis (Nutzerwahl).
//
// Achsendefinition (rechtshändig, NED-Konvention):
//   vertical  = Schwerkraftrichtung ↓ (= g_hat)
//   forward   = Fahrtrichtung ↑ (orthogonalisiert gegen g_hat)
//   lateral   = Seite rechts (= g_hat × forward)
//
// Gram-Schmidt-Orthogonalisierung: sichert, dass f_hat wirklich ⊥ g_hat,
// selbst wenn Sensor schräg montiert ist.
class BikeFrameCalibration {
  /// Schwerkraftrichtung (nach unten), Einheitsvektor.
  final (double, double, double) gHat;
  /// Fahrtrichtung (vorwärts), Einheitsvektor, ⊥ gHat.
  final (double, double, double) fHat;
  /// Rechte Seite des Fahrrads, Einheitsvektor, = gHat × fHat.
  final (double, double, double) lHat;
  /// Gewählte Vorwärtsachse.
  final ForwardAxis forwardAxis;

  const BikeFrameCalibration({
    required this.gHat,
    required this.fHat,
    required this.lHat,
    required this.forwardAxis,
  });

  /// Berechnet das Bike-Frame aus Orientierungskalibrierung + gewählter Achse.
  ///
  /// f_hat = exakt die gewählte Sensorachse (keine Projektion).
  /// l_hat = nächste Sensorachse per Kreuzprodukt-Snap:
  ///   1. cross(g_hat, f_hat) → Richtungsvektor der rechten Seite
  ///   2. Snap zur nächstliegenden Sensorachse (±X oder ±Y)
  ///   → beide Achsen sind reine int-Achsen, z.B. forwardG = sample.ax
  ///
  /// Vertikale Achse bleibt vollständig g_hat-projiziert (Neigungskorrektur).
  /// Gibt null zurück wenn orientCal ungültig oder Sensorachse ≈ Schwerkraftrichtung.
  static BikeFrameCalibration? compute(
      OrientationCalibration orientCal, ForwardAxis forwardAxis) {
    if (!orientCal.isValid) return null;

    final gx = orientCal.gx, gy = orientCal.gy, gz = orientCal.gz;
    final raw = forwardAxis.rawVector;
    final (fx, fy, fz) = (raw[0], raw[1], raw[2]);

    // Kreuzprodukt g_hat × f_hat → zeigt in Richtung „rechts" (NED-Konvention)
    final lcx = gy*fz - gz*fy;
    final lcy = gz*fx - gx*fz;
    final lcz = gx*fy - gy*fx;
    final lMag = sqrt(lcx*lcx + lcy*lcy + lcz*lcz);

    // Vorwärtsachse fast parallel zur Schwerkraft → Konfigurationsfehler
    if (lMag < 0.3) return null;

    // Snap: größte Komponente des Kreuzprodukts bestimmt die Lateral-Achse.
    // Ergebnis ist immer ±[1,0,0] oder ±[0,1,0] oder ±[0,0,1].
    final ax = lcx.abs(), ay = lcy.abs(), az = lcz.abs();
    double lx, ly, lz;
    if (ax >= ay && ax >= az) {
      lx = lcx > 0 ? 1.0 : -1.0; ly = 0.0; lz = 0.0;
    } else if (ay >= ax && ay >= az) {
      lx = 0.0; ly = lcy > 0 ? 1.0 : -1.0; lz = 0.0;
    } else {
      // Z als Lateral – erwartet bei USB-C-unten-Montage (+X vorwärts, +Y unten)
      lx = 0.0; ly = 0.0; lz = lcz > 0 ? 1.0 : -1.0;
    }

    return BikeFrameCalibration(
      gHat:        (gx, gy, gz),
      fHat:        (fx, fy, fz),
      lHat:        (lx, ly, lz),
      forwardAxis: forwardAxis,
    );
  }

  /// Lesbare Achsenbezeichnung für die UI.
  /// Gibt z.B. "+Y → +X" zurück (Vorwärts → Lateral rechts).
  String get axisLabel {
    String _axName((double, double, double) v) {
      final (x, y, z) = v;
      if (x.abs() > 0.5) return x > 0 ? '+X' : '−X';
      if (y.abs() > 0.5) return y > 0 ? '+Y' : '−Y';
      return z > 0 ? '+Z' : '−Z';
    }
    return '${_axName(fHat)} vorwärts · ${_axName(lHat)} rechts';
  }

  /// Dynamische Vertikalbeschleunigung in g (≈ 0 auf glatter Fläche).
  double verticalG(double ax, double ay, double az) {
    final (gx, gy, gz) = gHat;
    return ax*gx + ay*gy + az*gz - 1.0;
  }

  /// Longitudinale Beschleunigung in g (positiv = vorwärts).
  double forwardG(double ax, double ay, double az) {
    final (fx, fy, fz) = fHat;
    return ax*fx + ay*fy + az*fz;
  }

  /// Laterale Beschleunigung in g (positiv = rechts).
  double lateralG(double ax, double ay, double az) {
    final (lx, ly, lz) = lHat;
    return ax*lx + ay*ly + az*lz;
  }
}

// ── Orientierungskalibrierungs-Status ─────────────────────────────────────────
enum OrientCalStatus {
  inProgress,         // 0x10: Messung läuft
  done,               // 0x00: Kalibrierung erfolgreich
  errorOffsetMissing, // 0xFE: Offset-Kalibrierung muss zuerst durchgeführt werden
  error,              // 0xFF: Kalibrierung fehlgeschlagen (z.B. Bewegung, falscher Wert)
}

// ── Orientierungskalibrierungs-Ergebnis ───────────────────────────────────────
//
// Firmware misst Schwerkraftvektor [gx, gy, gz] im IMU-Frame, wenn das Fahrrad
// aufrecht und still auf ebenem Boden steht.
//
// Anwendung auf App-Seite (für FFT/Analyse auf dem "wahren Vertikal-Signal"):
//   a_vertikal_g = ax_g * gx + ay_g * gy + az_g * gz - 1.0
//   (dot-Produkt gibt total-vertikale g, -1.0 entfernt Schwerkraft)
//
// Firmware verwendet dieselbe Formel für on-device RMS/VDV – damit werden
// RMS-Werte korrekt (~0 mg auf glatter Straße, steigt mit Rauheit), unabhängig
// vom Montagewinkel.
class OrientationCalibration {
  final OrientCalStatus status;

  /// Einheitsvektor der Schwerkraftrichtung im IMU-Frame (dimensionslos).
  final double gx, gy, gz;

  /// Gemessener Schwerkraftbetrag in g (Qualitätsindikator, sollte ≈ 1.0 sein).
  final double gMagG;

  const OrientationCalibration({
    required this.status,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.gMagG,
  });

  /// Parst das 17-Byte-Notify-Paket der Firmware.
  factory OrientationCalibration.fromBytes(List<int> bytes) {
    if (bytes.isEmpty) {
      return const OrientationCalibration(
        status: OrientCalStatus.error,
        gx: 0, gy: 0, gz: 1, gMagG: 0,
      );
    }

    final s = switch (bytes[0]) {
      0x10 => OrientCalStatus.inProgress,
      0x00 => OrientCalStatus.done,
      0xFE => OrientCalStatus.errorOffsetMissing,
      _    => OrientCalStatus.error,
    };

    if (bytes.length < 17 || s != OrientCalStatus.done) {
      return OrientationCalibration(
        status: s, gx: 0, gy: 0, gz: 1, gMagG: 0,
      );
    }

    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    return OrientationCalibration(
      status: s,
      gx:    bd.getFloat32(1,  Endian.little),
      gy:    bd.getFloat32(5,  Endian.little),
      gz:    bd.getFloat32(9,  Endian.little),
      gMagG: bd.getFloat32(13, Endian.little),
    );
  }

  /// Projiziert eine kalibrierte Beschleunigung [ax, ay, az] in g auf die
  /// wahre Vertikalachse und gibt den dynamischen Anteil zurück (Schwerkraft
  /// subtrahiert). Entspricht genau dem, was die Firmware für RMS/VDV berechnet.
  ///
  /// Rückgabe: dynamische Vertikalbeschleunigung in g (≈ 0 auf glatter Fläche).
  double verticalG(double ax, double ay, double az) =>
      ax * gx + ay * gy + az * gz - 1.0;

  /// Horizontale Beschleunigungsmagnitude (senkrecht zur Vertikalachse) in g.
  /// Enthält laterale und longitudinale Komponenten kombiniert.
  double horizontalG(double ax, double ay, double az) {
    final vert = ax * gx + ay * gy + az * gz;
    final hx = ax - vert * gx;
    final hy = ay - vert * gy;
    final hz = az - vert * gz;
    final mag2 = hx*hx + hy*hy + hz*hz;
    return mag2 > 0 ? sqrt(mag2) : 0.0;
  }

  /// Tilt-Winkel des Sensors gegenüber der Vertikalachse in Grad.
  /// 0° = Z zeigt exakt nach oben; 90° = Sensor horizontal montiert.
  double get tiltDeg {
    final cosTheta = gz.abs().clamp(0.0, 1.0);
    final sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    const radToDeg = 180.0 / 3.141592653589793;
    return atan2(sinTheta, cosTheta) * radToDeg;
  }

  bool get isValid => status == OrientCalStatus.done;
}

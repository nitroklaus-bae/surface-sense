import 'dart:math';

// ── Ergebnis einer FFT-Berechnung ─────────────────────────────────────────────
class FftResult {
  final List<double> magnitudes;   // Amplitude pro Bin [g]
  final List<double> frequencies;  // Frequenz pro Bin [Hz]
  final double freqResolution;     // Hz pro Bin

  const FftResult({
    required this.magnitudes,
    required this.frequencies,
    required this.freqResolution,
  });

  double get peakFrequency {
    if (magnitudes.isEmpty) return 0;
    int idx = 0;
    for (int i = 1; i < magnitudes.length; i++) {
      if (magnitudes[i] > magnitudes[idx]) idx = i;
    }
    return frequencies[idx];
  }

  double get peakMagnitude =>
      magnitudes.isEmpty ? 0 : magnitudes.reduce(max);
}

// ── Signal-Analyse-Utilities ──────────────────────────────────────────────────
class SignalAnalysis {

  /// Nächste Zweierpotenz ≥ n
  static int nextPow2(int n) {
    int p = 1;
    while (p < n) p <<= 1;
    return p;
  }

  // ── Cooley-Tukey Radix-2 FFT (iterativ, Bit-Reversal-Permutation) ──────────
  // Nur für interne Nutzung; Eingabelänge muss Zweierpotenz sein.
  static void _fftInPlace(List<double> re, List<double> im) {
    final n = re.length;

    // Bit-Reversal-Permutation
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) {
        var t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }

    // Butterfly-Stufen
    for (int len = 2; len <= n; len <<= 1) {
      final ang  = -2 * pi / len;
      final wRe  = cos(ang);
      final wIm  = sin(ang);
      for (int i = 0; i < n; i += len) {
        double curRe = 1, curIm = 0;
        for (int k = 0; k < len >> 1; k++) {
          final uRe = re[i + k];
          final uIm = im[i + k];
          final h   = i + k + (len >> 1);
          final vRe = re[h] * curRe - im[h] * curIm;
          final vIm = re[h] * curIm + im[h] * curRe;
          re[i + k] = uRe + vRe;
          im[i + k] = uIm + vIm;
          re[h]     = uRe - vRe;
          im[h]     = uIm - vIm;
          final nr  = curRe * wRe - curIm * wIm;
          curIm     = curRe * wIm + curIm * wRe;
          curRe     = nr;
        }
      }
    }
  }

  /// FFT eines Zeitsignals.
  ///
  /// [signal]       – Messwerte in g (beliebige Länge; wird auf nächste 2er-Potenz
  ///                  zero-gepadded oder auf maxSamples begrenzt)
  /// [sampleRateHz] – Abtastrate
  /// [maxSamples]   – Max. FFT-Größe (Standard 4096; muss Zweierpotenz sein)
  ///
  /// Gibt die einseitige Amplitude (positiver Frequenzbereich) zurück.
  static FftResult computeFft(
    List<double> signal,
    double sampleRateHz, {
    int maxSamples = 4096,
  }) {
    if (signal.isEmpty) return FftResult(magnitudes: [], frequencies: [], freqResolution: 0);

    // Fensterlänge: min(nächste 2er-Potenz von signal.length, maxSamples)
    final targetLen = min(nextPow2(signal.length), maxSamples);
    // Wenn signal länger: die letzten targetLen Samples nehmen (aktuellste Daten)
    final offset = signal.length > targetLen ? signal.length - targetLen : 0;
    final n      = targetLen;

    final re = List<double>.generate(n, (i) {
      final idx = offset + i;
      final sample = idx < signal.length ? signal[idx] : 0.0;
      // Hanning-Fenster (reduziert Spectral Leakage)
      final w = 0.5 * (1 - cos(2 * pi * i / (n - 1)));
      return sample * w;
    });
    final im = List<double>.filled(n, 0.0);

    _fftInPlace(re, im);

    // Einseitiges Spektrum (nur positive Frequenzen), skaliert
    final halfN  = n ~/ 2;
    final scale  = 2.0 / n;
    final freqRes = sampleRateHz / n;

    final mags  = List<double>.generate(halfN, (k) => sqrt(re[k]*re[k] + im[k]*im[k]) * scale);
    final freqs = List<double>.generate(halfN, (k) => k * freqRes);

    return FftResult(magnitudes: mags, frequencies: freqs, freqResolution: freqRes);
  }

  // ── Statistische Metriken ─────────────────────────────────────────────────

  /// Root Mean Square [g]
  static double rms(List<double> signal) {
    if (signal.isEmpty) return 0;
    double sum = 0;
    for (final v in signal) sum += v * v;
    return sqrt(sum / signal.length);
  }

  /// Vibration Dose Value nach ISO 2631-1 [g·s^0.25]
  /// VDV = (∫ a⁴(t) dt)^0.25 ≈ (Σ aᵢ⁴ · dt)^0.25
  static double vdv(List<double> signal, double sampleRateHz) {
    if (signal.isEmpty) return 0;
    final dt = 1.0 / sampleRateHz;
    double sum = 0;
    for (final v in signal) sum += v * v * v * v;
    return pow(sum * dt, 0.25).toDouble();
  }

  /// Crest Factor = Peak / RMS (dimensionslos)
  static double crestFactor(List<double> signal) {
    final r = rms(signal);
    if (r == 0) return 0;
    double peak = 0;
    for (final v in signal) { final a = v.abs(); if (a > peak) peak = a; }
    return peak / r;
  }

  /// International Roughness Index (IRI) aus RMS-Beschleunigung [m/km]
  ///
  /// Vereinfachte Näherungsformel für Rad-Sensorik (Referenzgeschwindigkeit 20 km/h):
  ///   IRI [m/km] = 2.21 × RMS_g                (Basis, ohne Geschwindigkeit)
  ///   IRI [m/km] = 2.21 × RMS_g × √(20 / v)    (mit GPS-Geschwindigkeitskorrektur)
  ///
  /// Referenz-Kalibrierungsfaktor 2.21 basiert auf empirischer Korrelation
  /// Rad-Beschleunigungssensoren ↔ stationären IRI-Messgeräten bei ~20 km/h.
  ///
  /// Interpretation (EN-Skala):
  ///   < 1.0  = sehr glatt (Velodrom, Neubau)
  ///   1–2    = gut (Stadtstraße)
  ///   2–5    = mäßig (älteres Pflaster)
  ///   5–10   = rau (Schotter, Kopfsteinpflaster)
  ///   > 10   = sehr rau / unbefestigt
  ///
  /// [rmsG]         – RMS-Beschleunigung in g (aus SurfaceSample)
  /// [speedKmh]     – aktuelle Fahrgeschwindigkeit; null = Referenzgeschwindigkeit 20 km/h
  static double iriFromRms(double rmsG, {double? speedKmh}) {
    if (!rmsG.isFinite || rmsG <= 0) return 0.0;
    const calibration = 2.21;
    if (speedKmh == null || !speedKmh.isFinite || speedKmh <= 0) {
      return calibration * rmsG;
    }
    // Geschwindigkeitskorrektur: IRI ∝ RMS / √v  (empirisch)
    final vClamped = speedKmh.clamp(5.0, 60.0);
    return calibration * rmsG * sqrt(20.0 / vClamped);
  }

  /// Amplituden-Histogramm: gibt Map<Mittelwert des Bins → Anzahl> zurück
  static Map<double, int> histogram(List<double> signal, {int bins = 30}) {
    if (signal.isEmpty) return {};
    final min = signal.reduce((a, b) => a < b ? a : b);
    final max = signal.reduce((a, b) => a > b ? a : b);
    final range = max - min;
    if (range == 0) return {min: signal.length};
    final binWidth = range / bins;
    final counts = <double, int>{};
    for (int i = 0; i < bins; i++) {
      counts[min + (i + 0.5) * binWidth] = 0;
    }
    for (final v in signal) {
      int idx = ((v - min) / binWidth).floor().clamp(0, bins - 1);
      final key = min + (idx + 0.5) * binWidth;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }
}

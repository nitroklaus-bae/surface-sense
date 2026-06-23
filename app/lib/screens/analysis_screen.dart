import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/sensor_sample.dart';
import '../models/surface_sample.dart';
import '../providers/recording_provider.dart';
import '../utils/signal_analysis.dart';

// ── Achsen-Auswahl ────────────────────────────────────────────────────────────
enum _Axis { x, y, z, magnitude }

extension _AxisLabel on _Axis {
  String get label => switch (this) {
    _Axis.x => 'X',
    _Axis.y => 'Y',
    _Axis.z => 'Z',
    _Axis.magnitude => '|a|',
  };
  Color get color => switch (this) {
    _Axis.x => Colors.red,
    _Axis.y => Colors.green,
    _Axis.z => Colors.blue,
    _Axis.magnitude => Colors.purple,
  };
}

// ── Analyse-Fenster ───────────────────────────────────────────────────────────
enum _Window { s1, s2, s5, all }

extension _WindowLabel on _Window {
  String get label => switch (this) {
    _Window.s1 => '1 s',
    _Window.s2 => '2 s',
    _Window.s5 => '5 s',
    _Window.all => 'Gesamt',
  };
  int? get seconds => switch (this) {
    _Window.s1 => 1,
    _Window.s2 => 2,
    _Window.s5 => 5,
    _Window.all => null,
  };
}

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});
  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  _Axis   _axis   = _Axis.z;
  _Window _window = _Window.s2;

  @override
  Widget build(BuildContext context) {
    final prov    = context.watch<RecordingProvider>();
    final samples = prov.samples;

    if (samples.isEmpty) {
      return const Center(
        child: Text(
          'Keine Daten vorhanden.\nAufnahme starten und dann hier analysieren.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final surfaceSamples = prov.surfaceSamples;
    final odrHz = prov.frequencyHz.toDouble();

    // Zeitfenster auswählen
    final signal = _extractSignal(samples, odrHz);

    // FFT berechnen
    final fft = SignalAnalysis.computeFft(signal, odrHz, maxSamples: 4096);

    // Metriken
    final rmsVal = SignalAnalysis.rms(signal);
    final vdvVal = SignalAnalysis.vdv(signal, odrHz);
    final cfVal  = SignalAnalysis.crestFactor(signal);
    final hist   = SignalAnalysis.histogram(signal, bins: 24);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Steuerleiste ─────────────────────────────────────────────────
          _ControlRow(
            axis:      _axis,
            window:    _window,
            onAxis:    (a) => setState(() => _axis   = a),
            onWindow:  (w) => setState(() => _window = w),
            sampleCount: samples.length,
          ),
          const SizedBox(height: 12),

          // ── Zeitbereich ──────────────────────────────────────────────────
          _SectionCard(
            title: 'Zeitbereich',
            subtitle: 'Achse ${_axis.label}  ·  DC-frei  ·  ${(signal.length / odrHz).toStringAsFixed(2)} s',
            child: SizedBox(
              height: 160,
              child: signal.isEmpty
                  ? const Center(child: Text('Zu wenige Samples'))
                  : _WaveformChart(signal: signal, sampleRateHz: odrHz, color: _axis.color),
            ),
          ),
          const SizedBox(height: 10),

          // ── Frequenzspektrum ─────────────────────────────────────────────
          _SectionCard(
            title: 'Frequenzspektrum',
            subtitle: 'Peak: ${fft.peakFrequency.toStringAsFixed(1)} Hz  '
                      '(${fft.peakMagnitude.toStringAsFixed(4)} g)',
            child: SizedBox(
              height: 200,
              child: fft.magnitudes.isEmpty
                  ? const Center(child: Text('Zu wenige Samples'))
                  : _FftChart(fft: fft, color: _axis.color),
            ),
          ),
          const SizedBox(height: 10),

          // ── Kennwert-Kacheln ─────────────────────────────────────────────
          Row(children: [
            Expanded(child: _MetricCard(label: 'RMS',          value: '${rmsVal.toStringAsFixed(4)} g')),
            const SizedBox(width: 8),
            Expanded(child: _MetricCard(label: 'VDV',          value: '${vdvVal.toStringAsFixed(4)} g·s¼')),
            const SizedBox(width: 8),
            Expanded(child: _MetricCard(label: 'Crest Factor', value: cfVal.toStringAsFixed(2))),
          ]),
          const SizedBox(height: 10),

          Row(children: [
            Expanded(child: _MetricCard(
              label: 'Samples analysiert',
              value: signal.length.toString(),
            )),
            const SizedBox(width: 8),
            Expanded(child: _MetricCard(
              label: 'Dauer analysiert',
              value: '${(signal.length / odrHz).toStringAsFixed(1)} s',
            )),
            const SizedBox(width: 8),
            Expanded(child: _MetricCard(
              label: 'Gesamt Samples',
              value: samples.length.toString(),
            )),
          ]),
          const SizedBox(height: 10),

          // ── Amplituden-Histogramm ────────────────────────────────────────
          _SectionCard(
            title: 'Amplitudenverteilung',
            subtitle: 'Achse ${_axis.label}',
            child: SizedBox(
              height: 160,
              child: hist.isEmpty
                  ? const Center(child: Text('Keine Daten'))
                  : _HistogramChart(hist: hist, color: _axis.color),
            ),
          ),
          const SizedBox(height: 10),

          // ── IRI über Zeit ─────────────────────────────────────────────────
          if (surfaceSamples.isNotEmpty) ...[
            _IriTimeChart(surfaceSamples: surfaceSamples),
            const SizedBox(height: 10),
          ],

          // ── Erläuterungen ────────────────────────────────────────────────
          _InfoBox(),
        ],
      ),
    );
  }

  List<double> _extractSignal(List<SensorSample> samples, double odrHz) {
    final secs = _window.seconds;
    final src  = secs == null
        ? samples
        : samples.length > (secs * odrHz).ceil()
            ? samples.sublist(samples.length - (secs * odrHz).ceil())
            : samples;

    final raw = src.map((s) => switch (_axis) {
      _Axis.x         => s.ax,
      _Axis.y         => s.ay,
      _Axis.z         => s.az,
      _Axis.magnitude => sqrt(s.ax*s.ax + s.ay*s.ay + s.az*s.az),
    }).toList();

    // DC-Anteil (Schwerkraft) entfernen → nur dynamische Vibration
    if (raw.isEmpty) return raw;
    final mean = raw.reduce((a, b) => a + b) / raw.length;
    return raw.map((v) => v - mean).toList();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Steuerleiste
// ─────────────────────────────────────────────────────────────────────────────

class _ControlRow extends StatelessWidget {
  const _ControlRow({
    required this.axis, required this.window,
    required this.onAxis, required this.onWindow,
    required this.sampleCount,
  });

  final _Axis   axis;
  final _Window window;
  final ValueChanged<_Axis>   onAxis;
  final ValueChanged<_Window> onWindow;
  final int sampleCount;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Text('Achse:', style: TextStyle(fontSize: 12)),
      const SizedBox(width: 6),
      for (final a in _Axis.values) ...[
        GestureDetector(
          onTap: () => onAxis(a),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: axis == a ? a.color : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              a.label,
              style: TextStyle(
                color: axis == a ? Colors.white : Colors.black87,
                fontSize: 12, fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
      const Spacer(),
      DropdownButton<_Window>(
        value: window,
        isDense: true,
        items: _Window.values.map((w) =>
          DropdownMenuItem(value: w, child: Text(w.label, style: const TextStyle(fontSize: 12)))).toList(),
        onChanged: (w) { if (w != null) onWindow(w); },
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zeitbereich-Wellenform
// ─────────────────────────────────────────────────────────────────────────────

class _WaveformChart extends StatelessWidget {
  const _WaveformChart({required this.signal, required this.sampleRateHz, required this.color});
  final List<double> signal;
  final double sampleRateHz;
  final Color  color;

  @override
  Widget build(BuildContext context) {
    // Maximal 2048 Punkte darstellen (Performance)
    const maxPts = 2048;
    final step   = signal.length > maxPts ? (signal.length / maxPts).ceil() : 1;

    final spots = <FlSpot>[
      for (int i = 0; i < signal.length; i += step)
        FlSpot(i / sampleRateHz, signal[i]),
    ];

    final peak = signal.map((v) => v.abs()).reduce(max);
    final yMax = (peak * 1.2).clamp(0.01, double.infinity);

    return LineChart(LineChartData(
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: color,
          barWidth: 1.0,
          dotData: const FlDotData(show: false),
        ),
      ],
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          axisNameWidget: const Text('g', style: TextStyle(fontSize: 10)),
          sideTitles: SideTitles(
            showTitles: true, reservedSize: 44,
            getTitlesWidget: (v, _) =>
                Text(v.toStringAsFixed(3), style: const TextStyle(fontSize: 8)),
          ),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: const Text('s', style: TextStyle(fontSize: 10)),
          sideTitles: SideTitles(
            showTitles: true, reservedSize: 22,
            getTitlesWidget: (v, _) =>
                Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 8)),
          ),
        ),
        topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      minY: -yMax, maxY: yMax,
      gridData: FlGridData(
        horizontalInterval: yMax / 2,
        verticalInterval:   spots.last.x / 4,
      ),
      borderData: FlBorderData(show: true,
          border: Border.all(color: Colors.grey.shade300)),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFT-Liniendiagramm
// ─────────────────────────────────────────────────────────────────────────────

class _FftChart extends StatelessWidget {
  const _FftChart({required this.fft, required this.color});
  final FftResult fft;
  final Color     color;

  @override
  Widget build(BuildContext context) {
    // Nur bis 100 Hz anzeigen (meistens interessant für Straßenoberfläche)
    // Wenn Nyquist < 100 Hz, alles anzeigen
    final maxHz  = min(100.0, fft.frequencies.last);
    final cutIdx = fft.frequencies.indexWhere((f) => f > maxHz);
    final endIdx = cutIdx < 0 ? fft.frequencies.length : cutIdx;

    final spots = <FlSpot>[
      for (int i = 1; i < endIdx; i++)
        FlSpot(fft.frequencies[i], fft.magnitudes[i]),
    ];

    return LineChart(LineChartData(
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: color,
          barWidth: 1.2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: color.withOpacity(0.12),
          ),
        ),
      ],
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          axisNameWidget: const Text('g', style: TextStyle(fontSize: 10)),
          sideTitles: SideTitles(
            showTitles: true, reservedSize: 40,
            getTitlesWidget: (v, _) => Text(v.toStringAsFixed(3), style: const TextStyle(fontSize: 8)),
          ),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: const Text('Hz', style: TextStyle(fontSize: 10)),
          sideTitles: SideTitles(
            showTitles: true, reservedSize: 22,
            getTitlesWidget: (v, _) => Text('${v.toInt()}', style: const TextStyle(fontSize: 8)),
          ),
        ),
        topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        horizontalInterval: fft.peakMagnitude > 0 ? fft.peakMagnitude / 4 : 0.01,
      ),
      borderData: FlBorderData(show: true,
        border: Border.all(color: Colors.grey.shade300)),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Amplituden-Histogramm
// ─────────────────────────────────────────────────────────────────────────────

class _HistogramChart extends StatelessWidget {
  const _HistogramChart({required this.hist, required this.color});
  final Map<double, int> hist;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final entries = hist.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final maxCount = entries.fold(0, (m, e) => max(m, e.value));

    return BarChart(BarChartData(
      barGroups: entries.asMap().entries.map((e) {
        return BarChartGroupData(x: e.key, barRods: [
          BarChartRodData(
            toY: e.value.value.toDouble(),
            color: color.withOpacity(0.7),
            width: 8,
          ),
        ]);
      }).toList(),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true, reservedSize: 35,
            getTitlesWidget: (v, _) => Text(v.toInt().toString(), style: const TextStyle(fontSize: 8)),
          ),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: const Text('g', style: TextStyle(fontSize: 10)),
          sideTitles: SideTitles(
            showTitles: true, reservedSize: 22,
            interval: max(1, (entries.length / 6).roundToDouble()),
            getTitlesWidget: (v, _) {
              final idx = v.toInt();
              if (idx < 0 || idx >= entries.length) return const SizedBox.shrink();
              return Text(entries[idx].key.toStringAsFixed(2), style: const TextStyle(fontSize: 7));
            },
          ),
        ),
        topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      maxY: maxCount * 1.15,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: true, border: Border.all(color: Colors.grey.shade300)),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IRI-Zeitverlauf (aus 1-Hz-Surface-Samples)
// ─────────────────────────────────────────────────────────────────────────────

class _IriTimeChart extends StatelessWidget {
  const _IriTimeChart({required this.surfaceSamples});
  final List<SurfaceSample> surfaceSamples;

  @override
  Widget build(BuildContext context) {
    // Nur Samples mit gültigem IRI
    final withIri = surfaceSamples.where((s) => s.iriMKm != null).toList();
    if (withIri.isEmpty) {
      return const _SectionCard(
        title: 'IRI – Fahrbahnrauheit',
        subtitle: 'International Roughness Index [m/km] · GPS erforderlich',
        child: SizedBox(
          height: 80,
          child: Center(
            child: Text(
              'GPS-Geschwindigkeit wird für IRI-Berechnung benötigt.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final t0      = withIri.first.timestampMs;
    final spots   = <FlSpot>[
      for (final s in withIri)
        FlSpot((s.timestampMs - t0) / 1000.0, s.iriMKm!),
    ];

    final iriValues = withIri.map((s) => s.iriMKm!).toList();
    final avgIri    = iriValues.reduce((a, b) => a + b) / iriValues.length;
    final maxIri    = iriValues.reduce(max);
    final yMax      = (maxIri * 1.2).clamp(2.0, 20.0);

    String quality;
    Color  qualColor;
    if (avgIri < 2)      { quality = 'Sehr glatt'; qualColor = Colors.green; }
    else if (avgIri < 5) { quality = 'Gut';         qualColor = Colors.lightGreen; }
    else if (avgIri < 8) { quality = 'Mäßig';       qualColor = Colors.orange; }
    else                 { quality = 'Rau';          qualColor = Colors.red; }

    return _SectionCard(
      title: 'IRI – Fahrbahnrauheit',
      subtitle: 'Ø ${avgIri.toStringAsFixed(2)} m/km  ·  Max ${maxIri.toStringAsFixed(2)} m/km'
                '  ·  Qualität: $quality',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Qualitätsbewertung
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: qualColor, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(quality,
                style: TextStyle(color: qualColor, fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(width: 12),
            Text('${withIri.length} Messpunkte  ·  ${(withIri.length).toStringAsFixed(0)} s',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
          const SizedBox(height: 8),
          // IRI-Zeitverlauf
          SizedBox(
            height: 160,
            child: LineChart(LineChartData(
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  curveSmoothness: 0.2,
                  color: Colors.teal,
                  barWidth: 1.8,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.teal.withOpacity(0.25), Colors.teal.withOpacity(0.0)],
                    ),
                  ),
                ),
                // Referenzlinie: gute Qualitätsgrenze (IRI = 2)
                LineChartBarData(
                  spots: [FlSpot(spots.first.x, 2.0), FlSpot(spots.last.x, 2.0)],
                  color: Colors.green.withOpacity(0.5),
                  barWidth: 1.0,
                  dotData: const FlDotData(show: false),
                  dashArray: [6, 4],
                ),
              ],
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  axisNameWidget: const Text('m/km', style: TextStyle(fontSize: 10)),
                  sideTitles: SideTitles(
                    showTitles: true, reservedSize: 40,
                    getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 8)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  axisNameWidget: const Text('Zeit (s)', style: TextStyle(fontSize: 10)),
                  sideTitles: SideTitles(
                    showTitles: true, reservedSize: 22,
                    getTitlesWidget: (v, _) => Text(v.toInt().toString(), style: const TextStyle(fontSize: 8)),
                  ),
                ),
                topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              minY: 0, maxY: yMax,
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(show: true, border: Border.all(color: Colors.grey.shade300)),
            )),
          ),
          const SizedBox(height: 4),
          // IRI-Skala-Legende
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _IriLegendDot(color: Colors.green,     label: '< 2 sehr glatt'),
            _IriLegendDot(color: Colors.lightGreen, label: '< 5 gut'),
            _IriLegendDot(color: Colors.orange,    label: '< 8 mäßig'),
            _IriLegendDot(color: Colors.red,       label: '≥ 8 rau'),
          ]),
        ],
      ),
    );
  }
}

class _IriLegendDot extends StatelessWidget {
  const _IriLegendDot({required this.color, required this.label});
  final Color  color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      width: 8, height: 8, margin: const EdgeInsets.only(left: 10, right: 3),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
    Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Hilfswidgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.subtitle, required this.child});
  final String title, subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: const Text(
        'RMS – mittlere Beschleunigungsintensität (ISO 2631)\n'
        'VDV – Vibrationsdosisfaktor (berücksichtigt Spitzen)\n'
        'Crest Factor – Verhältnis Peak / RMS (Stoßcharakter)\n'
        'Spektrum – Energieverteilung über Frequenzen [Hz]\n'
        'IRI – International Roughness Index [m/km] (Fahrbahnqualität);\n'
        '  berechnet aus RMS + GPS-Geschwindigkeit, Kalibrierung auf ~20 km/h;\n'
        '  < 2 sehr glatt · 2–5 gut · 5–8 mäßig · ≥ 8 rau',
        style: TextStyle(fontSize: 11, height: 1.5),
      ),
    );
  }
}

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../providers/recording_provider.dart';
import '../models/sensor_sample.dart';
import '../services/foreground_service.dart';

// Full-Scale-Labels für UI
const _fsLabels = ['±2g', '±4g', '±8g', '±16g'];
const _fsHints  = [
  'Präzise, glatte Fahrbahn',
  'Asphalt, Schotter',
  'Kopfsteinpflaster, MTB',
  'Extremgelände, Sprünge',
];

class SensorScreen extends StatefulWidget {
  const SensorScreen({super.key});

  @override
  State<SensorScreen> createState() => _SensorScreenState();
}

class _SensorScreenState extends State<SensorScreen> {
  static const _freqOptions = [52, 104, 208, 416, 833, 1666];

  @override
  void initState() {
    super.initState();
    // Foreground-Service und Benachrichtigungsberechtigung initialisieren
    ForegroundService.init();
    ForegroundService.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<RecordingProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Surface Sensor', style: TextStyle(color: Colors.white)),
        actions: [
          if (prov.isTestMode)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: prov.isRecording ? null : prov.disableTestMode,
                child: Chip(
                  label: Text(
                    prov.phoneSampleRate > 0
                        ? 'TEST  ${prov.phoneSampleRate} Hz'
                        : 'TEST-MODUS',
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                  ),
                  backgroundColor: Colors.amberAccent.withOpacity(0.15),
                  side: const BorderSide(color: Colors.amberAccent, width: 1),
                  padding: EdgeInsets.zero,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _ConnectionChip(prov: prov),
            ),
        ],
      ),
      body: (prov.isConnected || prov.isTestMode)
          ? _buildConnectedBody(prov)
          : _buildDisconnectedBody(prov),
    );
  }

  // ── Disconnected ──────────────────────────────────────────────────────────────
  Widget _buildDisconnectedBody(RecordingProvider prov) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bluetooth_disabled, size: 72, color: Colors.grey),
          const SizedBox(height: 24),
          const Text('Nicht verbunden', style: TextStyle(color: Colors.white70, fontSize: 18)),
          const SizedBox(height: 8),
          if (prov.lastError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
              child: Text(prov.lastError!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: prov.isScanning ? null : prov.connect,
            icon: prov.isScanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bluetooth_searching),
            label: Text(prov.isScanning ? 'Suche…' : 'Gerät suchen'),
          ),
          const SizedBox(height: 12),
          // ── Test-Modus: Handy-IMU als Sensor ──────────────────────────────
          OutlinedButton.icon(
            onPressed: () {
              prov.enableTestMode();
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.amberAccent,
              side: const BorderSide(color: Colors.amberAccent, width: 1),
            ),
            icon: const Icon(Icons.science_outlined, size: 18),
            label: const Text('Test-Modus (Handy-IMU)'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Testet die App ohne externen Sensor',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ── Connected ─────────────────────────────────────────────────────────────────
  Widget _buildConnectedBody(RecordingProvider prov) {
    return Column(
      children: [
        // ── Live-Chart ─────────────────────────────────────────────────────────
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: _LiveChart(prov: prov),
          ),
        ),

        // ── Clipping-Warnung ───────────────────────────────────────────────────
        if (prov.lastSurface != null &&
            prov.lastSurface!.peakG > kFsG[prov.fsIndex] * 0.85)
          _ClippingWarningBanner(prov: prov),

        // ── 1-Hz Oberflächenkennwerte (live vom Device) ────────────────────────
        if (prov.isRecording || prov.lastSurface != null)
          _SurfaceLiveRow(prov: prov),

        // ── Stats ──────────────────────────────────────────────────────────────
        _StatsRow(prov: prov),

        const Divider(color: Color(0xFF30363D), height: 1),

        // ── Steuerung ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Montagepunkt
              Row(
                children: [
                  const Text('Montage', style: TextStyle(color: Colors.white70)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF21262D),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF30363D)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: kMountPoints.contains(prov.mountPoint)
                              ? prov.mountPoint
                              : kMountPoints[0],
                          dropdownColor: const Color(0xFF21262D),
                          isExpanded: true,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          style: const TextStyle(color: Colors.white),
                          onChanged: prov.isRecording
                              ? null
                              : (v) => prov.setMountPoint(v!),
                          items: kMountPoints
                              .map((mp) => DropdownMenuItem(
                                    value: mp,
                                    child: Text(mp,
                                      style: TextStyle(
                                        color: prov.isRecording
                                            ? Colors.white38
                                            : Colors.white,
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Montagepunkt wird in CSV und FIT gespeichert',
                    child: const Icon(Icons.info_outline, color: Colors.white38, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Frequenzwahl
              Row(
                children: [
                  const Text('Frequenz', style: TextStyle(color: Colors.white70)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF21262D),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF30363D)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _freqOptions.contains(prov.frequencyHz)
                              ? prov.frequencyHz
                              : _freqOptions[1],
                          dropdownColor: const Color(0xFF21262D),
                          isExpanded: true,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          style: const TextStyle(color: Colors.white),
                          onChanged: prov.isRecording
                              ? null
                              : (v) => prov.setFrequency(v!),
                          items: _freqOptions
                              .map((f) => DropdownMenuItem(
                                    value: f,
                                    child: Text(
                                      '$f Hz',
                                      style: TextStyle(
                                        color: prov.isRecording
                                            ? Colors.white38
                                            : Colors.white,
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Hinweis-Chip: Datenrate
                  _OdrInfoChip(hz: prov.frequencyHz),
                ],
              ),
              const SizedBox(height: 12),
              // Full-Scale-Wahl
              Row(
                children: [
                  const Text('Max. Beschl.', style: TextStyle(color: Colors.white70)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF21262D),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF30363D)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: prov.fsIndex,
                          dropdownColor: const Color(0xFF21262D),
                          isExpanded: true,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          style: const TextStyle(color: Colors.white),
                          onChanged: prov.isRecording
                              ? null
                              : (v) => prov.setFullScale(v!),
                          items: List.generate(
                            _fsLabels.length,
                            (i) => DropdownMenuItem(
                              value: i,
                              child: Tooltip(
                                message: _fsHints[i],
                                child: Text(
                                  _fsLabels[i],
                                  style: TextStyle(
                                    color: prov.isRecording ? Colors.white38 : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Auflösungs-Chip
                  _ResolutionChip(fsIndex: prov.fsIndex),
                ],
              ),
              const SizedBox(height: 12),
              // Kalibrierung (nur im BLE-Modus)
              if (!prov.isTestMode) ...[
                _CalibrationRow(prov: prov),
                const SizedBox(height: 8),
                _OrientCalibrationRow(prov: prov),
                const SizedBox(height: 8),
                // Temperaturanzeige (nur wenn Firmware v6 → tempChar vorhanden)
                if (!prov.imuTemperatureC.isNaN)
                  _TempRow(tempC: prov.imuTemperatureC),
                if (!prov.imuTemperatureC.isNaN)
                  const SizedBox(height: 8),
              ],
              // Garmin-Relay (BLE- und Test-Modus)
              _RelayRow(prov: prov),
              const SizedBox(height: 8),
              // Start / Stop
              Row(
                children: [
                  Expanded(
                    child: prov.isRecording
                        ? FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                            onPressed: prov.stopRecording,
                            icon: const Icon(Icons.stop),
                            label: const Text('Aufnahme stoppen'),
                          )
                        : FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.green),
                            onPressed: prov.startRecording,
                            icon: const Icon(Icons.fiber_manual_record),
                            label: const Text('Aufnahme starten'),
                          ),
                  ),
                  if (!prov.isRecording && prov.sampleCount > 0) ...[
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: 'CSV exportieren',
                      onPressed: () => _onExport(context, prov),
                      icon: const Icon(Icons.share, color: Colors.white70),
                    ),
                  ],
                ],
              ),
              // Gespeichert-Hinweis
              if (prov.lastSavedPath != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Gespeichert: ${prov.lastSavedPath!.split('/').last}',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _onExport(BuildContext context, RecordingProvider prov) async {
    final path = await prov.exportCsv();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(path != null ? 'Exportiert: ${path.split('/').last}' : 'Keine Daten vorhanden'),
        backgroundColor: path != null ? Colors.green : Colors.red,
      ),
    );
  }
}

// ── Live-Chart ────────────────────────────────────────────────────────────────
class _LiveChart extends StatelessWidget {
  final RecordingProvider prov;
  const _LiveChart({required this.prov});

  @override
  Widget build(BuildContext context) {
    final samples = prov.recentSamples(n: 200);

    if (samples.isEmpty) {
      return const Center(
        child: Text('Warte auf Daten…', style: TextStyle(color: Colors.white38)),
      );
    }

    List<FlSpot> axSpots = [];
    List<FlSpot> aySpots = [];
    List<FlSpot> azSpots = [];

    final t0 = samples.first.timestampMs;
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i];
      final t = (s.timestampMs - t0) / 1000.0;
      axSpots.add(FlSpot(t, s.ax));
      aySpots.add(FlSpot(t, s.ay));
      azSpots.add(FlSpot(t, s.az));
    }

    return LineChart(
      LineChartData(
        backgroundColor: const Color(0xFF0D1117),
        gridData: FlGridData(
          drawHorizontalLine: true,
          drawVerticalLine: true,
          horizontalInterval: 1,
          getDrawingHorizontalLine: (_) => FlLine(color: const Color(0xFF21262D), strokeWidth: 1),
          getDrawingVerticalLine:   (_) => FlLine(color: const Color(0xFF21262D), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            axisNameWidget: const Text('Zeit (s)', style: TextStyle(color: Colors.white38, fontSize: 11)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: const Text('g', style: TextStyle(color: Colors.white38, fontSize: 11)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ),
          ),
          topTitles:   AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          _line(axSpots, Colors.redAccent,   'X'),
          _line(aySpots, Colors.greenAccent, 'Y'),
          _line(azSpots, Colors.blueAccent,  'Z'),
        ],
        lineTouchData: const LineTouchData(enabled: false),
      ),
      duration: Duration.zero,
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color, String label) => LineChartBarData(
    spots: spots,
    color: color,
    barWidth: 1.5,
    dotData: const FlDotData(show: false),
    isCurved: false,
  );
}

// ── Stats-Zeile ───────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final RecordingProvider prov;
  const _StatsRow({required this.prov});

  @override
  Widget build(BuildContext context) {
    final samples = prov.recentSamples(n: 50);
    double ax = 0, ay = 0, az = 0;
    if (samples.isNotEmpty) {
      ax = samples.last.ax;
      ay = samples.last.ay;
      az = samples.last.az;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Stat('X', ax, Colors.redAccent),
          _Stat('Y', ay, Colors.greenAccent),
          _Stat('Z', az, Colors.blueAccent),
          _Stat('|a|', sqrt(ax * ax + ay * ay + az * az), Colors.white70),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${prov.sampleCount}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const Text('Samples', style: TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  const _Stat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(value.toStringAsFixed(3), style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
    ],
  );
}

// ── Kalibrierungs-Zeile ───────────────────────────────────────────────────────
class _CalibrationRow extends StatelessWidget {
  final RecordingProvider prov;
  const _CalibrationRow({required this.prov});

  @override
  Widget build(BuildContext context) {
    final cal   = prov.lastCalibration;
    final ready = prov.isConnected && !prov.isRecording && !prov.isCalibrating;

    String statusText;
    Color  statusColor;
    if (prov.isCalibrating) {
      statusText  = 'Kalibrierung läuft…';
      statusColor = Colors.orange;
    } else if (cal == null) {
      statusText  = 'Nicht kalibriert';
      statusColor = Colors.white38;
    } else if (cal.status == CalStatus.error) {
      statusText  = 'Kalibrierung fehlgeschlagen';
      statusColor = Colors.redAccent;
    } else {
      final fsG = kFsG[prov.fsIndex];
      final ax  = cal.offsetMg(cal.axOffsetRaw, fsG).toStringAsFixed(1);
      final ay  = cal.offsetMg(cal.ayOffsetRaw, fsG).toStringAsFixed(1);
      final az  = cal.offsetMg(cal.azOffsetRaw, fsG).toStringAsFixed(1);
      statusText  = 'Kalibriert  X:${ax}mg  Y:${ay}mg  Z:${az}mg';
      statusColor = Colors.greenAccent;
    }

    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: ready ? prov.calibrate : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white70,
            side: const BorderSide(color: Color(0xFF30363D)),
          ),
          icon: prov.isCalibrating
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
              : const Icon(Icons.tune, size: 16),
          label: const Text('Kalibrieren', style: TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            statusText,
            style: TextStyle(color: statusColor, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ── Orientierungskalibrierung ─────────────────────────────────────────────────
/// Schritt 2 der Kalibrierung: Fahrrad aufrecht auf ebenem Boden → Schwerkraft-
/// vektor messen. Zusätzlich wählt der Nutzer, welche physisch markierte Achse
/// des Sensors in Fahrtrichtung zeigt → vollständiges Bike-Koordinatensystem.
///
/// Nach erfolgreicher Kalibrierung + Achsenwahl:
///   • Firmware: RMS/VDV aus reinem Vertikalanteil (1g-kompensiert)
///   • App: verticalG / forwardG / lateralG für FFT-Analyse verfügbar
///   • RMS ≈ 0 mg auf glatter Straße, korrekt für jeden Montagewinkel
class _OrientCalibrationRow extends StatelessWidget {
  final RecordingProvider prov;
  const _OrientCalibrationRow({required this.prov});

  @override
  Widget build(BuildContext context) {
    final oc    = prov.lastOrientCal;
    final ready = prov.isConnected
        && !prov.isRecording
        && !prov.isOrientCalibrating
        && !prov.isCalibrating
        && prov.supportsOrientationCal;

    String statusText;
    Color  statusColor;

    if (!prov.supportsOrientationCal) {
      statusText  = 'Firmware ≥ v5.2 erforderlich';
      statusColor = Colors.white24;
    } else if (prov.isOrientCalibrating) {
      statusText  = 'Fahrrad still halten … (2 s)';
      statusColor = Colors.orange;
    } else if (oc == null) {
      statusText  = 'Nicht kalibriert  →  Schritt 2 empfohlen';
      statusColor = Colors.white38;
    } else {
      switch (oc.status) {
        case OrientCalStatus.done:
          final tilt = oc.tiltDeg.toStringAsFixed(1);
          final gStr = oc.gMagG.toStringAsFixed(3);
          statusText  = 'OK  Neigung ${tilt}°  |g| ${gStr} g';
          statusColor = Colors.greenAccent;
        case OrientCalStatus.errorOffsetMissing:
          statusText  = 'Zuerst Schritt 1 (Sensor-Kal.) durchführen';
          statusColor = Colors.orange;
        case OrientCalStatus.error:
          statusText  = 'Fehlgeschlagen – Sensor bewegt?';
          statusColor = Colors.redAccent;
        default:
          statusText  = 'Unbekannt';
          statusColor = Colors.white38;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Zeile: Button + Status ───────────────────────────────────────────
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: ready ? () => _showOrientCalDialog(context, prov) : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: BorderSide(
                  color: prov.hasOrientCal
                      ? Colors.greenAccent.withOpacity(0.6)
                      : const Color(0xFF30363D),
                ),
              ),
              icon: prov.isOrientCalibrating
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
                  : Icon(
                      prov.hasOrientCal ? Icons.explore : Icons.explore_outlined,
                      size: 16,
                      color: prov.hasOrientCal ? Colors.greenAccent : null,
                    ),
              label: const Text('Orientierung', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(statusText,
                  style: TextStyle(color: statusColor, fontSize: 11),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        // ── Fahrtrichtungs-Achsenauswahl ─────────────────────────────────────
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('Vorwärts-Achse',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(width: 8),
            // Während Brems-Kal.: Countdown + Anweisung statt Picker
            if (prov.isBrakeCalibrating)
              Expanded(
                child: Row(children: [
                  const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.orange),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Jetzt bremsen!  ${prov.brakeCalSecondsLeft} s',
                    style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ]),
              )
            else
              Expanded(child: _ForwardAxisPicker(prov: prov)),
            const SizedBox(width: 4),
            _BrakeCalButton(prov: prov),
            if (prov.bikeFrame != null && !prov.isBrakeCalibrating) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: prov.bikeFrame!.axisLabel,
                child: const Icon(Icons.check_circle_outline,
                    color: Colors.greenAccent, size: 16),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _showOrientCalDialog(BuildContext context, RecordingProvider prov) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.explore, color: Colors.cyanAccent, size: 22),
            SizedBox(width: 8),
            Text('Orientierungskalibrierung',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Voraussetzungen:',
                style: TextStyle(color: Colors.white70,
                    fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 8),
            _BulletText('Sensor-Kalibrierung (Schritt 1) abgeschlossen'),
            _BulletText('Fahrrad aufrecht auf ebenem Boden'),
            _BulletText('Sensor und Fahrrad während der Messung ruhig halten (~2 s)'),
            SizedBox(height: 12),
            Text('Was wird gemessen?',
                style: TextStyle(color: Colors.white70,
                    fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 6),
            Text(
              'Der Schwerkraftvektor im Sensorrahmen wird ermittelt. '
              'Danach berechnet der Sensor die wahre Vertikalbeschleunigung '
              'unabhängig vom Montagewinkel.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.cyanAccent.withOpacity(0.8)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Jetzt messen', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await prov.calibrateOrientation();
    }
  }
}

// ── Brems-Kalibrierungs-Button ────────────────────────────────────────────────
/// Kleiner Button neben dem Achsen-Picker. Startet die automatische Fahrtrichtungs-
/// erkennung per Bremsmanöver. Nur sichtbar wenn Orientierungskalibrierung aktiv ist.
///
/// Ablauf:
///   1. Fahrrad anfahren (Sensor muss kalibriert sein)
///   2. Innerhalb von 5 s kräftig bremsen
///   3. Algorithmus findet Peak-Verzögerung → snap auf nächste Achse → setzt forwardAxis
class _BrakeCalButton extends StatelessWidget {
  final RecordingProvider prov;
  const _BrakeCalButton({required this.prov});

  @override
  Widget build(BuildContext context) {
    // Nur anzeigen wenn Orientierungskalibrierung abgeschlossen ist
    if (!prov.hasOrientCal) return const SizedBox.shrink();

    if (prov.isBrakeCalibrating) {
      // Abbrechen-Button während Messung
      return GestureDetector(
        onTap: prov.cancelBrakeCalibration,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.orange.withOpacity(0.5)),
          ),
          child: const Icon(Icons.close, color: Colors.orange, size: 14),
        ),
      );
    }

    return Tooltip(
      message: 'Fahrtrichtung per Bremsmanöver erkennen:\n'
               'Fahren Sie los und bremsen Sie kräftig (5 s)',
      child: GestureDetector(
        onTap: prov.isRecording
            ? null
            : () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Fahrrad in Bewegung bringen und kräftig bremsen!',
                      style: TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Color(0xFF1F2937),
                    duration: Duration(seconds: 5),
                  ),
                );
                prov.startBrakeCalibration();
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF21262D),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: Icon(
            Icons.directions_bike_outlined,
            color: prov.isRecording ? Colors.white24 : Colors.white54,
            size: 14,
          ),
        ),
      ),
    );
  }
}

// ── Fahrtrichtungs-Achsen-Picker ──────────────────────────────────────────────
/// Kompakter Button-Wähler für ±X / ±Y / ±Z.
/// Manuell: Achse physisch markieren und in Fahrtrichtung ausrichten.
/// Automatisch: per _BrakeCalButton erkannt (dann ggf. ±Z möglich).
class _ForwardAxisPicker extends StatelessWidget {
  final RecordingProvider prov;
  const _ForwardAxisPicker({required this.prov});

  @override
  Widget build(BuildContext context) {
    final selected = prov.forwardAxis;
    final enabled  = !prov.isRecording;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: ForwardAxis.values.map((axis) {
        final isSelected = axis == selected;
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: GestureDetector(
            onTap: enabled ? () => prov.setForwardAxis(axis) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.cyanAccent.withOpacity(0.2)
                    : const Color(0xFF21262D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isSelected
                      ? Colors.cyanAccent.withOpacity(0.7)
                      : const Color(0xFF30363D),
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Tooltip(
                message: axis.description,
                child: Text(
                  axis.label,
                  style: TextStyle(
                    color: isSelected
                        ? Colors.cyanAccent
                        : (enabled ? Colors.white54 : Colors.white24),
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Hilfsmittel: Aufzählungspunkt für AlertDialog
class _BulletText extends StatelessWidget {
  final String text;
  const _BulletText(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• ', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
        Expanded(child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 12))),
      ],
    ),
  );
}

// ── 1-Hz Oberflächenkennwerte (live vom Device) ───────────────────────────────
/// Zeigt die vom Sensor berechneten Rauheitskennwerte (RMS, VDV, Peak) in
// ── Garmin-Relay-Zeile ────────────────────────────────────────────────────────
/// Schaltet den BLE-Peripheral-Relay-Modus ein:
/// Das Phone advertist als "SurfaceSensor" und leitet 1-Hz-Daten an den Garmin weiter.
class _RelayRow extends StatelessWidget {
  final RecordingProvider prov;
  const _RelayRow({required this.prov});

  @override
  Widget build(BuildContext context) {
    final state = prov.relayState;
    final on    = prov.relayMode;

    Color statusColor;
    String statusText;
    final count = prov.relayPublishCount;
    switch (state) {
      case RelayState.garminConnected:
        statusColor = Colors.greenAccent;
        statusText  = 'Garmin verbunden · $count Pakete gesendet';
      case RelayState.advertising:
        statusColor = Colors.amberAccent;
        statusText  = 'Warte auf Garmin…';
      case RelayState.error:
        statusColor = Colors.redAccent;
        statusText  = prov.relayLastError ?? 'Relay-Fehler';
      case RelayState.off:
        statusColor = Colors.grey;
        statusText  = count > 0 ? 'Inaktiv · $count Pakete gesendet' : 'Inaktiv';
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: on ? Colors.blueAccent.withOpacity(0.5) : const Color(0xFF30363D),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.router_outlined,
              color: on ? Colors.blueAccent : Colors.grey, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Garmin-Relay',
                    style: TextStyle(color: Colors.white, fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(statusText,
                        style: TextStyle(color: statusColor, fontSize: 11)),
                  ],
                ),
                if (!on)
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text(
                      'Phone leitet 1-Hz-Daten per BLE an Garmin Edge weiter.\n'
                      'Sensor bleibt exklusiv mit Phone verbunden.',
                      style: TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: on,
            onChanged: (v) => prov.setRelayMode(v),
            activeColor: Colors.blueAccent,
          ),
        ],
      ),
    );
  }
}

// ── Temperaturanzeige ─────────────────────────────────────────────────────────
/// Zeigt die IMU-Gehäusetemperatur (LSM6DS3, alle 5 s) und den Auto-Zero-Status.
/// Nur sichtbar wenn Firmware v6 verbunden ist (tempChar vorhanden).
class _TempRow extends StatelessWidget {
  final double tempC;
  const _TempRow({required this.tempC});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.thermostat_outlined, color: Colors.white38, size: 16),
        const SizedBox(width: 6),
        Text(
          'IMU ${tempC.toStringAsFixed(1)} °C',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: 'Temperatur-Drift-Kompensation (Auto-Zero) aktiv:\n'
                   'Firmware erkennt Stillstands-Phasen und korrigiert\n'
                   'den Offset-Drift des LSM6DS3 automatisch.',
          child: const Icon(Icons.auto_fix_high, color: Colors.tealAccent, size: 14),
        ),
        const SizedBox(width: 4),
        const Text(
          'Auto-Zero aktiv',
          style: TextStyle(color: Colors.tealAccent, fontSize: 11),
        ),
      ],
    );
  }
}

/// Echtzeit an. Der Sensor sendet diese Werte 1×/s während der Aufnahme.
class _SurfaceLiveRow extends StatelessWidget {
  final RecordingProvider prov;
  const _SurfaceLiveRow({required this.prov});

  Color _rmsColor(double rms) {
    if (rms < 0.05) return Colors.greenAccent;
    if (rms < 0.15) return Colors.yellowAccent;
    if (rms < 0.30) return const Color(0xFFFF9800); // orange
    return Colors.redAccent;
  }

  /// IRI-Farbskala: grün (< 2) → gelb (< 5) → orange (< 8) → rot (≥ 8)
  Color _iriColor(double? iri) {
    if (iri == null || !iri.isFinite) return Colors.white38;
    if (iri < 2.0) return Colors.greenAccent;
    if (iri < 5.0) return Colors.yellowAccent;
    if (iri < 8.0) return const Color(0xFFFF9800);
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final s = prov.lastSurface;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: s == null
          ? const Row(
              children: [
                SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38)),
                SizedBox(width: 10),
                Text('Warte auf Oberflächendaten …', style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Wenn Orientierungskalibrierung aktiv: "RMS⊥" = senkrechte Komponente
                _SurfStat(
                  prov.hasOrientCal ? 'RMS⊥' : 'RMS',
                  '${(s.rmsG * 1000).toStringAsFixed(1)} mg',
                  _rmsColor(s.rmsG),
                ),
                _SurfStat('VDV',  '${s.vdvG.toStringAsFixed(3)} g·s¼', Colors.cyanAccent),
                _SurfStat('CF',   s.crestFactor.toStringAsFixed(1),     Colors.purpleAccent),
                _SurfStat(
                  'IRI',
                  s.iriMKm != null
                      ? '${s.iriMKm!.toStringAsFixed(2)} m/km'
                      : '—',
                  _iriColor(s.iriMKm),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${prov.surfaceSamples.length}', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                    const Text('Punkte/1Hz', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
              ],
            ),
    );
  }
}

class _SurfStat extends StatelessWidget {
  final String label, value;
  final Color color;
  const _SurfStat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ],
  );
}

// ── Auflösungs-Chip ───────────────────────────────────────────────────────────
class _ResolutionChip extends StatelessWidget {
  final int fsIndex;
  const _ResolutionChip({required this.fsIndex});

  @override
  Widget build(BuildContext context) {
    // Auflösung: FS_g / 32768 in mg
    final resolutionMg = (kFsG[fsIndex] * 1000.0 / 32768.0);
    final label = resolutionMg < 1
        ? '${(resolutionMg * 1000).toStringAsFixed(0)} µg/bit'
        : '${resolutionMg.toStringAsFixed(1)} mg/bit';
    return Tooltip(
      message: 'Auflösung pro Bit',
      child: Chip(
        label: Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
        backgroundColor: const Color(0xFF21262D),
        side: const BorderSide(color: Color(0xFF30363D)),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── ODR-Info-Chip ─────────────────────────────────────────────────────────────
class _OdrInfoChip extends StatelessWidget {
  final int hz;
  const _OdrInfoChip({required this.hz});

  @override
  Widget build(BuildContext context) {
    // Datenrate: BATCH_SIZE Samples → ca. XX ms Latenz pro Paket
    final batchMs = (20 * 1000.0 / hz).toStringAsFixed(0);
    return Tooltip(
      message: 'Paket alle ~$batchMs ms (20 Samples/Batch)',
      child: Chip(
        label: Text('~${(hz / 1000.0).toStringAsFixed(1)} kS/s',
            style: const TextStyle(color: Colors.white60, fontSize: 11)),
        backgroundColor: const Color(0xFF21262D),
        side: const BorderSide(color: Color(0xFF30363D)),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── Clipping-Warnung ──────────────────────────────────────────────────────────
/// Zeigt eine Warnung wenn Peak-Beschleunigung > 85 % des Full-Scale-Bereichs.
/// Deutet auf Sensor-Clipping hin → FS-Bereich erhöhen oder Sensor sicherer montieren.
class _ClippingWarningBanner extends StatelessWidget {
  final RecordingProvider prov;
  const _ClippingWarningBanner({required this.prov});

  @override
  Widget build(BuildContext context) {
    final peak  = prov.lastSurface!.peakG;
    final fsMax = kFsG[prov.fsIndex].toDouble();
    final pct   = (peak / fsMax * 100).toStringAsFixed(0);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Clipping-Risiko: Peak ${peak.toStringAsFixed(3)} g = $pct % von ±${kFsG[prov.fsIndex]}g.'
              ' Nächst größeren FS-Bereich wählen.',
              style: const TextStyle(color: Colors.orange, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Verbindungs-Chip ──────────────────────────────────────────────────────────
class _ConnectionChip extends StatelessWidget {
  final RecordingProvider prov;
  const _ConnectionChip({required this.prov});

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color  color;
    if (prov.bleState == BleState.connected) {
      label = 'Verbunden';  color = Colors.greenAccent;
    } else if (prov.bleState == BleState.connecting) {
      label = 'Verbinde…';  color = Colors.orange;
    } else if (prov.bleState == BleState.scanning) {
      label = 'Suche…';     color = Colors.orange;
    } else {
      label = 'Getrennt';   color = Colors.redAccent;
    }
    return GestureDetector(
      onTap: prov.isConnected ? prov.disconnect : prov.connect,
      child: Chip(
        label: Text(label, style: TextStyle(color: color, fontSize: 12)),
        backgroundColor: color.withOpacity(0.15),
        side: BorderSide(color: color.withOpacity(0.4)),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

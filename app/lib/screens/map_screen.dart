import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/gps_sample.dart';
import '../models/sensor_sample.dart';
import '../providers/recording_provider.dart';
import '../utils/signal_analysis.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prov       = context.watch<RecordingProvider>();
    final gpsSamples = prov.gpsSamples;
    final imuSamples = prov.samples;

    if (gpsSamples.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.location_off_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              'Keine GPS-Daten vorhanden.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'GPS wird automatisch während der Aufnahme aufgezeichnet, '
              'sofern der Standortzugriff erlaubt ist.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
            ),
          ]),
        ),
      );
    }

    final segments   = _buildColoredSegments(gpsSamples, imuSamples);
    final bounds     = _computeBounds(gpsSamples);
    final stats      = _computeStats(segments, imuSamples);

    // Gültige GPS-Punkte für Marker (kein 0.0/NaN)
    final validGps = gpsSamples.where((p) =>
        p.latitude.isFinite  && p.latitude  != 0.0 &&
        p.longitude.isFinite && p.longitude != 0.0).toList();

    return Column(children: [
      // ── Karte ─────────────────────────────────────────────────────────────
      Expanded(
        child: FlutterMap(
          options: MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.all(40),
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.surface_sensor',
              maxZoom: 19,
            ),
            // Farbige Segmente
            PolylineLayer(
              polylines: segments.map((seg) => Polyline(
                points: seg.points,
                color: seg.color,
                strokeWidth: 5.0,
                borderColor: Colors.white.withOpacity(0.4),
                borderStrokeWidth: 1.0,
              )).toList(),
            ),
            // Start-/Endmarkierung (nur wenn gültige Punkte vorhanden)
            if (validGps.isNotEmpty)
              MarkerLayer(markers: [
                _buildMarker(validGps.first, Icons.play_circle, Colors.green),
                _buildMarker(validGps.last,  Icons.stop_circle,  Colors.red),
              ]),
          ],
        ),
      ),

      // ── Statistiken + Legende ──────────────────────────────────────────────
      Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(children: [
          // Stats-Zeile
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _StatChip(label: 'GPS-Punkte',  value: gpsSamples.length.toString()),
            _StatChip(label: 'Ø Vibration', value: '${stats.avgRms.toStringAsFixed(3)} g'),
            _StatChip(label: 'Max Vibr.',   value: '${stats.maxRms.toStringAsFixed(3)} g'),
            _StatChip(label: 'Strecke',     value: '${stats.distanceKm.toStringAsFixed(2)} km'),
          ]),
          const SizedBox(height: 6),
          // Legende
          const _Legend(),
        ]),
      ),
    ]);
  }

  // ── Hilfsmethoden ────────────────────────────────────────────────────────────

  Marker _buildMarker(GpsSample gps, IconData icon, Color color) {
    return Marker(
      point: LatLng(gps.latitude, gps.longitude),
      width: 28, height: 28,
      child: Icon(icon, color: color, size: 28),
    );
  }

  List<_ColoredSegment> _buildColoredSegments(
    List<GpsSample> gps, List<SensorSample> imu,
  ) {
    // Ungültige GPS-Punkte (0.0 / NaN / Inf) herausfiltern
    final validGps = gps.where((p) =>
        p.latitude.isFinite  && p.latitude  != 0.0 &&
        p.longitude.isFinite && p.longitude != 0.0).toList();
    if (validGps.length < 2) return [];

    final segments = <_ColoredSegment>[];

    for (int i = 0; i < validGps.length - 1; i++) {
      final gp = validGps[i];

      // IMU-Samples ±500 ms um diesen GPS-Punkt
      final window = imu
          .where((s) => (s.timestampMs - gp.timestampMs).abs() <= 500)
          .map((s) => s.az)
          .toList();

      final rms   = SignalAnalysis.rms(window);
      final color = _rmsToColor(rms);

      segments.add(_ColoredSegment(
        points: [
          LatLng(validGps[i].latitude,     validGps[i].longitude),
          LatLng(validGps[i + 1].latitude, validGps[i + 1].longitude),
        ],
        rms: rms,
        color: color,
      ));
    }
    return segments;
  }

  LatLngBounds _computeBounds(List<GpsSample> gps) {
    // Ungültige Koordinaten herausfiltern
    final valid = gps.where((p) =>
        p.latitude.isFinite  && p.latitude  != 0.0 &&
        p.longitude.isFinite && p.longitude != 0.0).toList();
    final pts = valid.isNotEmpty ? valid : gps;

    double minLat = pts.first.latitude,  maxLat = pts.first.latitude;
    double minLon = pts.first.longitude, maxLon = pts.first.longitude;
    for (final p in pts) {
      minLat = min(minLat, p.latitude);  maxLat = max(maxLat, p.latitude);
      minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude);
    }

    // Mindest-Ausdehnung: ~200 m — verhindert degenerierte Bounds
    // (identische Punkte → Zoom = Infinity → "NaN toInt"-Crash)
    const minSpan = 0.002; // ≈ 200 m in Breiten-/Längengrade
    if (maxLat - minLat < minSpan) {
      final pad = (minSpan - (maxLat - minLat)) / 2;
      maxLat += pad; minLat -= pad;
    }
    if (maxLon - minLon < minSpan) {
      final pad = (minSpan - (maxLon - minLon)) / 2;
      maxLon += pad; minLon -= pad;
    }

    return LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));
  }

  _SessionStats _computeStats(List<_ColoredSegment> segs, List<SensorSample> imu) {
    if (segs.isEmpty) return const _SessionStats(0, 0, 0);
    final rmsVals = segs.map((s) => s.rms).toList();
    final avg = rmsVals.fold(0.0, (a, b) => a + b) / rmsVals.length;
    final mx  = rmsVals.reduce(max);

    // Strecke aus Segment-Anfangspunkten berechnen
    double dist = 0;
    for (int i = 0; i < segs.length; i++) {
      final a = segs[i].points.first;
      final b = segs[i].points.last;
      dist += const Distance().as(LengthUnit.Kilometer, a, b);
    }
    return _SessionStats(avg, mx, dist);
  }

  // RMS → Farbe: grün (ruhig) → gelb → orange → rot (rau)
  static Color _rmsToColor(double rms) {
    if (!rms.isFinite || rms <= 0) return Colors.green;
    // Eingabe-Bereich: 0 … 0.5 g (normiert)
    final t = (rms / 0.5).clamp(0.0, 1.0);
    if (t < 0.33) {
      // grün → gelb
      return Color.lerp(Colors.green, Colors.yellow, t / 0.33)!;
    } else if (t < 0.66) {
      // gelb → orange
      return Color.lerp(Colors.yellow, Colors.orange, (t - 0.33) / 0.33)!;
    } else {
      // orange → rot
      return Color.lerp(Colors.orange, Colors.red, (t - 0.66) / 0.34)!;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ColoredSegment {
  final List<LatLng> points;
  final double rms;
  final Color  color;
  const _ColoredSegment({required this.points, required this.rms, required this.color});
}

class _SessionStats {
  final double avgRms, maxRms, distanceKm;
  const _SessionStats(this.avgRms, this.maxRms, this.distanceKm);
}

// ── Legende ───────────────────────────────────────────────────────────────────

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text('Oberfläche: ', style: TextStyle(fontSize: 11)),
      _LegendDot(color: Colors.green,  label: '< 0.1 g'),
      _LegendDot(color: Colors.yellow, label: '< 0.25 g'),
      _LegendDot(color: Colors.orange, label: '< 0.4 g'),
      _LegendDot(color: Colors.red,    label: '> 0.4 g'),
    ]);
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color  color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(width: 10, height: 10, margin: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
    Text(label, style: const TextStyle(fontSize: 10)),
  ]);
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(children: [
    Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
    Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
  ]);
}

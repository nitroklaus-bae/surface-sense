import 'package:flutter/material.dart';
import '../services/supabase_service.dart';

/// Zeigt die Fahrtenhistorie des eingeloggten Nutzers.
/// Daten kommen live aus Supabase (pull-to-refresh).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _supa = SupabaseService();

  List<RideSummary>? _rides;
  String?            _error;
  bool               _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final rides = await _supa.fetchRides();
      if (mounted) setState(() { _rides = rides; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  Future<void> _deleteRide(RideSummary ride) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Fahrt löschen?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${ride.name}\n${ride.durationLabel} · ${ride.distanceLabel}',
          style: const TextStyle(color: Colors.white54),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen', style: TextStyle(color: Colors.white54))),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _supa.deleteRide(ride);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.redAccent));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Fahrtenhistorie', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white38),
            tooltip: 'Abmelden',
            onPressed: () async {
              await _supa.signOut();
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _rides == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.tealAccent));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, color: Colors.white38, size: 48),
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: _load, child: const Text('Nochmal versuchen')),
      ]));
    }
    if (_rides == null || _rides!.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.directions_bike_outlined, color: Colors.white24, size: 64),
        SizedBox(height: 16),
        Text('Noch keine Fahrten aufgezeichnet.',
            style: TextStyle(color: Colors.white38, fontSize: 14)),
        SizedBox(height: 4),
        Text('Starte eine Aufnahme im Sensor-Tab.',
            style: TextStyle(color: Colors.white24, fontSize: 12)),
      ]));
    }

    return RefreshIndicator(
      color: Colors.tealAccent,
      backgroundColor: const Color(0xFF161B22),
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        itemCount: _rides!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _RideCard(
          ride:     _rides![i],
          onDelete: () => _deleteRide(_rides![i]),
          onDownload: () => _downloadFit(_rides![i]),
        ),
      ),
    );
  }

  Future<void> _downloadFit(RideSummary ride) async {
    if (ride.fitPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Keine FIT-Datei vorhanden.')));
      return;
    }
    final url = await _supa.fitDownloadUrl(ride.fitPath!);
    if (url == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('FIT-Download-URL in Zwischenablage kopiert.'),
          action: SnackBarAction(
            label: 'OK',
            onPressed: () {},
          ),
        ));
  }
}

// ── Ride-Karte ────────────────────────────────────────────────────────────────

class _RideCard extends StatelessWidget {
  final RideSummary ride;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  const _RideCard({
    required this.ride,
    required this.onDelete,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final iriColor = _iriColor(ride.avgIri);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        children: [
          // ── Header: Name + Datum ──────────────────────────────────────────
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            title: Text(ride.name,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            subtitle: Text(
              _formatDate(ride.startedAt),
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            trailing: PopupMenuButton<String>(
              color: const Color(0xFF21262D),
              icon: const Icon(Icons.more_vert, color: Colors.white38),
              onSelected: (v) {
                if (v == 'delete') onDelete();
                if (v == 'fit')    onDownload();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'fit',
                    child: Row(children: [
                      Icon(Icons.download, color: Colors.white54, size: 18),
                      SizedBox(width: 8),
                      Text('FIT herunterladen', style: TextStyle(color: Colors.white70)),
                    ])),
                const PopupMenuItem(value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                      SizedBox(width: 8),
                      Text('Löschen', style: TextStyle(color: Colors.redAccent)),
                    ])),
              ],
            ),
          ),

          // ── Metriken ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(children: [
              _Metric(Icons.timer_outlined,       ride.durationLabel, 'Dauer'),
              _Metric(Icons.straighten_outlined,  ride.distanceLabel, 'Strecke'),
              _Metric(Icons.vibration,
                  ride.avgRmsG != null
                      ? '${(ride.avgRmsG! * 1000).toStringAsFixed(1)} mg'
                      : '—',
                  'Ø RMS'),
              _IriMetric(ride.iriLabel, ride.iriQuality, iriColor),
            ]),
          ),

          // ── Montagepunkt ─────────────────────────────────────────────────
          if (ride.mountPoint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(children: [
                const Icon(Icons.place_outlined, color: Colors.white24, size: 14),
                const SizedBox(width: 4),
                Text(ride.mountPoint!,
                    style: const TextStyle(color: Colors.white24, fontSize: 11)),
              ]),
            ),
        ],
      ),
    );
  }

  Color _iriColor(double? iri) {
    if (iri == null) return Colors.white38;
    if (iri < 2) return Colors.greenAccent;
    if (iri < 5) return Colors.yellowAccent;
    if (iri < 8) return const Color(0xFFFF9800);
    return Colors.redAccent;
  }

  String _formatDate(DateTime dt) {
    final d = '${dt.day.toString().padLeft(2,'0')}.${dt.month.toString().padLeft(2,'0')}.${dt.year}';
    final t = '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    return '$d · $t Uhr';
  }
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final String   value;
  final String   label;
  const _Metric(this.icon, this.value, this.label);

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(children: [
      Icon(icon, color: Colors.white38, size: 16),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 13,
          fontWeight: FontWeight.w600)),
      Text(label,  style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]),
  );
}

class _IriMetric extends StatelessWidget {
  final String value;
  final String quality;
  final Color  color;
  const _IriMetric(this.value, this.quality, this.color);

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(children: [
      Icon(Icons.terrain_outlined, color: color, size: 16),
      const SizedBox(height: 4),
      Text(value,   style: TextStyle(color: color, fontSize: 13,
          fontWeight: FontWeight.w600)),
      Text(quality, style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]),
  );
}

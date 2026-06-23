import 'dart:io';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/surface_sample.dart';
import '../models/gps_sample.dart';

// ── Supabase-Konfiguration ────────────────────────────────────────────────────
// Werte aus: Supabase Dashboard → Settings → API
// TODO: Ersetze durch deine Projekt-URL und Anon-Key
const supabaseUrl  = 'https://cpxdxchlyvdbnsewicbq.supabase.co';
const supabaseAnon = 'sb_publishable_RPToUB4fonmTaGfdC3WZ2w_bOYdSGcc';

/// Zentraler Service für alle Supabase-Operationen:
/// Auth, Fahrten-Upload, Surface-Samples, FIT-Datei-Storage.
class SupabaseService {
  static final SupabaseService _instance = SupabaseService._();
  factory SupabaseService() => _instance;
  SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;

  // ── Auth ──────────────────────────────────────────────────────────────────

  User? get currentUser => _client.auth.currentUser;
  bool  get isSignedIn  => currentUser != null;

  Stream<AuthState> get authStateStream => _client.auth.onAuthStateChange;

  Future<void> signUp(String email, String password) async {
    final res = await _client.auth.signUp(email: email, password: password);
    if (res.user == null) throw Exception('Registrierung fehlgeschlagen');
  }

  Future<void> signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  // ── Ride-Upload ───────────────────────────────────────────────────────────

  /// Erstellt einen Ride-Eintrag in der Datenbank und gibt die neue ID zurück.
  Future<String> createRide({
    required DateTime startedAt,
    required DateTime endedAt,
    required List<SurfaceSample> samples,
    required List<GpsSample>     gpsSamples,
    String? name,
    String? mountPoint,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) throw Exception('Nicht eingeloggt');

    // Aggregierte Metriken berechnen
    double sumRms = 0, sumVdv = 0, sumIri = 0, maxIri = 0;
    int iriCount = 0;
    for (final s in samples) {
      sumRms += s.rmsG;
      sumVdv += s.vdvG;
      if (s.iriMKm != null) {
        sumIri += s.iriMKm!;
        if (s.iriMKm! > maxIri) maxIri = s.iriMKm!;
        iriCount++;
      }
    }
    final n = samples.isEmpty ? 1 : samples.length;

    // GPS-Strecke berechnen (einfache Summe der Abstände)
    double distanceM = 0;
    for (int i = 1; i < gpsSamples.length; i++) {
      distanceM += _haversineM(
        gpsSamples[i-1].latitude, gpsSamples[i-1].longitude,
        gpsSamples[i].latitude,   gpsSamples[i].longitude,
      );
    }

    final row = await _client.from('rides').insert({
      'user_id':      uid,
      'user_email':   currentUser?.email,
      'name':         name ?? _defaultRideName(startedAt),
      'started_at':   startedAt.toIso8601String(),
      'ended_at':     endedAt.toIso8601String(),
      'duration_s':   endedAt.difference(startedAt).inSeconds,
      'distance_m':   distanceM > 0 ? distanceM : null,
      'sample_count': samples.length,
      'avg_rms_g':    samples.isEmpty ? null : sumRms / n,
      'avg_vdv_g':    samples.isEmpty ? null : sumVdv / n,
      'avg_iri':      iriCount > 0 ? sumIri / iriCount : null,
      'max_iri':      iriCount > 0 ? maxIri : null,
      'mount_point':  mountPoint,
    }).select('id').single();

    return row['id'] as String;
  }

  /// Lädt alle Surface-Samples einer Fahrt hoch (Batch-Insert, 500 Zeilen pro Chunk).
  Future<void> uploadSurfaceSamples(
    String rideId,
    List<SurfaceSample> samples,
    List<GpsSample>     gpsSamples,
  ) async {
    if (samples.isEmpty) return;

    // GPS-Sample dem nächsten Surface-Sample zuordnen (±2 s)
    final rows = <Map<String, dynamic>>[];
    int gi = 0;
    for (final s in samples) {
      // Schiebe GPS-Zeiger vorwärts bis wir nah am Sample-Timestamp sind
      while (gi + 1 < gpsSamples.length &&
          (gpsSamples[gi + 1].timestampMs - s.timestampMs).abs() <
          (gpsSamples[gi].timestampMs     - s.timestampMs).abs()) {
        gi++;
      }
      final gps = gpsSamples.isNotEmpty ? gpsSamples[gi] : null;
      final dtMs = gps != null
          ? (gps.timestampMs - s.timestampMs).abs()
          : 999999;

      rows.add({
        'ride_id':      rideId,
        'ts_ms':        s.timestampMs,
        'rms_g':        s.rmsG,
        'vdv_g':        s.vdvG,
        'peak_g':       s.peakG,
        'crest_factor': s.crestFactor,
        'iri_m_km':     s.iriMKm,
        'lat':          (gps != null && dtMs < 2000) ? gps.latitude  : null,
        'lon':          (gps != null && dtMs < 2000) ? gps.longitude : null,
        'speed_kmh':    (gps != null && dtMs < 2000) ? gps.speed != null
                            ? gps.speed! * 3.6 : null : null,
      });
    }

    // Chunk-Upload (Supabase-Limit: ~1 MB pro Request)
    const chunkSize = 500;
    for (int i = 0; i < rows.length; i += chunkSize) {
      final chunk = rows.sublist(i, (i + chunkSize).clamp(0, rows.length));
      await _client.from('surface_samples').insert(chunk);
    }
  }

  /// Lädt eine FIT-Datei in Supabase Storage hoch.
  /// Pfad-Schema: {user_id}/{ride_id}.fit
  Future<String?> uploadFitFile(String rideId, File fitFile) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final path = '$uid/$rideId.fit';
    try {
      await _client.storage.from('ride-files').upload(
        path,
        fitFile,
        fileOptions: const FileOptions(contentType: 'application/octet-stream', upsert: true),
      );
      // FIT-Pfad in der rides-Zeile speichern
      await _client.from('rides').update({'fit_path': path}).eq('id', rideId);
      return path;
    } catch (e) {
      return null;   // Upload-Fehler nicht fatal — lokale Datei bleibt erhalten
    }
  }

  /// Lädt eine CSV-Datei in Supabase Storage hoch.
  Future<String?> uploadCsvFile(String rideId, File csvFile) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final path = '$uid/$rideId.csv';
    try {
      await _client.storage.from('ride-files').upload(
        path,
        csvFile,
        fileOptions: const FileOptions(contentType: 'text/csv', upsert: true),
      );
      await _client.from('rides').update({'csv_path': path}).eq('id', rideId);
      return path;
    } catch (e) {
      return null;
    }
  }

  // ── History-Queries ───────────────────────────────────────────────────────

  /// Gibt alle Fahrten des eingeloggten Nutzers zurück, neueste zuerst.
  Future<List<RideSummary>> fetchRides() async {
    final data = await _client
        .from('rides')
        .select()
        .order('started_at', ascending: false);
    return (data as List).map((r) => RideSummary.fromJson(r)).toList();
  }

  /// Gibt die Surface-Samples einer Fahrt zurück (für Wiedergabe / Analyse).
  Future<List<Map<String, dynamic>>> fetchSurfaceSamples(String rideId) async {
    final data = await _client
        .from('surface_samples')
        .select()
        .eq('ride_id', rideId)
        .order('ts_ms');
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Löscht eine Fahrt (CASCADE löscht auch surface_samples + Storage-Dateien).
  Future<void> deleteRide(RideSummary ride) async {
    // Storage-Dateien zuerst löschen
    final toDelete = [
      if (ride.fitPath != null) ride.fitPath!,
      if (ride.csvPath != null) ride.csvPath!,
    ];
    if (toDelete.isNotEmpty) {
      await _client.storage.from('ride-files').remove(toDelete);
    }
    await _client.from('rides').delete().eq('id', ride.id);
  }

  /// Gibt eine signierte Download-URL für eine FIT-Datei zurück (60 min gültig).
  Future<String?> fitDownloadUrl(String fitPath) async {
    try {
      return await _client.storage
          .from('ride-files')
          .createSignedUrl(fitPath, 3600);
    } catch (_) {
      return null;
    }
  }

  // ── Interne Hilfsfunktionen ───────────────────────────────────────────────

  String _defaultRideName(DateTime dt) {
    final h = dt.hour;
    final part = h < 10 ? 'Morgenrunde'
               : h < 13 ? 'Vormittagsrunde'
               : h < 17 ? 'Nachmittagsrunde'
               : 'Abendrunde';
    return '$part ${dt.day}.${dt.month}.${dt.year}';
  }

  /// Haversine-Distanz in Metern zwischen zwei GPS-Punkten.
  double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = _sin2(dLat / 2) +
        _cos(_rad(lat1)) * _cos(_rad(lat2)) * _sin2(dLon / 2);
    return 2 * r * _asin(_sqrt(a));
  }

  double _rad(double d) => d * 3.141592653589793 / 180.0;
  double _sin2(double x) => _sin(x) * _sin(x);
  // ignore: avoid_js_rounded_ints
  double _sin(double x)  => x - x*x*x/6 + x*x*x*x*x/120;
  double _cos(double x)  => 1 - x*x/2 + x*x*x*x/24;
  double _asin(double x) => x + x*x*x/6 + 3*x*x*x*x*x/40;
  double _sqrt(double x) => x <= 0 ? 0 : x < 1 ? x + (1-x)/2 * (x - (x+(1-x)/2)*(x+(1-x)/2)) : x;
}

// ── Datenmodell: Fahrten-Zusammenfassung ──────────────────────────────────────

class RideSummary {
  final String    id;
  final String    name;
  final DateTime  startedAt;
  final DateTime  endedAt;
  final int?      durationS;
  final double?   distanceM;
  final int?      sampleCount;
  final double?   avgRmsG;
  final double?   avgVdvG;
  final double?   avgIri;
  final double?   maxIri;
  final String?   fitPath;
  final String?   csvPath;
  final String?   mountPoint;

  const RideSummary({
    required this.id,
    required this.name,
    required this.startedAt,
    required this.endedAt,
    this.durationS,
    this.distanceM,
    this.sampleCount,
    this.avgRmsG,
    this.avgVdvG,
    this.avgIri,
    this.maxIri,
    this.fitPath,
    this.csvPath,
    this.mountPoint,
  });

  factory RideSummary.fromJson(Map<String, dynamic> j) => RideSummary(
    id:          j['id']          as String,
    name:        j['name']        as String? ?? '—',
    startedAt:   DateTime.parse(j['started_at'] as String).toLocal(),
    endedAt:     DateTime.parse(j['ended_at']   as String).toLocal(),
    durationS:   j['duration_s']  as int?,
    distanceM:   (j['distance_m'] as num?)?.toDouble(),
    sampleCount: j['sample_count'] as int?,
    avgRmsG:     (j['avg_rms_g']  as num?)?.toDouble(),
    avgVdvG:     (j['avg_vdv_g']  as num?)?.toDouble(),
    avgIri:      (j['avg_iri']    as num?)?.toDouble(),
    maxIri:      (j['max_iri']    as num?)?.toDouble(),
    fitPath:     j['fit_path']    as String?,
    csvPath:     j['csv_path']    as String?,
    mountPoint:  j['mount_point'] as String?,
  );

  String get durationLabel {
    if (durationS == null) return '—';
    final h = durationS! ~/ 3600;
    final m = (durationS! % 3600) ~/ 60;
    final s = durationS! % 60;
    return h > 0 ? '${h}h ${m}min' : m > 0 ? '${m}min ${s}s' : '${s}s';
  }

  String get distanceLabel {
    if (distanceM == null || distanceM! <= 0) return '—';
    return distanceM! >= 1000
        ? '${(distanceM! / 1000).toStringAsFixed(1)} km'
        : '${distanceM!.round()} m';
  }

  String get iriLabel => avgIri != null ? '${avgIri!.toStringAsFixed(1)} m/km' : '—';

  String get iriQuality {
    if (avgIri == null) return '—';
    if (avgIri! < 2) return 'sehr glatt';
    if (avgIri! < 5) return 'gut';
    if (avgIri! < 8) return 'mäßig';
    return 'rau';
  }
}

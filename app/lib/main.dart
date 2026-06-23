import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'providers/recording_provider.dart';
import 'services/ble_service.dart';
import 'services/supabase_service.dart';
import 'screens/sensor_screen.dart';
import 'screens/analysis_screen.dart';
import 'screens/map_screen.dart';
import 'screens/history_screen.dart';
import 'screens/auth_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();
  FlutterBluePlus.setLogLevel(LogLevel.warning);

  // Supabase initialisieren
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnon);

  runApp(const SurfaceSensorApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.bluetooth,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
  ].request();
}

class SurfaceSensorApp extends StatelessWidget {
  const SurfaceSensorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => RecordingProvider(BleService()),
      child: MaterialApp(
        title: 'Surface Sensor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blueAccent,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF0D1117),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ),
        home: const _AuthGate(),
      ),
    );
  }
}

// ── Auth-Gate: zeigt Login oder HomeScreen je nach Auth-Status ────────────────

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: SupabaseService().authStateStream,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) return const HomeScreen();
        return const AuthScreen();
      },
    );
  }
}

// ── Tab-Navigation ────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  static const _titles = ['Sensor', 'Analyse', 'Karte', 'Verlauf'];
  static const _icons  = [
    Icons.sensors,
    Icons.bar_chart,
    Icons.map_outlined,
    Icons.history,
  ];

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<RecordingProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_selectedIndex]),
        centerTitle: false,
        actions: [
          // Export-Button (nur wenn Daten vorhanden)
          if (prov.sampleCount > 0 && !prov.isRecording)
            PopupMenuButton<String>(
              icon: const Icon(Icons.upload_outlined),
              tooltip: 'Exportieren',
              onSelected: (v) => _onExport(context, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'csv',  child: Text('1-Hz Oberflächendaten (CSV)')),
                PopupMenuItem(value: 'raw',  child: Text('Rohdaten ax/ay/az (CSV)')),
                PopupMenuItem(value: 'fit',  child: Text('FIT-Datei (Garmin / Strava)')),
              ],
            ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: const [
          SensorScreen(),
          AnalysisScreen(),
          MapScreen(),
          HistoryScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: List.generate(4, (i) => NavigationDestination(
          icon: Icon(_icons[i]),
          label: _titles[i],
        )),
      ),
    );
  }

  Future<void> _onExport(BuildContext ctx, String type) async {
    final prov = ctx.read<RecordingProvider>();

    try {
      if (type == 'csv') {
        final path = await prov.exportCsv();
        if (path != null) await prov.shareFile(path);
        _snack(ctx, path != null ? 'CSV exportiert' : 'Keine Daten vorhanden');
      } else if (type == 'raw') {
        final path = await prov.exportRawCsv();
        if (path != null) await prov.shareFile(path);
        _snack(ctx, path != null ? 'Rohdaten-CSV exportiert' : 'Kein Ringpuffer vorhanden');
      } else if (type == 'fit') {
        final path = await prov.exportFit();
        if (path != null) {
          await prov.shareFile(path);
          _snack(ctx, 'FIT exportiert (für Garmin / Strava)');
        } else {
          _snack(ctx, 'FIT benötigt GPS-Daten');
        }
      }
    } catch (e) {
      _snack(ctx, 'Export fehlgeschlagen: $e');
    }
  }

  void _snack(BuildContext ctx, String msg) {
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}

import 'package:flutter/material.dart';
import '../services/supabase_service.dart';

/// Login- und Registrierungs-Screen.
/// Wird angezeigt wenn kein Nutzer eingeloggt ist.
/// Nach erfolgreichem Login wird er automatisch durch HomeScreen ersetzt
/// (AuthState-Listener in main.dart).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey      = GlobalKey<FormState>();

  bool   _isLogin  = true;    // true = Login, false = Registrierung
  bool   _loading  = false;
  String? _error;

  final _supa = SupabaseService();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      if (_isLogin) {
        await _supa.signIn(_emailCtrl.text.trim(), _passwordCtrl.text);
      } else {
        await _supa.signUp(_emailCtrl.text.trim(), _passwordCtrl.text);
      }
      // Navigation übernimmt AuthState-Listener in main.dart
    } catch (e) {
      setState(() { _error = e.toString().replaceAll('Exception: ', ''); });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo / Titel
                  const Icon(Icons.sensors, color: Colors.tealAccent, size: 56),
                  const SizedBox(height: 12),
                  const Text(
                    'SurfaceSense',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isLogin ? 'Anmelden' : 'Konto erstellen',
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                  const SizedBox(height: 36),

                  // E-Mail
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDeco('E-Mail', Icons.email_outlined),
                    validator: (v) =>
                        (v == null || !v.contains('@')) ? 'Gültige E-Mail eingeben' : null,
                  ),
                  const SizedBox(height: 16),

                  // Passwort
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDeco('Passwort', Icons.lock_outline),
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'Mindestens 6 Zeichen' : null,
                  ),
                  const SizedBox(height: 24),

                  // Fehler
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
                      ]),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Submit-Button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.tealAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _loading
                          ? const SizedBox(
                              height: 18, width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black54,
                              ))
                          : Text(
                              _isLogin ? 'Anmelden' : 'Registrieren',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Toggle Login/Registrierung
                  TextButton(
                    onPressed: _loading ? null : () {
                      setState(() { _isLogin = !_isLogin; _error = null; });
                    },
                    child: Text(
                      _isLogin
                          ? 'Noch kein Konto? Jetzt registrieren'
                          : 'Bereits registriert? Anmelden',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ),

                  // Offline-Hinweis
                  const SizedBox(height: 24),
                  const Text(
                    'Ohne Anmeldung kannst du den Sensor weiterhin\n'
                    'lokal verwenden – nur die Fahrtenhistorie ist nicht verfügbar.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String label, IconData icon) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white54),
    prefixIcon: Icon(icon, color: Colors.white38, size: 20),
    filled: true,
    fillColor: const Color(0xFF161B22),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFF30363D)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFF30363D)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Colors.tealAccent),
    ),
  );
}

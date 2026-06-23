# Supabase Backend – Einrichtungsanleitung

## 1. Supabase-Projekt erstellen

1. Gehe zu [supabase.com](https://supabase.com) → **Start your project** → Sign Up
2. Neues Projekt erstellen:
   - Name: `surface-sensor` (oder beliebig)
   - Datenbank-Passwort: sicheres Passwort notieren
   - Region: `eu-central-1` (Frankfurt) → niedrige Latenz
3. Warte bis das Projekt hochgefahren ist (~1 Min)

## 2. SQL-Migration ausführen

1. Im Supabase-Dashboard: **SQL Editor** → **New query**
2. Inhalt von `supabase/migrations/001_initial_schema.sql` einfügen
3. **Run** klicken
4. Erfolgsmeldung: `Success. No rows returned.`

> Die Migration erstellt: `rides`-Tabelle, `surface_samples`-Tabelle,
> PostGIS-Trigger (lat/lon → Geometry), Row-Level-Security-Policies,
> Storage-Bucket `ride-files` und die `ride_summary`-View.

## 3. API-Keys eintragen

1. Im Supabase-Dashboard: **Settings** → **API**
2. Kopiere:
   - **Project URL**: `https://XXXXXXXXXX.supabase.co`
   - **anon public** Key (beginnt mit `eyJ…`)
3. Öffne `app/lib/services/supabase_service.dart`
4. Ersetze die Platzhalter:

```dart
const supabaseUrl  = 'https://DEIN-PROJEKT.supabase.co';   // ← hier
const supabaseAnon = 'DEIN-ANON-KEY';                      // ← hier
```

> **Sicherheit:** Der Anon-Key ist sicher für Client-Apps — er hat nur Zugriff
> auf Daten, die Row-Level-Security erlaubt. Nie den `service_role`-Key in die App!

## 4. App bauen und testen

```bash
cd app
flutter pub get
flutter run
```

Beim ersten Start erscheint der **Login-Screen**.  
Nach Registrierung + Login ist die App wie gewohnt nutzbar,  
zusätzlich erscheint der Tab **Verlauf**.

Nach jeder Aufnahme werden Daten automatisch hochgeladen:
- Ride-Metadaten (Dauer, Strecke, Ø RMS, Ø IRI) in die `rides`-Tabelle
- Alle 1-Hz Surface-Samples in `surface_samples`
- FIT-Datei in Supabase Storage (`ride-files/{user_id}/{ride_id}.fit`)

## 5. Daten in Supabase prüfen

Im Dashboard unter **Table Editor**:
- `rides` → eine Zeile pro Fahrt
- `surface_samples` → alle 1-Hz-Punkte, Spalte `geom` ist befüllt

## 6. Offline-Betrieb

Die App funktioniert **ohne Login** weiterhin vollständig.  
Nur der Verlauf-Tab und der automatische Upload sind dann deaktiviert.  
Lokale CSV- und FIT-Exporte sind immer verfügbar.

## Nächste Schritte (optional)

| Schritt | Aufwand |
|---|---|
| Web-Dashboard (SvelteKit auf Vercel) mit Karte + IRI-Heatmap | ~2 Tage |
| Team-Funktionen: Ride-Sharing, gemeinsame Karte | ~1 Tag |
| ISO 2631-1 Wz-Gewichtung serverseitig via Edge Function | ~0,5 Tage |

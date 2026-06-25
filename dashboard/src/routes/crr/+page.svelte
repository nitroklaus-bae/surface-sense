<script>
  import { onMount, tick } from 'svelte';
  import { get } from 'svelte/store';
  import { parseFIT, parseGPX } from '$lib/rollex/trackParser';
  import { analyzeSurfaces, SURFACE_PROPS } from '$lib/rollex/surfaceAnalyzer';
  import { optimizeTires, formatTime } from '$lib/rollex/tireOptimizer';
  import { stravaStreamsToTrack } from '$lib/rollex/stravaAdapter';
  import { fmtPressure, pressureUnitLabel } from '$lib/rollex/units';
  import { copySetupSummary, downloadSetupPng } from '$lib/rollex/exportSetup';
  import { loadCentralRides, loadRideTrack, selectedRide as centralRide } from '$lib/rideSelection.js';
  import CrrSurface3DChart from '$lib/rollex/CrrSurface3DChart.svelte';
  import { crrSession, makeCrrProfileKey, makeCrrWeightsKey } from '$lib/rollex/crrSession.js';

  // ── Source selection ───────────────────────────────────────────────
  const restoredSession = get(crrSession);
  let source = restoredSession.source ?? 'supabase'; // 'supabase' | 'upload' | 'intervals' | 'strava'
  let rides = [];
  let selectedRideId = '';

  // ── Supabase source ────────────────────────────────────────────────
  // ── Upload source ──────────────────────────────────────────────────
  let uploadedTrack = null;
  let uploadName    = '';
  let uploadError   = '';

  // ── intervals.icu source ───────────────────────────────────────────
  let intervalsAthleteId  = '';
  let intervalsApiKey     = '';
  let intervalsActivities = [];
  let selectedIntervalsId = '';
  let intervalsLoading    = false;
  let intervalsError      = '';

  // ── Strava source ──────────────────────────────────────────────────
  let stravaToken      = null;
  let stravaAthlete    = null;
  let stravaActivities = [];
  let selectedStravaId = '';
  let stravaLoading    = false;
  let stravaError      = '';

  // ── Analysis state ─────────────────────────────────────────────────
  let analyzing = false;
  let progress  = '';
  let error     = '';
  let results   = restoredSession.results ?? null; // { surfaces, tireSetups, track, rideInfo }
  let sessionRideId = restoredSession.lastRideId ?? '';

  // ── Surface map (Leaflet) ──────────────────────────────────────────
  let L = null;
  let surfaceMapEl = null;
  let surfaceMap   = null;
  let mapColorMode = 'surface'; // 'surface' | 'iri'

  // ── Tab navigation ─────────────────────────────────────────────────
  let activeTab = restoredSession.activeTab === 'karte' ? 'karte' : 'analyse'; // 'analyse' | 'karte'
  let pressureUnits = 'bar';
  let exportNotice = '';

  // ── Rider profile (localStorage) ──────────────────────────────────
  let profile = {
    riderWeightKg:     75,
    bikeWeightKg:       9,
    avgPowerW:        220,
    minTireWidthMm:    25,
    maxTireWidthMm:    50,
    hasTubeless:      true,
    ambientTempCelsius: 20,
    crrModel:       'physical',
  };
  let weights = { speed: 0.6, puncture: 0.25, handling: 0.15 };

  $: if (
    source === 'supabase' &&
    results &&
    sessionRideId &&
    $centralRide?.id &&
    $centralRide.id !== sessionRideId &&
    !analyzing
  ) {
    results = null;
    activeTab = 'analyse';
    sessionRideId = $centralRide.id;
  }

  $: crrSession.update((state) => (
    state.source === source &&
    state.activeTab === activeTab &&
    state.results === results &&
    state.lastRideId === sessionRideId
      ? state
      : {
          ...state,
          source,
          activeTab,
          results,
          lastRideId: sessionRideId,
          lastProfileKey: makeCrrProfileKey(profile),
          lastWeightsKey: makeCrrWeightsKey(weights),
        }
  ));

  // ── onMount ────────────────────────────────────────────────────────
  onMount(async () => {
    // Load saved profile
    try {
      const saved = localStorage.getItem('crr_profile');
      if (saved) profile = { ...profile, ...JSON.parse(saved) };
      const savedW = localStorage.getItem('crr_weights');
      if (savedW) weights = { ...weights, ...JSON.parse(savedW) };
    } catch {}

    // Load saved intervals.icu settings
    try {
      const s = JSON.parse(localStorage.getItem('intervals_settings') ?? '{}');
      if (s.athleteId) intervalsAthleteId = s.athleteId;
      if (s.apiKey)    intervalsApiKey    = s.apiKey;
    } catch {}

    // Handle Strava OAuth callback in URL hash
    const hash = window.location.hash.slice(1);
    if (hash) {
      const p = new URLSearchParams(hash);
      const tok = p.get('strava_token');
      if (tok) {
        stravaToken = tok;
        const exp = parseInt(p.get('strava_expires') ?? '0');
        try { stravaAthlete = JSON.parse(decodeURIComponent(p.get('strava_athlete') ?? '{}')); } catch {}
        localStorage.setItem('strava_token', JSON.stringify({ token: tok, expiresAt: exp, athlete: stravaAthlete }));
        history.replaceState(null, '', window.location.pathname + window.location.search);
        source = 'strava';
      }
    }

    // Handle Strava error redirect
    const urlP = new URLSearchParams(window.location.search);
    const strErr = urlP.get('strava_error');
    if (strErr) {
      stravaError = `Verbindung fehlgeschlagen: ${strErr}`;
      history.replaceState(null, '', window.location.pathname);
      source = 'strava';
    }

    // Load saved Strava token
    if (!stravaToken) {
      try {
        const s = JSON.parse(localStorage.getItem('strava_token') ?? '{}');
        if (s.token && s.expiresAt * 1000 > Date.now()) {
          stravaToken  = s.token;
          stravaAthlete = s.athlete ?? null;
        } else {
          localStorage.removeItem('strava_token');
        }
      } catch {}
    }

    try {
      await loadCentralRides();
    } catch (e) {
      error = 'Zentrale Fahrt konnte nicht geladen werden: ' + (e instanceof Error ? e.message : String(e));
    }

    // Leaflet — browser only (no SSR)
    L = (await import('leaflet')).default;
    await import('leaflet/dist/leaflet.css');
  });

  // IRI → Heatmap-Farbe (grün → gelb → orange → rot)
  function iriHeatColor(iri) {
    if (iri == null || iri <= 0) return '#9ca3af';
    if (iri < 2)  return '#22c55e';
    if (iri < 4)  return '#84cc16';
    if (iri < 6)  return '#f59e0b';
    if (iri < 9)  return '#ef4444';
    return '#991b1b';
  }

  // ── Surface map ────────────────────────────────────────────────────
  async function drawSurfaceMap(track, surfaces, colorMode = mapColorMode) {
    await tick(); // wait for map div to appear in DOM
    if (!L || !surfaceMapEl) return;

    if (surfaceMap) { surfaceMap.remove(); surfaceMap = null; }

    surfaceMap = L.map(surfaceMapEl, { zoomControl: true });
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19,
    }).addTo(surfaceMap);

    const pts = track.points;

    // Basis-Polyline: gesamter Track als durchgehender grauer Pfad
    const allTrackPts = pts.filter(p => p.lat && p.lon).map(p => [p.lat, p.lon]);
    if (allTrackPts.length >= 2) {
      L.polyline(allTrackPts, { color: '#6b7280', weight: 4, opacity: 0.5 }).addTo(surfaceMap);
    }

    for (const seg of surfaces) {
      const latlngs = pts
        .slice(seg.startIdx, seg.endIdx + 1)
        .filter(p => p.lat && p.lon)
        .map(p => [p.lat, p.lon]);
      if (latlngs.length < 2) continue;

      const iriEst  = seg.surface.iri ?? SURFACE_PROPS[seg.surface.category]?.iri ?? null;
      const iriVal  = seg.measuredIri ?? iriEst;
      const color   = colorMode === 'iri' ? iriHeatColor(iriVal) : seg.surface.color;
      const label   = SURFACE_PROPS[seg.surface.category]?.label ?? seg.surface.category;
      const conf    = seg.osmConfidence != null ? (seg.osmConfidence * 100).toFixed(0) + '%' : '–';
      const iriDisp = seg.measuredIri != null
        ? `<b style="color:${iriHeatColor(seg.measuredIri)}">${seg.measuredIri.toFixed(1)}</b> m/km (gemessen)`
        : iriEst != null ? `${iriEst.toFixed(1)} m/km (geschätzt)` : '–';

      L.polyline(latlngs, { color, weight: 6, opacity: 0.88 })
        .bindPopup(
          `<div style="min-width:160px;font-family:sans-serif;font-size:13px">
            <b style="color:${color}">${label}</b><br/>
            <table style="border-collapse:collapse;margin-top:6px;width:100%">
              <tr><td style="color:#888;padding:2px 6px 2px 0">Strecke</td><td>${formatKm(seg.distanceMeters)}</td></tr>
              <tr><td style="color:#888;padding:2px 6px 2px 0">IRI</td><td>${iriDisp}</td></tr>
              <tr><td style="color:#888;padding:2px 6px 2px 0">OSM-Konfidenz</td><td>${conf}</td></tr>
            </table>
          </div>`,
          { maxWidth: 260 }
        )
        .bindTooltip(`<b>${label}</b> · ${formatKm(seg.distanceMeters)}`, { sticky: true })
        .addTo(surfaceMap);
    }

    // Start / End markers
    const validPts = pts.filter(p => p.lat && p.lon);
    if (validPts.length >= 2) {
      const mkIcon = (txt, bg) => L.divIcon({
        html: `<div style="background:${bg};color:#fff;border-radius:50%;width:24px;height:24px;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;border:2px solid #fff;box-shadow:0 1px 4px #0006">${txt}</div>`,
        iconSize: [24, 24], iconAnchor: [12, 12], className: ''
      });
      const first = validPts[0], last = validPts[validPts.length - 1];
      L.marker([first.lat, first.lon], { icon: mkIcon('S', '#22c55e') }).bindTooltip('Start').addTo(surfaceMap);
      L.marker([last.lat,  last.lon],  { icon: mkIcon('Z', '#ef4444') }).bindTooltip('Ziel').addTo(surfaceMap);
    }

    const allPts = validPts.map(p => [p.lat, p.lon]);
    if (allPts.length) surfaceMap.fitBounds(L.latLngBounds(allPts), { padding: [20, 20] });
    // Multiple invalidateSize calls to handle layout not yet settled after tab switch
    surfaceMap.invalidateSize();
    requestAnimationFrame(() => surfaceMap?.invalidateSize());
    setTimeout(() => surfaceMap?.invalidateSize(), 150);
  }

  // Redraw whenever results arrive, map tab becomes active, or color mode toggles
  $: if (results && L && activeTab === 'karte') drawSurfaceMap(results.track, results.surfaces, mapColorMode);

  function saveProfile() {
    try {
      localStorage.setItem('crr_profile', JSON.stringify(profile));
      localStorage.setItem('crr_weights', JSON.stringify(weights));
    } catch {}
  }

  // ── intervals.icu ──────────────────────────────────────────────────
  async function loadIntervalsActivities() {
    if (!intervalsAthleteId || !intervalsApiKey) {
      intervalsError = 'Bitte Athlete-ID und API-Key eingeben.'; return;
    }
    intervalsLoading = true;
    intervalsError   = '';
    try {
      const params = new URLSearchParams({ athleteId: intervalsAthleteId, apiKey: intervalsApiKey });
      const res = await fetch(`/api/intervals?${params}`);
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      // intervals.icu uses Strava-compatible type names but may vary — show all activities,
      // exclude obvious non-bike types (running, swimming, strength) to keep the list useful.
      const EXCLUDE = ['Run','Walk','Hike','Swim','WeightTraining','Yoga','Workout','Elliptical','StairStepper','RockClimbing','Crossfit','Rowing'];
      const arr = Array.isArray(data) ? data : (data?.activities ?? data?.data ?? []);
      intervalsActivities = (arr)
        .filter(a => !EXCLUDE.includes(a.type ?? ''))
        .map(a => ({
          id:           String(a.id),
          name:         a.name ?? 'Aktivität',
          type:         a.type ?? '',
          startedAt:    a.start_date_local ?? a.startDateLocal ?? a.date,
          distanceM:    a.distance ?? 0,
          movingTimeSec: a.moving_time ?? a.movingTime ?? 0,
        }));
      if (intervalsActivities.length > 0) selectedIntervalsId = intervalsActivities[0].id;
      localStorage.setItem('intervals_settings', JSON.stringify({ athleteId: intervalsAthleteId, apiKey: intervalsApiKey }));
    } catch (e) {
      intervalsError = e instanceof Error ? e.message : String(e);
    } finally {
      intervalsLoading = false;
    }
  }

  // ── Strava ─────────────────────────────────────────────────────────
  function connectStrava() {
    window.location.href = '/api/strava/auth';
  }

  function disconnectStrava() {
    stravaToken      = null;
    stravaAthlete    = null;
    stravaActivities = [];
    selectedStravaId = '';
    localStorage.removeItem('strava_token');
  }

  async function loadStravaActivities() {
    if (!stravaToken) return;
    stravaLoading = true;
    stravaError   = '';
    try {
      const res = await fetch(`/api/strava/activities?token=${stravaToken}`);
      if (res.status === 401) { disconnectStrava(); throw new Error('Token abgelaufen — bitte neu verbinden.'); }
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      const CYCLING = ['Ride','VirtualRide','GravelRide','MountainBikeRide','EBikeRide'];
      stravaActivities = (data ?? [])
        .filter(a => CYCLING.includes(a.type ?? a.sport_type ?? ''))
        .map(a => ({
          id:           String(a.id),
          name:         a.name ?? 'Aktivität',
          startedAt:    a.start_date_local,
          distanceM:    a.distance ?? 0,
          movingTimeSec: a.moving_time ?? 0,
        }));
      if (stravaActivities.length > 0) selectedStravaId = stravaActivities[0].id;
    } catch (e) {
      stravaError = e instanceof Error ? e.message : String(e);
    } finally {
      stravaLoading = false;
    }
  }

  // ── File upload ────────────────────────────────────────────────────
  async function handleFileInput(event) {
    const file = event.target.files?.[0];
    if (!file) return;
    uploadError   = '';
    uploadedTrack = null;
    uploadName    = file.name.replace(/\.(fit|gpx)$/i, '');
    try {
      const buffer = await file.arrayBuffer();
      if (file.name.toLowerCase().endsWith('.gpx')) {
        uploadedTrack = parseGPX(new TextDecoder().decode(buffer));
      } else {
        uploadedTrack = parseFIT(buffer);
      }
    } catch (e) {
      uploadError = e instanceof Error ? e.message : String(e);
    }
  }

  // ── Main analysis ──────────────────────────────────────────────────
  $: canAnalyze = !analyzing && (
    (source === 'supabase'  && !!$centralRide) ||
    (source === 'upload'    && !!uploadedTrack) ||
    (source === 'intervals' && !!selectedIntervalsId) ||
    (source === 'strava'    && !!stravaToken && !!selectedStravaId)
  );

  async function runAnalysis() {
    error   = '';
    results = null;
    analyzing = true;
    let track;
    let rideInfo = { name: 'Fahrt', startedAt: null, avgIri: null, source };

    try {
      // ── Supabase ──────────────────────────────────────────────────
      if (source === 'supabase') {
        const ride = $centralRide;
        if (!ride) throw new Error('Bitte auf der Fahrten-Seite zuerst eine zentrale Fahrt auswählen.');
        progress = ride.fit_path ? 'FIT-Datei wird geladen...' : 'GPS-Track aus SurfaceSense-Samples rekonstruieren...';
        track = await loadRideTrack(ride, { includeIri: true });

        // 1. Versuch: FIT-Datei aus Storage laden und parsen
        if (!track && ride.fit_path) {
          progress = 'FIT-Datei wird geladen…';
          try {
            const { data: blob, error: dlErr } = await supabase.storage
              .from('ride-files').download(ride.fit_path);
            if (!dlErr && blob) {
              progress = 'GPS-Track wird eingelesen…';
              track = parseFIT(await blob.arrayBuffer());
            }
          } catch (_) {
            // FIT fehlerhaft → Fallback unten
          }
        }

        // 2. Fallback: GPS-Track aus surface_samples rekonstruieren
        if (!track) {
          progress = 'GPS-Track aus SurfaceSense-Samples rekonstruieren…';
          const { data: sampleRows, error: sampleErr } = await supabase
            .from('surface_samples')
            .select('ts_ms,lat,lon,speed_kmh,iri_m_km')
            .eq('ride_id', ride.id)
            .order('ts_ms');
          if (sampleErr) throw new Error('Surface-Samples: ' + sampleErr.message);
          track = trackFromSurfaceSamples(sampleRows ?? []);
        }

        rideInfo = { name: ride.name ?? 'Fahrt', startedAt: ride.started_at, avgIri: ride.avg_iri, source };

      // ── Upload ────────────────────────────────────────────────────
      } else if (source === 'upload') {
        if (!uploadedTrack) throw new Error('Bitte zuerst eine FIT- oder GPX-Datei auswählen.');
        track = uploadedTrack;
        rideInfo = { name: uploadName || 'Hochgeladene Fahrt', startedAt: null, avgIri: null, source };

      // ── intervals.icu ─────────────────────────────────────────────
      } else if (source === 'intervals') {
        if (!selectedIntervalsId) throw new Error('Keine Aktivität ausgewählt.');
        progress = 'FIT-Datei von intervals.icu laden…';
        const params = new URLSearchParams({
          athleteId: intervalsAthleteId, apiKey: intervalsApiKey, id: selectedIntervalsId
        });
        const res = await fetch(`/api/intervals/fit?${params}`);
        if (!res.ok) {
          const txt = await res.text();
          let msg = txt;
          try { msg = JSON.parse(txt)?.message ?? txt; } catch {}
          throw new Error('intervals.icu: ' + msg.slice(0, 400));
        }
        progress = 'GPS-Track wird eingelesen…';
        track    = parseFIT(await res.arrayBuffer());
        const act = intervalsActivities.find(a => a.id === selectedIntervalsId);
        rideInfo = { name: act?.name ?? 'intervals.icu Fahrt', startedAt: act?.startedAt ?? null, avgIri: null, source };

      // ── Strava ────────────────────────────────────────────────────
      } else if (source === 'strava') {
        if (!stravaToken) throw new Error('Nicht mit Strava verbunden.');
        if (!selectedStravaId) throw new Error('Keine Aktivität ausgewählt.');
        progress = 'Strava-Aktivität wird geladen…';
        const res = await fetch(`/api/strava/streams?token=${stravaToken}&id=${selectedStravaId}`);
        if (res.status === 401) { disconnectStrava(); throw new Error('Strava-Token abgelaufen.'); }
        if (!res.ok) throw new Error('Strava: ' + (await res.text()).slice(0, 200));
        const streams = await res.json();
        const act = stravaActivities.find(a => a.id === selectedStravaId);
        progress = 'GPS-Track wird aufgebaut…';
        track    = stravaStreamsToTrack(streams, act?.startedAt ? new Date(act.startedAt) : undefined);
        rideInfo = { name: act?.name ?? 'Strava-Fahrt', startedAt: act?.startedAt ?? null, avgIri: null, source };
      }

      if (!track || track.points.length < 10)
        throw new Error('Zu wenige GPS-Punkte im Track (' + (track?.points.length ?? 0) + ').');

      // ── Common: OSM + tire optimization ───────────────────────────
      progress = 'OSM-Karte wird abgefragt…';
      const surfaces = await analyzeSurfaces(track, (phase, pct) => {
        progress = `${phase} (${pct}%)`;
      });

      progress = 'Reifen werden optimiert…';
      saveProfile();
      const tireSetups = optimizeTires(profile, surfaces, track.totalDistance, 5, track, weights);

      sessionRideId = source === 'supabase'
        ? ($centralRide?.id ?? '')
        : `${source}:${rideInfo.name}:${track.points.length}:${Math.round(track.totalDistance ?? 0)}`;
      results   = { surfaces, tireSetups, track, rideInfo };
      progress  = '';
      activeTab = 'analyse';
    } catch (e) {
      error    = e instanceof Error ? e.message : String(e);
      progress = '';
      // Scroll left panel to top so error message is visible
      setTimeout(() => document.querySelector('.panel-left')?.scrollTo({ top: 9999, behavior: 'smooth' }), 50);
    } finally {
      analyzing = false;
    }
  }

  // ── Display helpers ────────────────────────────────────────────────
  function surfaceColor(cat) { return SURFACE_PROPS[cat]?.color ?? '#9ca3af'; }
  function surfaceLabel(cat) { return SURFACE_PROPS[cat]?.label ?? cat; }

  function buildSurfaceBreakdown(surfaces) {
    const map = {};
    let total = 0;
    for (const seg of surfaces) {
      map[seg.surface.category] = (map[seg.surface.category] ?? 0) + seg.distanceMeters;
      total += seg.distanceMeters;
    }
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .map(([cat, m]) => ({ cat, m, pct: (m / total * 100).toFixed(1) }));
  }

  function iriQuality(iri) {
    if (iri < 2) return { label: 'Sehr glatt', color: '#22c55e' };
    if (iri < 5) return { label: 'Gut',        color: '#84cc16' };
    if (iri < 8) return { label: 'Mäßig',      color: '#f59e0b' };
    return           { label: 'Rau',        color: '#ef4444' };
  }

  function formatKm(m) { return m >= 1000 ? (m/1000).toFixed(1) + ' km' : Math.round(m) + ' m'; }
  function fmtDate(s)  { return s ? new Date(s).toLocaleDateString('de-DE', { day:'2-digit', month:'2-digit', year:'2-digit' }) : ''; }
  function pressureLabel(bar) { return `${fmtPressure(bar, pressureUnits)} ${pressureUnitLabel(pressureUnits)}`; }
  function setupMeta() {
    return {
      fileName: results?.rideInfo?.name ?? null,
      distanceM: results?.track?.totalDistance ?? 0,
      elevGainM: results?.track?.totalElevGain ?? 0,
      units: pressureUnits,
    };
  }
  async function copySetup(setup) {
    exportNotice = await copySetupSummary(setup, setupMeta()) ? 'Setup kopiert.' : 'Kopieren nicht möglich.';
    setTimeout(() => { exportNotice = ''; }, 2500);
  }
  function downloadSetup(setup) {
    downloadSetupPng(setup, setupMeta());
    exportNotice = 'PNG wird erstellt.';
    setTimeout(() => { exportNotice = ''; }, 2500);
  }
  function fmtDuration(sec) {
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
    return h > 0 ? `${h}h ${m}min` : `${m} min`;
  }
  const SOURCE_LABELS = { supabase: 'SurfaceSense', upload: 'Upload', intervals: 'intervals.icu', strava: 'Strava' };
</script>

<div class="page">
  <!-- ── Left panel ────────────────────────────────────────────────── -->
  <aside class="panel-left">
    <h2 class="section-title">Fahrer-Profil</h2>
    <div class="form-grid">
      <label class="field">
        <span>Körpergewicht (kg)</span>
        <input type="number" bind:value={profile.riderWeightKg} min="40" max="150" step="1" />
      </label>
      <label class="field">
        <span>Rad + Gepäck (kg)</span>
        <input type="number" bind:value={profile.bikeWeightKg} min="5" max="30" step="0.5" />
      </label>
      <label class="field">
        <span>Durchschnittsleistung (W)</span>
        <input type="number" bind:value={profile.avgPowerW} min="80" max="500" step="5" />
      </label>
      <label class="field">
        <span>Reifenbreite min (mm)</span>
        <input type="number" bind:value={profile.minTireWidthMm} min="18" max="60" step="1" />
      </label>
      <label class="field">
        <span>Reifenbreite max (mm)</span>
        <input type="number" bind:value={profile.maxTireWidthMm} min="18" max="80" step="1" />
      </label>
      <label class="field">
        <span>Temperatur (°C)</span>
        <input type="number" bind:value={profile.ambientTempCelsius} min="-10" max="45" step="1" />
      </label>
      <label class="field checkbox">
        <input type="checkbox" bind:checked={profile.hasTubeless} />
        <span>Nur Tubeless</span>
      </label>
    </div>

    <h2 class="section-title" style="margin-top:20px">Prioritäten</h2>
    <div class="form-grid">
      <label class="field">
        <span>Geschwindigkeit</span>
        <input type="range" bind:value={weights.speed} min="0" max="1" step="0.05" />
        <span class="range-val">{Math.round(weights.speed*100)}%</span>
      </label>
      <label class="field">
        <span>Pannen-Schutz</span>
        <input type="range" bind:value={weights.puncture} min="0" max="1" step="0.05" />
        <span class="range-val">{Math.round(weights.puncture*100)}%</span>
      </label>
      <label class="field">
        <span>Handling</span>
        <input type="range" bind:value={weights.handling} min="0" max="1" step="0.05" />
        <span class="range-val">{Math.round(weights.handling*100)}%</span>
      </label>
    </div>

    <!-- ── Datenquelle ───────────────────────────────────────────── -->
    <h2 class="section-title" style="margin-top:20px">Datenquelle</h2>
    <div class="source-tabs">
      <button class:active={source==='supabase'}  on:click={() => source='supabase'}>SurfaceSense</button>
      <button class:active={source==='upload'}    on:click={() => source='upload'}>Upload</button>
      <button class:active={source==='intervals'} on:click={() => source='intervals'}>intervals.icu</button>
      <button class:active={source==='strava'}    on:click={() => source='strava'}>Strava</button>
    </div>

    <!-- SurfaceSense Supabase -->
    {#if source === 'supabase'}
      {#if $centralRide}
        <div class="central-ride-card">
          <span>Aktuelle Fahrt</span>
          <strong>{fmtDate($centralRide.started_at)} · {$centralRide.name ?? 'Fahrt'} · {formatKm($centralRide.distance_m ?? 0)}</strong>
          <a href="/">Fahrt wechseln</a>
        </div>
      {:else}
        <p class="hint">Keine zentrale Fahrt ausgewählt. Bitte zuerst auf der Fahrten-Seite eine Fahrt wählen.</p>
        <a class="btn-secondary link-btn" href="/">Zur Fahrten-Auswahl</a>
      {/if}
    {/if}

    {#if false && source === 'supabase'}
      <select class="ride-select" bind:value={selectedRideId}>
        {#each rides as r}
          <option value={r.id}>{fmtDate(r.started_at)} · {r.name ?? 'Fahrt'} · {formatKm(r.distance_m ?? 0)}</option>
        {/each}
      </select>
      {#if rides.length === 0}
        <p class="hint">Keine Fahrten mit FIT-Datei gefunden. Erst in der App aufzeichnen und hochladen.</p>
      {/if}
    {/if}

    <!-- Upload -->
    {#if source === 'upload'}
      <label class="upload-zone">
        <input type="file" accept=".fit,.gpx" on:change={handleFileInput} />
        {#if uploadedTrack}
          <span class="upload-ok">✓ {uploadName} — {uploadedTrack.points.length} Punkte, {formatKm(uploadedTrack.totalDistance)}</span>
        {:else}
          <span>FIT oder GPX hier ablegen<br /><small>oder klicken zum Auswählen</small></span>
        {/if}
      </label>
      {#if uploadError}<p class="error-msg">{uploadError}</p>{/if}
    {/if}

    <!-- intervals.icu -->
    {#if source === 'intervals'}
      <div class="form-grid">
        <label class="field">
          <span>Athlete-ID</span>
          <input type="text" bind:value={intervalsAthleteId} placeholder="z. B. i12345" />
        </label>
        <label class="field">
          <span>API-Key</span>
          <input type="password" bind:value={intervalsApiKey} placeholder="aus Einstellungen > API" />
        </label>
      </div>
      <button class="btn-secondary" on:click={loadIntervalsActivities} disabled={intervalsLoading}>
        {intervalsLoading ? 'Lade…' : 'Aktivitäten laden'}
      </button>
      {#if intervalsError}<p class="error-msg">{intervalsError}</p>{/if}
      {#if intervalsActivities.length > 0}
        <p class="hint" style="color:#2dd4bf">{intervalsActivities.length} Aktivitäten geladen</p>
        <select class="ride-select" bind:value={selectedIntervalsId}>
          {#each intervalsActivities as a}
            <option value={a.id}>{fmtDate(a.startedAt)} · [{a.type}] {a.name} · {formatKm(a.distanceM)}</option>
          {/each}
        </select>
      {:else if !intervalsLoading && !intervalsError}
        <p class="hint">API-Key + Athlete-ID eingeben, dann „Aktivitäten laden".<br/>Den Key findest du unter intervals.icu → Einstellungen → API-Zugang.</p>
      {/if}
    {/if}

    <!-- Strava -->
    {#if source === 'strava'}
      {#if !stravaToken}
        <button class="btn-strava" on:click={connectStrava}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M15.387 17.944l-2.089-4.116h-3.065L15.387 24l5.15-10.172h-3.066m-7.008-5.599l2.836 5.598h4.172L10.463 0l-7 13.828h4.169"/></svg>
          Mit Strava verbinden
        </button>
        {#if stravaError}<p class="error-msg">{stravaError}</p>{/if}
        <p class="hint">Erfordert eine Strava-App-Konfiguration (STRAVA_CLIENT_ID + STRAVA_CLIENT_SECRET in Vercel).</p>
      {:else}
        <div class="strava-connected">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="#fc4c02"><path d="M15.387 17.944l-2.089-4.116h-3.065L15.387 24l5.15-10.172h-3.066m-7.008-5.599l2.836 5.598h4.172L10.463 0l-7 13.828h4.169"/></svg>
          <span>{stravaAthlete?.name ?? 'Verbunden'}</span>
          <button class="btn-text" on:click={disconnectStrava}>Trennen</button>
        </div>
        <button class="btn-secondary" on:click={loadStravaActivities} disabled={stravaLoading}>
          {stravaLoading ? 'Lade…' : 'Fahrten laden'}
        </button>
        {#if stravaError}<p class="error-msg">{stravaError}</p>{/if}
        {#if stravaActivities.length > 0}
          <select class="ride-select" bind:value={selectedStravaId}>
            {#each stravaActivities as a}
              <option value={a.id}>{fmtDate(a.startedAt)} · {a.name} · {formatKm(a.distanceM)}</option>
            {/each}
          </select>
        {/if}
      {/if}
    {/if}

    <button class="btn-analyze" on:click={runAnalysis} disabled={!canAnalyze}>
      {analyzing ? (progress || 'Analysiere…') : '⟳  Analysieren'}
    </button>

    {#if error}
      <p class="error-msg">{error}</p>
    {/if}
  </aside>

  <!-- ── Right panel ────────────────────────────────────────────────── -->
  <div class="panel-right">
    {#if !results && !analyzing}
      <div class="empty-state">
        <div class="empty-icon">🚴</div>
        <p>Fahrt auswählen und „Analysieren" klicken.</p>
        <p class="hint">
          <b>SurfaceSense</b> — eigene aufgezeichnete Fahrten mit Sensor-IRI.<br />
          <b>Upload</b> — beliebige .fit oder .gpx Datei.<br />
          <b>intervals.icu</b> — Fahrten aus intervals.icu via API-Key.<br />
          <b>Strava</b> — Fahrten aus Strava (OAuth).
        </p>
      </div>
    {/if}

    {#if analyzing}
      <div class="empty-state">
        <div class="spinner"></div>
        <p>{progress}</p>
      </div>
    {/if}

    {#if results}
      <!-- ── Tab bar ─────────────────────────────────────────────── -->
      <div class="tabs">
        <button class:active={activeTab === 'analyse'} on:click={() => activeTab = 'analyse'}>Analyse</button>
        <button class:active={activeTab === 'karte'}   on:click={() => activeTab = 'karte'}>Karte</button>
      </div>

      <!-- ── Analyse tab ─────────────────────────────────────────── -->
      {#if activeTab === 'analyse'}
        <div class="panel-scroll">
          <!-- Surface breakdown -->
          <section class="card">
            <div class="card-header">
              <h3>
                Oberflächenverteilung — {results.rideInfo.name}
                {#if results.rideInfo.startedAt} ({fmtDate(results.rideInfo.startedAt)}){/if}
              </h3>
              <span class="source-badge src-{results.rideInfo.source}">{SOURCE_LABELS[results.rideInfo.source]}</span>
            </div>
            <div class="surface-bar">
              {#each buildSurfaceBreakdown(results.surfaces) as seg}
                <div
                  class="surface-segment"
                  style="width:{seg.pct}%; background:{surfaceColor(seg.cat)}"
                  title="{surfaceLabel(seg.cat)}: {formatKm(seg.m)} ({seg.pct}%)"
                ></div>
              {/each}
            </div>
            <div class="surface-legend">
              {#each buildSurfaceBreakdown(results.surfaces) as seg}
                <span class="legend-item">
                  <span class="dot" style="background:{surfaceColor(seg.cat)}"></span>
                  {surfaceLabel(seg.cat)} {seg.pct}%
                </span>
              {/each}
            </div>
            <div class="meta-row">
              <span>Strecke: {formatKm(results.track.totalDistance)}</span>
              {#if results.rideInfo.avgIri}
                {@const q = iriQuality(results.rideInfo.avgIri)}
                <span>Ø IRI: <b style="color:{q.color}">{results.rideInfo.avgIri.toFixed(1)} m/km</b> — {q.label}</span>
              {/if}
              {#if results.track.hasPowerData}
                <span>⚡ Power-Daten vorhanden</span>
              {/if}
              <span>{results.surfaces.filter(s => s.measuredIri !== undefined).length} Segmente mit Sensor-IRI</span>
            </div>
          </section>

      <!-- Tire recommendations -->
      {#if results.tireSetups.length === 0}
        <section class="card">
          <p class="hint">Keine passenden Reifen gefunden. Bitte Breitenbereich prüfen.</p>
        </section>
      {:else}
        <section class="card">
          <h3>Reifen-Empfehlungen</h3>
          <div class="toolbar-row">
            <label>
              Druck
              <select bind:value={pressureUnits}>
                <option value="bar">bar</option>
                <option value="psi">psi</option>
              </select>
            </label>
            {#if exportNotice}<span class="export-notice">{exportNotice}</span>{/if}
          </div>
          <div class="tire-list">
            {#each results.tireSetups as setup, i}
              <div class="tire-card" class:best={i === 0}>
                {#if i === 0}<span class="badge-best">Beste Wahl</span>{/if}
                <div class="tire-header">
                  <span class="tire-name">
                    {setup.frontTire.brand} {setup.frontTire.model}
                    {#if setup.frontTire.id !== setup.rearTire.id}
                      / {setup.rearTire.brand} {setup.rearTire.model}
                    {/if}
                  </span>
                  <span class="tire-score">{setup.overallScore}/100</span>
                </div>
                <div class="tire-specs">
                  <div class="spec-block">
                    <span class="spec-label">Vorne</span>
                    <span class="spec-val">{setup.frontWidthMm}mm · {pressureLabel(setup.pressureFrontBar)}</span>
                  </div>
                  <div class="spec-block">
                    <span class="spec-label">Hinten</span>
                    <span class="spec-val">{setup.rearWidthMm}mm · {pressureLabel(setup.pressureRearBar)}</span>
                  </div>
                  <div class="spec-block">
                    <span class="spec-label">Crr eff.</span>
                    <span class="spec-val">{(setup.crrEffective * 1000).toFixed(2)} ‰</span>
                  </div>
                  <div class="spec-block">
                    <span class="spec-label">Est. Zeit</span>
                    <span class="spec-val">{formatTime(setup.totalTimeSec)}</span>
                  </div>
                </div>
                <div class="score-bars">
                  <div class="score-row">
                    <span>Geschwindigkeit</span>
                    <div class="bar-bg"><div class="bar-fill speed" style="width:{setup.speedScore}%"></div></div>
                    <span>{setup.speedScore}</span>
                  </div>
                  <div class="score-row">
                    <span>Pannenschutz</span>
                    <div class="bar-bg"><div class="bar-fill puncture" style="width:{setup.punctureRiskScore}%"></div></div>
                    <span>{setup.punctureRiskScore}</span>
                  </div>
                  <div class="score-row">
                    <span>Handling</span>
                    <div class="bar-bg"><div class="bar-fill handling" style="width:{setup.handlingRiskScore}%"></div></div>
                    <span>{setup.handlingRiskScore}</span>
                  </div>
                </div>
                <div class="power-breakdown">
                  <span title="Rollwiderstand">🔄 {setup.powerBreakdown.rollingResistanceW.toFixed(0)} W</span>
                  <span title="Luftwiderstand">💨 {setup.powerBreakdown.aerodynamicW.toFixed(0)} W</span>
                  <span title="Schwerkraft">⛰ {setup.powerBreakdown.gravityW.toFixed(0)} W</span>
                  {#if setup.timeSavingVsWorstSec > 0}
                    <span class="time-saving">+{formatTime(setup.timeSavingVsWorstSec)} vs. Schlechtester</span>
                  {/if}
                </div>
                <div class="setup-actions">
                  <button type="button" on:click={() => copySetup(setup)}>Setup kopieren</button>
                  <button type="button" on:click={() => downloadSetup(setup)}>PNG exportieren</button>
                </div>
              </div>
            {/each}
          </div>
        </section>
        <section class="detail-crr-analysis" aria-label="Detail-CRR-Analyse">
          <div class="detail-crr-heading">
            <span>Detail-CRR-Analyse</span>
            <small>3D-Modellvergleich fuer den ausgewaehlten Reifen</small>
          </div>
          <CrrSurface3DChart
            setups={results.tireSetups}
            totalWeightKg={profile.riderWeightKg + profile.bikeWeightKg}
            tempCelsius={profile.ambientTempCelsius}
          />
        </section>
      {/if}
        </div> <!-- end .panel-scroll -->
      {/if} <!-- end analyse tab -->

      <!-- ── Karte tab ───────────────────────────────────────────── -->
      {#if activeTab === 'karte'}
        <div class="map-wrapper">
          <div bind:this={surfaceMapEl} class="map-full"></div>

          <!-- Color mode toggle -->
          <div class="map-controls">
            <button
              class="map-toggle"
              class:active={mapColorMode === 'surface'}
              on:click={() => mapColorMode = 'surface'}
            >Oberfläche</button>
            <button
              class="map-toggle"
              class:active={mapColorMode === 'iri'}
              on:click={() => mapColorMode = 'iri'}
            >IRI-Heatmap</button>
          </div>

          <!-- Legend overlay -->
          <div class="map-legend">
            {#if mapColorMode === 'surface'}
              {#each buildSurfaceBreakdown(results.surfaces) as seg}
                <div class="legend-row">
                  <span class="legend-dot" style="background:{surfaceColor(seg.cat)}"></span>
                  <span class="legend-lbl">{surfaceLabel(seg.cat)}</span>
                  <span class="legend-pct">{seg.pct}%</span>
                </div>
              {/each}
            {:else}
              {#each [['< 2','#22c55e','Sehr glatt'],['2–4','#84cc16','Gut'],['4–6','#f59e0b','Mäßig'],['6–9','#ef4444','Rau'],['≥ 9','#991b1b','Sehr rau']] as [range, col, lbl]}
                <div class="legend-row">
                  <span class="legend-dot" style="background:{col}"></span>
                  <span class="legend-lbl">{lbl}</span>
                  <span class="legend-pct" style="color:#8b949e">{range} m/km</span>
                </div>
              {/each}
            {/if}
          </div>

          <!-- Track stats bar -->
          <div class="map-stats">
            <span>📏 {formatKm(results.track.totalDistance)}</span>
            <span>🔢 {results.surfaces.length} Segmente</span>
            {#if results.surfaces.filter(s => s.measuredIri != null).length > 0}
              <span>📡 {results.surfaces.filter(s => s.measuredIri != null).length} mit Sensor-IRI</span>
            {/if}
            {#if results.rideInfo.avgIri}
              {@const q = iriQuality(results.rideInfo.avgIri)}
              <span>Ø IRI <b style="color:{q.color}">{results.rideInfo.avgIri.toFixed(1)}</b> m/km</span>
            {/if}
          </div>
        </div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .page {
    display: grid;
    grid-template-columns: 300px 1fr;
    height: 100%;
    overflow: hidden;
  }

  /* ── Left panel ── */
  .panel-left {
    background: #161b22;
    border-right: 1px solid #30363d;
    padding: 20px 16px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .section-title {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.08em;
    color: #8b949e;
    text-transform: uppercase;
    margin-bottom: 8px;
    flex-shrink: 0;
  }

  .form-grid {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .field { display: flex; flex-direction: column; gap: 3px; }
  .field span { font-size: 12px; color: #8b949e; }
  .field input[type="number"],
  .field input[type="text"],
  .field input[type="password"] {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #e6edf3;
    font-size: 13px;
    padding: 5px 8px;
    width: 100%;
  }
  .field input[type="range"] { padding: 2px 0; width: 100%; }
  .field.checkbox { flex-direction: row; align-items: center; gap: 8px; }
  .field.checkbox span { color: #e6edf3; }
  .range-val { font-size: 11px; color: #2dd4bf; text-align: right; }

  /* Source tabs */
  .source-tabs {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 4px;
    margin-bottom: 10px;
  }
  .source-tabs button {
    background: #0d1117;
    border: 1px solid #30363d;
    color: #8b949e;
    border-radius: 6px;
    padding: 6px 2px;
    font-size: 10px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .source-tabs button.active {
    border-color: #2dd4bf;
    color: #2dd4bf;
    background: #2dd4bf11;
  }
  .source-tabs button:hover:not(.active) { border-color: #6b7280; color: #e6edf3; }

  /* Upload zone */
  .upload-zone {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    border: 2px dashed #30363d;
    border-radius: 8px;
    padding: 16px 12px;
    cursor: pointer;
    text-align: center;
    font-size: 12px;
    color: #8b949e;
    min-height: 70px;
    transition: border-color 0.15s;
    margin-bottom: 4px;
  }
  .upload-zone:hover { border-color: #2dd4bf; }
  .upload-zone input { display: none; }
  .upload-ok { color: #2dd4bf; font-weight: 600; font-size: 12px; }
  .upload-zone small { font-size: 11px; margin-top: 2px; display: block; }

  /* intervals.icu / Strava */
  .btn-secondary {
    background: #0d1117;
    border: 1px solid #30363d;
    color: #e6edf3;
    border-radius: 6px;
    padding: 7px 12px;
    font-size: 13px;
    cursor: pointer;
    width: 100%;
    margin-top: 4px;
    transition: border-color 0.15s;
  }
  .btn-secondary:hover:not(:disabled) { border-color: #8b949e; }
  .btn-secondary:disabled { opacity: 0.5; cursor: not-allowed; }
  .link-btn { display: inline-flex; text-decoration: none; margin-top: 8px; }

  .central-ride-card {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 10px 12px;
    background: #0d1117;
    border: 1px solid #2dd4bf55;
    border-radius: 8px;
  }
  .central-ride-card span {
    color: #8b949e;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .central-ride-card strong { color: #e6edf3; font-size: 13px; }
  .central-ride-card a { color: #2dd4bf; font-size: 12px; text-decoration: none; }
  .central-ride-card a:hover { text-decoration: underline; }

  .btn-strava {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    background: #fc4c02;
    border: none;
    border-radius: 6px;
    color: #fff;
    font-size: 13px;
    font-weight: 600;
    padding: 9px;
    cursor: pointer;
    width: 100%;
    transition: opacity 0.15s;
  }
  .btn-strava:hover { opacity: 0.88; }

  .strava-connected {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: #e6edf3;
    padding: 6px 0;
  }
  .strava-connected span { flex: 1; }
  .btn-text {
    background: none;
    border: none;
    color: #8b949e;
    font-size: 12px;
    cursor: pointer;
    padding: 0;
    text-decoration: underline;
  }

  .ride-select {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #e6edf3;
    font-size: 12px;
    padding: 6px 8px;
    width: 100%;
    margin-top: 4px;
    margin-bottom: 8px;
  }

  .btn-analyze {
    background: #2dd4bf;
    border: none;
    border-radius: 8px;
    color: #0d1117;
    font-weight: 700;
    font-size: 14px;
    padding: 10px;
    cursor: pointer;
    width: 100%;
    transition: opacity 0.15s;
    margin-top: 8px;
  }
  .btn-analyze:hover:not(:disabled) { opacity: 0.88; }
  .btn-analyze:disabled { opacity: 0.45; cursor: not-allowed; }

  .error-msg {
    font-size: 12px;
    color: #ef4444;
    margin-top: 4px;
    padding: 8px;
    background: #ef444411;
    border-radius: 6px;
    border: 1px solid #ef444433;
  }

  .hint {
    font-size: 12px;
    color: #8b949e;
    line-height: 1.5;
    margin-top: 4px;
  }

  /* Leaflet z-index fix */
  :global(.leaflet-pane),
  :global(.leaflet-top),
  :global(.leaflet-bottom) { z-index: 400; }
  .map-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 6px 14px;
    padding: 10px 16px;
    border-top: 1px solid #30363d;
  }

  /* ── Right panel ── */
  .panel-right {
    display: flex;
    flex-direction: column;
    overflow: hidden;
    padding: 0;
    /* must be explicit so child map-wrapper can use flex:1 */
    min-height: 0;
    height: 100%;
  }

  /* scrollable wrapper inside Analyse tab */
  .panel-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* Tab bar */
  .tabs {
    display: flex;
    gap: 0;
    border-bottom: 1px solid #30363d;
    background: #161b22;
    flex-shrink: 0;
  }
  .tabs button {
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    color: #8b949e;
    padding: 10px 20px;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: color 0.15s, border-color 0.15s;
    margin-bottom: -1px;
  }
  .tabs button:hover { color: #e6edf3; }
  .tabs button.active { color: #e6edf3; border-bottom-color: #2dd4bf; }

  /* Map fills remaining panel height */
  /* ── Map wrapper ── */
  .map-wrapper {
    position: relative;
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }
  /* position:absolute so Leaflet reads concrete pixel dimensions from the wrapper */
  .map-full {
    position: absolute;
    inset: 0;
  }

  .map-controls {
    position: absolute;
    top: 10px;
    right: 10px;
    z-index: 1000;
    display: flex;
    background: #161b22ee;
    border: 1px solid #30363d;
    border-radius: 6px;
    overflow: hidden;
  }
  .map-toggle {
    background: none;
    border: none;
    color: #8b949e;
    font-size: 12px;
    padding: 5px 10px;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }
  .map-toggle.active { background: #2dd4bf22; color: #2dd4bf; }
  .map-toggle:not(.active):hover { color: #e6edf3; }

  .map-legend {
    position: absolute;
    bottom: 36px;
    left: 10px;
    z-index: 1000;
    background: #161b22ee;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    max-height: 260px;
    overflow-y: auto;
  }
  .legend-row {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    white-space: nowrap;
  }
  .legend-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
  .legend-lbl { color: #e6edf3; flex: 1; }
  .legend-pct { color: #2dd4bf; font-variant-numeric: tabular-nums; }

  .map-stats {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    z-index: 1000;
    background: #161b22ee;
    border-top: 1px solid #30363d;
    padding: 5px 12px;
    display: flex;
    gap: 16px;
    font-size: 12px;
    color: #8b949e;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    height: 100%;
    padding: 20px;
    color: #8b949e;
    text-align: center;
    max-width: 460px;
    margin: 0 auto;
  }
  .empty-state .hint { text-align: left; line-height: 1.8; }
  .empty-icon { font-size: 48px; }

  .spinner {
    width: 32px; height: 32px;
    border: 3px solid #30363d;
    border-top-color: #2dd4bf;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ── Cards ── */
  .card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
    padding: 16px 20px;
  }
  .card-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 14px;
  }
  .card-header h3 { font-size: 14px; font-weight: 600; color: #e6edf3; margin: 0; }
  .card h3 { font-size: 14px; font-weight: 600; margin-bottom: 14px; color: #e6edf3; }
  .detail-crr-analysis {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .detail-crr-heading {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
    padding: 0 2px;
  }
  .detail-crr-heading span {
    color: #e6edf3;
    font-size: 14px;
    font-weight: 700;
  }
  .detail-crr-heading small {
    color: #8b949e;
    font-size: 12px;
    text-align: right;
  }

  /* Source badge */
  .source-badge {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.06em;
    border-radius: 4px;
    padding: 2px 7px;
    white-space: nowrap;
    flex-shrink: 0;
  }
  .src-supabase  { background: #2dd4bf22; color: #2dd4bf; border: 1px solid #2dd4bf44; }
  .src-upload    { background: #6366f122; color: #818cf8; border: 1px solid #6366f144; }
  .src-intervals { background: #f59e0b22; color: #fbbf24; border: 1px solid #f59e0b44; }
  .src-strava    { background: #fc4c0222; color: #fc4c02; border: 1px solid #fc4c0244; }

  /* Surface bar */
  .surface-bar {
    display: flex;
    height: 18px;
    border-radius: 6px;
    overflow: hidden;
    margin-bottom: 10px;
    gap: 1px;
  }
  .surface-segment { height: 100%; min-width: 2px; transition: opacity 0.15s; }
  .surface-segment:hover { opacity: 0.8; }

  .surface-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    margin-bottom: 10px;
  }
  .legend-item { display: flex; align-items: center; gap: 5px; font-size: 12px; color: #8b949e; }
  .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }

  .meta-row {
    display: flex;
    gap: 20px;
    font-size: 12px;
    color: #8b949e;
    flex-wrap: wrap;
  }

  /* Tire cards */
  .tire-list { display: flex; flex-direction: column; gap: 12px; }
  .toolbar-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin: -2px 0 12px;
    font-size: 12px;
    color: #8b949e;
  }
  .toolbar-row label { display: flex; align-items: center; gap: 8px; }
  .toolbar-row select {
    background: #0d1117;
    color: #e6edf3;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 4px 8px;
  }
  .export-notice { color: #2dd4bf; }

  .tire-card {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 14px 16px;
    position: relative;
  }
  .tire-card.best { border-color: #2dd4bf55; background: #2dd4bf08; }

  .badge-best {
    position: absolute;
    top: 10px; right: 12px;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.06em;
    background: #2dd4bf22;
    color: #2dd4bf;
    border: 1px solid #2dd4bf55;
    border-radius: 4px;
    padding: 2px 7px;
  }

  .tire-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
    padding-right: 90px;
  }
  .tire-name  { font-size: 14px; font-weight: 600; color: #e6edf3; }
  .tire-score { font-size: 18px; font-weight: 700; color: #2dd4bf; }

  .tire-specs {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 8px;
    margin-bottom: 12px;
  }
  .spec-block { display: flex; flex-direction: column; gap: 2px; }
  .spec-label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: #8b949e; }
  .spec-val   { font-size: 13px; font-weight: 600; color: #e6edf3; }

  .score-bars { display: flex; flex-direction: column; gap: 5px; margin-bottom: 10px; }
  .score-row {
    display: grid;
    grid-template-columns: 100px 1fr 32px;
    gap: 8px;
    align-items: center;
    font-size: 12px;
    color: #8b949e;
  }
  .bar-bg { height: 6px; background: #30363d; border-radius: 3px; overflow: hidden; }
  .bar-fill { height: 100%; border-radius: 3px; transition: width 0.4s ease; }
  .bar-fill.speed    { background: #2dd4bf; }
  .bar-fill.puncture { background: #f59e0b; }
  .bar-fill.handling { background: #6366f1; }
  .score-row span:last-child { text-align: right; font-weight: 600; color: #e6edf3; }

  .power-breakdown {
    display: flex;
    gap: 16px;
    font-size: 12px;
    color: #8b949e;
    flex-wrap: wrap;
    border-top: 1px solid #30363d;
    padding-top: 8px;
    margin-top: 4px;
  }
  .time-saving { margin-left: auto; color: #2dd4bf; font-weight: 600; }
  .setup-actions {
    display: flex;
    gap: 8px;
    margin-top: 10px;
  }
  .setup-actions button {
    background: #1c2333;
    color: #e6edf3;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 6px 10px;
    font-size: 12px;
    cursor: pointer;
  }
  .setup-actions button:hover { border-color: #2dd4bf; color: #2dd4bf; }
</style>

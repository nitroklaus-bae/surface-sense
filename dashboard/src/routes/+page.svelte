<script>
  import { onMount, onDestroy } from 'svelte';
  import { fetchRides, fetchSamples, deleteRide,
           fmtDuration, fmtDistance, fmtDate, iriColor, iriLabel } from '$lib/supabase.js';
  import RideChart from '$lib/RideChart.svelte';

  let rides = [];
  let isAdminUser = false;
  let selectedRide = null;
  let compareRide = null;       // zweite Fahrt im Vergleichsmodus
  let compareMode = false;
  let samples = [];
  let compareSamples = [];
  let loadingRides = true;
  let loadingSamples = false;
  let error = '';
  let map = null;
  let L = null;
  let markers = [];
  let mapEl;
  let showChart = false;

  // ── Stats ─────────────────────────────────────────────────────────────────
  $: totalDist  = rides.reduce((s, r) => s + (r.distance_m ?? 0), 0);
  $: totalRides = rides.length;
  $: avgIri     = rides.filter(r => r.avg_iri).length
    ? rides.filter(r => r.avg_iri).reduce((s, r) => s + r.avg_iri, 0) / rides.filter(r => r.avg_iri).length
    : null;

  onMount(async () => {
    await loadRides();
    await initMap();
  });

  onDestroy(() => { map?.remove(); });

  async function loadRides() {
    loadingRides = true;
    try {
      const result = await fetchRides();
      rides = result.rides;
      isAdminUser = result.admin;
      if (rides.length > 0) selectRide(rides[0]);
    } catch (e) {
      error = e.message;
    } finally {
      loadingRides = false;
    }
  }

  async function initMap() {
    // Leaflet nur im Browser laden (kein SSR)
    L = (await import('leaflet')).default;
    await import('leaflet/dist/leaflet.css');

    map = L.map(mapEl, {
      center: [48.137, 11.576],   // München als Fallback
      zoom: 13,
      zoomControl: true,
    });

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '© OpenStreetMap',
      maxZoom: 19,
    }).addTo(map);
  }

  async function selectRide(ride) {
    if (compareMode) {
      // Im Vergleichsmodus: zweite Fahrt setzen (nicht dieselbe wie erste)
      if (ride?.id === selectedRide?.id) return;
      compareRide = ride;
      compareSamples = [];
      if (!ride) { drawMap(samples, []); return; }
      loadingSamples = true;
      try {
        compareSamples = await fetchSamples(ride.id);
        drawMap(samples, compareSamples);
      } catch(e) { console.error(e); }
      finally { loadingSamples = false; }
      return;
    }

    // Normalmodus
    selectedRide = ride;
    compareRide = null;
    compareSamples = [];
    samples = [];
    if (!ride) return;

    loadingSamples = true;
    try {
      samples = await fetchSamples(ride.id);
      drawMap(samples, []);
    } catch(e) {
      console.error(e);
    } finally {
      loadingSamples = false;
    }
  }

  function toggleCompareMode() {
    compareMode = !compareMode;
    if (!compareMode) {
      compareRide = null;
      compareSamples = [];
      drawMap(samples, []);
    }
  }

  // Farbe für Ride A (IRI-basiert teal) vs Ride B (lila)
  function iriColorB(iri) {
    if (iri == null) return '#a855f7';
    if (iri < 2)    return '#c084fc';
    if (iri < 5)    return '#a855f7';
    if (iri < 8)    return '#9333ea';
    return '#7e22ce';
  }

  function drawMap(ptsA, ptsB) {
    if (!map || !L) return;

    markers.forEach(m => m.remove());
    markers = [];

    const validA = ptsA.filter(p => p.lat && p.lon);
    const validB = ptsB.filter(p => p.lat && p.lon);
    if (!validA.length && !validB.length) return;

    // Ride A — IRI-Farben (teal/grün/gelb/rot)
    validA.forEach(p => {
      const m = L.circleMarker([p.lat, p.lon], {
        radius: 5,
        color: iriColor(p.iri_m_km),
        fillColor: iriColor(p.iri_m_km),
        fillOpacity: 0.85,
        weight: 0,
      }).bindTooltip(
        `<b>Fahrt A</b><br>IRI: ${p.iri_m_km != null ? p.iri_m_km.toFixed(2) + ' m/km' : '—'}<br>RMS: ${(p.rms_g * 1000).toFixed(1)} mg`,
        { direction: 'top', offset: [0, -4] }
      );
      m.addTo(map);
      markers.push(m);
    });

    // Ride B — lila Töne
    validB.forEach(p => {
      const m = L.circleMarker([p.lat, p.lon], {
        radius: 5,
        color: iriColorB(p.iri_m_km),
        fillColor: iriColorB(p.iri_m_km),
        fillOpacity: 0.85,
        weight: 0,
      }).bindTooltip(
        `<b>Fahrt B</b><br>IRI: ${p.iri_m_km != null ? p.iri_m_km.toFixed(2) + ' m/km' : '—'}<br>RMS: ${(p.rms_g * 1000).toFixed(1)} mg`,
        { direction: 'top', offset: [0, -4] }
      );
      m.addTo(map);
      markers.push(m);
    });

    const allPts = [...validA, ...validB];
    const bounds = L.latLngBounds(allPts.map(p => [p.lat, p.lon]));
    map.fitBounds(bounds, { padding: [24, 24] });
  }

  async function handleDelete(ride) {
    if (!confirm(`Fahrt "${ride.name}" wirklich löschen?`)) return;
    try {
      await deleteRide(ride.id, ride.fit_path, ride.csv_path);
      rides = rides.filter(r => r.id !== ride.id);
      if (selectedRide?.id === ride.id) {
        selectedRide = null;
        samples = [];
        markers.forEach(m => m.remove());
        markers = [];
      }
    } catch(e) {
      alert('Fehler: ' + e.message);
    }
  }
</script>

<svelte:head><title>SurfaceSense Dashboard</title></svelte:head>

<div class="layout">

  <!-- ── Linke Spalte: Stats + Ride-Liste ──────────────────────────────── -->
  <aside>
    <!-- Stats-Zeile -->
    <div class="stats-row">
      <div class="stat">
        <span class="stat-val">{totalRides}</span>
        <span class="stat-lbl">Fahrten</span>
      </div>
      <div class="stat">
        <span class="stat-val">{fmtDistance(totalDist)}</span>
        <span class="stat-lbl">Gesamt</span>
      </div>
      <div class="stat">
        <span class="stat-val" style="color:{iriColor(avgIri)}">
          {avgIri != null ? avgIri.toFixed(1) : '—'}
        </span>
        <span class="stat-lbl">Ø IRI m/km</span>
      </div>
    </div>

    <!-- Vergleichs-Toggle -->
    <div class="compare-bar">
      <button class="btn-compare" class:active={compareMode} on:click={toggleCompareMode}>
        {compareMode ? '✕ Vergleich beenden' : '⇄ Fahrten vergleichen'}
      </button>
      {#if compareMode}
        <span class="compare-hint">
          {compareRide ? `B: ${compareRide.name}` : 'Zweite Fahrt wählen →'}
        </span>
      {/if}
    </div>

    <!-- Ride-Liste -->
    <div class="ride-list">
      {#if loadingRides}
        <div class="center"><div class="spinner"></div></div>
      {:else if error}
        <div class="error">{error}</div>
      {:else if rides.length === 0}
        <div class="empty">Noch keine Fahrten.<br>Starte eine Aufnahme in der App.</div>
      {:else}
        {#each rides as ride (ride.id)}
          <button
            class="ride-card"
            class:selected={!compareMode && selectedRide?.id === ride.id}
            class:selected-a={compareMode && selectedRide?.id === ride.id}
            class:selected-b={compareMode && compareRide?.id === ride.id}
            on:click={() => selectRide(ride)}
          >
            <div class="ride-header">
              <span class="ride-name">{ride.name}</span>
              {#if compareMode && selectedRide?.id === ride.id}
                <span class="badge-ab badge-a">A</span>
              {:else if compareMode && compareRide?.id === ride.id}
                <span class="badge-ab badge-b">B</span>
              {:else}
                <button class="btn-delete" on:click|stopPropagation={() => handleDelete(ride)}
                  title="Löschen">✕</button>
              {/if}
            </div>
            {#if isAdminUser && ride.user_email}
              <div class="ride-user">{ride.user_email}</div>
            {/if}
            <div class="ride-date">{fmtDate(ride.started_at)}</div>
            <div class="ride-metrics">
              <span>⏱ {fmtDuration(ride.duration_s)}</span>
              <span>📍 {fmtDistance(ride.distance_m)}</span>
              <span style="color:{iriColor(ride.avg_iri)}">
                ◆ {ride.avg_iri != null ? ride.avg_iri.toFixed(1) + ' m/km' : '—'}
              </span>
            </div>
            {#if ride.avg_iri != null}
              <div class="iri-bar">
                <div class="iri-fill"
                  style="width:{Math.min(ride.avg_iri / 12 * 100, 100)}%;
                         background:{iriColor(ride.avg_iri)}">
                </div>
              </div>
            {/if}
          </button>
        {/each}
      {/if}
    </div>
  </aside>

  <!-- ── Rechte Spalte: Karte + Charts ─────────────────────────────────── -->
  <section class="right">

    <!-- Karte -->
    <div class="map-wrap">
      <div bind:this={mapEl} class="map"></div>

      <!-- Legende -->
      <div class="legend">
        <span style="color:#4ade80">● sehr glatt &lt;2</span>
        <span style="color:#facc15">● gut &lt;5</span>
        <span style="color:#f97316">● mäßig &lt;8</span>
        <span style="color:#f87171">● rau ≥8</span>
        <span class="legend-unit">IRI [m/km] · Fahrt A</span>
        {#if compareMode && compareRide}
          <span class="legend-unit" style="margin-top:4px; border-top:1px solid #30363d; padding-top:4px">
            <span style="color:#a855f7">●</span> Fahrt B (lila)
          </span>
        {/if}
      </div>

      {#if loadingSamples}
        <div class="map-overlay"><div class="spinner"></div></div>
      {/if}

      {#if selectedRide && samples.length === 0 && !loadingSamples}
        <div class="map-overlay muted">Keine GPS-Daten für diese Fahrt</div>
      {/if}
    </div>

    <!-- Detail-Info (kompakt, immer sichtbar) -->
    {#if selectedRide}
      <div class="detail">
        {#if compareMode && compareRide}
          <!-- ── Vergleichsmodus: Side-by-Side ────────────────────────────── -->
          <div class="compare-panels">
            <div class="compare-panel panel-a">
              <div class="panel-label">A</div>
              <div class="detail-header">
                <h2>{selectedRide.name}</h2>
                <div class="detail-meta">{fmtDate(selectedRide.started_at)} · {fmtDuration(selectedRide.duration_s)} · {fmtDistance(selectedRide.distance_m)}</div>
              </div>
              <div class="detail-metrics">
                <div class="metric">
                  <span class="metric-val">{selectedRide.avg_rms_g != null ? (selectedRide.avg_rms_g * 1000).toFixed(1) : '—'}</span>
                  <span class="metric-lbl">Ø RMS [mg]</span>
                </div>
                <div class="metric">
                  <span class="metric-val">{selectedRide.avg_vdv_g != null ? selectedRide.avg_vdv_g.toFixed(3) : '—'}</span>
                  <span class="metric-lbl">Ø VDV</span>
                </div>
                <div class="metric" style="color:{iriColor(selectedRide.avg_iri)}">
                  <span class="metric-val">{selectedRide.avg_iri != null ? selectedRide.avg_iri.toFixed(2) : '—'}</span>
                  <span class="metric-lbl">Ø IRI · {iriLabel(selectedRide.avg_iri)}</span>
                </div>
                <div class="metric" style="color:{iriColor(selectedRide.max_iri)}">
                  <span class="metric-val">{selectedRide.max_iri != null ? selectedRide.max_iri.toFixed(2) : '—'}</span>
                  <span class="metric-lbl">Max IRI</span>
                </div>
              </div>
            </div>

            <div class="compare-divider"></div>

            <div class="compare-panel panel-b">
              <div class="panel-label panel-label-b">B</div>
              <div class="detail-header">
                <h2>{compareRide.name}</h2>
                <div class="detail-meta">{fmtDate(compareRide.started_at)} · {fmtDuration(compareRide.duration_s)} · {fmtDistance(compareRide.distance_m)}</div>
              </div>
              <div class="detail-metrics">
                <div class="metric">
                  <span class="metric-val">{compareRide.avg_rms_g != null ? (compareRide.avg_rms_g * 1000).toFixed(1) : '—'}</span>
                  <span class="metric-lbl">Ø RMS [mg]</span>
                </div>
                <div class="metric">
                  <span class="metric-val">{compareRide.avg_vdv_g != null ? compareRide.avg_vdv_g.toFixed(3) : '—'}</span>
                  <span class="metric-lbl">Ø VDV</span>
                </div>
                <div class="metric" style="color:{iriColor(compareRide.avg_iri)}">
                  <span class="metric-val">{compareRide.avg_iri != null ? compareRide.avg_iri.toFixed(2) : '—'}</span>
                  <span class="metric-lbl">Ø IRI · {iriLabel(compareRide.avg_iri)}</span>
                </div>
                <div class="metric" style="color:{iriColor(compareRide.max_iri)}">
                  <span class="metric-val">{compareRide.max_iri != null ? compareRide.max_iri.toFixed(2) : '—'}</span>
                  <span class="metric-lbl">Max IRI</span>
                </div>
              </div>
            </div>
          </div>

        {:else}
          <!-- ── Normalmodus ──────────────────────────────────────────────── -->
          <div class="detail-row">
            <div class="detail-header">
              <h2>{selectedRide.name}</h2>
              <div class="detail-meta">
                {#if isAdminUser && selectedRide.user_email}
                  <span style="color:#2dd4bf">{selectedRide.user_email}</span> ·
                {/if}
                {fmtDate(selectedRide.started_at)} ·
                {fmtDuration(selectedRide.duration_s)} ·
                {fmtDistance(selectedRide.distance_m)}
              </div>
            </div>
            <div class="detail-metrics">
              <div class="metric">
                <span class="metric-val">{selectedRide.avg_rms_g != null ? (selectedRide.avg_rms_g * 1000).toFixed(1) : '—'}</span>
                <span class="metric-lbl">Ø RMS [mg]</span>
              </div>
              <div class="metric">
                <span class="metric-val">{selectedRide.avg_vdv_g != null ? selectedRide.avg_vdv_g.toFixed(3) : '—'}</span>
                <span class="metric-lbl">Ø VDV [g·s^0.25]</span>
              </div>
              <div class="metric" style="color:{iriColor(selectedRide.avg_iri)}">
                <span class="metric-val">{selectedRide.avg_iri != null ? selectedRide.avg_iri.toFixed(2) : '—'}</span>
                <span class="metric-lbl">Ø IRI [m/km] · {iriLabel(selectedRide.avg_iri)}</span>
              </div>
              <div class="metric" style="color:{iriColor(selectedRide.max_iri)}">
                <span class="metric-val">{selectedRide.max_iri != null ? selectedRide.max_iri.toFixed(2) : '—'}</span>
                <span class="metric-lbl">Max IRI [m/km]</span>
              </div>
            </div>
            {#if samples.length > 0}
              <button class="btn-chart" on:click={() => showChart = !showChart}
                title={showChart ? 'Chart verbergen' : 'Chart anzeigen'}>
                {showChart ? '▼' : '▲'} Chart
              </button>
            {/if}
          </div>
        {/if}
      </div>

      <!-- Chart: ausklappbar unter dem Detail-Panel -->
      {#if showChart && !compareMode && samples.length > 0}
        <div class="chart-panel">
          <RideChart {samples} />
        </div>
      {/if}
    {/if}
  </section>
</div>

<style>
  .layout {
    display: grid;
    grid-template-columns: 320px 1fr;
    height: 100%;
    overflow: hidden;
  }

  /* ── Linke Spalte ────────────────────────────────────────────────────── */
  aside {
    display: flex;
    flex-direction: column;
    border-right: 1px solid #30363d;
    overflow: hidden;
    background: #0d1117;
  }

  .stats-row {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 1px;
    background: #30363d;
    border-bottom: 1px solid #30363d;
    flex-shrink: 0;
  }
  .stat {
    background: #161b22;
    padding: 12px 8px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2px;
  }
  .stat-val { font-size: 18px; font-weight: 700; color: #e6edf3; }
  .stat-lbl { font-size: 10px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }

  .ride-list {
    flex: 1;
    overflow-y: auto;
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .ride-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 12px;
    cursor: pointer;
    text-align: left;
    width: 100%;
    transition: border-color 0.15s, background 0.15s;
  }
  .ride-card:hover { border-color: #8b949e; }
  .ride-card.selected { border-color: #2dd4bf; background: #0d2d2a; }

  .ride-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 4px;
  }
  .ride-name { font-size: 13px; font-weight: 600; color: #e6edf3; }
  .btn-delete {
    background: none; border: none;
    color: #6b7280; font-size: 11px; cursor: pointer;
    padding: 2px 4px; border-radius: 4px;
    transition: color 0.15s;
  }
  .btn-delete:hover { color: #f85149; }

  /* ── Vergleichs-Bar ──────────────────────────────────────────────────── */
  .compare-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px;
    border-bottom: 1px solid #30363d;
    flex-shrink: 0;
  }
  .btn-compare {
    background: none;
    border: 1px solid #30363d;
    color: #8b949e;
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 12px;
    cursor: pointer;
    transition: border-color 0.15s, color 0.15s;
    white-space: nowrap;
  }
  .btn-compare:hover { border-color: #8b949e; color: #e6edf3; }
  .btn-compare.active { border-color: #2dd4bf; color: #2dd4bf; }
  .compare-hint { font-size: 11px; color: #8b949e; }

  .ride-card.selected-a { border-color: #2dd4bf; background: #0d2d2a; }
  .ride-card.selected-b { border-color: #a855f7; background: #1a0d2a; }

  .badge-ab {
    font-size: 10px; font-weight: 700;
    padding: 1px 6px; border-radius: 4px;
  }
  .badge-a { background: #2dd4bf22; color: #2dd4bf; border: 1px solid #2dd4bf55; }
  .badge-b { background: #a855f722; color: #a855f7; border: 1px solid #a855f755; }

  /* ── Vergleichs-Panels ───────────────────────────────────────────────── */
  .compare-panels {
    display: grid;
    grid-template-columns: 1fr 1px 1fr;
    gap: 0;
  }
  .compare-panel { padding: 12px 16px; position: relative; }
  .compare-divider { background: #30363d; }
  .panel-label {
    position: absolute; top: 12px; right: 12px;
    font-size: 11px; font-weight: 700;
    background: #2dd4bf22; color: #2dd4bf;
    border: 1px solid #2dd4bf55;
    border-radius: 4px; padding: 1px 6px;
  }
  .panel-label-b { background: #a855f722; color: #a855f7; border-color: #a855f755; }

  .ride-user {
    font-size: 10px;
    color: #2dd4bf;
    margin-bottom: 3px;
    opacity: 0.8;
  }
  .ride-date { font-size: 11px; color: #8b949e; margin-bottom: 8px; }
  .ride-metrics {
    display: flex;
    gap: 10px;
    font-size: 12px;
    color: #8b949e;
    margin-bottom: 8px;
    flex-wrap: wrap;
  }

  .iri-bar {
    height: 3px;
    background: #21262d;
    border-radius: 2px;
    overflow: hidden;
  }
  .iri-fill { height: 100%; border-radius: 2px; transition: width 0.3s; }

  /* ── Rechte Spalte ───────────────────────────────────────────────────── */
  .right {
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .map-wrap {
    position: relative;
    flex: 1;
    min-height: 0;
  }
  .map { width: 100%; height: 100%; }

  .legend {
    position: absolute;
    bottom: 24px;
    right: 12px;
    background: rgba(13,17,23,0.85);
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 8px 12px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 11px;
    z-index: 1000;
    backdrop-filter: blur(4px);
  }
  .legend-unit { color: #8b949e; border-top: 1px solid #30363d; padding-top: 4px; margin-top: 2px; }

  .map-overlay {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(13,17,23,0.6);
    z-index: 999;
    font-size: 13px;
  }
  .map-overlay.muted { color: #8b949e; background: transparent; }

  /* ── Detail-Panel (kompakt, kein Chart hier) ───────────────────────── */
  .detail {
    border-top: 1px solid #30363d;
    padding: 10px 16px;
    background: #0d1117;
    flex-shrink: 0;
  }

  /* Normalmodus: alles in einer Zeile */
  .detail-row {
    display: flex;
    align-items: center;
    gap: 16px;
    flex-wrap: wrap;
  }

  .detail-header { flex-shrink: 0; }
  .detail-header h2 { font-size: 13px; font-weight: 700; color: #e6edf3; margin-bottom: 1px; }
  .detail-meta { font-size: 11px; color: #8b949e; }

  .detail-metrics {
    display: flex;
    gap: 20px;
    flex: 1;
    flex-wrap: wrap;
  }
  .metric { display: flex; flex-direction: column; gap: 1px; }
  .metric-val { font-size: 16px; font-weight: 700; color: #e6edf3; }
  .metric-lbl { font-size: 10px; color: #8b949e; }

  .btn-chart {
    background: none;
    border: 1px solid #30363d;
    color: #8b949e;
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 11px;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.15s, color 0.15s;
    flex-shrink: 0;
  }
  .btn-chart:hover { border-color: #8b949e; color: #e6edf3; }

  /* Ausklappbares Chart-Panel */
  .chart-panel {
    border-top: 1px solid #30363d;
    height: 200px;
    flex-shrink: 0;
    overflow: hidden;
    background: #0d1117;
  }

  /* ── Helpers ─────────────────────────────────────────────────────────── */
  .center { display: flex; justify-content: center; align-items: center; padding: 40px; }
  .spinner {
    width: 24px; height: 24px;
    border: 2px solid #30363d;
    border-top-color: #2dd4bf;
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  .error { color: #f85149; font-size: 13px; padding: 16px; }
  .empty { color: #8b949e; font-size: 13px; padding: 24px; text-align: center; line-height: 1.6; }
</style>

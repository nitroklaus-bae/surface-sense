<script>
  import { onMount, tick } from 'svelte'
  import { supabase } from '$lib/supabase.js'
  import { parseGPX, parseFIT, trackFromSurfaceSamples } from '$lib/rollex/trackParser'
  import {
    buildGrades, simulate, constantPower, strategyPower, fitInterpolatedPower,
    formatDuration, downsample, detectClimbs,
  } from '$lib/rollex/performanceModel'
  import { computeAirDensity } from '$lib/rollex/rollingResistance'

  // ── State ──────────────────────────────────────────────────────────────────
  let track       = null
  let powerFit    = null   // reference FIT track for scenario 2
  let Chart       = null
  let chartSpeed  = null, chartPower = null
  let chartElSpeed, chartElPower
  let results     = null   // { s1, s2, s3 } or null
  let analyzing   = false
  let error       = ''

  // Track source
  let source      = 'upload'
  let rides       = []
  let selectedId  = ''
  let loadingRides= false

  // Shared physics params
  let massKg      = 73
  let bikeMassKg  = 8
  let crrPreset   = 'road28'
  let crrCustom   = 0.0045
  let cdaPreset   = 'drops'
  let cdaCustom   = 0.32
  let tempC       = 20

  const CRR_MAP = {
    road25 : { label: 'Rennrad 25 mm', crr: 0.003  },
    road28 : { label: 'Rennrad 28 mm', crr: 0.0042 },
    gravel : { label: 'Gravel 40 mm',  crr: 0.007  },
    mtb    : { label: 'MTB 2.1"',      crr: 0.012  },
    custom : { label: 'Manuell',       crr: null   },
  }
  const CDA_MAP = {
    tt    : { label: 'TT / Aerobar',    cda: 0.22 },
    drops : { label: 'Im Unterlenker',  cda: 0.32 },
    hoods : { label: 'Auf den Griffen', cda: 0.38 },
    mtb   : { label: 'MTB aufrecht',    cda: 0.50 },
    custom: { label: 'Manuell',         cda: null },
  }

  $: crrEff    = crrPreset === 'custom' ? crrCustom : (CRR_MAP[crrPreset]?.crr ?? 0.004)
  $: cdaEff    = cdaPreset === 'custom' ? cdaCustom : (CDA_MAP[cdaPreset]?.cda ?? 0.32)
  $: totalMass = massKg + bikeMassKg

  // Szenario 1 — Konstante Wattvorgabe
  let constWatts  = 220

  // Szenario 2 — Watt aus FIT-Datei
  let fitScalePct = 100

  // Szenario 3 — Pacing-Strategie
  let stratWatts  = 220
  let stratType   = 'mountain'

  $: canRun = !analyzing && !!track

  // Scenario display colors
  const S_COLORS = ['#2dd4bf', '#f59e0b', '#a78bfa']
  const S_LABELS = ['Konstante Watt', 'FIT-Datei', 'Pacing-Strategie']

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  onMount(async () => {
    const script = document.createElement('script')
    script.src = 'https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js'
    script.onload = () => { Chart = window.Chart }
    document.head.appendChild(script)
  })

  // ── Track loading ──────────────────────────────────────────────────────────
  function handleTrackFile(e) {
    const file = e.target.files?.[0]
    if (!file) return
    error = ''; track = null; results = null
    const reader = new FileReader()
    reader.onload = ev => {
      try {
        if (file.name.toLowerCase().endsWith('.gpx'))
          track = parseGPX(new TextDecoder().decode(ev.target.result))
        else
          track = parseFIT(ev.target.result)
        if (track.points.length < 2) { track = null; error = 'Track enthält keine GPS-Punkte' }
      } catch (ex) { error = 'Ladefehler: ' + ex.message }
    }
    file.name.toLowerCase().endsWith('.gpx')
      ? reader.readAsText(file)
      : reader.readAsArrayBuffer(file)
  }

  function handlePowerFile(e) {
    const file = e.target.files?.[0]
    if (!file) return
    error = ''; powerFit = null
    const reader = new FileReader()
    reader.onload = ev => {
      try {
        const t = parseFIT(ev.target.result)
        if (!t.hasPowerData) { error = 'FIT-Datei enthält keine Leistungsdaten'; return }
        powerFit = t
      } catch (ex) { error = 'FIT-Fehler: ' + ex.message }
    }
    reader.readAsArrayBuffer(file)
  }

  async function loadSupabaseRides() {
    loadingRides = true
    const { data } = await supabase
      .from('rides')
      .select('id,name,started_at,fit_path,avg_rms_g')
      .order('started_at', { ascending: false })
      .limit(50)
    rides = data ?? []
    if (rides.length) selectedId = rides[0].id
    loadingRides = false
  }

  async function loadSupabaseTrack() {
    if (!selectedId) return
    error = ''; track = null; results = null; analyzing = true
    const ride = rides.find(r => r.id === selectedId)
    try {
      if (ride?.fit_path) {
        const { data: blob } = await supabase.storage.from('ride-files').download(ride.fit_path)
        if (blob) { track = parseFIT(await blob.arrayBuffer()); analyzing = false; return }
      }
      const { data: rows } = await supabase
        .from('surface_samples')
        .select('ts_ms,lat,lon,speed_kmh')
        .eq('ride_id', selectedId)
        .order('ts_ms')
      track = trackFromSurfaceSamples(rows ?? [])
    } catch (ex) { error = 'Fehler: ' + ex.message }
    analyzing = false
  }

  // ── Simulation — alle 3 Szenarien gleichzeitig ────────────────────────────
  async function run() {
    if (!canRun) return
    analyzing = true; error = ''; results = null

    try {
      const rhoAir = computeAirDensity(tempC)
      const params = { totalMassKg: totalMass, cdA: cdaEff, crrEff, rhoAir }
      const n      = track.points.length - 1
      const { grades } = buildGrades(track)

      // Szenario 1: Konstante Watt
      const p1 = constantPower(n, constWatts)
      const s1 = simulate(track, p1, params)

      // Szenario 2: FIT-Datei (optional)
      let s2 = null
      if (powerFit) {
        const p2 = fitInterpolatedPower(powerFit, track, fitScalePct / 100)
        s2 = simulate(track, p2, params)
      }

      // Szenario 3: Pacing-Strategie
      const p3 = strategyPower(grades, stratWatts, stratType)
      const s3 = simulate(track, p3, params)

      results = { s1, s2, s3 }
    } catch (ex) {
      error = ex.message
    }

    analyzing = false
    await tick()
    if (results) drawCharts()
  }

  // ── Charts ────────────────────────────────────────────────────────────────
  function drawCharts() {
    if (!Chart || !results) return
    const { s1, s2, s3 } = results

    const pts1   = downsample(s1.points, 300)
    const labels = pts1.map(p => p.distKm.toFixed(2))

    // Speed chart
    chartSpeed?.destroy()
    const speedDatasets = [
      {
        label: S_LABELS[0],
        data: pts1.map(p => +p.speedKmh.toFixed(1)),
        borderColor: S_COLORS[0], borderWidth: 2, pointRadius: 0, tension: 0.2, fill: false,
      },
    ]
    if (s2) {
      const pts2 = downsample(s2.points, 300)
      speedDatasets.push({
        label: S_LABELS[1],
        data: pts2.map(p => +p.speedKmh.toFixed(1)),
        borderColor: S_COLORS[1], borderWidth: 2, pointRadius: 0, tension: 0.2, fill: false,
      })
    }
    const pts3 = downsample(s3.points, 300)
    speedDatasets.push({
      label: S_LABELS[2],
      data: pts3.map(p => +p.speedKmh.toFixed(1)),
      borderColor: S_COLORS[2], borderWidth: 2, pointRadius: 0, tension: 0.2, fill: false,
    })
    speedDatasets.push({
      label: 'Höhe (m)',
      data: pts1.map(p => +p.elevM.toFixed(0)),
      yAxisID: 'yElev', borderColor: '#30363d', borderWidth: 1,
      backgroundColor: '#30363d44', pointRadius: 0, tension: 0.3, fill: true, order: 10,
    })

    chartSpeed = new Chart(chartElSpeed, {
      data: { labels, datasets: speedDatasets },
      options: {
        animation: false, responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { labels: { color: '#8b949e', font: { size: 12 } } },
          tooltip: { backgroundColor: '#1c2333', titleColor: '#e6edf3', bodyColor: '#8b949e',
            callbacks: { title: i => `${i[0]?.label} km` } },
        },
        scales: {
          x: { ticks: { color: '#8b949e', maxTicksLimit: 10, font: { size: 11 } },
               grid: { color: '#21262d' },
               title: { display: true, text: 'Distanz (km)', color: '#8b949e' } },
          y: { position: 'left', ticks: { color: '#8b949e', font: { size: 11 } },
               grid: { color: '#21262d' },
               title: { display: true, text: 'Geschw. (km/h)', color: '#8b949e' } },
          yElev: { position: 'right', ticks: { color: '#4b5563', font: { size: 10 } },
                   grid: { drawOnChartArea: false },
                   title: { display: true, text: 'Höhe (m)', color: '#4b5563' } },
        },
      },
    })

    // Power chart
    chartPower?.destroy()
    const powerDatasets = [
      {
        label: S_LABELS[0],
        data: pts1.map(p => +p.powerW.toFixed(0)),
        borderColor: S_COLORS[0], borderWidth: 2, pointRadius: 0, tension: 0.2, fill: false,
      },
    ]
    if (s2) {
      const pts2d = downsample(s2.points, 300)
      powerDatasets.push({
        label: S_LABELS[1],
        data: pts2d.map(p => +p.powerW.toFixed(0)),
        borderColor: S_COLORS[1], borderWidth: 2, pointRadius: 0, tension: 0.2, fill: false,
      })
    }
    powerDatasets.push({
      label: S_LABELS[2],
      data: pts3.map(p => +p.powerW.toFixed(0)),
      borderColor: S_COLORS[2], borderWidth: 2, pointRadius: 0, tension: 0.2, fill: false,
    })

    chartPower = new Chart(chartElPower, {
      data: { labels, datasets: powerDatasets },
      options: {
        animation: false, responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { labels: { color: '#8b949e', font: { size: 12 } } },
          tooltip: { backgroundColor: '#1c2333', titleColor: '#e6edf3', bodyColor: '#8b949e',
            callbacks: { title: i => `${i[0]?.label} km` } },
        },
        scales: {
          x: { ticks: { color: '#8b949e', maxTicksLimit: 10, font: { size: 11 } },
               grid: { color: '#21262d' },
               title: { display: true, text: 'Distanz (km)', color: '#8b949e' } },
          y: { position: 'left', ticks: { color: '#8b949e', font: { size: 11 } },
               grid: { color: '#21262d' },
               title: { display: true, text: 'Leistung (W)', color: '#8b949e' } },
        },
      },
    })
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  $: climbs = results ? detectClimbs(results.s1.points) : []

  function wkg(w) { return massKg > 0 ? (w / massKg).toFixed(2) : '–' }

  function timeDiff(base, other) {
    if (!base || !other) return ''
    const d = other.totalTimeSec - base.totalTimeSec
    if (Math.abs(d) < 1) return '='
    return d > 0 ? `+${formatDuration(d)}` : `−${formatDuration(-d)}`
  }

  function diffClass(base, other) {
    if (!base || !other) return ''
    const d = other.totalTimeSec - base.totalTimeSec
    if (Math.abs(d) < 1) return ''
    return d > 0 ? 'slower' : 'faster'
  }
</script>

<div class="layout">
  <!-- ── Left: Inputs ──────────────────────────────────────────────────── -->
  <div class="panel-left">
    <div class="panel-title">⚡ Performance Vergleich</div>

    <!-- Track source -->
    <section class="section">
      <div class="section-label">Strecke</div>
      <div class="toggle-row">
        <button class:active={source === 'upload'} on:click={() => source = 'upload'}>Upload</button>
        <button class:active={source === 'supabase'} on:click={() => { source = 'supabase'; loadSupabaseRides() }}>Eigene Fahrten</button>
      </div>

      {#if source === 'upload'}
        <label class="file-label">
          <span>GPX / FIT wählen</span>
          <input type="file" accept=".gpx,.fit" on:change={handleTrackFile} />
        </label>
        {#if track}
          <div class="info-chip ok">
            ✓ {track.points.length} Pkt · {(track.totalDistance/1000).toFixed(1)} km · {track.totalElevGain.toFixed(0)} m ↑
            {#if track.hasPowerData}<span class="badge">⚡ Power</span>{/if}
          </div>
        {/if}
      {:else}
        {#if loadingRides}
          <div class="info-chip">Lade Fahrten…</div>
        {:else if rides.length === 0}
          <div class="info-chip warn">Keine Fahrten gefunden</div>
        {:else}
          <select bind:value={selectedId} class="sel">
            {#each rides as r}
              <option value={r.id}>{r.name ?? r.id.slice(0,8)} — {r.started_at?.slice(0,10)}</option>
            {/each}
          </select>
          <button class="btn-secondary" on:click={loadSupabaseTrack} disabled={analyzing}>Laden</button>
          {#if track}
            <div class="info-chip ok">✓ {track.points.length} Punkte geladen</div>
          {/if}
        {/if}
      {/if}
    </section>

    <!-- Physik -->
    <section class="section">
      <div class="section-label">Physik (geteilt)</div>
      <div class="param-row">
        <label>Fahrer<span class="unit">kg</span></label>
        <input type="number" bind:value={massKg} min="40" max="150" step="1" class="num-in" />
      </div>
      <div class="param-row">
        <label>Rad<span class="unit">kg</span></label>
        <input type="number" bind:value={bikeMassKg} min="5" max="30" step="0.5" class="num-in" />
      </div>
      <div class="param-row sm"><span class="dim">Gesamt: {totalMass.toFixed(1)} kg</span></div>

      <div class="param-row">
        <label>Position / CdA</label>
        <select bind:value={cdaPreset} class="sel-sm">
          {#each Object.entries(CDA_MAP) as [k, v]}
            <option value={k}>{v.label}{v.cda != null ? ` (${v.cda})` : ''}</option>
          {/each}
        </select>
      </div>
      {#if cdaPreset === 'custom'}
        <div class="param-row">
          <label>CdA m²</label>
          <input type="number" bind:value={cdaCustom} min="0.15" max="0.8" step="0.01" class="num-in" />
        </div>
      {/if}

      <div class="param-row">
        <label>Bereifung / Crr</label>
        <select bind:value={crrPreset} class="sel-sm">
          {#each Object.entries(CRR_MAP) as [k, v]}
            <option value={k}>{v.label}{v.crr != null ? ` (${v.crr})` : ''}</option>
          {/each}
        </select>
      </div>
      {#if crrPreset === 'custom'}
        <div class="param-row">
          <label>Crr</label>
          <input type="number" bind:value={crrCustom} min="0.001" max="0.05" step="0.0005" class="num-in" />
        </div>
      {/if}

      <div class="param-row">
        <label>Temperatur<span class="unit">°C</span></label>
        <input type="number" bind:value={tempC} min="-10" max="45" step="1" class="num-in" />
      </div>
    </section>

    <!-- Szenario 1 -->
    <section class="section scenario-section" style="--sc: {S_COLORS[0]}">
      <div class="section-label">
        <span class="sc-dot" style="background:{S_COLORS[0]}"></span>
        Szenario 1 — Konstante Watt
      </div>
      <div class="param-row">
        <label>Leistung<span class="unit">W</span></label>
        <input type="number" bind:value={constWatts} min="50" max="600" step="5" class="num-in" />
      </div>
      <input type="range" bind:value={constWatts} min="50" max="600" step="5" class="slider" style="accent-color:{S_COLORS[0]}" />
      <div class="param-row sm"><span class="dim">{wkg(constWatts)} W/kg · gleichmäßig</span></div>
    </section>

    <!-- Szenario 2 -->
    <section class="section scenario-section" style="--sc: {S_COLORS[1]}">
      <div class="section-label">
        <span class="sc-dot" style="background:{S_COLORS[1]}"></span>
        Szenario 2 — Watt aus FIT-Datei
      </div>
      <div class="section-hint">FIT-Datei mit Leistungsdaten als Referenzfahrt</div>
      <label class="file-label">
        <span>Leistungs-FIT wählen</span>
        <input type="file" accept=".fit" on:change={handlePowerFile} />
      </label>
      {#if powerFit}
        <div class="info-chip ok">✓ {powerFit.points.length} Pkt · Ø {powerFit.avgPower?.toFixed(0) ?? '?'} W</div>
      {:else}
        <div class="info-chip warn">Kein FIT → Szenario 2 wird übersprungen</div>
      {/if}
      <div class="param-row">
        <label>Skalierung<span class="unit">%</span></label>
        <input type="number" bind:value={fitScalePct} min="50" max="150" step="5" class="num-in" />
      </div>
      <input type="range" bind:value={fitScalePct} min="50" max="150" step="5" class="slider" style="accent-color:{S_COLORS[1]}" />
      <div class="param-row sm"><span class="dim">100 % = identische Leistung</span></div>
    </section>

    <!-- Szenario 3 -->
    <section class="section scenario-section" style="--sc: {S_COLORS[2]}">
      <div class="section-label">
        <span class="sc-dot" style="background:{S_COLORS[2]}"></span>
        Szenario 3 — Pacing-Strategie
      </div>
      <div class="param-row">
        <label>Ziel-Ø<span class="unit">W</span></label>
        <input type="number" bind:value={stratWatts} min="50" max="600" step="5" class="num-in" />
      </div>
      <input type="range" bind:value={stratWatts} min="50" max="600" step="5" class="slider" style="accent-color:{S_COLORS[2]}" />
      <div class="param-row sm"><span class="dim">{wkg(stratWatts)} W/kg Zieldurchschnitt</span></div>
      <div class="param-row">
        <label>Strategie</label>
        <select bind:value={stratType} class="sel-sm">
          <option value="constant">Gleichmäßig</option>
          <option value="mountain">Bergoptimiert</option>
          <option value="negative_split">Negative Split</option>
        </select>
      </div>
      <div class="strategy-info">
        {#if stratType === 'constant'}
          Konstant auf jedem Abschnitt — optimal auf flachen Strecken.
        {:else if stratType === 'mountain'}
          +25 % bergauf, −35 % bergab, normalisiert auf Ziel-Ø.
        {:else}
          1. Hälfte 94 %, 2. Hälfte 106 % der Zielleistung.
        {/if}
      </div>
    </section>

    <button class="btn-run" on:click={run} disabled={!canRun}>
      {#if analyzing}Berechne alle Szenarien…{:else}▶ Alle 3 vergleichen{/if}
    </button>

    {#if error}
      <div class="error-box">{error}</div>
    {/if}
  </div>

  <!-- ── Right: Results ──────────────────────────────────────────────── -->
  <div class="panel-right">
    {#if !results && !analyzing}
      <div class="placeholder">
        <div class="placeholder-icon">🚴</div>
        <div>Strecke laden, Parameter setzen<br/>und „Alle 3 vergleichen" klicken</div>
        <div class="placeholder-sub">Szenario 2 (FIT) ist optional</div>
      </div>

    {:else if analyzing}
      <div class="placeholder">
        <div class="spinner"></div>
        <div>Simuliere 3 Szenarien…</div>
      </div>

    {:else if results}
      <!-- Comparison table -->
      <div class="compare-card">
        <div class="compare-title">Szenarienvergleich</div>
        <table class="compare-table">
          <thead>
            <tr>
              <th></th>
              <th>
                <span class="sc-dot sm" style="background:{S_COLORS[0]}"></span>
                Konstante Watt
              </th>
              {#if results.s2}
              <th>
                <span class="sc-dot sm" style="background:{S_COLORS[1]}"></span>
                FIT-Datei
              </th>
              {/if}
              <th>
                <span class="sc-dot sm" style="background:{S_COLORS[2]}"></span>
                Pacing-Strategie
              </th>
            </tr>
          </thead>
          <tbody>
            <tr class="row-highlight">
              <td class="row-label">Gesamtzeit</td>
              <td class="val time-val">{formatDuration(results.s1.totalTimeSec)}</td>
              {#if results.s2}
              <td class="val">
                {formatDuration(results.s2.totalTimeSec)}
                <span class="diff {diffClass(results.s1, results.s2)}">{timeDiff(results.s1, results.s2)}</span>
              </td>
              {/if}
              <td class="val">
                {formatDuration(results.s3.totalTimeSec)}
                <span class="diff {diffClass(results.s1, results.s3)}">{timeDiff(results.s1, results.s3)}</span>
              </td>
            </tr>
            <tr>
              <td class="row-label">Ø Geschw.</td>
              <td class="val">{results.s1.avgSpeedKmh.toFixed(1)} km/h</td>
              {#if results.s2}<td class="val">{results.s2.avgSpeedKmh.toFixed(1)} km/h</td>{/if}
              <td class="val">{results.s3.avgSpeedKmh.toFixed(1)} km/h</td>
            </tr>
            <tr>
              <td class="row-label">Ø Leistung</td>
              <td class="val">{results.s1.avgPowerW.toFixed(0)} W</td>
              {#if results.s2}<td class="val">{results.s2.avgPowerW.toFixed(0)} W</td>{/if}
              <td class="val">{results.s3.avgPowerW.toFixed(0)} W</td>
            </tr>
            <tr>
              <td class="row-label">Ø W/kg</td>
              <td class="val">{wkg(results.s1.avgPowerW)}</td>
              {#if results.s2}<td class="val">{wkg(results.s2.avgPowerW)}</td>{/if}
              <td class="val">{wkg(results.s3.avgPowerW)}</td>
            </tr>
            <tr>
              <td class="row-label">Max. Geschw.</td>
              <td class="val">{results.s1.maxSpeedKmh.toFixed(1)} km/h</td>
              {#if results.s2}<td class="val">{results.s2.maxSpeedKmh.toFixed(1)} km/h</td>{/if}
              <td class="val">{results.s3.maxSpeedKmh.toFixed(1)} km/h</td>
            </tr>
            <tr>
              <td class="row-label">Höhenmeter</td>
              <td class="val">{results.s1.totalElevGainM.toFixed(0)} m</td>
              {#if results.s2}<td class="val">{results.s2.totalElevGainM.toFixed(0)} m</td>{/if}
              <td class="val">{results.s3.totalElevGainM.toFixed(0)} m</td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Speed chart -->
      <div class="chart-wrap">
        <div class="chart-title">Geschwindigkeit im Vergleich</div>
        <div class="chart-box"><canvas bind:this={chartElSpeed}></canvas></div>
      </div>

      <!-- Power chart -->
      <div class="chart-wrap">
        <div class="chart-title">Leistungsprofil im Vergleich</div>
        <div class="chart-box"><canvas bind:this={chartElPower}></canvas></div>
      </div>

      <!-- Climbs -->
      {#if climbs.length}
        <div class="climbs-card">
          <div class="compare-title">Anstiege (Referenz: Szenario 1)</div>
          <table class="compare-table">
            <thead>
              <tr>
                <th>Abschnitt</th><th>Distanz</th><th>Anstieg</th><th>Ø %</th>
                <th style="color:{S_COLORS[0]}">Zeit S1</th>
                {#if results.s2}<th style="color:{S_COLORS[1]}">Zeit S2</th>{/if}
                <th style="color:{S_COLORS[2]}">Zeit S3</th>
              </tr>
            </thead>
            <tbody>
              {#each climbs as c}
                {@const c2 = results.s2 ? detectClimbs(results.s2.points).find(x => Math.abs(x.startKm - c.startKm) < 1) : null}
                {@const c3 = detectClimbs(results.s3.points).find(x => Math.abs(x.startKm - c.startKm) < 1)}
                <tr>
                  <td class="muted">{c.startKm.toFixed(1)}–{c.endKm.toFixed(1)} km</td>
                  <td>{c.distKm.toFixed(2)} km</td>
                  <td class="climb-gain">+{c.gainM.toFixed(0)} m</td>
                  <td>{c.avgGradePct.toFixed(1)} %</td>
                  <td class="mono" style="color:{S_COLORS[0]}">{formatDuration(c.timeSec)}</td>
                  {#if results.s2}
                  <td class="mono" style="color:{S_COLORS[1]}">{c2 ? formatDuration(c2.timeSec) : '–'}</td>
                  {/if}
                  <td class="mono" style="color:{S_COLORS[2]}">{c3 ? formatDuration(c3.timeSec) : '–'}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .layout {
    display: flex;
    height: 100%;
    overflow: hidden;
    background: #0d1117;
  }

  .panel-left {
    width: 300px;
    flex-shrink: 0;
    background: #161b22;
    border-right: 1px solid #30363d;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    padding: 16px;
    gap: 4px;
  }
  .panel-title {
    font-size: 14px;
    font-weight: 700;
    color: #e6edf3;
    margin-bottom: 8px;
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px 0;
    border-bottom: 1px solid #21262d;
  }
  .scenario-section {
    border-left: 2px solid var(--sc);
    padding-left: 8px;
    margin-left: -8px;
  }
  .section-label {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.7px;
    text-transform: uppercase;
    color: #8b949e;
    margin-bottom: 2px;
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .section-hint { font-size: 11px; color: #6e7681; line-height: 1.4; }

  .sc-dot {
    display: inline-block;
    width: 8px; height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .sc-dot.sm { width: 7px; height: 7px; }

  .toggle-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 4px;
  }
  .toggle-row button {
    background: #21262d;
    border: 1px solid #30363d;
    color: #8b949e;
    padding: 5px 8px;
    border-radius: 6px;
    font-size: 12px;
    cursor: pointer;
    transition: background 0.15s, color 0.15s, border-color 0.15s;
  }
  .toggle-row button.active { background: #2dd4bf22; border-color: #2dd4bf66; color: #2dd4bf; }
  .toggle-row button:hover:not(.active) { border-color: #8b949e; color: #e6edf3; }

  .file-label { display: flex; align-items: center; gap: 8px; cursor: pointer; }
  .file-label span {
    flex: 1;
    background: #21262d;
    border: 1px dashed #30363d;
    border-radius: 6px;
    padding: 5px 8px;
    font-size: 11px;
    color: #8b949e;
    text-align: center;
    transition: border-color 0.15s, color 0.15s;
  }
  .file-label:hover span { border-color: #2dd4bf66; color: #2dd4bf; }
  .file-label input { display: none; }

  .info-chip {
    font-size: 11px; color: #8b949e;
    background: #21262d; border: 1px solid #30363d;
    border-radius: 6px; padding: 4px 8px;
  }
  .info-chip.ok   { color: #34d399; border-color: #34d39944; background: #34d39910; }
  .info-chip.warn { color: #f59e0b; border-color: #f59e0b44; background: #f59e0b10; }
  .badge { margin-left: 5px; background: #f59e0b22; color: #f59e0b; padding: 1px 4px; border-radius: 3px; font-size: 10px; }

  .param-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .param-row label { font-size: 12px; color: #8b949e; flex: 1; display: flex; align-items: center; gap: 3px; }
  .unit { font-size: 10px; color: #6e7681; }
  .param-row.sm { margin-top: -2px; }
  .dim { font-size: 11px; color: #6e7681; }

  .num-in {
    width: 68px; background: #21262d; border: 1px solid #30363d;
    border-radius: 6px; color: #e6edf3; font-size: 12px; padding: 4px 6px; text-align: right;
  }
  .num-in:focus { outline: none; border-color: #2dd4bf66; }

  .sel, .sel-sm {
    background: #21262d; border: 1px solid #30363d;
    border-radius: 6px; color: #e6edf3; font-size: 11px; padding: 4px 6px;
  }
  .sel { width: 100%; }
  .sel-sm { flex: 1; min-width: 0; }

  .slider { width: 100%; margin: 2px 0; }

  .strategy-info {
    font-size: 11px; color: #6e7681;
    background: #21262d; border-radius: 6px; padding: 5px 7px; line-height: 1.4;
  }

  .btn-run {
    margin-top: 8px; background: #2dd4bf; color: #0d1117;
    border: none; border-radius: 8px; font-size: 13px; font-weight: 700;
    padding: 10px; cursor: pointer; transition: opacity 0.15s; width: 100%;
  }
  .btn-run:hover:not(:disabled) { opacity: 0.85; }
  .btn-run:disabled { opacity: 0.4; cursor: not-allowed; }

  .btn-secondary {
    background: #21262d; border: 1px solid #30363d; color: #e6edf3;
    border-radius: 6px; font-size: 12px; padding: 5px 10px; cursor: pointer; width: 100%;
  }
  .btn-secondary:hover { border-color: #8b949e; }
  .btn-secondary:disabled { opacity: 0.5; }

  .error-box {
    background: #ef444420; border: 1px solid #ef444460;
    border-radius: 6px; color: #f87171; font-size: 12px; padding: 8px 10px; margin-top: 4px;
  }

  .panel-right {
    flex: 1; display: flex; flex-direction: column;
    overflow-y: auto; padding: 20px; gap: 16px; min-height: 0;
  }

  .placeholder {
    flex: 1; display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    gap: 12px; color: #8b949e; font-size: 14px; text-align: center;
  }
  .placeholder-icon { font-size: 48px; }
  .placeholder-sub { font-size: 12px; color: #6e7681; }

  .spinner {
    width: 32px; height: 32px;
    border: 3px solid #30363d; border-top-color: #2dd4bf;
    border-radius: 50%; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  .compare-card, .climbs-card {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 14px 16px;
  }
  .compare-title {
    font-size: 12px; font-weight: 600; color: #8b949e;
    text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 12px;
  }
  .compare-table { width: 100%; border-collapse: collapse; font-size: 13px; }
  .compare-table th {
    text-align: left; color: #8b949e; font-size: 11px; font-weight: 600;
    padding: 4px 10px; border-bottom: 1px solid #21262d;
  }
  .compare-table td { padding: 7px 10px; border-bottom: 1px solid #21262d; color: #e6edf3; }
  .compare-table tr:last-child td { border-bottom: none; }
  .row-highlight { background: #2dd4bf08; }
  .row-label { color: #8b949e; font-size: 12px; white-space: nowrap; }
  .val { font-variant-numeric: tabular-nums; font-weight: 600; }
  .time-val { font-size: 15px; color: #2dd4bf; }
  .diff { margin-left: 6px; font-size: 11px; font-weight: 400; font-variant-numeric: tabular-nums; }
  .diff.faster { color: #34d399; }
  .diff.slower { color: #f87171; }
  .muted { color: #8b949e; }
  .climb-gain { color: #f59e0b; font-weight: 600; }
  .mono { font-variant-numeric: tabular-nums; }

  .chart-wrap {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 14px 16px;
  }
  .chart-title {
    font-size: 12px; font-weight: 600; color: #8b949e;
    text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 10px;
  }
  .chart-box { height: 180px; position: relative; }
</style>

<script>
  import { onMount, tick } from 'svelte'
  import { supabase } from '$lib/supabase.js'
  import { parseGPX, parseFIT, trackFromSurfaceSamples } from '$lib/rollex/trackParser.js'
  import {
    buildGrades, simulate, constantPower, strategyPower, fitInterpolatedPower,
    formatDuration, downsample, detectClimbs,
  } from '$lib/rollex/performanceModel.js'
  import { computeAirDensity } from '$lib/rollex/rollingResistance.js'

  // ── State ──────────────────────────────────────────────────────────────────
  let track       = null
  let powerFit    = null   // reference FIT track for power mode
  let Chart       = null
  let chart1      = null, chart2 = null
  let chartEl1, chartEl2
  let result      = null
  let analyzing   = false
  let error       = ''

  // Track source
  let source      = 'upload'   // 'upload' | 'supabase'
  let rides       = []
  let selectedId  = ''
  let loadingRides= false

  // Rider params
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
    tt    : { label: 'TT / Aerobar',   cda: 0.22 },
    drops : { label: 'Im Unterlenker', cda: 0.32 },
    hoods : { label: 'Auf den Griffen',cda: 0.38 },
    mtb   : { label: 'MTB aufrecht',   cda: 0.50 },
    custom: { label: 'Manuell',        cda: null },
  }

  $: crrEff     = crrPreset === 'custom' ? crrCustom : (CRR_MAP[crrPreset]?.crr ?? 0.004)
  $: cdaEff     = cdaPreset === 'custom' ? cdaCustom : (CDA_MAP[cdaPreset]?.cda ?? 0.32)
  $: totalMass  = massKg + bikeMassKg

  // Power mode
  let powerMode   = 'constant'   // 'constant' | 'fit' | 'strategy'
  let constWatts  = 220
  let fitScalePct = 100
  let stratWatts  = 220
  let stratType   = 'constant'   // 'constant' | 'mountain' | 'negative_split'

  $: canRun = !analyzing && !!track && (
    powerMode !== 'fit' || !!powerFit
  )

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  onMount(async () => {
    // Load Chart.js 4 from CDN
    const script = document.createElement('script')
    script.src = 'https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js'
    script.onload = () => { Chart = window.Chart }
    document.head.appendChild(script)
  })

  // ── Track loading ──────────────────────────────────────────────────────────
  function handleTrackFile(e) {
    const file = e.target.files?.[0]
    if (!file) return
    error = ''; track = null; result = null
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
    const { data } = await supabase.from('rides').select('id,name,started_at,fit_path,avg_rms_g').order('started_at', { ascending: false }).limit(50)
    rides = data ?? []
    if (rides.length) selectedId = rides[0].id
    loadingRides = false
  }

  async function loadSupabaseTrack() {
    if (!selectedId) return
    error = ''; track = null; result = null; analyzing = true
    const ride = rides.find(r => r.id === selectedId)
    try {
      if (ride?.fit_path) {
        const { data: blob } = await supabase.storage.from('ride-files').download(ride.fit_path)
        if (blob) { track = parseFIT(await blob.arrayBuffer()); analyzing = false; return }
      }
      // Fallback: reconstruct from surface_samples
      const { data: rows } = await supabase.from('surface_samples')
        .select('ts_ms,lat,lon,speed_kmh').eq('ride_id', selectedId).order('ts_ms')
      track = trackFromSurfaceSamples(rows ?? [])
    } catch (ex) { error = 'Fehler: ' + ex.message }
    analyzing = false
  }

  // ── Simulation ────────────────────────────────────────────────────────────
  async function run() {
    if (!canRun) return
    analyzing = true; error = ''; result = null

    try {
      const rhoAir = computeAirDensity(tempC)
      const params = { totalMassKg: totalMass, cdA: cdaEff, crrEff, rhoAir }
      const n      = track.points.length - 1

      let powers
      if (powerMode === 'constant') {
        powers = constantPower(n, constWatts)
      } else if (powerMode === 'fit') {
        powers = fitInterpolatedPower(powerFit, track, fitScalePct / 100)
      } else {
        const { grades } = buildGrades(track)
        powers = strategyPower(grades, stratWatts, stratType)
      }

      result = simulate(track, powers, params)
    } catch (ex) {
      error = ex.message
    }

    analyzing = false
    await tick()
    if (result) drawCharts()
  }

  // ── Charts ────────────────────────────────────────────────────────────────
  function drawCharts() {
    if (!Chart || !result) return
    const pts = downsample(result.points, 400)

    const labels  = pts.map(p => p.distKm.toFixed(2))
    const speeds  = pts.map(p => +p.speedKmh.toFixed(1))
    const elevs   = pts.map(p => +p.elevM.toFixed(0))
    const powers  = pts.map(p => +p.powerW.toFixed(0))
    const grades  = pts.map(p => +p.gradePct.toFixed(1))

    // Chart 1: Speed + Elevation
    chart1?.destroy()
    chart1 = new Chart(chartEl1, {
      data: {
        labels,
        datasets: [
          {
            type: 'line', label: 'Geschwindigkeit (km/h)', data: speeds,
            yAxisID: 'ySpeed', borderColor: '#2dd4bf', borderWidth: 2,
            pointRadius: 0, tension: 0.2, fill: false, order: 1,
          },
          {
            type: 'line', label: 'Höhe (m)', data: elevs,
            yAxisID: 'yElev', borderColor: '#64748b', borderWidth: 1.5,
            backgroundColor: '#64748b22', pointRadius: 0, tension: 0.3, fill: true, order: 2,
          },
        ],
      },
      options: {
        animation: false, responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: { legend: { labels: { color: '#8b949e', font: { size: 12 } } },
          tooltip: { backgroundColor: '#1c2333', titleColor: '#e6edf3', bodyColor: '#8b949e',
            callbacks: { title: i => `${i[0]?.label} km` } } },
        scales: {
          x: { ticks: { color: '#8b949e', maxTicksLimit: 10, font: { size: 11 } },
               grid: { color: '#21262d' }, title: { display: true, text: 'Distanz (km)', color: '#8b949e' } },
          ySpeed: { position: 'left', ticks: { color: '#2dd4bf', font: { size: 11 } },
            grid: { color: '#21262d' }, title: { display: true, text: 'km/h', color: '#2dd4bf' } },
          yElev:  { position: 'right', ticks: { color: '#64748b', font: { size: 11 } },
            grid: { drawOnChartArea: false }, title: { display: true, text: 'Höhe m', color: '#64748b' } },
        },
      },
    })

    // Chart 2: Power + Gradient
    const gradColors = grades.map(g =>
      g > 8 ? '#ef4444' : g > 4 ? '#f97316' : g > 1 ? '#eab308'
        : g < -4 ? '#60a5fa' : g < -1 ? '#93c5fd' : '#34d399'
    )
    chart2?.destroy()
    chart2 = new Chart(chartEl2, {
      data: {
        labels,
        datasets: [
          {
            type: 'line', label: 'Leistung (W)', data: powers,
            yAxisID: 'yPower', borderColor: '#f59e0b', borderWidth: 2,
            pointRadius: 0, tension: 0.2, fill: false, order: 1,
          },
          {
            type: 'bar', label: 'Steigung (%)', data: grades,
            yAxisID: 'yGrade', backgroundColor: gradColors, order: 2, barPercentage: 1.0, categoryPercentage: 1.0,
          },
        ],
      },
      options: {
        animation: false, responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: { legend: { labels: { color: '#8b949e', font: { size: 12 } } },
          tooltip: { backgroundColor: '#1c2333', titleColor: '#e6edf3', bodyColor: '#8b949e',
            callbacks: { title: i => `${i[0]?.label} km` } } },
        scales: {
          x: { ticks: { color: '#8b949e', maxTicksLimit: 10, font: { size: 11 } },
               grid: { color: '#21262d' }, title: { display: true, text: 'Distanz (km)', color: '#8b949e' } },
          yPower: { position: 'left', ticks: { color: '#f59e0b', font: { size: 11 } },
            grid: { color: '#21262d' }, title: { display: true, text: 'Watt', color: '#f59e0b' } },
          yGrade: { position: 'right', ticks: { color: '#8b949e', font: { size: 11 } },
            grid: { drawOnChartArea: false }, title: { display: true, text: 'Steigung %', color: '#8b949e' } },
        },
      },
    })
  }

  // ── Derived ───────────────────────────────────────────────────────────────
  $: climbs = result ? detectClimbs(result.points) : []

  function wkg(w) { return massKg > 0 ? (w / massKg).toFixed(2) : '–' }

  // Time splits at 10 / 25 / 50 / 75 % of distance
  $: splits = result ? [0.1, 0.25, 0.5, 0.75].map(frac => {
    const targetDist = result.totalDistKm * frac
    const pt = result.points.find(p => p.distKm >= targetDist)
    return pt ? { label: (targetDist).toFixed(1) + ' km', time: formatDuration(pt.cumTimeSec) } : null
  }).filter(Boolean) : []
</script>

<div class="layout">
  <!-- ── Left: Inputs ────────────────────────────────────────────────────── -->
  <div class="panel-left">
    <div class="panel-title">Performance Predictor</div>

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
            ✓ {track.points.length} Punkte · {(track.totalDistance/1000).toFixed(1)} km · {track.totalElevGain.toFixed(0)} m ↑
            {#if track.hasPowerData}<span class="badge">⚡ Leistungsdaten</span>{/if}
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

    <!-- Rider params -->
    <section class="section">
      <div class="section-label">Fahrerparameter</div>

      <div class="param-row">
        <label>Fahrergewicht<span class="unit">kg</span></label>
        <input type="number" bind:value={massKg} min="40" max="150" step="1" class="num-in" />
      </div>
      <div class="param-row">
        <label>Radgewicht<span class="unit">kg</span></label>
        <input type="number" bind:value={bikeMassKg} min="5" max="30" step="0.5" class="num-in" />
      </div>
      <div class="param-row sm">
        <span class="dim">Gesamt: {totalMass.toFixed(1)} kg</span>
      </div>

      <div class="param-row">
        <label>Position / CdA</label>
        <select bind:value={cdaPreset} class="sel-sm">
          {#each Object.entries(CDA_MAP) as [k, v]}
            <option value={k}>{v.label} {v.cda != null ? `(${v.cda} m²)` : ''}</option>
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
            <option value={k}>{v.label} {v.crr != null ? `(${v.crr})` : ''}</option>
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

    <!-- Power mode -->
    <section class="section">
      <div class="section-label">Leistungsvorgabe</div>

      <div class="toggle-row three">
        <button class:active={powerMode === 'constant'} on:click={() => powerMode = 'constant'}>Konstant</button>
        <button class:active={powerMode === 'fit'}      on:click={() => powerMode = 'fit'}>FIT-Datei</button>
        <button class:active={powerMode === 'strategy'} on:click={() => powerMode = 'strategy'}>Strategie</button>
      </div>

      {#if powerMode === 'constant'}
        <div class="param-row">
          <label>Leistung<span class="unit">W</span></label>
          <input type="number" bind:value={constWatts} min="50" max="600" step="5" class="num-in" />
        </div>
        <input type="range" bind:value={constWatts} min="50" max="600" step="5" class="slider" />
        <div class="param-row sm">
          <span class="dim">{wkg(constWatts)} W/kg</span>
        </div>

      {:else if powerMode === 'fit'}
        <div class="section-hint">Lade eine FIT-Datei mit Leistungsdaten (z.B. aus Garmin oder Wahoo) als Referenzfahrt.</div>
        <label class="file-label">
          <span>Leistungs-FIT wählen</span>
          <input type="file" accept=".fit" on:change={handlePowerFile} />
        </label>
        {#if powerFit}
          <div class="info-chip ok">✓ {powerFit.points.length} Punkte · Ø {powerFit.avgPower?.toFixed(0) ?? '?'} W</div>
        {/if}
        <div class="param-row">
          <label>Skalierung<span class="unit">%</span></label>
          <input type="number" bind:value={fitScalePct} min="50" max="150" step="5" class="num-in" />
        </div>
        <input type="range" bind:value={fitScalePct} min="50" max="150" step="5" class="slider" />
        <div class="param-row sm">
          <span class="dim">100 % = identische Leistung · &lt;100 % = ruhigeres Tempo</span>
        </div>

      {:else}
        <div class="param-row">
          <label>Ziel-Ø-Leistung<span class="unit">W</span></label>
          <input type="number" bind:value={stratWatts} min="50" max="600" step="5" class="num-in" />
        </div>
        <input type="range" bind:value={stratWatts} min="50" max="600" step="5" class="slider" />
        <div class="param-row sm">
          <span class="dim">{wkg(stratWatts)} W/kg</span>
        </div>
        <div class="param-row">
          <label>Pacing-Strategie</label>
          <select bind:value={stratType} class="sel-sm">
            <option value="constant">Gleichmäßig (Constant Power)</option>
            <option value="mountain">Bergoptimiert (+Berg / −Abfahrt)</option>
            <option value="negative_split">Negative Split (2. Hälfte schneller)</option>
          </select>
        </div>
        <div class="strategy-info">
          {#if stratType === 'constant'}
            Konstante Leistung auf jedem Abschnitt — physiologisch optimal auf flachen Strecken.
          {:else if stratType === 'mountain'}
            Mehr Watt bergauf (+25 % max), Erholung bergab (−35 %) — normalisiert auf Ziel-Ø.
          {:else}
            Erste Hälfte bei 94 %, zweite bei 106 % — für progressive Renntaktik.
          {/if}
        </div>
      {/if}
    </section>

    <button class="btn-run" on:click={run} disabled={!canRun}>
      {#if analyzing}Berechne…{:else}▶ Vorhersagen{/if}
    </button>

    {#if error}
      <div class="error-box">{error}</div>
    {/if}
  </div>

  <!-- ── Right: Results ──────────────────────────────────────────────────── -->
  <div class="panel-right">
    {#if !result && !analyzing}
      <div class="placeholder">
        <div class="placeholder-icon">🚴</div>
        <div>Strecke laden und Parameter setzen,<br/>dann „Vorhersagen" klicken</div>
      </div>

    {:else if analyzing}
      <div class="placeholder">
        <div class="spinner"></div>
        <div>Simuliere…</div>
      </div>

    {:else if result}
      <!-- Key metrics -->
      <div class="metrics-grid">
        <div class="metric big">
          <div class="metric-label">Gesamtzeit</div>
          <div class="metric-value time">{formatDuration(result.totalTimeSec)}</div>
        </div>
        <div class="metric">
          <div class="metric-label">Distanz</div>
          <div class="metric-value">{result.totalDistKm.toFixed(1)} <span class="metric-unit">km</span></div>
        </div>
        <div class="metric">
          <div class="metric-label">Ø Geschw.</div>
          <div class="metric-value">{result.avgSpeedKmh.toFixed(1)} <span class="metric-unit">km/h</span></div>
        </div>
        <div class="metric">
          <div class="metric-label">Höhenmeter</div>
          <div class="metric-value">{result.totalElevGainM.toFixed(0)} <span class="metric-unit">m</span></div>
        </div>
        <div class="metric">
          <div class="metric-label">Ø Leistung</div>
          <div class="metric-value">{result.avgPowerW.toFixed(0)} <span class="metric-unit">W</span></div>
        </div>
        <div class="metric">
          <div class="metric-label">Ø W/kg</div>
          <div class="metric-value">{wkg(result.avgPowerW)}</div>
        </div>
      </div>

      <!-- Time splits -->
      {#if splits.length}
        <div class="splits-row">
          {#each splits as s}
            <div class="split"><span class="split-dist">{s.label}</span><span class="split-time">{s.time}</span></div>
          {/each}
        </div>
      {/if}

      <!-- Chart 1: Speed + Elevation -->
      <div class="chart-wrap">
        <div class="chart-title">Geschwindigkeit &amp; Höhenprofil</div>
        <div class="chart-box"><canvas bind:this={chartEl1}></canvas></div>
      </div>

      <!-- Chart 2: Power + Gradient -->
      <div class="chart-wrap">
        <div class="chart-title">Leistung &amp; Steigung</div>
        <div class="chart-box"><canvas bind:this={chartEl2}></canvas></div>
      </div>

      <!-- Climbs table -->
      {#if climbs.length}
        <div class="climbs-section">
          <div class="climbs-title">Anstiege</div>
          <table class="climbs-table">
            <thead>
              <tr><th>Abschnitt</th><th>Länge</th><th>Anstieg</th><th>Ø Stg.</th><th>Zeit</th><th>Ø km/h</th></tr>
            </thead>
            <tbody>
              {#each climbs as c, i}
                <tr>
                  <td class="muted">{c.startKm.toFixed(1)}–{c.endKm.toFixed(1)} km</td>
                  <td>{c.distKm.toFixed(2)} km</td>
                  <td class="climb-gain">+{c.gainM.toFixed(0)} m</td>
                  <td>{c.avgGradePct.toFixed(1)} %</td>
                  <td class="mono">{formatDuration(c.timeSec)}</td>
                  <td>{c.avgSpeedKmh.toFixed(1)}</td>
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

  /* ── Left panel ── */
  .panel-left {
    width: 320px;
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
    font-size: 15px;
    font-weight: 700;
    color: #e6edf3;
    margin-bottom: 8px;
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 12px 0;
    border-bottom: 1px solid #21262d;
  }
  .section:last-of-type { border-bottom: none; }
  .section-label {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.8px;
    text-transform: uppercase;
    color: #8b949e;
    margin-bottom: 2px;
  }
  .section-hint {
    font-size: 12px;
    color: #8b949e;
    line-height: 1.4;
  }

  /* Toggle buttons */
  .toggle-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 4px;
  }
  .toggle-row.three { grid-template-columns: 1fr 1fr 1fr; }
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
  .toggle-row button.active {
    background: #2dd4bf22;
    border-color: #2dd4bf66;
    color: #2dd4bf;
  }
  .toggle-row button:hover:not(.active) { border-color: #8b949e; color: #e6edf3; }

  /* File input */
  .file-label {
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
  }
  .file-label span {
    flex: 1;
    background: #21262d;
    border: 1px dashed #30363d;
    border-radius: 6px;
    padding: 6px 10px;
    font-size: 12px;
    color: #8b949e;
    text-align: center;
    transition: border-color 0.15s, color 0.15s;
  }
  .file-label:hover span { border-color: #2dd4bf66; color: #2dd4bf; }
  .file-label input { display: none; }

  /* Info chips */
  .info-chip {
    font-size: 11px;
    color: #8b949e;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 4px 8px;
  }
  .info-chip.ok    { color: #34d399; border-color: #34d39944; background: #34d39910; }
  .info-chip.warn  { color: #f59e0b; border-color: #f59e0b44; background: #f59e0b10; }
  .badge { margin-left: 6px; background: #f59e0b22; color: #f59e0b; padding: 1px 5px; border-radius: 4px; font-size: 10px; }

  /* Params */
  .param-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .param-row label {
    font-size: 12px;
    color: #8b949e;
    flex: 1;
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .unit { font-size: 10px; color: #6e7681; margin-left: 2px; }
  .param-row.sm { margin-top: -2px; }
  .dim { font-size: 11px; color: #6e7681; }

  .num-in {
    width: 70px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #e6edf3;
    font-size: 12px;
    padding: 4px 7px;
    text-align: right;
  }
  .num-in:focus { outline: none; border-color: #2dd4bf66; }

  .sel, .sel-sm {
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #e6edf3;
    font-size: 12px;
    padding: 4px 7px;
  }
  .sel { width: 100%; }
  .sel-sm { flex: 1; min-width: 0; }

  .slider {
    width: 100%;
    accent-color: #2dd4bf;
    margin: 2px 0;
  }

  .strategy-info {
    font-size: 11px;
    color: #6e7681;
    background: #21262d;
    border-radius: 6px;
    padding: 6px 8px;
    line-height: 1.4;
  }

  .btn-run {
    margin-top: 8px;
    background: #2dd4bf;
    color: #0d1117;
    border: none;
    border-radius: 8px;
    font-size: 14px;
    font-weight: 700;
    padding: 10px;
    cursor: pointer;
    transition: opacity 0.15s;
    width: 100%;
  }
  .btn-run:hover:not(:disabled) { opacity: 0.85; }
  .btn-run:disabled { opacity: 0.4; cursor: not-allowed; }

  .btn-secondary {
    background: #21262d;
    border: 1px solid #30363d;
    color: #e6edf3;
    border-radius: 6px;
    font-size: 12px;
    padding: 5px 10px;
    cursor: pointer;
    width: 100%;
  }
  .btn-secondary:hover { border-color: #8b949e; }
  .btn-secondary:disabled { opacity: 0.5; }

  .error-box {
    background: #ef444420;
    border: 1px solid #ef444460;
    border-radius: 6px;
    color: #f87171;
    font-size: 12px;
    padding: 8px 10px;
    margin-top: 4px;
  }

  /* ── Right panel ── */
  .panel-right {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    padding: 20px;
    gap: 16px;
    min-height: 0;
  }

  .placeholder {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    color: #8b949e;
    font-size: 14px;
    text-align: center;
  }
  .placeholder-icon { font-size: 48px; }
  .spinner {
    width: 32px; height: 32px;
    border: 3px solid #30363d;
    border-top-color: #2dd4bf;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* Metrics */
  .metrics-grid {
    display: grid;
    grid-template-columns: 2fr 1fr 1fr 1fr 1fr 1fr;
    gap: 10px;
  }
  .metric {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 12px 14px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .metric.big { border-color: #2dd4bf44; background: #2dd4bf0a; }
  .metric-label { font-size: 11px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
  .metric-value { font-size: 22px; font-weight: 700; color: #e6edf3; line-height: 1; }
  .metric.big .metric-value { font-size: 28px; color: #2dd4bf; }
  .metric-value.time { font-size: 24px; color: #2dd4bf; font-variant-numeric: tabular-nums; }
  .metric-unit { font-size: 13px; color: #8b949e; font-weight: 400; }

  /* Splits */
  .splits-row {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .split {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 6px 12px;
    display: flex;
    gap: 8px;
    align-items: center;
    font-size: 12px;
  }
  .split-dist { color: #8b949e; }
  .split-time { color: #e6edf3; font-weight: 600; font-variant-numeric: tabular-nums; }

  /* Charts */
  .chart-wrap {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 14px 16px;
  }
  .chart-title {
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 10px;
  }
  .chart-box {
    height: 180px;
    position: relative;
  }

  /* Climbs table */
  .climbs-section {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 14px 16px;
  }
  .climbs-title {
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 10px;
  }
  .climbs-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }
  .climbs-table th {
    text-align: left;
    color: #8b949e;
    font-size: 11px;
    font-weight: 600;
    padding: 4px 8px;
    border-bottom: 1px solid #21262d;
  }
  .climbs-table td {
    padding: 6px 8px;
    color: #e6edf3;
    border-bottom: 1px solid #21262d;
  }
  .climbs-table tr:last-child td { border-bottom: none; }
  .climbs-table td.muted { color: #8b949e; }
  .climbs-table td.climb-gain { color: #f59e0b; font-weight: 600; }
  .climbs-table td.mono { font-variant-numeric: tabular-nums; }
</style>

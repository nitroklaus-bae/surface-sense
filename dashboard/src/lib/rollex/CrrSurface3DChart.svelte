<script>
  import { onMount } from 'svelte';
  import {
    crrComponents,
    crrComponentsISO8608,
    crrComponentsKarrasch,
    crrComponentsKarraschTable,
    crrComponentsPhysical,
    interpolateCrr,
    silcaPressureForIri,
    structuralMinPressure,
  } from '$lib/rollex/rollingResistance';
  import { SURFACE_PROPS } from '$lib/rollex/surfaceAnalyzer';
  import { TIRE_DATABASE } from '$lib/rollex/tires';

  export let setups = [];
  export let totalWeightKg = 84;
  export let tempCelsius = 20;

  const P_VALS = Array.from({ length: 11 }, (_, i) => 1.0 + i * 0.5);
  const IRI_VALS = Array.from({ length: 13 }, (_, i) => 1.5 + i * 0.5);
  const NP = P_VALS.length - 1;
  const NIRI = IRI_VALS.length - 1;
  const HW = 18;
  const HH = 10;

  const MODEL_FILL = {
    physical: 'rgba(244,63,94,0.52)',
    three: 'rgba(6,182,212,0.50)',
    iso: 'rgba(245,158,11,0.46)',
    karrasch: 'rgba(16,185,129,0.46)',
    table: 'rgba(139,92,246,0.42)',
  };
  const MODEL_EDGE = {
    physical: 'rgba(251,113,133,0.95)',
    three: 'rgba(34,211,238,0.9)',
    iso: 'rgba(251,191,36,0.9)',
    karrasch: 'rgba(52,211,153,0.9)',
    table: 'rgba(167,139,250,0.86)',
  };
  const MODEL_LABEL = {
    physical: 'Physikalisch',
    three: '3-Term kalibriert',
    iso: 'ISO 8608',
    karrasch: 'Karrasch Zuwachs',
    table: 'Karrasch-Tabelle',
  };
  const MODES = [
    { key: 'all', label: 'Alle' },
    { key: 'physical', label: 'Physikalisch' },
    { key: 'three', label: '3-Term' },
    { key: 'iso', label: 'ISO 8608' },
    { key: 'karrasch', label: 'Karrasch' },
    { key: 'table', label: 'Tabelle' },
    { key: 'diff', label: 'Delta' },
  ];
  const DIFF_MODELS = [
    { key: 'physical', label: 'Physik - Karrasch' },
    { key: 'three', label: '3-Term - Karrasch' },
    { key: 'iso', label: 'ISO - Karrasch' },
  ];
  const SURFACE_OPTS = Object.keys(SURFACE_PROPS)
    .filter((cat) => cat !== 'unknown')
    .map((cat) => ({ cat, label: SURFACE_PROPS[cat].label }));

  let canvasEl;
  let raf = 0;
  let surface = 'rough_asphalt';
  let mode = 'physical';
  let diffModel = 'physical';
  let tireId = '';
  let widthMm = 0;

  $: defaultSetup = setups?.[0] ?? null;
  $: if (!tireId) tireId = defaultSetup?.rearTire?.id ?? TIRE_DATABASE[0]?.id ?? '';
  $: tire = TIRE_DATABASE.find((item) => item.id === tireId) ?? TIRE_DATABASE[0];
  $: if (tire && (!widthMm || !tire.widths.includes(Number(widthMm)))) {
    widthMm = defaultSetup?.rearTire?.id === tire.id && tire.widths.includes(defaultSetup.rearWidthMm)
      ? defaultSetup.rearWidthMm
      : tire.widths[Math.floor(tire.widths.length / 2)];
  }
  $: effWidth = Number(widthMm);
  $: drawKey = `${tireId}|${effWidth}|${surface}|${mode}|${diffModel}|${totalWeightKg}|${tempCelsius}`;
  $: if (canvasEl && drawKey) scheduleDraw();

  onMount(() => {
    scheduleDraw();
    const resize = () => scheduleDraw();
    window.addEventListener('resize', resize);
    return () => {
      window.removeEventListener('resize', resize);
      cancelAnimationFrame(raf);
    };
  });

  function scheduleDraw() {
    if (!canvasEl) return;
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(drawChart);
  }

  function heatColor(t, alpha = 1) {
    const stops = [[59, 130, 246], [34, 197, 94], [234, 179, 8], [239, 68, 68]];
    const seg = Math.max(0, Math.min(1, t)) * (stops.length - 1);
    const i = Math.min(Math.floor(seg), stops.length - 2);
    const f = seg - i;
    const c = stops[i].map((v, j) => Math.round(v + f * (stops[i + 1][j] - v)));
    return `rgba(${c[0]},${c[1]},${c[2]},${alpha})`;
  }

  function divColor(t, alpha = 1) {
    const neg = [37, 99, 235];
    const mid = [226, 232, 240];
    const pos = [220, 38, 38];
    const clamped = Math.max(-1, Math.min(1, t));
    const c = clamped < 0
      ? mid.map((v, j) => Math.round(v + (-clamped) * (neg[j] - v)))
      : mid.map((v, j) => Math.round(v + clamped * (pos[j] - v)));
    return `rgba(${c[0]},${c[1]},${c[2]},${alpha})`;
  }

  function proj(pi, iriI, z, cx, cy, zs) {
    return [cx + (pi - iriI) * HW, cy - (pi + iriI) * HH - z * zs];
  }

  function drawSurface(ctx, grid, cx, cy, zs, colorFn, edge = 'rgba(15,23,42,0.28)') {
    for (let sum = NP + NIRI; sum >= 0; sum -= 1) {
      for (let pi = Math.min(sum, NP); pi >= Math.max(0, sum - NIRI); pi -= 1) {
        const iriI = sum - pi;
        if (pi >= NP || iriI >= NIRI) continue;
        const z00 = grid[pi][iriI];
        const z10 = grid[pi + 1][iriI];
        const z11 = grid[pi + 1][iriI + 1];
        const z01 = grid[pi][iriI + 1];
        const [x00, y00] = proj(pi, iriI, z00, cx, cy, zs);
        const [x10, y10] = proj(pi + 1, iriI, z10, cx, cy, zs);
        const [x11, y11] = proj(pi + 1, iriI + 1, z11, cx, cy, zs);
        const [x01, y01] = proj(pi, iriI + 1, z01, cx, cy, zs);
        ctx.beginPath();
        ctx.moveTo(x00, y00);
        ctx.lineTo(x10, y10);
        ctx.lineTo(x11, y11);
        ctx.lineTo(x01, y01);
        ctx.closePath();
        ctx.fillStyle = colorFn((z00 + z10 + z11 + z01) / 4);
        ctx.strokeStyle = edge;
        ctx.lineWidth = 0.55;
        ctx.fill();
        ctx.stroke();
      }
    }
  }

  function drawMany(ctx, layers, cx, cy, zs) {
    const cellAvg = (grid, pi, iriI) =>
      (grid[pi][iriI] + grid[pi + 1][iriI] + grid[pi + 1][iriI + 1] + grid[pi][iriI + 1]) / 4;
    const quad = (grid, pi, iriI, fill, edge) => {
      const z00 = grid[pi][iriI];
      const z10 = grid[pi + 1][iriI];
      const z11 = grid[pi + 1][iriI + 1];
      const z01 = grid[pi][iriI + 1];
      const [x00, y00] = proj(pi, iriI, z00, cx, cy, zs);
      const [x10, y10] = proj(pi + 1, iriI, z10, cx, cy, zs);
      const [x11, y11] = proj(pi + 1, iriI + 1, z11, cx, cy, zs);
      const [x01, y01] = proj(pi, iriI + 1, z01, cx, cy, zs);
      ctx.beginPath();
      ctx.moveTo(x00, y00);
      ctx.lineTo(x10, y10);
      ctx.lineTo(x11, y11);
      ctx.lineTo(x01, y01);
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.strokeStyle = edge;
      ctx.lineWidth = 0.65;
      ctx.fill();
      ctx.stroke();
    };
    for (let sum = NP + NIRI; sum >= 0; sum -= 1) {
      for (let pi = Math.min(sum, NP); pi >= Math.max(0, sum - NIRI); pi -= 1) {
        const iriI = sum - pi;
        if (pi >= NP || iriI >= NIRI) continue;
        const ordered = [...layers].sort((a, b) => cellAvg(a.grid, pi, iriI) - cellAvg(b.grid, pi, iriI));
        for (const layer of ordered) quad(layer.grid, pi, iriI, layer.fill, layer.edge);
      }
    }
  }

  function drawAxes(ctx, cx, cy, zs) {
    ctx.save();
    ctx.strokeStyle = 'rgba(148,163,184,0.55)';
    ctx.fillStyle = '#9ca3af';
    ctx.lineWidth = 1.4;
    ctx.font = '11px system-ui';

    let [x0, y0] = proj(0, 0, 0, cx, cy, zs);
    let [xN, yN] = proj(NP + 1, 0, 0, cx, cy, zs);
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    ctx.lineTo(xN, yN);
    ctx.stroke();
    for (let pi = 0; pi <= NP; pi += 2) {
      const [tx, ty] = proj(pi, 0, 0, cx, cy, zs);
      ctx.beginPath();
      ctx.arc(tx, ty, 2, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillText(P_VALS[pi].toFixed(1), tx + 4, ty + 10);
    }
    ctx.font = '700 11px system-ui';
    const [px, py] = proj((NP + 1) / 2, -1.4, 0, cx, cy, zs);
    ctx.fillText('Druck (bar)', px, py);

    ctx.font = '11px system-ui';
    [x0, y0] = proj(0, 0, 0, cx, cy, zs);
    [xN, yN] = proj(0, NIRI + 1, 0, cx, cy, zs);
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    ctx.lineTo(xN, yN);
    ctx.stroke();
    for (let ii = 0; ii <= NIRI; ii += 2) {
      const [tx, ty] = proj(0, ii, 0, cx, cy, zs);
      ctx.beginPath();
      ctx.arc(tx, ty, 2, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillText(IRI_VALS[ii].toFixed(1), tx - 30, ty + 4);
    }
    ctx.font = '700 11px system-ui';
    const [ix, iy] = proj(0, (NIRI + 1) / 2 + 1, 0, cx, cy, zs);
    ctx.fillText('IRI (m/km)', ix - 58, iy);
    ctx.restore();
  }

  function drawHeatLegend(ctx, minV, maxV, x, y, diverging = false) {
    const w = 12;
    const h = 120;
    const steps = 60;
    for (let i = 0; i < steps; i += 1) {
      const t = 1 - i / steps;
      ctx.fillStyle = diverging ? divColor(t * 2 - 1) : heatColor(t);
      ctx.fillRect(x, y + (i / steps) * h, w, h / steps + 1);
    }
    ctx.strokeStyle = 'rgba(226,232,240,0.5)';
    ctx.lineWidth = 1;
    ctx.strokeRect(x, y, w, h);
    ctx.font = '10px system-ui';
    ctx.fillStyle = '#cbd5e1';
    ctx.fillText((maxV * 1000).toFixed(1), x + w + 3, y + 9);
    ctx.fillText((minV * 1000).toFixed(1), x + w + 3, y + h + 4);
    ctx.save();
    ctx.translate(x - 4, y + h / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.textAlign = 'center';
    ctx.fillText(diverging ? 'Delta Crr x10^-3' : 'Crr x10^-3', 0, 0);
    ctx.restore();
  }

  function drawChart() {
    if (!canvasEl || !tire || !effWidth) return;
    const ctx = canvasEl.getContext('2d');
    if (!ctx) return;

    const logicalW = 620;
    const logicalH = 400;
    const dpr = window.devicePixelRatio || 1;
    canvasEl.width = logicalW * dpr;
    canvasEl.height = logicalH * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, logicalW, logicalH);

    const gradient = ctx.createLinearGradient(0, 0, 0, logicalH);
    gradient.addColorStop(0, '#111827');
    gradient.addColorStop(1, '#0b1220');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, logicalW, logicalH);

    const crrBase = interpolateCrr(tire.crr, effWidth);
    const wheelLoadKg = totalWeightKg * 0.55;
    const mk = (fn) => Array.from(
      { length: NP + 1 },
      (_, pi) => Array.from({ length: NIRI + 1 }, (_, ii) => fn(P_VALS[pi], IRI_VALS[ii])),
    );
    const grids = {
      physical: mk((p, iri) => crrComponentsPhysical(crrBase, effWidth, p, iri, surface, wheelLoadKg, tempCelsius).total),
      three: mk((p, iri) => crrComponents(crrBase, effWidth, p, iri, surface, tempCelsius).total),
      iso: mk((p, iri) => crrComponentsISO8608(crrBase, effWidth, p, iri, surface, wheelLoadKg, tempCelsius).total),
      karrasch: mk((p) => crrComponentsKarrasch(crrBase, effWidth, p, surface, tempCelsius).total),
      table: mk(() => crrComponentsKarraschTable(crrBase, surface).total),
    };
    const cx = 305;
    const cy = 348;

    if (mode === 'diff') {
      const modelGrid = grids[diffModel];
      const diffGrid = modelGrid.map((row, pi) => row.map((v, ii) => v - grids.karrasch[pi][ii]));
      let amp = 0;
      for (const row of diffGrid) for (const v of row) amp = Math.max(amp, Math.abs(v));
      amp = amp || 1e-6;
      const zs = 112 / amp;
      ctx.save();
      ctx.setLineDash([3, 3]);
      ctx.strokeStyle = 'rgba(148,163,184,0.55)';
      ctx.lineWidth = 1;
      const corners = [[0, 0], [NP, 0], [NP, NIRI], [0, NIRI]].map(([p, iriI]) => proj(p, iriI, 0, cx, cy, zs));
      ctx.beginPath();
      ctx.moveTo(corners[0][0], corners[0][1]);
      corners.slice(1).forEach(([x, y]) => ctx.lineTo(x, y));
      ctx.closePath();
      ctx.stroke();
      ctx.restore();
      drawSurface(ctx, diffGrid, cx, cy, zs, (v) => divColor(v / amp, 0.94));
      drawAxes(ctx, cx, cy, zs);
      drawHeatLegend(ctx, -amp, amp, logicalW - 55, 32, true);
    } else {
      const active = mode === 'all' ? ['physical', 'three', 'iso', 'karrasch', 'table'] : [mode];
      let maxV = 0;
      for (const key of active) for (const row of grids[key]) for (const v of row) maxV = Math.max(maxV, v);
      const zs = 132 / (maxV || 1e-6);

      if (mode === 'all') {
        drawMany(
          ctx,
          active.map((key) => ({ grid: grids[key], fill: MODEL_FILL[key], edge: MODEL_EDGE[key] })),
          cx,
          cy,
          zs,
        );
      } else {
        const grid = grids[mode];
        let minV = Infinity;
        for (const row of grid) for (const v of row) minV = Math.min(minV, v);
        drawSurface(ctx, grid, cx, cy, zs, (v) => heatColor((v - minV) / ((maxV - minV) || 1e-6), 0.96));
        drawHeatLegend(ctx, minV, maxV, logicalW - 55, 32);
      }
      drawAxes(ctx, cx, cy, zs);

      if (mode === 'all' || mode === 'three' || mode === 'physical') {
        const refGrid = mode === 'physical' ? grids.physical : grids.three;
        const nominalIri = SURFACE_PROPS[surface].iri;
        const pStructMin = structuralMinPressure(totalWeightKg, effWidth, true, true);
        const pAt = (ii) => {
          const p = silcaPressureForIri(effWidth, surface, nominalIri, IRI_VALS[ii], totalWeightKg, true);
          return Math.max(pStructMin, Math.min(P_VALS[NP], p));
        };
        const piOf = (p) => Math.max(0, Math.min(NP, (p - P_VALS[0]) / (P_VALS[1] - P_VALS[0])));
        const zAtPI = (grid, piF, ii) => {
          const lo = Math.floor(piF);
          const hi = Math.min(NP, lo + 1);
          const f = piF - lo;
          return grid[lo][ii] + f * (grid[hi][ii] - grid[lo][ii]);
        };
        ctx.save();
        ctx.setLineDash([5, 3]);
        ctx.strokeStyle = 'rgba(129,140,248,0.98)';
        ctx.lineWidth = 2;
        for (let ii = 0; ii < NIRI; ii += 1) {
          const pi0 = piOf(pAt(ii));
          const pi1 = piOf(pAt(ii + 1));
          const [x, y] = proj(pi0, ii, zAtPI(refGrid, pi0, ii), cx, cy, zs);
          const [xn, yn] = proj(pi1, ii + 1, zAtPI(refGrid, pi1, ii + 1), cx, cy, zs);
          ctx.beginPath();
          ctx.moveTo(x, y);
          ctx.lineTo(xn, yn);
          ctx.stroke();
        }
        ctx.setLineDash([]);
        ctx.fillStyle = 'rgba(129,140,248,0.98)';
        for (const ii of [0, NIRI]) {
          const pi = piOf(pAt(ii));
          const [x, y] = proj(pi, ii, zAtPI(refGrid, pi, ii), cx, cy, zs);
          ctx.beginPath();
          ctx.arc(x, y, 2.6, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.restore();
      }
    }

    ctx.font = '700 12px system-ui';
    ctx.fillStyle = '#f8fafc';
    ctx.fillText(`${tire.brand} ${tire.model} | ${effWidth} mm`, 12, 20);
    ctx.font = '11px system-ui';
    ctx.fillStyle = '#94a3b8';
    ctx.fillText(`Crr-Basis ${(crrBase * 1000).toFixed(2)} x10^-3 @5 bar | ${SURFACE_PROPS[surface].label}`, 12, 37);

    const swatch = (x, y, fill, label) => {
      ctx.fillStyle = fill;
      ctx.fillRect(x, y, 14, 10);
      ctx.strokeStyle = 'rgba(226,232,240,0.45)';
      ctx.strokeRect(x, y, 14, 10);
      ctx.fillStyle = '#cbd5e1';
      ctx.font = '10px system-ui';
      ctx.fillText(label, x + 19, y + 9);
    };

    if (mode === 'all') {
      swatch(12, logicalH - 88, MODEL_FILL.physical, MODEL_LABEL.physical);
      swatch(12, logicalH - 72, MODEL_FILL.three, MODEL_LABEL.three);
      swatch(12, logicalH - 56, MODEL_FILL.iso, MODEL_LABEL.iso);
      swatch(12, logicalH - 40, MODEL_FILL.karrasch, MODEL_LABEL.karrasch);
      swatch(12, logicalH - 24, MODEL_FILL.table, MODEL_LABEL.table);
    } else if (mode === 'diff') {
      ctx.fillStyle = '#cbd5e1';
      ctx.font = '10px system-ui';
      ctx.fillText('Rot: Modell hoeher als Karrasch | Blau: Modell niedriger | gestrichelt: Nullebene', 12, logicalH - 20);
    }

    if (mode === 'all' || mode === 'three' || mode === 'physical') {
      const nominalIri = SURFACE_PROPS[surface].iri;
      const pLo = silcaPressureForIri(effWidth, surface, nominalIri, IRI_VALS[0], totalWeightKg, true);
      const pHi = silcaPressureForIri(effWidth, surface, nominalIri, IRI_VALS[NIRI], totalWeightKg, true);
      ctx.save();
      ctx.setLineDash([5, 3]);
      ctx.strokeStyle = 'rgba(129,140,248,0.98)';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(logicalW - 178, logicalH - 20);
      ctx.lineTo(logicalW - 154, logicalH - 20);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.font = '10px system-ui';
      ctx.fillStyle = '#cbd5e1';
      ctx.fillText(`Silca-Druck (${pLo.toFixed(1)} -> ${pHi.toFixed(1)} bar)`, logicalW - 150, logicalH - 16);
      ctx.restore();
    }
  }

  function chartNote(currentMode) {
    if (currentMode === 'diff') {
      return 'Differenzflaeche gegen Karrasch: rot bedeutet, dass das Modell mehr Widerstand prognostiziert, blau weniger.';
    }
    if (currentMode === 'all') {
      return 'Alle Modellflaechen liegen uebereinander. So siehst du schnell, ob ein Modell bei Druck oder Rauheit ausreisst.';
    }
    if (currentMode === 'table') {
      return 'Die Karrasch-Tabelle ist absichtlich flach: sie nutzt je Oberflaeche einen festen Multiplikator ohne Druck- oder IRI-Verlauf.';
    }
    return 'Hoehe und Farbe zeigen Crr. Die violette Linie markiert den Silca-orientierten optimalen Druck ueber zunehmende Rauheit.';
  }
</script>

<section class="model-card">
  <div class="chart-head">
    <div>
      <h3>3D-Modellvergleich fuer Reifen</h3>
      <p>CRR ueber Reifendruck und IRI fuer den ausgewaehlten Reifen.</p>
    </div>
  </div>

  <div class="control-grid">
    <label>
      Reifen
      <select bind:value={tireId}>
        {#each TIRE_DATABASE as item}
          <option value={item.id}>{item.brand} {item.model}</option>
        {/each}
      </select>
    </label>
    <label>
      Breite
      <select bind:value={widthMm}>
        {#each tire.widths as width}
          <option value={width}>{width} mm</option>
        {/each}
      </select>
    </label>
    <label>
      Oberflaeche
      <select bind:value={surface}>
        {#each SURFACE_OPTS as option}
          <option value={option.cat}>{option.label}</option>
        {/each}
      </select>
    </label>
  </div>

  <div class="mode-row" aria-label="Widerstandsmodell">
    {#each MODES as item}
      <button type="button" class:active={mode === item.key} on:click={() => mode = item.key}>
        {item.label}
      </button>
    {/each}
  </div>

  {#if mode === 'diff'}
    <div class="mode-row sub" aria-label="Differenzmodell">
      {#each DIFF_MODELS as item}
        <button type="button" class:active={diffModel === item.key} on:click={() => diffModel = item.key}>
          {item.label}
        </button>
      {/each}
    </div>
  {/if}

  <div class="canvas-scroll">
    <canvas bind:this={canvasEl} class="chart-canvas" width="620" height="400"></canvas>
  </div>

  <p class="chart-note">{chartNote(mode)}</p>
</section>

<style>
  .model-card {
    border: 1px solid rgba(148, 163, 184, 0.18);
    border-radius: 8px;
    padding: 1rem;
    background: rgba(13, 17, 23, 0.76);
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.28);
  }
  .chart-head {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 0.85rem;
  }
  h3 {
    margin: 0 0 0.25rem;
    color: #f3f4f6;
    font-size: 1rem;
  }
  p {
    margin: 0;
  }
  .chart-head p,
  .chart-note {
    color: #9ca3af;
    font-size: 0.84rem;
    line-height: 1.45;
  }
  .control-grid {
    display: grid;
    grid-template-columns: minmax(220px, 1.5fr) minmax(120px, 0.6fr) minmax(160px, 0.9fr);
    gap: 0.65rem;
    margin-bottom: 0.75rem;
  }
  label {
    display: grid;
    gap: 0.28rem;
    color: #9ca3af;
    font-size: 0.78rem;
    font-weight: 650;
  }
  select {
    width: 100%;
    min-width: 0;
    border: 1px solid rgba(148, 163, 184, 0.26);
    border-radius: 7px;
    background: #111827;
    color: #e5e7eb;
    padding: 0.48rem 0.55rem;
    font-size: 0.84rem;
  }
  .mode-row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin-bottom: 0.65rem;
  }
  .mode-row.sub {
    margin-top: -0.25rem;
  }
  button {
    border: 1px solid rgba(148, 163, 184, 0.22);
    border-radius: 7px;
    background: rgba(31, 41, 55, 0.78);
    color: #cbd5e1;
    padding: 0.42rem 0.62rem;
    font-size: 0.78rem;
    font-weight: 700;
    cursor: pointer;
    transition: background 0.16s ease, border-color 0.16s ease, color 0.16s ease;
  }
  button:hover {
    background: rgba(55, 65, 81, 0.92);
    color: #f8fafc;
  }
  button.active {
    border-color: rgba(45, 212, 191, 0.55);
    background: rgba(20, 184, 166, 0.17);
    color: #99f6e4;
  }
  .canvas-scroll {
    overflow-x: auto;
    border-radius: 8px;
    border: 1px solid rgba(148, 163, 184, 0.14);
    background: #0b1220;
  }
  .chart-canvas {
    display: block;
    width: 100%;
    min-width: 620px;
    height: auto;
  }
  .chart-note {
    margin-top: 0.65rem;
  }

  @media (max-width: 760px) {
    .control-grid {
      grid-template-columns: 1fr;
    }
    .model-card {
      padding: 0.85rem;
    }
  }
</style>

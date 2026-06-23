<script>
  import { onMount, onDestroy, afterUpdate } from 'svelte';

  export let samples = [];

  let canvasEl;
  let chart = null;
  let Chart;

  onMount(async () => {
    const mod = await import('chart.js');
    Chart = mod.Chart;
    Chart.register(...mod.registerables);
    buildChart();
  });

  afterUpdate(() => {
    if (Chart && canvasEl) buildChart();
  });

  onDestroy(() => { chart?.destroy(); });

  function buildChart() {
    if (!canvasEl || !Chart || samples.length === 0) return;
    chart?.destroy();

    // Zeitachse: Sekunden ab Start
    const t0 = samples[0].ts_ms;
    const labels = samples.map(s => ((s.ts_ms - t0) / 1000).toFixed(0));

    const rmsMg  = samples.map(s => s.rms_g  != null ? +(s.rms_g  * 1000).toFixed(2) : null);
    const iri    = samples.map(s => s.iri_m_km != null ? +s.iri_m_km.toFixed(3) : null);
    const speed  = samples.map(s => s.speed_kmh != null ? +s.speed_kmh.toFixed(1) : null);

    chart = new Chart(canvasEl, {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'RMS [mg]',
            data: rmsMg,
            borderColor: '#60a5fa',
            backgroundColor: 'rgba(96,165,250,0.08)',
            borderWidth: 1.5,
            pointRadius: 0,
            yAxisID: 'yRms',
            tension: 0.3,
            spanGaps: true,
          },
          {
            label: 'IRI [m/km]',
            data: iri,
            borderColor: '#4ade80',
            backgroundColor: 'rgba(74,222,128,0.08)',
            borderWidth: 1.5,
            pointRadius: 0,
            yAxisID: 'yIri',
            tension: 0.3,
            spanGaps: true,
          },
          {
            label: 'Speed [km/h]',
            data: speed,
            borderColor: '#a78bfa',
            borderWidth: 1,
            pointRadius: 0,
            yAxisID: 'ySpeed',
            tension: 0.3,
            borderDash: [4, 3],
            spanGaps: true,
          },
        ],
      },
      options: {
        animation: false,
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: {
            labels: { color: '#8b949e', font: { size: 11 }, boxWidth: 12, padding: 16 },
          },
          tooltip: {
            backgroundColor: '#161b22',
            borderColor: '#30363d',
            borderWidth: 1,
            titleColor: '#e6edf3',
            bodyColor: '#8b949e',
            padding: 10,
          },
        },
        scales: {
          x: {
            ticks: { color: '#8b949e', font: { size: 10 }, maxTicksLimit: 12 },
            grid: { color: '#21262d' },
            title: { display: true, text: 'Zeit [s]', color: '#8b949e', font: { size: 11 } },
          },
          yRms: {
            type: 'linear',
            position: 'left',
            ticks: { color: '#60a5fa', font: { size: 10 } },
            grid: { color: '#21262d' },
            title: { display: true, text: 'RMS [mg]', color: '#60a5fa', font: { size: 11 } },
          },
          yIri: {
            type: 'linear',
            position: 'right',
            ticks: { color: '#4ade80', font: { size: 10 } },
            grid: { drawOnChartArea: false },
            title: { display: true, text: 'IRI [m/km]', color: '#4ade80', font: { size: 11 } },
          },
          ySpeed: {
            type: 'linear',
            position: 'right',
            display: false,
          },
        },
      },
    });
  }
</script>

<div class="chart-wrap">
  <canvas bind:this={canvasEl}></canvas>
</div>

<style>
  .chart-wrap {
    height: 140px;
    width: 100%;
  }
  canvas { width: 100% !important; }
</style>

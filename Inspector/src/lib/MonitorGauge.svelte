<script lang="ts">
  import { dialArc, dialPoint, formatNumber, gaugeFraction, gaugeScale, gaugeZones, thresholds, thresholdText } from "./monitors";
  import type { MonitorInfo } from "./types";

  let { monitor }: { monitor: MonitorInfo } = $props();
  // A half-circle dial: coloured bands for the healthy, warning and error
  // ranges, ticks, the two thresholds marked across the band, and a needle.
  const cx = 84;
  const cy = 86;
  const radius = 66;
  const scale = $derived(gaugeScale(monitor));
  const zones = $derived(gaugeZones(monitor, scale));
  const ticks = Array.from({ length: 21 }, (_, index) => index / 20);
  const marks = $derived(thresholds(monitor).map((mark) => ({ state: mark.state, at: gaugeFraction(mark.value, scale) })));
  const needle = $derived(monitor.value != null && Number.isFinite(monitor.value) ? gaugeFraction(monitor.value, scale) : null);
  const line = (at: number, from: number, to: number) => {
    const [x1, y1] = dialPoint(at, from, cx, cy);
    const [x2, y2] = dialPoint(at, to, cx, cy);
    return { x1, y1, x2, y2 };
  };
  const label = $derived(`${monitor.name}: ${monitor.value == null ? "no sample" : monitor.display || formatNumber(monitor.value)}; ${thresholdText(monitor)}; dial from ${formatNumber(scale.min)} to ${formatNumber(scale.max)}`);
</script>

<svg class="gauge" class:disabled={!monitor.enabled} viewBox="0 0 168 104" width="168" height="104" role="img" aria-label={label}>
  <path class="track" d={dialArc(0, 1, radius, cx, cy)} />
  {#each zones as zone}<path class="zone zone-{zone.state}" d={dialArc(zone.from, zone.to, radius + 3, cx, cy)} />{/each}
  {#each ticks as at, index}<line class="tick" class:major={index % 5 === 0} {...line(at, radius - 7, radius - (index % 5 === 0 ? 15 : 11))} />{/each}
  {#each marks as mark}<line class="mark mark-{mark.state}" {...line(mark.at, radius + 7, radius - 16)} />{/each}
  {#if needle === null}
    <path class="no-sample" d={dialArc(0, 1, radius - 24, cx, cy)} />
  {:else}
    <line class="needle needle-{monitor.state}" {...line(needle, 0, radius - 9)} />
  {/if}
  <circle class="hub" cx={cx} cy={cy} r="6" />
  <circle class="hub-head" cx={cx} cy={cy} r="2.4" />
  <text class="scale" x={cx - radius} y={cy + 15} text-anchor="middle">{formatNumber(scale.min)}</text>
  <text class="scale" x={cx + radius} y={cy + 15} text-anchor="middle">{formatNumber(scale.max)}</text>
</svg>

<style>
  .gauge { display: block; flex: none; overflow: visible; }
  .track { fill: none; stroke: var(--inset); stroke-width: 12; }
  .zone { fill: none; stroke-width: 4; }
  .zone-ok { stroke: var(--verdigris); opacity: .45; }
  .zone-warning { stroke: var(--amber); opacity: .7; }
  .zone-error { stroke: var(--danger); opacity: .75; }
  .tick { stroke: var(--faint); stroke-width: 1; opacity: .7; }
  .tick.major { stroke: var(--muted); stroke-width: 1.4; opacity: 1; }
  .mark { stroke-width: 2.2; stroke-linecap: round; }
  .mark-warning { stroke: var(--amber); }
  .mark-error { stroke: var(--danger); }
  .needle { stroke: var(--accent); stroke-width: 2.2; stroke-linecap: round; }
  .needle-warning { stroke: var(--amber); }
  .needle-error { stroke: var(--danger); }
  .no-sample { fill: none; stroke: var(--faint); stroke-width: 1; stroke-dasharray: 2 4; }
  .hub { fill: var(--raised); stroke: var(--accent-dim); stroke-width: 1.5; }
  .hub-head { fill: var(--accent); }
  .scale { fill: var(--faint); font: 12px var(--mono); }
  .disabled { opacity: .45; filter: grayscale(1); }
  @media print { .track { stroke: #eee; } }
</style>

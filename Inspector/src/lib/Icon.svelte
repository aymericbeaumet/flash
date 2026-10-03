<script lang="ts">
  let { name, size = 18 }: { name: string; size?: number } = $props();
  const paths: Record<string, string> = {
    home: "m3 10 9-7 9 7v10H3z M9 20v-7h6v7",
    docs: "M4 3h6l2 2 2-2h6v17h-6l-2 1-2-1H4z M12 5v16 M6 8h3 M15 8h3 M6 12h3 M15 12h3",
    mappings: "M3 5h18v14H3z M6 9h1 M10 9h1 M14 9h1 M18 9h.1 M6 13h1 M10 13h1 M14 13h4 M8 16h8",
    commands: "m5 5 6 6-6 6 M13 18h6",
    plugins: "M9 3v4 M15 3v4 M6 7h12v4a6 6 0 0 1-6 6v4 M6 11a6 6 0 0 0 6 6",
    state: "M3 12h4l3-8 4 16 3-8h4",
    logs: "M5 4h14v16H5z M8 8h8 M8 12h8 M8 16h5",
    clipboard: "M9 5H5v16h14V5h-4 M9 3h6v4H9z M8 12h8 M8 16h5",
    search: "M10 17a7 7 0 1 0 0-14 7 7 0 0 0 0 14 M15 15l6 6",
    arrow: "M4 12h15 M13 6l6 6-6 6",
    bolt: "m13 2-9 12h7l-1 8 10-13h-7z",
    grid: "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z",
    close: "m6 6 12 12 M6 18 18 6",
    check: "m5 12 4 4L19 6",
    settings: "M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M9 15v6",
    chevron: "m9 5 7 7-7 7",
    shield: "m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z M8 12l3 3 5-6",
    menu: "M4 6h16 M4 12h16 M4 18h16",
  };
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={paths[name] ?? paths.docs} /></svg>

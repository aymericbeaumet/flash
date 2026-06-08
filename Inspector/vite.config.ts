import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// The flash runtime serves the inspector as a single self-contained
// HTML document (no network access to a CDN, no separate asset routes),
// so everything is inlined into one file that the Swift DebugServer ships
// verbatim as a SwiftPM resource.
export default defineConfig({
  plugins: [svelte(), viteSingleFile()],
  build: {
    target: "es2022",
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
    chunkSizeWarningLimit: 100_000_000,
    reportCompressedSize: false,
  },
});

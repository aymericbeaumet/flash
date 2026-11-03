import { readFileSync } from "node:fs";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// The flash runtime serves the inspector as a single self-contained
// HTML document (no network access to a CDN, no separate asset routes),
// so everything is inlined into one file that the Swift DebugServer ships
// verbatim as a SwiftPM resource.
//
// `--mode site` builds the published manual's browser side instead: the same
// App hydrating prerendered pages, with shared scripts and styles under the
// site's path (`docs/nav.json` names it). `scripts/site.ts` drives that build
// and its server render.
export default defineConfig(({ mode }) => {
  if (mode === "site") {
    const site = JSON.parse(readFileSync(new URL("../docs/nav.json", import.meta.url), "utf8")) as { site: { url: string } };
    return {
      base: new URL(site.site.url).pathname,
      plugins: [svelte()],
      build: {
        target: "es2022",
        outDir: "dist-site/client",
        emptyOutDir: true,
        assetsDir: "_app",
        cssCodeSplit: false,
        reportCompressedSize: false,
        minify: "oxc",
        rollupOptions: { input: "site.html" },
      },
    };
  }
  const dev = mode === "development";
  return {
    // Keep intermediate chunks for Vite's license inventory. Only index.html
    // is shipped; its scripts and styles are still inlined.
    plugins: [svelte(), viteSingleFile({ deleteInlinedFiles: false })],
    build: {
      target: "es2022",
      license: { fileName: "licenses.json" },
      cssCodeSplit: false,
      assetsInlineLimit: 100_000_000,
      chunkSizeWarningLimit: 100_000_000,
      reportCompressedSize: false,
      // A `--dev` install wants a fast, readable bundle; a release install
      // wants the optimized one. Both still inline to a single file.
      minify: dev ? false : "oxc",
      sourcemap: dev,
    },
  };
});

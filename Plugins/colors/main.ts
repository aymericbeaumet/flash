// CSS color conversions, in TypeScript on Bun (one of the deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Additive evaluator: input that parses as `#rgb`/`#rrggbb`, `rgb(r, g, b)`,
// or `hsl(h, s%, l%)` answers with all three forms, each copyable. Anything
// else is declined with an empty answer list — pure in-memory arithmetic,
// nothing warmed, no I/O anywhere.

import { Plugin, type Answer } from "../_typescript_flash_plugin/flashplugin";

type RGB = { r: number; g: number; b: number };

const HEX = /^#([0-9a-f]{3}|[0-9a-f]{6})$/;
const RGB_FN = /^rgb\(\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*\)$/;
const HSL_FN =
  /^hsl\(\s*(\d{1,3}(?:\.\d+)?)\s*[, ]\s*(\d{1,3}(?:\.\d+)?)%\s*[, ]\s*(\d{1,3}(?:\.\d+)?)%\s*\)$/;

function parse(query: string): RGB | null {
  const hex = HEX.exec(query);
  if (hex) {
    let digits = hex[1];
    if (digits.length === 3) digits = [...digits].map((d) => d + d).join("");
    const value = parseInt(digits, 16);
    return { r: value >> 16, g: (value >> 8) & 0xff, b: value & 0xff };
  }
  const rgb = RGB_FN.exec(query);
  if (rgb) {
    const [r, g, b] = [+rgb[1], +rgb[2], +rgb[3]];
    return r > 255 || g > 255 || b > 255 ? null : { r, g, b };
  }
  const hsl = HSL_FN.exec(query);
  if (hsl) {
    const [h, s, l] = [+hsl[1] % 360, +hsl[2] / 100, +hsl[3] / 100];
    if (s > 1 || l > 1) return null;
    // Standard HSL→RGB (CSS Color 4 reference algorithm).
    const f = (n: number) => {
      const k = (n + h / 30) % 12;
      const a = s * Math.min(l, 1 - l);
      return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    };
    return {
      r: Math.round(f(0) * 255),
      g: Math.round(f(8) * 255),
      b: Math.round(f(4) * 255),
    };
  }
  return null;
}

function toHsl({ r, g, b }: RGB): string {
  const [rn, gn, bn] = [r / 255, g / 255, b / 255];
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const l = (max + min) / 2;
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === rn) h = ((gn - bn) / d) % 6;
    else if (max === gn) h = (bn - rn) / d + 2;
    else h = (rn - gn) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  const s = l === 0 || l === 1 ? 0 : d / (1 - Math.abs(2 * l - 1));
  const pct = (x: number) => `${Math.round(x * 100)}%`;
  return `hsl(${Math.round(h)}, ${pct(s)}, ${pct(l)})`;
}

const plugin = new Plugin();
plugin.onQuery = (params) => {
  const query = String(params.query ?? "").trim().toLowerCase();
  const rgb = parse(query);
  if (rgb === null) return [];
  const hexDigit = (v: number) => v.toString(16).padStart(2, "0");
  const forms = [
    `#${hexDigit(rgb.r)}${hexDigit(rgb.g)}${hexDigit(rgb.b)}`,
    `rgb(${rgb.r}, ${rgb.g}, ${rgb.b})`,
    toHsl(rgb),
  ];
  return forms.map(
    (title): Answer => ({
      title,
      subtitle: "color",
      effect: { type: "copy_text", text: title },
    }),
  );
};
await plugin.serve();

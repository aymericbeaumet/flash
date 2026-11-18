import svelte from "eslint-plugin-svelte";
import ts from "typescript-eslint";

// Prettier owns the layout; svelte-check owns the types and the compiler's warnings. ESLint
// holds what neither can state: what the page may execute and which module may import which.

// Import boundaries. A file takes the last `boundary` that names it.
const marked = {
  name: "marked",
  message: "Only src/lib/markdown.ts lexes Markdown; read its tree through markdown-tree.ts.",
};
const buildScripts = {
  regex: "(^|/)scripts/",
  message: "The build scripts stay out of the page.",
};
const lexer = {
  regex: "(^|/)markdown(\\.ts)?$",
  message: "This module stays free of the Markdown lexer; markdown-tree.ts has the tree.",
};
const boundary = (files, paths, patterns) => ({
  files,
  rules: { "no-restricted-imports": ["error", { paths, patterns }] },
});

export default [
  { ignores: ["dist/", "dist-site/"] },
  ...svelte.configs.base,
  {
    files: ["**/*.ts", "**/*.js"],
    languageOptions: { parser: ts.parser },
  },
  {
    files: ["**/*.svelte", "**/*.svelte.ts"],
    languageOptions: { parserOptions: { parser: ts.parser } },
  },
  {
    plugins: { "@typescript-eslint": ts.plugin },
    rules: {
      // No string is parsed as HTML or run as code: the manual renders from a tree, and
      // plugin-authored Markdown and live values are untrusted text.
      "svelte/no-at-html-tags": "error",
      "no-restricted-properties": [
        "error",
        { property: "innerHTML", message: "Build nodes; no string is parsed as HTML." },
        { property: "outerHTML", message: "Build nodes; no string is parsed as HTML." },
        { property: "insertAdjacentHTML", message: "Build nodes; no string is parsed as HTML." },
        { object: "document", property: "write", message: "Build nodes instead." },
      ],
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-new-func": "error",

      // Leftovers of a debugging session.
      "no-debugger": "error",
      "svelte/no-at-debug-tags": "error",
      "svelte/no-inspect": "error",

      // Escapes from the type check.
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/ban-ts-comment": "error",
    },
  },
  {
    // The page reports through its own surfaces; only the build scripts own a terminal.
    files: ["src/**"],
    rules: { "no-console": "error" },
  },
  boundary(["src/**"], [marked], [buildScripts]),
  boundary(["src/lib/markdown.ts"], [], [buildScripts]),
  // What the page needs of the manual without rendering Markdown.
  boundary(["src/lib/markdown-tree.ts", "src/lib/docsite.ts"], [marked], [buildScripts, lexer]),
];

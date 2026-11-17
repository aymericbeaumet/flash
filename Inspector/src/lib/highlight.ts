/**
 * A small syntax highlighter for the fenced code the documentation uses:
 * TOML, shell, JSON, Rust and Lua. It splits a block into runs and names the
 * kind of each; the renderer turns a named run into a `<span class="tok-…">`
 * and leaves the rest as text. Unknown languages stay plain. Nothing loads
 * from the network and nothing is parsed as HTML.
 */

export type TokenKind = "comment" | "string" | "number" | "keyword" | "key" | "section" | "variable" | "flag" | "function" | "type";
export type Run = { text: string; kind?: TokenKind };

type Rule = [TokenKind, RegExp];

const word = (words: string) => new RegExp(`\\b(?:${words.split(" ").join("|")})\\b`, "y");
const doubleQuoted = /"(?:\\.|[^"\\\n])*"/y;
const singleQuoted = /'[^'\n]*'/y;
const number = /-?\b(?:0x[\da-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b/y;

const toml: Rule[] = [
  ["comment", /#[^\n]*/y],
  ["section", /(?<=^|\n)[ \t]*\[\[?[^\]\n]+\]\]?/y],
  ["key", /(?:"(?:\\.|[^"\\\n])*"|[A-Za-z0-9_.-]+)(?=[ \t]*=)/y],
  ["string", /"""[\s\S]*?"""|'''[\s\S]*?'''/y],
  ["string", doubleQuoted],
  ["string", singleQuoted],
  ["keyword", word("true false")],
  ["number", /\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?/y],
  ["number", number],
];

const json: Rule[] = [
  ["key", /"(?:\\.|[^"\\\n])*"(?=\s*:)/y],
  ["string", doubleQuoted],
  ["keyword", word("true false null")],
  ["number", number],
];

const shell: Rule[] = [
  ["comment", /(?<=^|\s)#[^\n]*/y],
  ["string", doubleQuoted],
  ["string", singleQuoted],
  ["variable", /\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@#?*$!-])/y],
  ["flag", /(?<=\s)--?[A-Za-z][\w-]*/y],
  ["keyword", word("if then else elif fi for while until do done case esac function in export local return set source")],
];

const rust: Rule[] = [
  ["comment", /\/\/[^\n]*|\/\*[\s\S]*?\*\//y],
  ["string", /r#*"[\s\S]*?"#*/y],
  ["string", doubleQuoted],
  ["keyword", word("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while")],
  ["function", /\b[a-z_][a-z0-9_]*!/y],
  ["type", /\b[A-Z][A-Za-z0-9_]*\b/y],
  ["number", number],
];

const lua: Rule[] = [
  ["comment", /--\[\[[\s\S]*?\]\]|--[^\n]*/y],
  ["string", doubleQuoted],
  ["string", singleQuoted],
  ["keyword", word("and break do else elseif end false for function if in local nil not or repeat return then true until while")],
  ["number", number],
];

const languages: Record<string, Rule[]> = { toml, json, jsonc: json, sh: shell, bash: shell, shell, zsh: shell, console: shell, rust, rs: rust, lua };

/** Splits `code` into runs; an unknown language is one plain run. */
export function highlight(code: string, language: string | undefined): Run[] {
  const rules = language ? languages[language.toLowerCase()] : undefined;
  if (!rules) return code ? [{ text: code }] : [];
  const runs: Run[] = [];
  let plain = "";
  let position = 0;
  outer: while (position < code.length) {
    for (const [kind, pattern] of rules) {
      pattern.lastIndex = position;
      const match = pattern.exec(code);
      if (!match || !match[0]) continue;
      if (plain) { runs.push({ text: plain }); plain = ""; }
      runs.push({ text: match[0], kind });
      position += match[0].length;
      continue outer;
    }
    // A word that no rule claims moves as one, so a keyword never starts
    // in the middle of an identifier.
    const rest = /[A-Za-z0-9_]+|[^]/y;
    rest.lastIndex = position;
    const step = rest.exec(code)![0];
    plain += step;
    position += step.length;
  }
  if (plain) runs.push({ text: plain });
  return runs;
}

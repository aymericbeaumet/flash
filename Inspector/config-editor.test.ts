import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  blocksSave,
  ConfigChecker,
  lineMarks,
  offsetOfLine,
  readCheckReply,
  summarize,
  type CheckState,
  type EditorDiagnostic,
} from "./src/lib/config-check.ts";
import { configDocument, type ConfigSourceNode } from "./src/lib/config-json.ts";
import { keyHelp, type SchemaNode } from "./src/lib/config-schema.ts";
import { keyPathAt } from "./src/lib/toml-caret.ts";

const file = "/Users/me/.config/flash/flash.toml";

test("a check reply becomes the editor's diagnostics, placed and ranked", () => {
  const reply = {
    path: file,
    diagnostics: [
      { path: file, line: 2, column: 7, message: 'mapping "t": expected an argv array' },
      { path: file, line: 5, column: 14, message: "hints.min_length: must be at least 1" },
      { path: "/Applications/Flash.app/config.default.toml", line: 9, column: 1, message: "x" },
      { path: file, message: "plugins.feed: unknown plugin" },
    ],
  };
  assert.deepEqual(readCheckReply(reply), [
    {
      severity: "error",
      line: 2,
      column: 7,
      message: 'mapping "t": expected an argv array',
    },
    { severity: "error", line: 5, column: 14, message: "hints.min_length: must be at least 1" },
    // Another file's diagnostic is not this text's to fix: no line here, and it never blocks.
    {
      severity: "warning",
      message: "x",
      file: "/Applications/Flash.app/config.default.toml:9:1",
    },
    { severity: "error", message: "plugins.feed: unknown plugin" },
  ]);
  assert.deepEqual(readCheckReply({ path: file, diagnostics: [] }), []);
  for (const malformed of [
    null,
    [],
    { path: file },
    { path: file, diagnostics: [{ path: file }] },
    { path: file, diagnostics: [{ path: file, message: "m", line: "2" }] },
    { diagnostics: [] },
  ])
    assert.throws(() => readCheckReply(malformed), /check reply/, JSON.stringify(malformed));
});

/** A checker whose clock and replies are driven by hand. */
function checker(delayMs = 300) {
  let time = 0;
  let serial = 0;
  const timers = new Map<number, { at: number; callback: () => void }>();
  const requests: { text: string; signal: AbortSignal; answer: (reply: unknown) => void }[] = [];
  const seen: CheckState[] = [];
  const check = new ConfigChecker(
    (text, signal) =>
      new Promise((resolve, reject) => {
        requests.push({
          text,
          signal,
          answer: (reply) => (reply instanceof Error ? reject(reply) : resolve(reply)),
        });
      }),
    (state) => seen.push(state),
    {
      setTimer: (callback, delay) => {
        timers.set(++serial, { at: time + delay, callback });
        return serial;
      },
      clearTimer: (handle) => {
        timers.delete(handle as number);
      },
    },
    delayMs,
  );
  const flush = () => new Promise((resolve) => setImmediate(resolve));
  return {
    check,
    requests,
    seen,
    flush,
    last: () => seen.at(-1)!,
    advance(ms: number) {
      time += ms;
      for (const [handle, timer] of [...timers]) {
        if (timer.at > time) continue;
        timers.delete(handle);
        timer.callback();
      }
    },
  };
}
const reply = (...lines: number[]) => ({
  path: file,
  diagnostics: lines.map((line) => ({ path: file, line, column: 1, message: `line ${line}` })),
});

test("typing checks once it pauses, not per key", async () => {
  const { check, requests, advance, last, flush } = checker(300);
  check.edit("a");
  assert.deepEqual(last(), { status: "pending", diagnostics: [] });
  advance(200);
  check.edit("ab");
  advance(200);
  assert.equal(requests.length, 0, "the pause starts again with each key");
  advance(100);
  assert.deepEqual(
    requests.map((request) => request.text),
    ["ab"],
  );
  requests[0].answer(reply(3));
  await flush();
  assert.equal(last().status, "checked");
  assert.deepEqual(
    last().diagnostics.map((diagnostic) => diagnostic.line),
    [3],
  );
  check.edit("ab");
  advance(1000);
  assert.equal(requests.length, 1, "the same text is not checked again");
});

test("a stale reply never overwrites a newer one, in either order", async () => {
  const { check, requests, advance, last, seen, flush } = checker(300);
  check.edit("one");
  advance(300);
  check.edit("two");
  // The first check is still in flight; what it found stays up, marked as not current.
  assert.equal(last().status, "pending");
  assert.equal(requests[0].signal.aborted, true, "an overtaken check is abandoned");
  advance(300);
  assert.equal(requests.length, 2);
  // The newer reply lands first, then the older one.
  requests[1].answer(reply(2));
  await flush();
  requests[0].answer(reply(1));
  await flush();
  assert.equal(last().status, "checked");
  assert.deepEqual(
    last().diagnostics.map((diagnostic) => diagnostic.line),
    [2],
  );
  // The older reply lands while the newer text still waits for its pause.
  const before = seen.length;
  check.edit("three");
  advance(300);
  check.edit("four");
  requests[2].answer(reply(3));
  await flush();
  assert.equal(seen.length, before + 2, "only the two edits changed the state");
  assert.equal(last().status, "pending");
  assert.deepEqual(
    last().diagnostics.map((diagnostic) => diagnostic.line),
    [2],
    "the last verdict stays until the new one",
  );
});

test("a check that fails says so, and blocks nothing", async () => {
  const { check, requests, advance, last, flush } = checker();
  check.edit("a");
  advance(300);
  requests[0].answer(new TypeError("Failed to fetch"));
  await flush();
  assert.equal(last().status, "failed");
  assert.match(last().error ?? "", /not answering/);
  assert.deepEqual(last().diagnostics, []);
  assert.equal(blocksSave(last()), false);
  // The same text is asked again: the failure was the request's, not the text's.
  check.edit("a");
  advance(300);
  assert.equal(requests.length, 2);
  requests[1].answer({ nonsense: true });
  await flush();
  assert.equal(last().status, "failed");
  assert.match(last().error ?? "", /check reply/);
});

test("saving settles the verdict on the text it writes, without waiting for the pause", async () => {
  const { check, requests, last, flush } = checker();
  check.edit("a");
  const settled = check.settle("a");
  assert.equal(requests.length, 1, "the pending check runs now");
  requests[0].answer(reply(1));
  const verdict = await settled;
  assert.equal(verdict.status, "checked");
  assert.equal(blocksSave(verdict), true);
  assert.equal(await check.settle("a"), last(), "a settled text asks nothing");
  assert.equal(requests.length, 1);
  // Text the checker never saw is checked first.
  const next = check.settle("b");
  assert.equal(requests.length, 2);
  // An edit made while the save waits makes its verdict stale: nothing to save on.
  check.edit("c");
  requests[1].answer(reply());
  await flush();
  assert.equal((await next).status, "pending");
  check.stop();
});

test("only an error in the checked text blocks a save", () => {
  const error: EditorDiagnostic = { severity: "error", line: 1, message: "e" };
  const warning: EditorDiagnostic = { severity: "warning", message: "w", file: "elsewhere" };
  assert.equal(blocksSave({ status: "checked", diagnostics: [warning] }), false);
  assert.equal(blocksSave({ status: "checked", diagnostics: [warning, error] }), true);
  assert.equal(blocksSave({ status: "pending", diagnostics: [error] }), false);
  assert.equal(summarize({ status: "checked", diagnostics: [] }), "No problems");
  assert.equal(summarize({ status: "checked", diagnostics: [error] }), "1 error");
  assert.equal(
    summarize({ status: "checked", diagnostics: [error, error, warning] }),
    "2 errors, 1 warning",
  );
  assert.equal(summarize({ status: "pending", diagnostics: [error] }), "Checking…");
  assert.equal(summarize({ status: "failed", diagnostics: [], error: "x" }), "Not checked");
  assert.equal(summarize({ status: "idle", diagnostics: [] }), "");
});

test("diagnostics mark their lines in the gutter, the worst one winning", () => {
  const marks = lineMarks(
    [
      { severity: "warning", line: 2, message: "first" },
      { severity: "error", line: 2, message: "second" },
      { severity: "error", line: 9, message: "past the end" },
      { severity: "error", line: 0, message: "before the start" },
      { severity: "error", message: "nowhere" },
    ],
    4,
  );
  assert.deepEqual(marks, [
    { line: 1, severity: "error", title: "before the start" },
    { line: 2, severity: "error", title: "first\nsecond" },
    { line: 4, severity: "error", title: "past the end" },
  ]);
});

test("a diagnostic's line and column are a caret position in the text", () => {
  const text = "[hints]\nmin_length = 0\n\nkeys = 'abc'";
  assert.equal(offsetOfLine(text, 1), 0);
  assert.equal(offsetOfLine(text, 2), 8);
  assert.equal(offsetOfLine(text, 2, 14), 21);
  assert.equal(offsetOfLine(text, 2, 99), 22, "a column past the line stops at its end");
  assert.equal(offsetOfLine(text, 3), 23);
  assert.equal(offsetOfLine(text, 4, 1), 24);
  assert.equal(offsetOfLine(text, 99), text.length, "a line past the text is its end");
  assert.equal(offsetOfLine(text, 0), 0);
  assert.equal(offsetOfLine("a\r\nb", 2), 3);
});

const toml = `# Flash
top = 1

[hints]
min_length = 2 # shortest label
keys = "<qwerty>"

[mode.normal.mappings]
"t" = ["flash", "tab", "new"]
"g.g" = false
a.b = 1
many = [
  "one",
  "two # not a comment",
]
after = true
text = """
[not.a.table]
still = "text"
"""
'lit eral' = 1

[[tiling.rules]]
app = "x"
[plugins."com.example"]
deep = { inner = 1 }
`;
const at = (needle: string, into = 0) => {
  const index = toml.indexOf(needle);
  assert.notEqual(index, -1, needle);
  return keyPathAt(toml, index + into);
};

test("the caret's key path follows TOML's tables, keys and open values", () => {
  assert.deepEqual(at("# Flash"), []);
  assert.deepEqual(at("top = 1"), ["top"]);
  assert.deepEqual(at("[hints]", 3), ["hints"]);
  assert.deepEqual(at("min_length"), ["hints", "min_length"]);
  assert.deepEqual(at("# shortest"), ["hints", "min_length"], "anywhere on the key's line");
  assert.deepEqual(at('"<qwerty>"'), ["hints", "keys"]);
  assert.deepEqual(at('"t" ='), ["mode", "normal", "mappings", "t"]);
  assert.deepEqual(at('"g.g"'), ["mode", "normal", "mappings", "g.g"], "a quoted dot is no path");
  assert.deepEqual(at("a.b = 1"), ["mode", "normal", "mappings", "a", "b"]);
  assert.deepEqual(at('"one"'), ["mode", "normal", "mappings", "many"]);
  assert.deepEqual(at('"two #'), ["mode", "normal", "mappings", "many"]);
  assert.deepEqual(at("]\nafter"), ["mode", "normal", "mappings", "many"]);
  assert.deepEqual(at("after = true"), ["mode", "normal", "mappings", "after"]);
  assert.deepEqual(at("[not.a.table]"), ["mode", "normal", "mappings", "text"]);
  assert.deepEqual(at('still = "text"'), ["mode", "normal", "mappings", "text"]);
  assert.deepEqual(at("'lit eral'"), ["mode", "normal", "mappings", "lit eral"]);
  assert.deepEqual(at("[[tiling.rules]]"), ["tiling", "rules"]);
  assert.deepEqual(at('app = "x"'), ["tiling", "rules", "app"]);
  assert.deepEqual(at('[plugins."com.example"]'), ["plugins", "com.example"]);
  assert.deepEqual(at("deep = {"), ["plugins", "com.example", "deep"]);
  assert.deepEqual(keyPathAt(toml, toml.length), ["plugins", "com.example"]);
  assert.deepEqual(keyPathAt("", 0), []);
  assert.deepEqual(keyPathAt("[hints", 3), [], "a header that does not close names nothing");
  assert.deepEqual(keyPathAt("[hints]\n= 3", 9), ["hints"]);
});

const schema: SchemaNode = {
  type: "object",
  description: "Flash's configuration.",
  properties: {
    hints: {
      type: "object",
      description: "Hint labels.",
      properties: {
        min_length: { type: "integer", minimum: 1, description: "Shortest label." },
        adjust_digits: { type: "string", enum: ["width", "grid"] },
      },
    },
    mode: {
      properties: {
        normal: {
          properties: {
            mappings: {
              type: "object",
              description: "Key → command.",
              additionalProperties: {
                description: "A command for the key, or false.",
                anyOf: [{ type: "array", items: { type: "string" } }, { const: false }],
              },
            },
          },
        },
      },
    },
    tiling: {
      properties: {
        rules: {
          type: "array",
          description: "Windows that float.",
          items: { type: "object", properties: { app: { type: "string", description: "App." } } },
        },
      },
    },
  },
};

test("the key under the caret reads its help from the schema", () => {
  assert.deepEqual(keyHelp(schema, ["hints", "min_length"]), {
    key: "hints.min_length",
    type: "integer",
    description: "Shortest label.",
  });
  // A key without words of its own shows its table's, and says whose they are.
  assert.deepEqual(keyHelp(schema, ["hints", "adjust_digits"]), {
    key: "hints.adjust_digits",
    type: "string",
    values: ['"width"', '"grid"'],
    description: "Hint labels.",
    from: "hints",
  });
  assert.deepEqual(keyHelp(schema, ["mode", "normal", "mappings", "g.g"]), {
    key: 'mode.normal.mappings."g.g"',
    type: "array or false",
    description: "A command for the key, or false.",
  });
  assert.deepEqual(keyHelp(schema, ["tiling", "rules"]), {
    key: "tiling.rules",
    type: "array",
    description: "Windows that float.",
  });
  assert.deepEqual(keyHelp(schema, ["tiling", "rules", "app"]), {
    key: "tiling.rules.app",
    type: "string",
    description: "App.",
  });
  // A key the schema does not have: its nearest table's words, and no type.
  assert.deepEqual(keyHelp(schema, ["hints", "nope", "deeper"]), {
    key: "hints.nope.deeper",
    unknown: true,
    description: "Hint labels.",
    from: "hints",
  });
  assert.equal(keyHelp(schema, []), null);
});

test("the published schema answers for the keys of the reference file", () => {
  const published = JSON.parse(
    readFileSync(new URL("../docs/schema/flash.schema.json", import.meta.url), "utf8"),
  ) as SchemaNode;
  const reference = readFileSync(new URL("../config.default.toml", import.meta.url), "utf8");
  const leader = keyHelp(published, keyPathAt(reference, reference.indexOf("\nleader = ") + 1));
  assert.equal(leader?.key, "mode.normal.leader");
  assert.ok(!leader?.unknown && leader?.type && leader.description, JSON.stringify(leader));
  const mapping = keyHelp(published, ["mode", "normal", "mappings", "t"]);
  assert.match(mapping?.description ?? "", /argv array/);
});

const resolved = {
  hints: { keys: "abc", min_length: 1 },
  statusbar: { enabled: true, height: 24 },
  plugins: { enabled: ["tmux", "feed"] },
  untouched: { a: 1 },
};
const sources: ConfigSourceNode = {
  hints: { keys: { $: { layer: "config", where: "flash.toml" } } },
  statusbar: { $: { layer: "env", where: "FLASH_STATUSBAR" } },
  plugins: { enabled: { feed: { $: { layer: "config", where: "flash.toml" } } } },
  untouched: { a: { $: { layer: "default" } } },
};
const textOf = (document: { tokens: { text: string }[] }) =>
  JSON.parse(document.tokens.map((token) => token.text).join(""));

test("overrides only keeps what a layer above the defaults wrote", () => {
  assert.deepEqual(textOf(configDocument(resolved, sources, "", false)), resolved);
  const only = configDocument(resolved, sources, "", true);
  assert.deepEqual(textOf(only), {
    hints: { keys: "abc" },
    statusbar: { enabled: true, height: 24 },
    plugins: { enabled: ["feed"] },
  });
  assert.deepEqual(
    only.tokens.filter((token) => token.where).map((token) => token.where),
    ["config · flash.toml", "config · flash.toml", "env · FLASH_STATUSBAR"],
  );
  // The search narrows the overrides, never widens them.
  assert.deepEqual(textOf(configDocument(resolved, sources, "feed", true)), {
    plugins: { enabled: ["feed"] },
  });
  assert.equal(configDocument(resolved, sources, "min_length", true).empty, true);
  assert.equal(configDocument(resolved, { untouched: sources.untouched }, "", true).empty, true);
  assert.equal(configDocument(resolved, undefined, "", true).empty, true);
});

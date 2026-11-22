// Writes the snapshot's TypeScript types from its JSON Schema.
//
//   node scripts/state-types.ts    docs/schema/inspector/state.schema.json -> src/lib/state.generated.ts
//
// The schema is the contract: `InspectorStateSchemaTests` validates what the
// resident really builds against it, so the page's types are generated from
// it rather than written beside it. `mise run build:schema` runs this, and
// `state-types.test.ts` fails while the committed file is stale. It reads
// the subset of JSON Schema the state schema uses and refuses anything else.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export interface Schema {
  description?: string;
  type?: string | string[];
  enum?: unknown[];
  const?: unknown;
  properties?: Record<string, Schema>;
  required?: string[];
  additionalProperties?: boolean | Schema;
  maxProperties?: number;
  items?: Schema;
  anyOf?: Schema[];
  oneOf?: Schema[];
  $ref?: string;
  definitions?: Record<string, Schema>;
  [keyword: string]: unknown;
}

/** Keywords that shape a type, and those that only bound a value of it. */
const shaping = new Set([
  ...["type", "enum", "const", "properties", "required", "additionalProperties", "items"],
  ...["anyOf", "oneOf", "$ref", "maxProperties"],
]);
const bounding = new Set([
  ...["description", "title", "minimum", "maximum", "minItems", "maxItems"],
  ...["minLength", "maxLength", "pattern", "$schema", "$id", "definitions"],
]);

/** What the page calls a definition, where it is not the definition's name in PascalCase. */
const names: Record<string, string> = {
  command: "CommandInfo",
  event_monitor: "EventMonitorInfo",
  keyboard: "KeyboardState",
  mappings: "MappingsState",
  plugin: "PluginInfo",
  telemetry: "TelemetryState",
  telemetry_exporter: "TelemetryExporterState",
  telemetry_receiver: "TelemetryReceiverState",
  value_monitor: "MonitorInfo",
  // `Window` is the browser's.
  window: "FlashWindow",
};

const pascal = (name: string) =>
  name
    .split("_")
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join("");
const typeName = (definition: string) => names[definition] ?? pascal(definition);

const comment = (schema: Schema, indent: string) =>
  schema.description
    ? `${indent}/** ${schema.description.replace(/\s+/g, " ").replace(/\*\//g, "*\\/")} */\n`
    : "";
const key = (name: string) => (/^[A-Za-z_$][\w$]*$/.test(name) ? name : JSON.stringify(name));

/** A union's members, each once, in the order given. */
const union = (members: string[]) => [...new Set(members)].join(" | ");
/** An array of `element`: a union is parenthesized first. */
const arrayOf = (element: string) =>
  /[|\n]/.test(element) && !element.startsWith("{") ? `(${element})[]` : `${element}[]`;

function objectType(schema: Schema, where: string, indent: string): string {
  const properties = Object.entries(schema.properties ?? {});
  const additional = schema.additionalProperties;
  if (schema.maxProperties === 0) return "Record<string, never>";
  for (const name of schema.required ?? [])
    if (!schema.properties?.[name]) throw new Error(`${where}: requires ${name}, which it lacks`);
  if (!properties.length) {
    if (additional === false) return "Record<string, never>";
    return additional && typeof additional === "object"
      ? `Record<string, ${typeOf(additional, `${where}/*`, indent)}>`
      : "Record<string, unknown>";
  }
  const inner = `${indent}  `;
  const required = new Set(schema.required ?? []);
  const members = properties.map(([name, property]) => ({
    name,
    optional: !required.has(name),
    type: typeOf(property, `${where}/${name}`, inner),
    comment: comment(property, inner),
  }));
  const lines = members.map(
    (member) =>
      `${member.comment}${inner}${key(member.name)}${member.optional ? "?" : ""}: ${member.type};\n`,
  );
  if (additional !== false) {
    // TypeScript holds every named member to the index signature's type.
    const open =
      additional && typeof additional === "object"
        ? union([
            typeOf(additional, `${where}/*`, inner),
            ...members.map((member) => member.type),
            ...(members.some((member) => member.optional) ? ["undefined"] : []),
          ])
        : "unknown";
    lines.push(`${inner}[key: string]: ${open};\n`);
  }
  return `{\n${lines.join("")}${indent}}`;
}

function primitive(type: string, schema: Schema, where: string, indent: string): string {
  switch (type) {
    case "string":
    case "boolean":
    case "null":
      return type;
    case "integer":
    case "number":
      return "number";
    case "array":
      return arrayOf(schema.items ? typeOf(schema.items, `${where}[]`, indent) : "unknown");
    case "object":
      return objectType(schema, where, indent);
    default:
      throw new Error(`${where}: type ${type} is not one this generator writes`);
  }
}

/** The TypeScript type of `schema`, which sits at `where` in the document. */
function typeOf(schema: Schema, where: string, indent: string): string {
  for (const keyword of Object.keys(schema))
    if (!shaping.has(keyword) && !bounding.has(keyword))
      throw new Error(`${where}: ${keyword} is not a keyword this generator reads`);
  if (schema.$ref !== undefined) {
    const definition = /^#\/definitions\/([a-z][a-z0-9_]*)$/.exec(schema.$ref)?.[1];
    if (!definition) throw new Error(`${where}: ${schema.$ref} is not a local definition`);
    return typeName(definition);
  }
  if (schema.const !== undefined) return JSON.stringify(schema.const);
  if (schema.enum) return union(schema.enum.map((value) => JSON.stringify(value)));
  const alternatives = schema.anyOf ?? schema.oneOf;
  if (alternatives)
    return union(
      alternatives.map((alternative, index) => typeOf(alternative, `${where}|${index}`, indent)),
    );
  if (schema.type === undefined) throw new Error(`${where}: no type`);
  return union([schema.type].flat().map((type) => primitive(type, schema, where, indent)));
}

/** The generated module's text for the state schema `root`. */
export function stateTypes(root: Schema): string {
  const declare = (name: string, schema: Schema, where: string) => {
    const type = typeOf(schema, where, "");
    return (
      comment(schema, "") +
      (type.startsWith("{")
        ? `export interface ${name} ${type}\n`
        : `export type ${name} = ${type};\n`)
    );
  };
  const definitions = Object.entries(root.definitions ?? {});
  const taken = new Map<string, string>();
  for (const [definition] of definitions) {
    const name = typeName(definition);
    const other = taken.get(name);
    if (other || name === "StateSnapshot")
      throw new Error(`${definition} and ${other ?? "the snapshot"} are both ${name}`);
    taken.set(name, definition);
  }
  return [
    "// Generated by scripts/state-types.ts from docs/schema/inspector/state.schema.json.\n" +
      "// Do not edit: change the schema, then run `mise run build:schema`.\n",
    declare("StateSnapshot", { ...root, definitions: undefined }, "#"),
    ...definitions.map(([definition, schema]) =>
      declare(typeName(definition), schema, `#/definitions/${definition}`),
    ),
  ].join("\n");
}

export const schemaFile = new URL("../../docs/schema/inspector/state.schema.json", import.meta.url);
export const typesFile = new URL("../src/lib/state.generated.ts", import.meta.url);

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(typesFile, stateTypes(JSON.parse(readFileSync(schemaFile, "utf8")) as Schema));
  console.log(`Wrote ${fileURLToPath(typesFile)}`);
}

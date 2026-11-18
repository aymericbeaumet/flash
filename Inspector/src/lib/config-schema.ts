// What `flash.toml`'s JSON Schema says about a key, for the config editor's
// key help. The resident serves the schema of the version it runs with the
// manual's files (`/docs/schema/flash.schema.json`); this reads the subset
// of JSON Schema that `ConfigSchema` writes.

export interface SchemaNode {
  type?: string | string[];
  description?: string;
  enum?: unknown[];
  const?: unknown;
  default?: unknown;
  minimum?: number;
  maximum?: number;
  properties?: Record<string, SchemaNode>;
  additionalProperties?: SchemaNode | boolean;
  items?: SchemaNode;
  anyOf?: SchemaNode[];
}

/** Where the manual's files serve the schema. */
export const schemaAddress = "/docs/schema/flash.schema.json";

export interface KeyHelp {
  /** The key as TOML spells it. */
  key: string;
  type?: string;
  /** The values an enumerated key takes, as TOML writes them. */
  values?: string[];
  description?: string;
  /** The table whose description this is, when the key has none of its own. */
  from?: string;
  /** The schema has no such key. */
  unknown?: true;
}

/** The schema of `part` under `node`: a named key, a table's free keys, or the same inside an array of tables or an alternative. */
function child(node: SchemaNode, part: string): SchemaNode | undefined {
  const named = node.properties?.[part];
  if (named) return named;
  if (node.additionalProperties && typeof node.additionalProperties === "object")
    return node.additionalProperties;
  if (node.items) {
    const inside = child(node.items, part);
    if (inside) return inside;
  }
  for (const alternative of node.anyOf ?? []) {
    const inside = child(alternative, part);
    if (inside) return inside;
  }
  return undefined;
}

function typeOf(node: SchemaNode): string | undefined {
  if (node.type) return [node.type].flat().join(" or ");
  if (node.const !== undefined) return JSON.stringify(node.const);
  if (node.enum) return "one of";
  const alternatives = [...new Set((node.anyOf ?? []).map(typeOf).filter(Boolean))];
  return alternatives.length ? alternatives.join(" or ") : undefined;
}

const spell = (path: string[]) =>
  path.map((part) => (/^[A-Za-z0-9_-]+$/.test(part) ? part : JSON.stringify(part))).join(".");

/**
 * The help for the key at `path` (`keyPathAt`): its type, its values and its
 * description, or the nearest table's description when it has none. Null at
 * the top of the file.
 */
export function keyHelp(schema: SchemaNode, path: string[]): KeyHelp | null {
  if (!path.length) return null;
  let node: SchemaNode | undefined = schema;
  let described: { description: string; depth: number } | undefined;
  for (let depth = 0; depth < path.length && node; depth += 1) {
    node = child(node, path[depth]);
    if (node?.description) described = { description: node.description, depth: depth + 1 };
  }
  const help: KeyHelp = { key: spell(path) };
  if (node) {
    const type = typeOf(node);
    if (type) help.type = type;
    if (node.enum) help.values = node.enum.map((value) => JSON.stringify(value));
  } else help.unknown = true;
  if (described) {
    help.description = described.description;
    if (described.depth < path.length) help.from = spell(path.slice(0, described.depth));
  }
  return help;
}

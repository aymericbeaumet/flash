export interface ConfigSourceMark {
  layer: string;
  where: string;
}

export interface ConfigSourceNode {
  $?: { layer?: string; where?: string };
  [key: string]: unknown;
}

export interface ConfigToken {
  text: string;
  where?: string;
}

const markOf = (node: ConfigSourceNode | undefined): ConfigSourceMark | undefined => {
  const mark = node?.$;
  if (!mark || typeof mark.layer !== "string" || !mark.layer || mark.layer === "default") return undefined;
  return { layer: mark.layer, where: typeof mark.where === "string" ? mark.where : "" };
};

const whereLabel = (mark: ConfigSourceMark) => (!mark.where || mark.where === mark.layer ? mark.layer : `${mark.layer} · ${mark.where}`);

const asNode = (value: unknown): ConfigSourceNode | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? value as ConfigSourceNode : undefined;

const childNode = (node: ConfigSourceNode | undefined, key: string) => asNode(node?.[key]);

const hasChildMarks = (node: ConfigSourceNode | undefined) =>
  !!node && Object.keys(node).some((key) => key !== "$");

const sourceText = (node: ConfigSourceNode | undefined): string => {
  if (!node) return "";
  const mark = markOf(node);
  const own = mark ? whereLabel(mark) : "";
  return Object.keys(node).filter((key) => key !== "$").map((key) => `${key} ${sourceText(childNode(node, key))}`).join(" ") + own;
};

const pretty = (value: unknown, indent: number) => {
  const raw = JSON.stringify(value, null, 2) ?? "null";
  if (!indent) return raw;
  const pad = " ".repeat(indent);
  return raw.split("\n").map((line, index) => (index === 0 ? line : pad + line)).join("\n");
};

const arrayChild = (node: ConfigSourceNode | undefined, element: unknown): ConfigSourceNode | undefined => {
  if (!node) return undefined;
  if (element && typeof element === "object" && !Array.isArray(element)) {
    const key = (element as { key?: unknown }).key;
    if (typeof key === "string") return childNode(node, key);
  }
  if (typeof element === "string") return childNode(node, element);
  return undefined;
};

const include = (key: string, value: unknown, source: ConfigSourceNode | undefined, query: string, force: boolean) => {
  if (!query || force) return true;
  const q = query.toLowerCase();
  return key.toLowerCase().includes(q) || (JSON.stringify(value) ?? "").toLowerCase().includes(q) || sourceText(source).toLowerCase().includes(q);
};

function emitValue(value: unknown, indent: number, source: ConfigSourceNode | undefined, inherited: ConfigSourceMark | undefined, query: string, force: boolean): ConfigToken[] {
  const own = markOf(source);
  const effective = own ?? inherited;
  if (!hasChildMarks(source)) {
    const text = pretty(value, indent);
    return effective ? [{ text, where: whereLabel(effective) }] : [{ text }];
  }
  if (Array.isArray(value)) return emitArray(value, indent, source, effective, query, force);
  if (value && typeof value === "object") return emitObject(value as Record<string, unknown>, indent, source, effective, query, force);
  const text = pretty(value, indent);
  return effective ? [{ text, where: whereLabel(effective) }] : [{ text }];
}

function emitObject(value: Record<string, unknown>, indent: number, source: ConfigSourceNode | undefined, inherited: ConfigSourceMark | undefined, query: string, force: boolean): ConfigToken[] {
  const keys = Object.keys(value).filter((key) => include(key, value[key], childNode(source, key), query, force)).sort();
  if (!keys.length) return [{ text: "{}" }];
  const pad = " ".repeat(indent + 2);
  const tokens: ConfigToken[] = [{ text: "{\n" }];
  keys.forEach((key, index) => {
    const child = childNode(source, key);
    tokens.push({ text: `${pad}${JSON.stringify(key)}: ` });
    tokens.push(...emitValue(value[key], indent + 2, child, inherited, query, force || (!!query && key.toLowerCase().includes(query.toLowerCase()))));
    tokens.push({ text: index < keys.length - 1 ? ",\n" : "\n" });
  });
  tokens.push({ text: `${" ".repeat(indent)}}` });
  return tokens;
}

function emitArray(value: unknown[], indent: number, source: ConfigSourceNode | undefined, inherited: ConfigSourceMark | undefined, query: string, force: boolean): ConfigToken[] {
  const items = value
    .map((element) => ({ element, source: arrayChild(source, element) }))
    .filter(({ element, source: child }) => include("", element, child, query, force));
  if (!items.length) return [{ text: "[]" }];
  const pad = " ".repeat(indent + 2);
  const tokens: ConfigToken[] = [{ text: "[\n" }];
  items.forEach(({ element, source: child }, index) => {
    tokens.push({ text: pad });
    tokens.push(...emitValue(element, indent + 2, child, inherited, query, force));
    tokens.push({ text: index < items.length - 1 ? ",\n" : "\n" });
  });
  tokens.push({ text: `${" ".repeat(indent)}]` });
  return tokens;
}

export function configDocument(config: unknown, sources: ConfigSourceNode | undefined, query: string): { tokens: ConfigToken[]; empty: boolean } {
  const root = config && typeof config === "object" && !Array.isArray(config) ? config as Record<string, unknown> : {};
  const q = query.trim();
  if (q && !include("", root, sources, q, false)) return { tokens: [], empty: true };
  return { tokens: emitValue(root, 0, sources, undefined, q, false), empty: false };
}

export type SourceKind = "builtin" | "plugin" | "config" | "env" | "cli";

export interface SourceRef {
  kind: SourceKind;
  label: string;
}

/** Mapping `origin` (`default`, `config:<file>`, `plugin:<name>`, `env:…`, `cli:…`). */
export function sourceFromOrigin(origin: string | undefined): SourceRef {
  if (!origin || origin === "default") return { kind: "builtin", label: "" };
  const split = origin.indexOf(":");
  if (split > 0) {
    const kind = origin.slice(0, split);
    const label = origin.slice(split + 1);
    if (kind === "plugin" || kind === "config" || kind === "env" || kind === "cli") return { kind, label };
  }
  if (origin === "config" || origin === "env" || origin === "cli") return { kind: origin, label: "" };
  return { kind: "config", label: origin };
}

export function sourceFromCommand(kind: "core" | "plugin", source: string): SourceRef {
  return kind === "plugin" ? { kind: "plugin", label: source } : { kind: "builtin", label: "" };
}

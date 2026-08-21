"""Send-side payload constructors and ${var} substitution.

Generators keep large or binary payloads out of the spec files:

  {"$repeat": {"value": X, "count": N, "join"?: ""}}
      X string -> the string repeated N times (joined by "join", default "")
      X object/array/number -> an array of N copies
  {"$hex": "ff fe 0a"}
      raw bytes; only meaningful as the whole send_raw value

Variables (${plugin_id}, ${data_dir}, ${parent_pid}) substitute inside every
string, including inside generator values.
"""


def substitute(value, variables):
    if isinstance(value, str):
        for name, replacement in variables.items():
            value = value.replace("${%s}" % name, str(replacement))
        return value
    if isinstance(value, list):
        return [substitute(item, variables) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, variables) for key, item in value.items()}
    return value


def expand(value, variables):
    """Substitute variables and expand generators; returns JSON-ready data."""
    if isinstance(value, dict):
        if set(value) == {"$repeat"}:
            spec = value["$repeat"]
            inner = expand(spec["value"], variables)
            count = int(spec["count"])
            if isinstance(inner, str):
                return str(spec.get("join", "")).join([inner] * count)
            return [inner for _ in range(count)]
        if set(value) == {"$hex"}:
            return bytes.fromhex(value["$hex"].replace(" ", ""))
        return {key: expand(item, variables) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item, variables) for item in value]
    if isinstance(value, str):
        return substitute(value, variables)
    return value


def raw_bytes(value, variables):
    """Expand a send_raw value to bytes (string -> utf-8, $hex -> raw)."""
    expanded = expand(value, variables)
    if isinstance(expanded, bytes):
        return expanded
    if isinstance(expanded, str):
        return expanded.encode("utf-8")
    raise ValueError(f"send_raw expects a string or $hex value, got {type(expanded).__name__}")

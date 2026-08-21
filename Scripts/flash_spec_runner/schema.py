"""Structural validation for spec files.

A malformed spec file is one failed result row per targeted plugin, never a
crashed run: validation happens at load time and produces readable errors.
The executable reference for authors is Plugins/_flash_plugin_specs/schema.json.
"""

STEP_KINDS = {
    "send", "send_raw", "send_batch", "expect", "expect_notification",
    "expect_all", "expect_none", "expect_host_rpc", "reply_host_rpc",
    "sleep_ms", "close_stdin", "kill_parent", "expect_exit", "expect_stderr",
}

# Modifier keys allowed alongside each step kind.
STEP_MODIFIERS = {
    "expect": {"within_ms", "not_before_ms"},
    "expect_notification": {"within_ms"},
    "expect_all": {"within_ms"},
    "expect_none": {"for_ms"},
    "expect_host_rpc": {"within_ms", "reply", "capture"},
    "expect_exit": {"within_ms"},
}

TOP_KEYS = {
    "name", "description", "contract", "issue", "requires", "timeout_ms",
    "env", "env_unset", "config", "data_dir", "parent", "host", "steps",
}

REQUIRES_PREDICATES = {
    "exec", "sources", "sources_warm", "sources_live", "queries", "commands",
    "hints", "source_actions", "navigation", "status", "listen",
}


class SpecError(Exception):
    """A spec file that does not conform to the schema."""


def validate(spec, origin):
    if not isinstance(spec, dict):
        raise SpecError(f"{origin}: spec must be an object")
    unknown = set(spec) - TOP_KEYS
    if unknown:
        raise SpecError(f"{origin}: unknown top-level key(s) {sorted(unknown)}")
    if "contract" not in spec or not isinstance(spec["contract"], str) or not spec["contract"]:
        raise SpecError(f"{origin}: 'contract' (the pinned contract clause) is required")
    requires = spec.get("requires", [])
    if not isinstance(requires, list):
        raise SpecError(f"{origin}: 'requires' must be an array of predicates")
    for predicate in requires:
        if not isinstance(predicate, str) or (
            predicate not in REQUIRES_PREDICATES and not predicate.startswith("capability:")
        ):
            raise SpecError(f"{origin}: unknown requires predicate {predicate!r}")
    steps = spec.get("steps")
    if not isinstance(steps, list) or not steps:
        raise SpecError(f"{origin}: 'steps' must be a non-empty array")
    for index, step in enumerate(steps):
        _validate_step(step, f"{origin} steps[{index}]")
    host = spec.get("host", {})
    if host and (not isinstance(host, dict) or set(host) - {"replies"}):
        raise SpecError(f"{origin}: 'host' supports only a 'replies' table")
    if spec.get("parent") not in (None, "ephemeral"):
        raise SpecError(f"{origin}: 'parent' must be \"ephemeral\" when present")
    for key in ("env", "config", "data_dir"):
        if key in spec and not isinstance(spec[key], dict):
            raise SpecError(f"{origin}: '{key}' must be an object")
    if "env_unset" in spec and not isinstance(spec["env_unset"], list):
        raise SpecError(f"{origin}: 'env_unset' must be an array")


def _validate_step(step, origin):
    if not isinstance(step, dict):
        raise SpecError(f"{origin}: step must be an object")
    kinds = [key for key in step if key in STEP_KINDS]
    if len(kinds) != 1:
        raise SpecError(f"{origin}: step must have exactly one action, got {sorted(step)}")
    kind = kinds[0]
    extras = set(step) - {kind} - STEP_MODIFIERS.get(kind, set())
    if extras:
        raise SpecError(f"{origin}: unknown key(s) {sorted(extras)} on {kind}")
    body = step[kind]
    if kind == "expect" and (not isinstance(body, dict) or "id" not in body):
        raise SpecError(f"{origin}: expect must carry the awaited frame 'id'")
    if kind == "expect_notification" and (not isinstance(body, dict) or "method" not in body):
        raise SpecError(f"{origin}: expect_notification must carry 'method'")
    if kind == "expect_all":
        if not isinstance(body, list) or not body:
            raise SpecError(f"{origin}: expect_all takes a non-empty matcher array")
        for matcher in body:
            if not isinstance(matcher, dict) or "id" not in matcher:
                raise SpecError(f"{origin}: every expect_all matcher needs an 'id'")
    if kind == "expect_host_rpc" and (not isinstance(body, dict) or "method" not in body):
        raise SpecError(f"{origin}: expect_host_rpc must carry 'method'")
    if kind == "reply_host_rpc":
        if not isinstance(body, dict) or "to" not in body or "result" not in body:
            raise SpecError(f"{origin}: reply_host_rpc needs 'to' (capture name) and 'result'")
    if kind == "expect_exit" and (not isinstance(body, dict) or "code" not in body):
        raise SpecError(f"{origin}: expect_exit needs 'code'")
    if kind == "expect_stderr":
        if not isinstance(body, dict) or not ({"contains", "absent"} & set(body)):
            raise SpecError(f"{origin}: expect_stderr needs 'contains' or 'absent'")
    if kind == "sleep_ms" and not isinstance(body, int):
        raise SpecError(f"{origin}: sleep_ms takes milliseconds")
    if kind == "send_batch" and (not isinstance(body, list) or not body):
        raise SpecError(f"{origin}: send_batch takes a non-empty frame array")

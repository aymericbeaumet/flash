"""Matcher grammar for expect* steps.

Subset semantics on objects (extra actual keys are fine), exact length on
arrays with elementwise match, scalars compare equal. An expected object with
any "$"-prefixed key is a shape matcher:

  $type      "string" | "number" | "int" | "bool" | "array" | "object" | "null"
             (number/int deliberately reject booleans)
  $min_len   length floor (strings and arrays)
  $max_len   length ceiling
  $len       exact length
  $each      matcher applied to every array element
  $absent    the key must NOT exist in the parent object
  $any       the key must exist, any value
  $contains  substring (strings)
  $one_of    value equals one of the listed literals

That is the complete grammar — deliberately no regex, no numeric comparators,
no boolean combinators. If a behavior can't be expressed, extend the schema,
don't script around it.
"""


def match(expected, actual, path="frame"):
    """Return a list of mismatch descriptions (empty = pass)."""
    if isinstance(expected, dict) and any(k.startswith("$") for k in expected):
        return _match_shape(expected, actual, path)
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {_type_name(actual)}"]
        problems = []
        for key, value in expected.items():
            if isinstance(value, dict) and value.get("$absent") is True:
                if key in actual:
                    problems.append(f"{path}.{key}: expected absent, present")
                continue
            if key not in actual:
                problems.append(f"{path}.{key}: missing")
            else:
                problems += match(value, actual[key], f"{path}.{key}")
        return problems
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(expected) != len(actual):
            return [f"{path}: expected {expected!r}, got {actual!r}"]
        problems = []
        for index, (want, got) in enumerate(zip(expected, actual)):
            problems += match(want, got, f"{path}[{index}]")
        return problems
    if expected != actual:
        return [f"{path}: expected {expected!r}, got {actual!r}"]
    return []


_KINDS = {
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "object": lambda v: isinstance(v, dict),
    # bool is an int subclass in Python; number/int must reject it.
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "int": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "bool": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}

_SHAPE_KEYS = {
    "$type", "$min_len", "$max_len", "$len", "$each", "$absent", "$any",
    "$contains", "$one_of",
}


def _type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    return type(value).__name__


def _match_shape(expected, actual, path):
    problems = []
    unknown = set(expected) - _SHAPE_KEYS
    if unknown:
        return [f"{path}: unknown matcher key(s) {sorted(unknown)}"]
    if expected.get("$any") is True:
        pass  # key existence was already proven by reaching here
    if "$type" in expected:
        kind = expected["$type"]
        if kind not in _KINDS:
            return [f"{path}: unknown $type {kind!r}"]
        if not _KINDS[kind](actual):
            return [f"{path}: expected {kind}, got {_type_name(actual)}"]
    sized = isinstance(actual, (str, list))
    for key, op in (("$min_len", "<"), ("$max_len", ">"), ("$len", "!=")):
        if key in expected:
            if not sized:
                problems.append(f"{path}: {key} on unsized {_type_name(actual)}")
            elif (
                (op == "<" and len(actual) < expected[key])
                or (op == ">" and len(actual) > expected[key])
                or (op == "!=" and len(actual) != expected[key])
            ):
                problems.append(f"{path}: length {len(actual)} violates {key}={expected[key]}")
    if "$contains" in expected:
        if not isinstance(actual, str) or expected["$contains"] not in actual:
            problems.append(f"{path}: expected substring {expected['$contains']!r} in {actual!r}")
    if "$one_of" in expected and actual not in expected["$one_of"]:
        problems.append(f"{path}: {actual!r} not in {expected['$one_of']!r}")
    if "$each" in expected:
        if not isinstance(actual, list):
            problems.append(f"{path}: $each on non-array {_type_name(actual)}")
        else:
            for index, item in enumerate(actual):
                problems += match(expected["$each"], item, f"{path}[{index}]")
    return problems

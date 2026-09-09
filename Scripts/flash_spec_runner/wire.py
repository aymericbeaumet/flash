"""Validation applied to every response, independently of scenario matchers."""

import math


def valid_pid(value):
    return type(value) is int and 1 <= value <= 2147483647


def absolute_url(value):
    scheme, separator, _ = value.partition(":")
    return bool(separator and scheme and scheme.isascii() and scheme[0].isalpha()
                and all(character.isalnum() or character in "+-." for character in scheme))


def valid_target(target):
    if not isinstance(target, dict) or set(target) - {
        "id", "frame", "role", "label", "url", "pid", "enters_insert_mode", "priority"
    } or not isinstance(target.get("id"), str) or not target["id"]:
        return False
    frame = target.get("frame")
    if not isinstance(frame, dict) or set(frame) != {"x", "y", "width", "height"}:
        return False
    try:
        if any(type(value) not in (int, float) or not math.isfinite(value)
               for value in frame.values()):
            return False
        if (frame["width"] <= 0 or frame["height"] <= 0
                or not math.isfinite(frame["x"] + frame["width"])
                or not math.isfinite(frame["y"] + frame["height"])):
            return False
    except OverflowError:
        return False
    if target.get("pid") is not None and not valid_pid(target["pid"]):
        return False
    if any(target.get(key) is not None and not isinstance(target[key], str)
           for key in ("role", "label", "url")):
        return False
    if target.get("enters_insert_mode") is not None and type(target["enters_insert_mode"]) is not bool:
        return False
    return target.get("priority") is None or target["priority"] in (
        "low", "normal", "high", "important", "urgent"
    )


def validate_result(method, result):
    if not isinstance(result, dict) or type(result.get("ok")) is not bool:
        return "result.ok must be a boolean"
    if result["ok"]:
        if method == "initialize" and (
            type(result.get("protocol_version")) is not int or result["protocol_version"] != 1
        ):
            return "protocol_version must be integer 1"
        if "error" in result or "unhandled" in result:
            return "successful result cannot contain error or unhandled"
        if result.get("target_pid") is not None and not valid_pid(result["target_pid"]):
            return "target_pid must be a positive Int32"
        for key in ("navigation_url", "message"):
            if result.get(key) is not None and not isinstance(result[key], str):
                return f"{key} must be a string"
        if method == "perform":
            if set(result) - {"ok", "target_pid", "navigation_url", "message"}:
                return "unknown perform result field"
            if result.get("navigation_url") is not None and not absolute_url(result["navigation_url"]):
                return "navigation_url must be absolute"
        if method == "hints":
            if set(result) - {"ok", "targets", "context_pid"}:
                return "unknown hints result field"
            if result.get("context_pid") is not None and not valid_pid(result["context_pid"]):
                return "context_pid must be a positive Int32"
            if not isinstance(result.get("targets"), list) or not all(map(valid_target, result["targets"])):
                return "targets must contain canonical hint targets"
    else:
        failure_keys = {"ok", "error"}
        if method == "initialize" and "protocol_version" in result:
            if type(result["protocol_version"]) is not int or result["protocol_version"] != 1:
                return "protocol_version must be integer 1"
            failure_keys.add("protocol_version")
        if any(key in result for key in ("target_pid", "navigation_url", "message")):
            return "failed result cannot contain success fields"
        if method == "perform" and result.get("unhandled") is True:
            if set(result) != {"ok", "unhandled"}:
                return "unhandled result must contain only ok and unhandled"
        elif (set(result) != failure_keys or not isinstance(result.get("error"), str)
              or not result["error"].strip()):
            return "failed result requires a nonempty error"
    return None

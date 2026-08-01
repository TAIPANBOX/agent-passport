#!/usr/bin/env bash
# Enforces invariant 5 of CLAUDE.md: an optional field never quietly becomes
# required, and more generally that v0.2 is a WIDENING of v0.1.
#
# SPEC 6.4 promises that existing emitters may keep emitting v0.1 and that the
# two versions differ only in `source`. That promise is what lets tokenfuse,
# engram, idryx and qryx move at their own pace, and it is worth exactly as much
# as something that checks it.
#
# WHAT CANNOT BE CHECKED THE OBVIOUS WAY. `schema` is a `const` in each file, so
# a v0.1 event does not validate against the v0.2 schema and never will. That is
# by design, not drift. So the behavioural half swaps ONLY the version string
# and then requires the event to pass: everything else about a v0.1 event must
# still be acceptable to v0.2, which is the actual promise.
#
# The structural half compares the two schemas directly, ignoring `schema`
# itself, and refuses anything that narrows.
#
# This file is the ONE copy of this check.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PY_BIN=python3
if ! python3 -c "import jsonschema" 2>/dev/null; then
	if python3 -m venv "$WORK/venv" >/dev/null 2>&1 &&
		"$WORK/venv/bin/pip" install --quiet jsonschema >/dev/null 2>&1; then
		PY_BIN="$WORK/venv/bin/python"
	else
		echo "FAIL: could not get jsonschema, so the behavioural half measured nothing."
		exit 1
	fi
fi

"$PY_BIN" - <<'PY'
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

OLD = pathlib.Path("schemas/agent-event.schema.json")
NEW = pathlib.Path("schemas/agent-event.v0.2.schema.json")
V1 = "taipanbox.dev/agent-event/v0.1"
V2 = "taipanbox.dev/agent-event/v0.2"

old = json.loads(OLD.read_text())
new = json.loads(NEW.read_text())
problems = []

# ------------------------------------------------------------ structural
old_req, new_req = set(old.get("required", [])), set(new.get("required", []))
for f in sorted(new_req - old_req):
    problems.append(
        f"'{f}' is required in v0.2 and was not in v0.1. An emitter still on "
        f"v0.1 cannot move without changing what it sends, which is the "
        f"compatibility promise in SPEC 6.4."
    )

old_props, new_props = old.get("properties", {}), new.get("properties", {})
for f in sorted(set(old_props) - set(new_props)):
    problems.append(f"'{f}' exists in v0.1 and is gone from v0.2")

NARROWING = ("minLength", "minItems", "minimum", "minProperties")
WIDENING = ("maxLength", "maxItems", "maximum", "maxProperties")

# Where v0.1 constrains a field to an enum, compatibility is DECIDABLE: every
# value v0.1 accepted is validated against v0.2's schema for that field. No
# heuristic needed, and heuristics get this wrong.
#
# The first version of this script did use one and was wrong on the only field
# that actually changed. v0.1's `source` is an enum of four names; v0.2 is any
# string with minLength 1. Comparing bounds in isolation reported "tightened
# minLength from unset to 1", when in fact every one of those four names is
# non-empty and still accepted. A bound is not a narrowing if the old schema
# was narrower by another means.
for name in sorted(set(old_props) & set(new_props)):
    if name == "schema":
        continue  # deliberately different: a const per version
    o, n = old_props[name], new_props[name]

    if "enum" in o:
        member_validator = Draft202012Validator(n)
        for value in o["enum"]:
            errs = list(member_validator.iter_errors(value))
            if errs:
                problems.append(
                    f"'{name}' accepted {value!r} in v0.1 and v0.2 rejects it: "
                    f"{errs[0].message}"
                )
        continue

    # No enum in v0.1: the field was open, so any new constraint in v0.2 can
    # only reject something v0.1 allowed.
    if "enum" in n:
        problems.append(
            f"'{name}' was unconstrained in v0.1 and is an enum in v0.2, which "
            f"rejects values v0.1 allowed"
        )
    for k in NARROWING:
        if k in n and n[k] > o.get(k, 0):
            problems.append(f"'{name}' tightened {k} from {o.get(k, 'unset')} to {n[k]}")
    for k in WIDENING:
        if k in n and k in o and n[k] < o[k]:
            problems.append(f"'{name}' tightened {k} from {o[k]} to {n[k]}")
    if "pattern" in n and n.get("pattern") != o.get("pattern"):
        problems.append(
            f"'{name}' changed its pattern between versions "
            f"({o.get('pattern', 'none')} -> {n['pattern']}), which needs a human"
        )

# ------------------------------------------------------------ behavioural
events = [
    json.loads(l)
    for l in pathlib.Path("examples/events.ndjson").read_text().splitlines()
    if l.strip()
]
v1 = [e for e in events if e.get("schema") == V1]
if not v1:
    problems.append(
        "examples/events.ndjson carries no v0.1 event, so nothing exercised the "
        "widening. Keep at least one: the promise is about them."
    )

validator = Draft202012Validator(new)
for i, e in enumerate(v1, 1):
    moved = dict(e, schema=V2)
    for err in sorted(validator.iter_errors(moved), key=str):
        loc = "/".join(str(p) for p in err.path) or "(root)"
        problems.append(
            f"v0.1 example {i}, with only its version string changed, is rejected "
            f"by v0.2 at {loc}: {err.message}"
        )

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("v0.2 must accept everything v0.1 accepted. SPEC 6.4 is what lets the")
    print("existing emitters move at their own pace. See CLAUDE.md invariant 5.")
    sys.exit(1)

print(
    f"OK: v0.2 widens v0.1. {len(v1)} v0.1 example(s) pass under v0.2 with only "
    f"the version string changed;"
)
print("    nothing newly required, no field removed, no constraint tightened.")
PY

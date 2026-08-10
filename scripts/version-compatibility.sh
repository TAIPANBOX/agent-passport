#!/usr/bin/env bash
# Enforces invariant 5 of CLAUDE.md: an optional field never quietly becomes
# required, and more generally that each event schema version is a WIDENING of
# the one before it.
#
# SPEC 6.4 promises that existing emitters may keep emitting an older version.
# That promise is what lets tokenfuse, engram, idryx and qryx move at their own
# pace, and it is worth exactly as much as something that checks it.
#
# It checks every CONSECUTIVE PAIR rather than one hardcoded pair. It compared
# only v0.1 with v0.2 until 2026-08-10, and on the day v0.3 arrived it would
# have gone on reporting OK about a comparison that no longer covered the newest
# version: a check silent about the thing that had just changed.
#
# WHAT CANNOT BE CHECKED THE OBVIOUS WAY. `schema` is a `const` in each file, so
# an older event does not validate against a newer schema and never will. That
# is by design, not drift. So the behavioural half swaps ONLY the version string
# and then requires the event to pass: everything else about an older event must
# still be acceptable to the newer schema, which is the actual promise.
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
import re
import sys

from jsonschema import Draft202012Validator

# Every consecutive pair, oldest first. Adding a version means adding one line
# here and nothing else.
VERSIONS = [
    ("taipanbox.dev/agent-event/v0.1", pathlib.Path("schemas/agent-event.schema.json")),
    ("taipanbox.dev/agent-event/v0.2", pathlib.Path("schemas/agent-event.v0.2.schema.json")),
    ("taipanbox.dev/agent-event/v0.3", pathlib.Path("schemas/agent-event.v0.3.schema.json")),
]
for _, path in VERSIONS:
    if not path.is_file():
        print(f"FAIL: {path} is not there, so this check measured nothing.")
        sys.exit(1)

NARROWING = ("minLength", "minItems", "minimum", "minProperties")
WIDENING = ("maxLength", "maxItems", "maximum", "maxProperties")

OPTIONAL_GROUP = re.compile(r"\((?:[^()]*)\)\?")


def widened_by_optional_group(old_pat: str, new_pat: str) -> bool:
    """True when new_pat is old_pat with optional groups added and nothing else.

    Regex language inclusion is not decidable in general, and this check used to
    say so and fail EVERY pattern change. That was right while no pattern had
    ever changed, and it would have made v0.3 permanently red for the single
    edit it exists to carry.

    So it decides the one shape a widening actually takes here: an optional
    group in front of what was already accepted, `(claimed:)?agent://...`.
    Removing every `(...)?` from the new pattern must give back the old one
    exactly. Any other pattern edit still fails and still needs a person, which
    is the half worth keeping.
    """
    return OPTIONAL_GROUP.sub("", new_pat) == old_pat


problems = []
events = [
    json.loads(line)
    for line in pathlib.Path("examples/events.ndjson").read_text().splitlines()
    if line.strip()
]

for (v_old, path_old), (v_new, path_new) in zip(VERSIONS, VERSIONS[1:]):
    old = json.loads(path_old.read_text())
    new = json.loads(path_new.read_text())
    pair = f"{v_old.rsplit('/', 1)[-1]} -> {v_new.rsplit('/', 1)[-1]}"

    # ------------------------------------------------------------ structural
    old_req, new_req = set(old.get("required", [])), set(new.get("required", []))
    for f in sorted(new_req - old_req):
        problems.append(
            f"{pair}: '{f}' is required in the newer schema and was not in the "
            f"older one. An emitter still on the older version cannot move "
            f"without changing what it sends, which is the compatibility "
            f"promise in SPEC 6.4."
        )

    old_props, new_props = old.get("properties", {}), new.get("properties", {})
    for f in sorted(set(old_props) - set(new_props)):
        problems.append(f"{pair}: '{f}' exists in the older schema and is gone")

    # Where the older schema constrains a field to an enum, compatibility is
    # DECIDABLE: every value it accepted is validated against the newer schema
    # for that field. No heuristic needed, and heuristics get this wrong.
    #
    # The first version of this script did use one and was wrong on the only
    # field that had actually changed. v0.1's `source` is an enum of four names;
    # v0.2 is any string with minLength 1. Comparing bounds in isolation
    # reported "tightened minLength from unset to 1", when in fact every one of
    # those four names is non-empty and still accepted. A bound is not a
    # narrowing if the old schema was narrower by another means.
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
                        f"{pair}: '{name}' accepted {value!r} before and now "
                        f"rejects it: {errs[0].message}"
                    )
            continue

        # No enum in the older schema: the field was open, so any new constraint
        # can only reject something the older one allowed.
        if "enum" in n:
            problems.append(
                f"{pair}: '{name}' was unconstrained before and is an enum now, "
                f"which rejects values the older schema allowed"
            )
        for k in NARROWING:
            if k in n and n[k] > o.get(k, 0):
                problems.append(
                    f"{pair}: '{name}' tightened {k} from {o.get(k, 'unset')} to {n[k]}"
                )
        # An upper bound the newer schema has and the older does not is a
        # narrowing as surely as a lowered one: the older one accepted
        # everything above it. The lower-bound loop above already reads an
        # absent bound as 0 and so catches its own version of this; this loop
        # used to require the key in BOTH schemas, which meant a max* bound
        # introduced by one side alone passed as though nothing changed. Found
        # by adding maxItems to on_behalf_of and watching the check approve the
        # one-sided version of that edit.
        for k in WIDENING:
            if k not in n:
                continue
            if k not in o:
                problems.append(
                    f"{pair}: '{name}' has {k} {n[k]} now and no {k} at all "
                    f"before, so the newer schema rejects values the older one "
                    f"accepted"
                )
            elif n[k] < o[k]:
                problems.append(f"{pair}: '{name}' tightened {k} from {o[k]} to {n[k]}")
        if "pattern" in n and n.get("pattern") != o.get("pattern"):
            if "pattern" not in o or not widened_by_optional_group(o["pattern"], n["pattern"]):
                problems.append(
                    f"{pair}: '{name}' changed its pattern "
                    f"({o.get('pattern', 'none')} -> {n['pattern']}) in a shape "
                    f"this check cannot decide is a widening, which needs a human"
                )

    # ------------------------------------------------------------ behavioural
    older = [e for e in events if e.get("schema") == v_old]
    if not older:
        problems.append(
            f"{pair}: examples/events.ndjson carries no "
            f"{v_old.rsplit('/', 1)[-1]} event, so nothing exercised this "
            f"widening. Keep at least one: the promise is about them."
        )

    validator = Draft202012Validator(new)
    for i, e in enumerate(older, 1):
        moved = dict(e, schema=v_new)
        for err in sorted(validator.iter_errors(moved), key=str):
            loc = "/".join(str(p) for p in err.path) or "(root)"
            problems.append(
                f"{pair}: example {i}, with only its version string changed, is "
                f"rejected at {loc}: {err.message}"
            )

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("Each version must accept everything the one before it accepted. SPEC 6.4")
    print("is what lets the existing emitters move at their own pace. See CLAUDE.md")
    print("invariant 5.")
    sys.exit(1)

pairs = len(VERSIONS) - 1
older_versions = {v for v, _ in VERSIONS[:-1]}
exercised = sum(1 for e in events if e.get("schema") in older_versions)
print(
    f"OK: {pairs} consecutive version pair(s), each a widening of the one before it."
)
print(
    f"    {exercised} example(s) pass under the next version with only the "
    f"version string changed;"
)
print("    nothing newly required, no field removed, no constraint tightened.")
PY

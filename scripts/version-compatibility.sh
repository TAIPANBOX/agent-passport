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
# Since 1.0 it walks TWO chains, the event envelope's and the Passport's, and it
# knows one thing about a major boundary that SPEC 6.4.1 names: the Passport's
# top level closes (`additionalProperties` true or absent, then false), and
# nothing else may narrow, across a major or not. A pair inside one major that
# closes the top level fails; a pair across a major that narrows anything else
# fails; a pair across a major that closes only the top level passes, once.
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

# Every consecutive pair, oldest first, per document kind. Adding a version
# means adding one line to the right chain and nothing else.
EVENT_VERSIONS = [
    ("taipanbox.dev/agent-event/v0.1", pathlib.Path("schemas/agent-event.schema.json")),
    ("taipanbox.dev/agent-event/v0.2", pathlib.Path("schemas/agent-event.v0.2.schema.json")),
    ("taipanbox.dev/agent-event/v0.3", pathlib.Path("schemas/agent-event.v0.3.schema.json")),
    ("taipanbox.dev/agent-event/v1.0", pathlib.Path("schemas/agent-event.v1.0.schema.json")),
]
PASSPORT_VERSIONS = [
    ("taipanbox.dev/agent-passport/v0.1", pathlib.Path("schemas/agent-passport.schema.json")),
    ("taipanbox.dev/agent-passport/v1.0", pathlib.Path("schemas/agent-passport.v1.0.schema.json")),
]
for _, path in EVENT_VERSIONS + PASSPORT_VERSIONS:
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


def major(version: str) -> int:
    m = re.search(r"/v(\d+)\.\d+$", version)
    if not m:
        print(f"FAIL: {version!r} is not a version string this check can read, so it measured nothing.")
        sys.exit(1)
    return int(m.group(1))


def closes_top_level(old: dict, new: dict) -> bool:
    return old.get("additionalProperties", True) is not False and new.get("additionalProperties", True) is False


problems = []


def compare_chain(kind, versions, older_documents):
    """older_documents: list of (label, document) carrying a `schema` field."""
    for (v_old, path_old), (v_new, path_new) in zip(versions, versions[1:]):
        old = json.loads(path_old.read_text())
        new = json.loads(path_new.read_text())
        pair = f"{kind} {v_old.rsplit('/', 1)[-1]} -> {v_new.rsplit('/', 1)[-1]}"
        across_major = major(v_new) != major(v_old)

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

        # The ONE narrowing SPEC 6.4.1 allows, and only across a major: the top
        # level closes. Inside a major it is a narrowing like any other.
        if closes_top_level(old, new) and not across_major:
            problems.append(
                f"{pair}: the newer schema closes its top level (additionalProperties "
                f"false) inside one major version, which rejects documents the older "
                f"one accepted. SPEC 6.4.1 allows that across a major only."
            )
        if old.get("additionalProperties", True) is False and new.get("additionalProperties", True) is not False:
            pass  # reopening is a widening; nothing to say

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
            # A nested object that closes its top level is the same narrowing one
            # level down, and 6.4.1 names the document's top level only.
            if isinstance(o, dict) and isinstance(n, dict) and closes_top_level(o, n):
                problems.append(
                    f"{pair}: '{name}' closes additionalProperties, which 6.4.1 allows "
                    f"for the document's top level only"
                )

        # ------------------------------------------------------------ behavioural
        older = [(label, d) for label, d in older_documents if d.get("schema") == v_old]
        if not older:
            problems.append(
                f"{pair}: no example carries {v_old.rsplit('/', 1)[-1]}, so nothing "
                f"exercised this widening. Keep at least one: the promise is about them."
            )

        validator = Draft202012Validator(new)
        for label, d in older:
            moved = dict(d, schema=v_new)
            for err in sorted(validator.iter_errors(moved), key=str):
                loc = "/".join(str(p) for p in err.path) or "(root)"
                problems.append(
                    f"{pair}: {label}, with only its version string changed, is "
                    f"rejected at {loc}: {err.message}"
                )
    return len(versions) - 1


events = [
    (f"examples/events.ndjson line {i}", json.loads(line))
    for i, line in enumerate(pathlib.Path("examples/events.ndjson").read_text().splitlines(), 1)
    if line.strip()
]
passports = []
for path in sorted(pathlib.Path("examples").glob("passport*.json")):
    doc = json.loads(path.read_text())
    if isinstance(doc, dict):
        passports.append((str(path), doc))

event_pairs = compare_chain("event", EVENT_VERSIONS, events)
passport_pairs = compare_chain("passport", PASSPORT_VERSIONS, passports)

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("Each version must accept everything the one before it accepted. SPEC 6.4")
    print("is what lets the existing emitters move at their own pace; SPEC 6.4.1")
    print("names the one narrowing a major may make. See CLAUDE.md invariant 5.")
    sys.exit(1)

older_events = {v for v, _ in EVENT_VERSIONS[:-1]}
older_passports = {v for v, _ in PASSPORT_VERSIONS[:-1]}
exercised = sum(1 for _, e in events if e.get("schema") in older_events) + sum(
    1 for _, d in passports if d.get("schema") in older_passports
)
print(
    f"OK: {event_pairs} event and {passport_pairs} passport consecutive version pair(s), "
    f"each a widening of the one before it, or across a major the one narrowing 6.4.1 names."
)
print(
    f"    {exercised} example(s) pass under the next version with only the "
    f"version string changed;"
)
print("    nothing newly required, no field removed, no constraint tightened.")
PY

#!/usr/bin/env bash
# Enforces invariant 2 of CLAUDE.md: schemas/ is the machine form of SPEC.md and
# must not drift from it.
#
# Implementers read one of the two. A field added to the schema without the
# prose means anyone building from SPEC.md builds the wrong thing, and nothing
# in this repo notices: the examples still validate, because they were written
# against the schema.
#
# WHAT THIS CATCHES, AND WHAT IT DOES NOT
#
# It walks every property name declared in schemas/*.json and fails when one
# does not appear anywhere in SPEC.md. That is the schema-ahead-of-prose
# direction.
#
# It does NOT catch prose ahead of schema. A field described in SPEC.md that no
# schema declares would pass this cleanly. Catching that needs a reader, because
# the prose names things it does not define, quotes examples, and discusses
# fields belonging to other documents. Half the surface, honestly labelled,
# beats a check that guesses at the other half and gets disabled for crying
# wolf.
#
# It also says nothing about whether the prose describing a field is CORRECT.
# A name present in both places can still be documented wrongly.
#
# This file is the ONE copy of this check. CI and any local hook both call it.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - <<'PY'
import json
import pathlib
import re
import sys

spec_path = pathlib.Path("SPEC.md")
spec = spec_path.read_text()

schemas = sorted(pathlib.Path("schemas").glob("*.json"))
if not schemas:
    print("FAIL: no schemas found, so this check measured nothing")
    sys.exit(1)

problems = []
checked = 0


def properties(node, trail):
    """Yield (name, dotted-path) for every declared property in the schema."""
    if isinstance(node, dict):
        props = node.get("properties")
        if isinstance(props, dict):
            for name, sub in props.items():
                yield name, ".".join(trail + [name])
                yield from properties(sub, trail + [name])
        for key in ("$defs", "definitions"):
            sub = node.get(key)
            if isinstance(sub, dict):
                for defname, defnode in sub.items():
                    yield from properties(defnode, trail + [f"<{defname}>"])
        for key in ("items", "additionalProperties", "contains"):
            sub = node.get(key)
            if isinstance(sub, dict):
                yield from properties(sub, trail)
        for key in ("allOf", "anyOf", "oneOf", "prefixItems"):
            sub = node.get(key)
            if isinstance(sub, list):
                for item in sub:
                    yield from properties(item, trail)


for path in schemas:
    try:
        schema = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        problems.append(f"{path}: invalid JSON ({e})")
        continue

    seen = {}
    for name, dotted in properties(schema, []):
        seen.setdefault(name, dotted)

    if not seen:
        problems.append(f"{path}: declares no properties at all, which is suspicious")
        continue

    for name, dotted in sorted(seen.items()):
        checked += 1
        # Word boundary, so `id` does not match inside `agent_id`.
        if not re.search(rf"(?<![\w.]){re.escape(name)}(?![\w])", spec):
            problems.append(
                f"{path.name} declares '{name}' (at {dotted}) and SPEC.md never "
                f"mentions it. An implementer reading the prose builds without it."
            )

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("schemas/ is the machine form of SPEC.md. A field in one and not the")
    print("other means the two documents describe different products, and the")
    print("examples will not notice because they were written against the schema.")
    print("See CLAUDE.md invariant 2.")
    sys.exit(1)

print(
    f"OK: {checked} property declarations across {len(schemas)} schemas, every "
    f"one named in SPEC.md."
)
print("    (This direction only: prose without a schema still needs a reader.)")
PY

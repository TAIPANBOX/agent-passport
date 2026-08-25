#!/usr/bin/env bash
# Enforces invariant 9 of CLAUDE.md: nothing in this repo names a model
# provider in a spelling the 4.7 registry does not carry.
#
# WHY A SEPARATE CHECK, AND NOT A CASE THE OTHERS ALMOST COVER
#
# Same reason `artifacts-match-registry.sh` exists one registry over.
# `provider` is an open string in `schemas/agent-passport.schema.json`
# (`type: string, minLength: 1`), and it has to stay one: invariant 5 says each
# version widens the one before it, so an enum here would narrow the field and
# break every passport carrying a provider we had not thought of. So a passport
# declaring `Anthropic`, `anthropic-ai` or `Claude` validates cleanly against
# the schema, forever, and `validate_examples.py` will never say a word.
#
# That is correct for somebody else's passport and wrong for ours. Our own
# examples and our own documents are what an implementer copies, and a provider
# spelled three ways across them teaches three spellings.
#
# WHAT IT READS
#
# SPEC 4.7's table is the source of truth. Everything else is measured
# against it:
#   1. every `models[].provider` in examples/*.json;
#   2. SPEC 4.5's own inline example, which is the first thing a reader copies;
#   3. the schema's description of `provider`, which listed six providers by
#      name until this registry existed and would have gone on listing them
#      while the registry moved.
#
# WHAT IT CANNOT DO, stated plainly
#
# It says nothing about a passport outside this repo, which is the whole point
# of the field staying open: an operator may name a provider nobody registered
# and must not be refused for it. It also cannot judge whether a registered id
# names the provider a document MEANT. `openai` where `openrouter` was intended
# is a correct spelling of the wrong provider, and no script sees that.
#
# It does not read free prose. A sentence naming a provider in passing is out
# of scope for the same reason the 6.2 gate leaves prose alone: it would have
# to tell an example apart from a discussion, and a check that guesses there
# gets switched off by the third false alarm.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - "$@" <<'PY'
import json
import pathlib
import re
import sys

fails = []


def fail(msg):
    fails.append(msg)


spec = pathlib.Path("SPEC.md").read_text()


def section_of(number):
    """The text of one '### <number>' section, up to the next heading."""
    m = re.search(rf"^### {re.escape(number)}\b.*?$", spec, re.M)
    if not m:
        return None
    rest = spec[m.end():]
    nxt = re.search(r"^#{2,3} ", rest, re.M)
    return rest[: nxt.start()] if nxt else rest


# ---------------------------------------------------------------------------
# The registry. If this stops parsing, the check has measured nothing and says
# so, rather than reporting a clean bill of health over an empty set.

section = section_of("4.7")
if section is None:
    print("FAIL: SPEC.md has no '### 4.7' heading, so the provider registry could")
    print("      not be found and this check measured nothing.")
    sys.exit(1)

header = re.search(r"^\|\s*id\s*\|\s*names\s*\|\s*$", section, re.M)
if not header:
    print("FAIL: SPEC 4.7 has no '| id | names |' table header, so the registry")
    print("      could not be parsed and this check measured nothing.")
    sys.exit(1)

lines = section[header.end():].splitlines()
if not lines or not re.match(r"^\|[\s:|-]+\|$", lines[1] if len(lines) > 1 else ""):
    print("FAIL: SPEC 4.7's registry header is not followed by a table divider.")
    sys.exit(1)

registry = {}
for raw in lines[2:]:
    line = raw.strip()
    if not line.startswith("|"):
        break
    cells = [c.strip() for c in line.strip("|").split("|")]
    if len(cells) != 2:
        fail(f"SPEC 4.7 registry row: expected two cells, got {len(cells)}: {line}")
        continue
    m = re.fullmatch(r"`([a-z0-9-]+)`", cells[0])
    if not m:
        fail(f"SPEC 4.7 registry row: first cell is not a provider id: {cells[0]}")
        continue
    if not cells[1]:
        fail(f"SPEC 4.7 registry row for `{m.group(1)}` says what it names nowhere")
    registry[m.group(1)] = cells[1]

if len(registry) < 6:
    print(f"FAIL: SPEC 4.7 parsed to only {len(registry)} provider(s), which cannot")
    print("      be right, so this check measured nothing.")
    sys.exit(1)

# A row of the same table anywhere else in 4.7 is a second copy that can drift
# from the first while both look maintained.
for raw in lines[2 + len(registry):]:
    line = raw.strip()
    if re.match(r"^\|\s*`[a-z0-9-]+`\s*\|", line):
        fail(f"SPEC 4.7 carries a registry row outside its table: {line}")


def known(value):
    return value in registry


def suggestion(value):
    lowered = value.lower()
    if lowered in registry:
        return f" (`{lowered}` is registered; ids are lowercase)"
    return ""


# ---------------------------------------------------------------------------
# 1. The examples, which are what an implementer copies first.

for path in sorted(pathlib.Path("examples").glob("*.json")):
    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"{path}: not valid JSON ({exc})")
        continue
    for i, entry in enumerate(doc.get("models", []) or []):
        if not isinstance(entry, dict):
            continue
        value = entry.get("provider")
        if value is None:
            continue
        if not known(value):
            fail(
                f"{path}: models[{i}].provider is `{value}`, which SPEC 4.7 does "
                f"not register{suggestion(value)}"
            )

# ---------------------------------------------------------------------------
# 2. SPEC 4.5's inline example. A reader copies the JSON in the section long
#    before they reach a registry two subsections down.

body = section_of("4.5")
if body is None:
    print("FAIL: SPEC.md has no '### 4.5' heading, so the field this registry")
    print("      governs could not be found and this check measured nothing.")
    sys.exit(1)

inline = re.findall(r'"provider"\s*:\s*"([^"]*)"', body)
if not inline:
    print("FAIL: SPEC 4.5 shows no `provider` value at all, so the example this")
    print("      check exists to measure is gone and it measured nothing.")
    sys.exit(1)
for value in inline:
    if not known(value):
        fail(
            f"SPEC 4.5's own example declares provider `{value}`, which 4.7 does "
            f"not register{suggestion(value)}"
        )

# ---------------------------------------------------------------------------
# 3. The schema's description of the field. It enumerated six providers by name
#    until 4.7 existed, which is a second copy of a vocabulary kept by hand in a
#    file nobody edits when the registry moves.

schema_path = pathlib.Path("schemas/agent-passport.schema.json")
try:
    schema = json.loads(schema_path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    print(f"FAIL: {schema_path} could not be read ({exc}), so this check measured")
    print("      nothing about the schema.")
    sys.exit(1)

models = schema.get("properties", {}).get("models", {})
provider = models.get("items", {}).get("properties", {}).get("provider")
if provider is None:
    print("FAIL: the passport schema declares no models[].provider, so the field")
    print("      this registry governs is gone and this check measured nothing.")
    sys.exit(1)

description = provider.get("description", "")
if "4.7" not in description:
    fail(
        "the schema's description of `provider` does not point at SPEC 4.7, so a "
        "reader of the schema alone never learns the registry exists"
    )
for value in re.findall(r"\b([a-z][a-z0-9-]{3,})\b", description):
    # Only complain about a word that reads as a provider id, which means one
    # the registry knows or one that used to be listed there. A description is
    # prose and full of ordinary words.
    if value in ("provider", "string", "value", "legal", "lowercase", "registered", "names", "when", "stays", "open", "should", "label", "unregistered"):
        continue
    if value in registry:
        fail(
            f"the schema's description of `provider` names `{value}`, which makes "
            "it a second copy of the registry: point at SPEC 4.7 instead of "
            "listing ids"
        )

# ---------------------------------------------------------------------------

if fails:
    print()
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print(f"{len(fails)} problem(s) against the SPEC 4.7 provider registry.")
    sys.exit(1)

print(
    f"providers: {len(registry)} registered in SPEC 4.7, and every provider named "
    "in the examples, in 4.5's own example and in the schema agrees with it."
)
PY

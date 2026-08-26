#!/usr/bin/env bash
# Enforces invariant 10 of CLAUDE.md: nothing in this repo names an agent
# framework in a spelling the 4.8 registry does not carry.
#
# WHY A SECOND SCRIPT, AND NOT TWO MORE CASES INSIDE THE PROVIDER GATE
#
# The two registries look alike and the temptation is real, so the reasons are
# written down rather than left to be re-argued.
#
#   1. A gate that measured nothing must say so about ONE registry without
#      that verdict swallowing the other. Both scripts exit on the first
#      "measured nothing" condition, which is correct and is the whole point;
#      folded together, a missing 4.8 heading would abort before a single
#      provider was compared, and the run would report the wrong subject as
#      gone.
#   2. The subjects are not the same shape. `provider` is nested in an array
#      inside a `### 4.5` section; `runtime` is a top-level scalar whose only
#      example lives under `## 4`, which the provider gate's section reader
#      cannot address, and it has a fourth subject the provider gate has none
#      of (README's field table names a runtime id by hand and its `models`
#      row names no provider at all).
#   3. CLAUDE.md holds one invariant per gate and cites the gate by name. A
#      script called `providers-match-registry.sh` standing behind an
#      invariant about frameworks is the stale pointer this repo keeps
#      finding in its own prose.
#
# WHAT THAT COSTS, stated rather than hidden: the registry-table parser below
# is the third copy of the same twenty lines, after `providers-match-registry.sh`
# and `artifacts-match-registry.sh`. A bug fixed in one is not fixed in the
# others. That is a real debt and it is the price of reason 1.
#
# WHAT IT READS
#
# SPEC 4.8's table is the source of truth. Four things are measured against it:
#   1. every top-level `runtime` in examples/*.json;
#   2. SPEC section 4's own passport example, which carries a `runtime` and is
#      the first thing a reader copies;
#   3. the schema's description of `runtime`, which said "e.g. langgraph" until
#      this registry existed and would have gone on saying it while the
#      registry moved;
#   4. README's passport field table, which said the same thing in the same
#      words, in the file most readers reach first.
#
# WHAT IT CANNOT DO, stated plainly
#
# It says nothing about a passport outside this repo. `runtime` is an open
# string on purpose (4.8), an operator may name a framework nobody registered,
# and refusing one would be the bug.
#
# It cannot tell a correctly spelled wrong framework from a right one.
# `langchain` where `langgraph` was meant is a registered id naming the wrong
# thing, and no script sees that. 4.8 says which one to write when both are
# installed; nothing here checks that anybody did.
#
# It does not read free prose, for the reason the other two registry gates give:
# it would have to tell an example apart from a discussion, and a check that
# guesses there is switched off by its third false alarm.
#
# It does not read the SVGs, and that one is a choice with a reason rather than
# an oversight. `docs/envelope.svg` carries "framework label, e.g. langgraph" in
# a text node, which is a fourth copy of this vocabulary. It is not wrong today,
# `langgraph` being registered, and it is left out because README renders
# `docs/envelope.png`, this repo holds no generator for it, and a gate that
# forced an edit to the SVG would open a divergence between the picture and the
# rendered picture that it has no way to close. `artifacts-match-registry.sh`
# reads SVG text nodes for 6.2 ATTRIBUTION, which is a different question about
# the same files: who emits what, not how a label is spelled.

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


def section_of(number, level):
    """The text of one heading's section, up to the next heading of any level.

    `level` is the number of hashes, because this registry governs a field
    whose example lives under `## 4` while the registry itself is a `### 4.8`.
    """
    hashes = "#" * level
    # `(?![\w.])` rather than `\b`, because the heading this reads for the
    # document example is `## 4.` and a `\b` after a dot never matches a space.
    # It still separates `4.8` from `4.8bis` and `## 4.` from `## 4.1`.
    m = re.search(rf"^{hashes} {re.escape(number)}(?![\w.]).*?$", spec, re.M)
    if not m:
        return None
    rest = spec[m.end():]
    nxt = re.search(r"^#{2,3} ", rest, re.M)
    return rest[: nxt.start()] if nxt else rest


# ---------------------------------------------------------------------------
# The registry. If this stops parsing, the check has measured nothing and says
# so, rather than reporting a clean bill of health over an empty set.

section = section_of("4.8", 3)
if section is None:
    print("FAIL: SPEC.md has no '### 4.8' heading, so the runtime registry could")
    print("      not be found and this check measured nothing.")
    sys.exit(1)

header = re.search(r"^\|\s*id\s*\|\s*names\s*\|\s*$", section, re.M)
if not header:
    print("FAIL: SPEC 4.8 has no '| id | names |' table header, so the registry")
    print("      could not be parsed and this check measured nothing.")
    sys.exit(1)

lines = section[header.end():].splitlines()
if not lines or not re.match(r"^\|[\s:|-]+\|$", lines[1] if len(lines) > 1 else ""):
    print("FAIL: SPEC 4.8's registry header is not followed by a table divider.")
    sys.exit(1)

registry = {}
for raw in lines[2:]:
    line = raw.strip()
    if not line.startswith("|"):
        break
    cells = [c.strip() for c in line.strip("|").split("|")]
    if len(cells) != 2:
        fail(f"SPEC 4.8 registry row: expected two cells, got {len(cells)}: {line}")
        continue
    m = re.fullmatch(r"`([a-z0-9-]+)`", cells[0])
    if not m:
        fail(f"SPEC 4.8 registry row: first cell is not a runtime id: {cells[0]}")
        continue
    if not cells[1]:
        fail(f"SPEC 4.8 registry row for `{m.group(1)}` says what it names nowhere")
    registry[m.group(1)] = cells[1]

if len(registry) < 4:
    print(f"FAIL: SPEC 4.8 parsed to only {len(registry)} runtime(s), which cannot")
    print("      be right, so this check measured nothing.")
    sys.exit(1)

# A row of the same table anywhere else in 4.8 is a second copy that can drift
# from the first while both look maintained.
for raw in lines[2 + len(registry):]:
    line = raw.strip()
    if re.match(r"^\|\s*`[a-z0-9-]+`\s*\|", line):
        fail(f"SPEC 4.8 carries a registry row outside its table: {line}")


def known(value):
    return value in registry


def suggestion(value):
    lowered = value.lower()
    if lowered in registry:
        return f" (`{lowered}` is registered; ids are lowercase)"
    return ""


def ids_named_in(text):
    """Registered ids appearing as whole tokens.

    A token rather than a word, so `autogen` does not match inside
    `autogenerated` and `semantic-kernel` matches across its hyphen. The
    provider gate does the same job with a word scan plus a list of ordinary
    words to ignore, which needs extending every time a description gains a
    word; this needs extending never.
    """
    return [
        rid
        for rid in registry
        if re.search(rf"(?<![a-z0-9-]){re.escape(rid)}(?![a-z0-9-])", text)
    ]


# ---------------------------------------------------------------------------
# 1. The examples, which are what an implementer copies first.

measured = 0
for path in sorted(pathlib.Path("examples").glob("*.json")):
    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"{path}: not valid JSON ({exc})")
        continue
    value = doc.get("runtime")
    if not isinstance(value, str):
        continue
    measured += 1
    if not known(value):
        fail(
            f"{path}: runtime is `{value}`, which SPEC 4.8 does not "
            f"register{suggestion(value)}"
        )

if measured == 0:
    print("FAIL: no example in examples/ declares a `runtime` at all, so the")
    print("      documents this check exists to measure carry nothing and it")
    print("      measured nothing about them.")
    sys.exit(1)

# ---------------------------------------------------------------------------
# 2. Section 4's own passport example. A reader copies the document at the top
#    of the section long before they reach a registry eight subsections down.

body = section_of("4.", 2)
if body is None:
    print("FAIL: SPEC.md has no '## 4.' heading, so the passport document whose")
    print("      example this check measures could not be found and it measured")
    print("      nothing.")
    sys.exit(1)

inline = re.findall(r'"runtime"\s*:\s*"([^"]*)"', body)
if not inline:
    print("FAIL: SPEC section 4's passport example shows no `runtime` value at")
    print("      all, so the example this check exists to measure is gone and it")
    print("      measured nothing.")
    sys.exit(1)
for value in inline:
    if not known(value):
        fail(
            f"SPEC section 4's own example declares runtime `{value}`, which 4.8 "
            f"does not register{suggestion(value)}"
        )

# ---------------------------------------------------------------------------
# 3. The schema's description of the field. It read "Free-form label for the
#    agent runtime/framework (e.g. langgraph)" until 4.8 existed, which is a
#    second copy of a vocabulary kept by hand in a file nobody edits when the
#    registry moves.

schema_path = pathlib.Path("schemas/agent-passport.schema.json")
try:
    schema = json.loads(schema_path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    print(f"FAIL: {schema_path} could not be read ({exc}), so this check measured")
    print("      nothing about the schema.")
    sys.exit(1)

runtime = schema.get("properties", {}).get("runtime")
if runtime is None:
    print("FAIL: the passport schema declares no top-level `runtime`, so the")
    print("      field this registry governs is gone and this check measured")
    print("      nothing.")
    sys.exit(1)

description = runtime.get("description", "")
if "4.8" not in description:
    fail(
        "the schema's description of `runtime` does not point at SPEC 4.8, so a "
        "reader of the schema alone never learns the registry exists"
    )
for value in ids_named_in(description):
    fail(
        f"the schema's description of `runtime` names `{value}`, which makes it a "
        "second copy of the registry: point at SPEC 4.8 instead of listing ids"
    )

# ---------------------------------------------------------------------------
# 4. README's passport field table. Same second copy, one file further out, and
#    the one a reader reaches before either the schema or the spec.

readme_path = pathlib.Path("README.md")
try:
    readme = readme_path.read_text()
except OSError as exc:
    print(f"FAIL: {readme_path} could not be read ({exc}), so this check measured")
    print("      nothing about it.")
    sys.exit(1)

row = re.search(r"^\|\s*`runtime`\s*\|.*$", readme, re.M)
if row is None:
    print("FAIL: README.md's passport field table has no `runtime` row, so the")
    print("      copy this check exists to measure is gone and it measured")
    print("      nothing about README.")
    sys.exit(1)

if "4.8" not in row.group(0):
    fail(
        "README's `runtime` row does not point at SPEC 4.8, so a reader who gets "
        "the field from README never learns the registry exists"
    )
for value in ids_named_in(row.group(0)):
    fail(
        f"README's `runtime` row names `{value}`, which makes it a second copy of "
        "the registry: point at SPEC 4.8 instead of listing ids"
    )

# ---------------------------------------------------------------------------

if fails:
    print()
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print(f"{len(fails)} problem(s) against the SPEC 4.8 runtime registry.")
    sys.exit(1)

print(
    f"runtimes: {len(registry)} registered in SPEC 4.8, and every runtime named "
    f"in {measured} example(s), in section 4's own example, in the schema and in "
    "README agrees with it."
)
PY

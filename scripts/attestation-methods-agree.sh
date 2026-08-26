#!/usr/bin/env bash
# Enforces invariant 11 of CLAUDE.md: every place this repo lists the
# attestation methods lists the same ones.
#
# WHY THIS IS NOT A FOURTH REGISTRY GATE
#
# `attestation.method` looks like the provider, runtime and artifact registries
# and is not one, so it deliberately does not reuse their machinery.
#
# Those three are OPEN labels that SPEC registers a spelling for, so SPEC's
# table is the source of truth and the schema merely points at it. This one is
# a CLOSED enum: the schema does not point at a list, the schema IS the list,
# and 4.8 says why the two are different promises. A consumer ACTS on an
# attestation method, so a value it cannot place leaves it unable to judge the
# posture 4.3 exists to make visible.
#
# That inverts where truth lives, and it is why there is no fourth copy of the
# registry-table parser the other three share and name as debt in their own
# headers. The schema's enum is read as JSON, and everything else is compared
# to it.
#
# WHAT IT READS
#
# `schemas/agent-passport.schema.json`, `properties.attestation.properties
# .method.enum`, is the source of truth. Three things are measured against it:
#
#   1. SPEC 4.3's "One of:" line, which is what a reader of the spec sees;
#   2. README's `attestation.method` row, which is what a reader who never
#      opens the spec sees, and which is where this went wrong;
#   3. every `attestation.method` in examples/*.json, because an example is
#      the first thing anyone copies.
#
# WHAT MADE IT NECESSARY, on the day it was written
#
# `dpop-key` was added to SPEC 4.3 and to the schema on 2026-08-26 by PR #44
# and NOT to README, whose row went on listing five methods as though it were
# the whole set. Nothing was wrong in either file on its own. The schema was
# right, the spec was right, and the table most readers reach first was a
# quietly short answer to "what may I write here". That is the same defect the
# three registry gates exist for, one field further out, and it survived the
# gates already in this repository because none of them read an enum.
#
# It refuses when it found nothing to compare. A check that goes green once its
# subject has vanished is worse than no check.

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


# ---------------------------------------------------------------------------
# The source of truth. If the enum cannot be read, this check has measured
# nothing and says so rather than reporting health over an empty set.

schema_path = pathlib.Path("schemas/agent-passport.schema.json")
if not schema_path.exists():
    print("FAIL: schemas/agent-passport.schema.json is not there, so the")
    print("      attestation methods have no source of truth and this check")
    print("      measured nothing.")
    sys.exit(1)

try:
    schema = json.loads(schema_path.read_text())
except ValueError as exc:
    print(f"FAIL: schemas/agent-passport.schema.json does not parse ({exc}), so")
    print("      this check measured nothing.")
    sys.exit(1)

node = (
    schema.get("properties", {})
    .get("attestation", {})
    .get("properties", {})
    .get("method", {})
)
methods = node.get("enum")
if not isinstance(methods, list) or not methods:
    print("FAIL: the schema declares no enum at properties.attestation.properties")
    print("      .method, so `attestation.method` has stopped being a closed set")
    print("      and this check measured nothing. If that was deliberate, this")
    print("      gate is the wrong shape and CLAUDE.md invariant 11 needs redoing,")
    print("      not this line deleting.")
    sys.exit(1)

if len(methods) < 3:
    print(f"FAIL: the schema's attestation enum parsed to only {len(methods)}")
    print("      value(s), which cannot be right, so this check measured nothing.")
    sys.exit(1)

canonical = list(methods)
canonical_set = set(canonical)

for m in canonical:
    if not isinstance(m, str) or not re.fullmatch(r"[a-z0-9-]+", m):
        print(f"FAIL: the schema's attestation enum carries {m!r}, which is not an")
        print("      id, so the set this check compares against is not trustworthy.")
        sys.exit(1)


def listed_ids(text):
    """The `backticked` ids in a run of prose, in the order written."""
    return re.findall(r"`([a-z0-9-]+)`", text)


def compare(where, found):
    """One subject against the schema, both directions."""
    missing = [m for m in canonical if m not in found]
    extra = [m for m in found if m not in canonical_set]
    if missing:
        fail(
            f"{where} does not list {', '.join('`' + m + '`' for m in missing)}, "
            f"which the schema accepts. A reader who trusts it will not know the "
            f"value is legal."
        )
    if extra:
        fail(
            f"{where} lists {', '.join('`' + m + '`' for m in extra)}, which the "
            f"schema rejects. A reader who trusts it will write a passport that "
            f"does not validate."
        )
    dupes = [m for m in set(found) if found.count(m) > 1]
    if dupes:
        fail(f"{where} names {', '.join(sorted(dupes))} more than once.")


# ---------------------------------------------------------------------------
# 1. SPEC 4.3

spec = pathlib.Path("SPEC.md").read_text()
m = re.search(r"^### 4\.3\b.*?$", spec, re.M)
if not m:
    print("FAIL: SPEC.md has no '### 4.3' heading, so the prose definition")
    print("      of `attestation.method` could not be found and this check")
    print("      measured nothing.")
    sys.exit(1)

rest = spec[m.end():]
nxt = re.search(r"^#{2,3} ", rest, re.M)
section = rest[: nxt.start()] if nxt else rest

one_of = re.search(r"One of:(.*?)\.\s*$", section, re.S | re.M)
if not one_of:
    print("FAIL: SPEC 4.3 has no 'One of:' line, so the methods it names could not")
    print("      be read and this check measured nothing.")
    sys.exit(1)

compare("SPEC 4.3's 'One of:' line", listed_ids(one_of.group(1)))

# ---------------------------------------------------------------------------
# 2. README's field table

readme = pathlib.Path("README.md").read_text()
row = None
for line in readme.splitlines():
    if re.match(r"^\|\s*`attestation\.method`\s*\|", line):
        if row is not None:
            fail(
                "README has more than one `attestation.method` row, and two rows "
                "can drift from each other while both look maintained."
            )
            break
        row = line

if row is None:
    print("FAIL: README.md has no `attestation.method` row, so the table most")
    print("      readers reach first was not compared and this check")
    print("      measured nothing.")
    sys.exit(1)

# Only the "one of" clause is the list. The prose after it legitimately names
# a method again to say something about it, and the first version of this gate
# read the whole row and called that a duplicate, which would have left it red
# on a correct README forever.
clause = re.search(r"\bone of\b(.*?)(?:;|\|\s*$)", row, re.I)
if clause is None:
    print("FAIL: README's `attestation.method` row has no 'one of' clause, so")
    print("      the methods it offers could not be read and this check")
    print("      measured nothing about the table most readers reach first.")
    sys.exit(1)

compare("README's `attestation.method` row", listed_ids(clause.group(1)))

# ---------------------------------------------------------------------------
# 3. Examples

examples = sorted(pathlib.Path("examples").glob("*.json")) if pathlib.Path("examples").is_dir() else []
declaring = 0
for path in examples:
    try:
        doc = json.loads(path.read_text())
    except ValueError:
        continue  # not this gate's subject; the schema gate owns that
    if not isinstance(doc, dict):
        continue
    att = doc.get("attestation")
    if not isinstance(att, dict) or "method" not in att:
        continue
    declaring += 1
    value = att["method"]
    if value not in canonical_set:
        fail(
            f"{path} declares attestation.method {value!r}, which the schema "
            f"rejects."
        )

# An example set that declares no attestation at all is not proof of agreement.
# It is this check having nothing to say about the files people copy from.
if examples and declaring == 0:
    print(f"FAIL: none of the {len(examples)} example(s) declares an")
    print("      `attestation.method`, so the files a reader copies from were not")
    print("      compared and this check measured nothing about them.")
    sys.exit(1)

# ---------------------------------------------------------------------------

if fails:
    print()
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print(f"{len(fails)} problem(s) against the schema's attestation method enum.")
    sys.exit(1)

print(
    f"attestation: {len(canonical)} method(s) in the schema's enum, and SPEC 4.3, "
    f"README's field table and {declaring} example(s) all agree with it."
)
PY

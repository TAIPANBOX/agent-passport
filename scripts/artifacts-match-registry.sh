#!/usr/bin/env bash
# Enforces invariant 7 of CLAUDE.md: no artifact in this repo contradicts the
# event-type registry in SPEC 6.2.
#
# WHY THIS IS A SEPARATE CHECK, AND NOT A CASE THE OTHER TWO ALMOST COVER
#
# The existing gates run in one direction each and neither can see this class
# of defect. `schema-matches-spec.sh` compares the schemas with the prose, and
# the registry is not in the schemas: `source` and `type` are open strings on
# purpose (6.1), so every artifact below conforms to the schema whichever
# source it names. `validate_examples.py` validates the examples against those
# same schemas, so an example line attributing an event to a producer that
# emits nothing passes it cleanly, forever.
#
# The registry is the only place in this repo that says WHO emits WHAT, and
# until this script nothing read it. That is not theoretical. Three artifacts
# claimed idryx as an emitter from the first commit (dd65336, 2026-07-09):
# examples/events.ndjson and both diagrams. The audit of 2026-08-03 (1299780)
# corrected the prose in 6.2 and reached none of them; they were found by eye
# and fixed by hand, one commit each, on 2026-08-05.
#
# WHAT IT READS
#
# SPEC 6.2's table is the source of truth. Everything else is measured against
# it:
#   1. SPEC 6.1's own list of registered sources, which has drifted from 6.2
#      before, leaving two live producers out of the registry entirely;
#   2. examples/*.ndjson, every `source` / `type` pair on every line;
#   3. README.md's copy of the same table, which has drifted from it before;
#   4. the <text> nodes of assets/*.svg and docs/*.svg;
#   5. README.md's mermaid flowchart, for producer arrows into the event bus.
#
# WHAT IT CANNOT DO, stated plainly so nobody mistakes it for more
#
# It does not read free prose, and that is a decision rather than an omission.
# A sentence like 6.4's list of existing emitters needs a reader to see that it
# contradicts 6.2, because a script would have to tell it apart from 6.2's own
# "idryx emits nothing into this envelope", which puts the same source beside
# the same verb and is correct. A check that guesses there cries wolf and gets
# switched off. That 6.4 sentence survived the 2026-08-03 audit for precisely
# this reason: nothing structural touches a sentence.
#
# In the SVGs it judges attribution, not direction. It cannot tell a producer
# box from a consumer box, so it asks two answerable questions instead: which
# source is a type drawn next to (within three text nodes, the width of one
# card: product, plane, type), and does any type belonging to a source that
# emits nothing appear at all. A text node that says "reserved" or "not
# emitted" is skipped, so a diagram may still label a reserved name honestly.
#
# In the flowchart it maps a node to a source only by the product name in its
# label, the text before the colon. A source whose `source` string is not its
# product name is out of scope on that half rather than guessed at.
#
# It says nothing about a source the registry lists and no artifact mentions.
# Absence is a different defect and it needs a reader.
#
# This file is the ONE copy of this check. CI and any local hook both call it.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - <<'PY'
import glob
import html
import json
import pathlib
import re
import sys

problems = []


def fail(msg):
    problems.append(msg)


# --------------------------------------------------------------- the registry
#
# One table, in SPEC 6.2, parsed strictly. If this section stops parsing, the
# check has measured nothing and says so rather than passing quietly.

spec = pathlib.Path("SPEC.md").read_text()


def section_of(number):
    """The text of one '### <number>' subsection, up to the next heading."""
    start = re.search(rf"^### {re.escape(number)} .*$", spec, re.M)
    if not start:
        return None
    rest = spec[start.end():]
    end = re.search(r"^### ", rest, re.M)
    return rest[: end.start()] if end else rest


section = section_of("6.2")
if section is None:
    print("FAIL: SPEC.md has no '### 6.2' heading, so the registry could not be")
    print("      found and this check measured nothing.")
    sys.exit(1)
section_lines = section.splitlines()

HEADER = re.compile(r"^\|\s*`source`\s*\|\s*`type` values\s*\|\s*$")
DIVIDER = re.compile(r"^\|[\s:\-|]+\|\s*$")
ROWISH = re.compile(r"^\|\s*`[a-z0-9_-]+`\s*\|")

header_at = next((i for i, l in enumerate(section_lines) if HEADER.match(l)), None)
if header_at is None:
    print("FAIL: SPEC 6.2 has no '| `source` | `type` values |' table header, so")
    print("      the registry could not be parsed and this check measured nothing.")
    sys.exit(1)
if not DIVIDER.match(section_lines[header_at + 1]):
    print("FAIL: SPEC 6.2's registry header is not followed by a table divider.")
    sys.exit(1)


def types_of(cell):
    """Every `backticked` type name in a table cell, in order."""
    return re.findall(r"`([a-z0-9_]+)`", cell)


def is_reserved(cell):
    return bool(re.search(r"RESERVED|not emitted today", cell, re.I))


registry = {}   # source -> {"types": [...], "reserved": bool}
row_at = header_at + 2
while row_at < len(section_lines) and section_lines[row_at].startswith("|"):
    line = section_lines[row_at]
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) != 2:
        fail(f"SPEC 6.2 registry row {row_at}: expected two cells, got {len(cells)}: {line}")
        row_at += 1
        continue
    name = re.fullmatch(r"`([a-z0-9_-]+)`", cells[0])
    if not name:
        fail(f"SPEC 6.2 registry row {row_at}: first cell is not a `source` name: {cells[0]}")
        row_at += 1
        continue
    registry[name.group(1)] = {"types": types_of(cells[1]), "reserved": is_reserved(cells[1])}
    row_at += 1

# A second fragment of the same table, anywhere else in 6.2, is a copy that can
# drift from the first and answer the same question twice. One was found below
# the prose on 2026-08-06, repeating the last two rows verbatim.
for i in range(row_at, len(section_lines)):
    if ROWISH.match(section_lines[i]):
        fail(
            f"SPEC 6.2 carries a registry row outside its table: "
            f"{section_lines[i].strip()!r}. The registry must be one table; a "
            f"second fragment is a copy that drifts."
        )

if len(registry) < 3:
    print(f"FAIL: SPEC 6.2 parsed to only {len(registry)} source(s), which cannot be right.")
    sys.exit(1)

for source, row in registry.items():
    if not row["types"]:
        fail(f"SPEC 6.2's row for `{source}` names no type at all")

EMITTING = {s for s, r in registry.items() if not r["reserved"]}
RESERVED = {s for s, r in registry.items() if r["reserved"]}

owners = {}     # type -> set of sources whose row lists it
for source, row in registry.items():
    for t in row["types"]:
        owners.setdefault(t, set()).add(source)

# A type nobody live emits: every source that lists it has a reserved row.
reserved_only = {t for t, srcs in owners.items() if srcs and not (srcs & EMITTING)}


def attribution(t):
    """How SPEC 6.2 attributes a type, for the other side of an error message."""
    srcs = owners.get(t)
    if not srcs:
        return "SPEC 6.2 lists it under no source at all"
    listed = ", ".join(f"`{s}`" + (" (RESERVED)" if s in RESERVED else "") for s in sorted(srcs))
    return f"SPEC 6.2 lists it under {listed}"


# ------------------------------------------- 6.1's list of registered sources
#
# The same document lists its sources twice: 6.1 says which are registered,
# 6.2 says what each emits. They have disagreed before, in this direction:
# wardryx, verdryx and mockryx were in 6.1 while 6.2 had rows for one of them,
# so two of the stack's producers were invisible to anyone reading the registry
# (fixed by 1299780 on 2026-08-03).

s61 = section_of("6.1")
if s61 is None:
    fail("SPEC.md has no '### 6.1' heading, so its list of registered sources was not read")
else:
    lines61 = s61.splitlines()
    H61 = re.compile(r"^\|\s*`source`\s*\|\s*Product\s*\|\s*$")
    at = next((i for i, l in enumerate(lines61) if H61.match(l)), None)
    if at is None:
        fail(
            "SPEC 6.1 no longer carries the '| `source` | Product |' table of "
            "registered sources. If it moved, this half of the check moves with it."
        )
    else:
        registered = set()
        i = at + 2
        while i < len(lines61) and lines61[i].startswith("|"):
            cells = [c.strip() for c in lines61[i].strip().strip("|").split("|")]
            name = re.fullmatch(r"`([a-z0-9_-]+)`", cells[0]) if cells else None
            if name:
                registered.add(name.group(1))
            i += 1
        for s in sorted(registered - set(registry)):
            fail(f"SPEC 6.1 registers `{s}` and 6.2 has no row saying what it emits")
        for s in sorted(set(registry) - registered):
            fail(f"SPEC 6.2 has a row for `{s}` and 6.1 does not register it as a source")


# ------------------------------------------------------------------- examples

example_lines = 0
for path in sorted(glob.glob("examples/*.ndjson")):
    for lineno, raw in enumerate(pathlib.Path(path).read_text().splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError as e:
            fail(f"{path}:{lineno}: invalid JSON ({e})")
            continue
        example_lines += 1
        source, etype = event.get("source"), event.get("type")
        if not isinstance(source, str) or not isinstance(etype, str):
            fail(f"{path}:{lineno}: `source` and `type` must both be strings")
            continue

        if source not in registry:
            fail(
                f"{path}:{lineno} emits `source: \"{source}\"` and SPEC 6.2 "
                f"registers no such source. An undeclared source on the shared "
                f"bus is an extension no consumer was told about."
            )
            continue

        if source in RESERVED:
            fail(
                f"{path}:{lineno} emits `source: \"{source}\"`, `type: \"{etype}\"`, "
                f"and SPEC 6.2's `{source}` row is marked RESERVED, not emitted "
                f"today. One of the two is wrong: either that producer emits "
                f"after all, or this line claims an event nobody writes."
            )
            continue

        if etype not in registry[source]["types"]:
            fail(
                f"{path}:{lineno} attributes `type: \"{etype}\"` to "
                f"`source: \"{source}\"`, whose SPEC 6.2 row does not list it. "
                f"{attribution(etype)}."
            )

# ------------------------------------------------------- README's copy of 6.2

readme_path = pathlib.Path("README.md")
readme = readme_path.read_text()
readme_lines = readme.splitlines()

R_HEADER = re.compile(r"^\|\s*`source`\s*\|\s*Product\s*\|\s*`type` values\s*\|\s*$")
r_header_at = next((i for i, l in enumerate(readme_lines) if R_HEADER.match(l)), None)
if r_header_at is None:
    fail(
        "README.md no longer carries the registry table this check compares "
        "against SPEC 6.2 ('| `source` | Product | `type` values |'). If the "
        "copy was removed on purpose, remove this half of the check with it."
    )
else:
    mirror = {}
    i = r_header_at + 2
    while i < len(readme_lines) and readme_lines[i].startswith("|"):
        cells = [c.strip() for c in readme_lines[i].strip().strip("|").split("|")]
        if len(cells) == 3:
            name = re.fullmatch(r"`([a-z0-9_-]+)`", cells[0])
            if name:
                mirror[name.group(1)] = {
                    "types": types_of(cells[2]),
                    "reserved": is_reserved(cells[2]),
                }
        i += 1

    for s in sorted(set(mirror) - set(registry)):
        fail(f"README.md's registry copy has a `{s}` row and SPEC 6.2 has none")
    for s in sorted(set(registry) - set(mirror)):
        fail(f"SPEC 6.2 registers `{s}` and README.md's copy has no row for it")
    for s in sorted(set(registry) & set(mirror)):
        spec_types, mirror_types = set(registry[s]["types"]), set(mirror[s]["types"])
        for t in sorted(mirror_types - spec_types):
            fail(f"README.md's copy lists `{t}` under `{s}` and SPEC 6.2's row does not")
        for t in sorted(spec_types - mirror_types):
            fail(f"SPEC 6.2 lists `{t}` under `{s}` and README.md's copy does not")
        if registry[s]["reserved"] != mirror[s]["reserved"]:
            which = "SPEC 6.2" if registry[s]["reserved"] else "README.md's copy"
            fail(
                f"`{s}` is marked RESERVED in {which} only. Whether a producer "
                f"emits is the one thing this table exists to say."
            )

# ----------------------------------------------------------- diagrams (SVG)


def boundary(token):
    return re.compile(rf"(?<![0-9a-z_]){re.escape(token)}(?![0-9a-z_])")


TYPE_RE = {t: boundary(t) for t in owners}
SOURCE_RE = {s: boundary(s) for s in registry}

svgs = sorted(glob.glob("assets/*.svg") + glob.glob("docs/*.svg"))
NEARBY = 3  # one card is product, plane, type

for path in svgs:
    svg = pathlib.Path(path).read_text()
    nodes = [
        html.unescape(re.sub(r"<[^>]+>", "", raw)).strip()
        for raw in re.findall(r"<text\b[^>]*>(.*?)</text>", svg, re.S)
    ]
    last_source, last_source_at = None, None
    for idx, text in enumerate(nodes):
        low = text.lower()

        here = [(m.start(), s) for s, rx in SOURCE_RE.items() if (m := rx.search(low))]
        if here:
            last_source, last_source_at = max(here)[1], idx

        if re.search(r"reserved|not emitted", low):
            continue  # a diagram may name a reserved type as reserved

        for t, rx in TYPE_RE.items():
            if not rx.search(low):
                continue
            if t in reserved_only:
                fail(
                    f"{path} draws `{t}` in a text node ({text!r}), and "
                    f"{attribution(t)}, whose row says it emits nothing into "
                    f"this envelope. The picture claims a producer the registry "
                    f"denies."
                )
                continue
            if last_source_at is not None and idx - last_source_at <= NEARBY:
                if last_source not in owners[t]:
                    fail(
                        f"{path} draws `{t}` beside `{last_source}` "
                        f"({text!r}), and {attribution(t)}. The picture "
                        f"attributes a type to the wrong producer."
                    )

# ------------------------------------------------------ README's mermaid graph

mermaid = re.search(r"```mermaid\n(.*?)```", readme, re.S)
if not mermaid:
    fail("README.md has no mermaid block, so the flowchart half measured nothing")
else:
    body = mermaid.group(1)

    DECL = re.compile(r"([A-Za-z_]\w*)(?:\[\[|\{\{|\(\[|\[\(|\[|\()\"([^\"]*)\"")
    node_source = {}   # node id -> registry source, by product name only
    bus_ids = set()
    for node_id, label in DECL.findall(body):
        if re.search(r"agent-event bus", label, re.I):
            bus_ids.add(node_id)
        product = re.split(r"[\s,:]", label.split(":")[0].strip())[0].lower()
        if product in registry:
            node_source[node_id] = product

    if not bus_ids:
        fail(
            "README.md's flowchart has no node labelled as the agent-event bus, "
            "so producer arrows could not be judged and this half measured nothing"
        )
    else:
        stripped = body
        for pat in (r"\[\[.*?\]\]", r"\{\{.*?\}\}", r"\(\[.*?\]\)", r"\[\(.*?\)\]", r"\[.*?\]"):
            stripped = re.sub(pat, "", stripped)
        EDGE = re.compile(
            r"^\s*([A-Za-z_]\w*)\s*(?:==>|-->|-\.->|--[xo])\s*(?:\|[^|]*\|)?\s*([A-Za-z_]\w*)"
        )
        into_bus = set()
        for line in stripped.splitlines():
            m = EDGE.match(line)
            if m and m.group(2) in bus_ids:
                into_bus.add(m.group(1))

        drawn = {}
        for node_id, s in node_source.items():
            drawn.setdefault(s, set()).add(node_id)

        for s in sorted(drawn):
            writers = drawn[s] & into_bus
            if s in RESERVED and writers:
                fail(
                    f"README.md's flowchart draws {sorted(writers)} into the "
                    f"agent-event bus, and SPEC 6.2 marks `{s}` RESERVED, not "
                    f"emitted today. The diagram makes it a producer."
                )
            if s in EMITTING and not writers:
                fail(
                    f"README.md's flowchart gives `{s}` no arrow into the "
                    f"agent-event bus (nodes {sorted(drawn[s])}), and SPEC 6.2 "
                    f"lists {len(registry[s]['types'])} type(s) it emits today."
                )

# ---------------------------------------------------------------------- result

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("SPEC 6.2 is the registry: it says which product emits which event")
    print("types into this envelope TODAY. An artifact that says otherwise is a")
    print("claim a consumer can act on and be wrong about, and neither the")
    print("schema check nor the example validator can see it, because `source`")
    print("and `type` are open strings by design. See CLAUDE.md invariant 7.")
    sys.exit(1)

print(
    f"OK: SPEC 6.2 registers {len(registry)} sources "
    f"({len(EMITTING)} emitting, {len(RESERVED)} reserved) and "
    f"{sum(len(r['types']) for r in registry.values())} types; "
    f"{example_lines} example event(s), README's copy of the table, "
    f"{len(svgs)} SVG(s) and the README flowchart all agree with it."
)
print("    (Structured artifacts only: free prose still needs a reader.)")
PY

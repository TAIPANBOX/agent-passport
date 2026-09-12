#!/usr/bin/env bash
# Enforces invariant 13 of CLAUDE.md: every scenario in features/ names a gate
# that exists, and every scenario names one at all.
#
# A specification repository has no test suite to bind a scenario to, so the
# binding here is to the GATE that holds the promise: a script under scripts/
# or the validator under .github/scripts/. The scenario is what a reader reads
# instead of the gate's source; the binding is what stops the two from
# drifting apart into a story about checks that no longer run.
#
# It refuses to report success when it measured nothing: no features/ directory,
# no scenario in it, or a binding line it cannot read.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

features = sorted(pathlib.Path("features").glob("*.feature")) if pathlib.Path("features").is_dir() else []
if not features:
    print("FAIL: no features/*.feature to read, so this check measured nothing.")
    sys.exit(1)

BINDING = re.compile(r"^\s*#\s*@gate:\s*(.+?)\s*$")
fails = []
scenarios = 0
bindings = 0

for path in features:
    lines = path.read_text().splitlines()
    current = None
    bound = False
    def close(current, bound):
        if current is not None and not bound:
            fails.append(f"{path}: scenario {current!r} names no gate (add a `# @gate: <command>` line inside it)")
    for line in lines:
        if re.match(r"^\s*Scenario( Outline)?:", line):
            close(current, bound)
            current = line.split(":", 1)[1].strip()
            bound = False
            scenarios += 1
            continue
        m = BINDING.match(line)
        if m:
            if current is None:
                fails.append(f"{path}: a `# @gate:` line sits outside any scenario")
                continue
            command = m.group(1)
            # The gate is the first path-shaped token that points into scripts/
            # or .github/scripts/; anything else is a command this repo does not own.
            target = None
            for tok in command.split():
                if tok.startswith("scripts/") or tok.startswith(".github/scripts/"):
                    target = tok
                    break
            if target is None:
                fails.append(f"{path}: scenario {current!r} binds to {command!r}, which names no script under scripts/ or .github/scripts/")
            elif not pathlib.Path(target).is_file():
                fails.append(f"{path}: scenario {current!r} binds to {target}, which does not exist")
            elif target.startswith("scripts/") and not (pathlib.Path(target).stat().st_mode & 0o111):
                fails.append(f"{path}: scenario {current!r} binds to {target}, which is not executable")
            else:
                bindings += 1
            bound = True
    close(current, bound)

if scenarios == 0:
    print("FAIL: the feature files carry no Scenario at all, so this check measured nothing.")
    sys.exit(1)

if fails:
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print("Every scenario names the gate that holds it, and every gate named exists.")
    print("See CLAUDE.md invariant 13.")
    sys.exit(1)

print(f"OK: {scenarios} scenario(s) across {len(features)} feature file(s), {bindings} binding(s), every one pointing at a gate that exists.")
PY

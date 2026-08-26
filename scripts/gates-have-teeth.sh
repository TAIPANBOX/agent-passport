#!/usr/bin/env bash
# Checks that the gates in `scripts/` still FAIL on the faults they exist to
# catch, still PASS on what they must not catch, and REFUSE to report success
# when they measured nothing at all.
#
# WHY
#
# Every gate here parses text, and a text parser does not break loudly: it
# stops matching and reports success. The mutants that proved each one existed
# as prose, in commit messages and in the `*(gate: ...)*` markers in CLAUDE.md,
# which is a record of what was true once. Nothing ran them again.
#
# A gate that has quietly stopped catching anything looks exactly like a gate
# with nothing to catch, and stays that way until the fault it guards ships.
#
# WHY THE THIRD PROPERTY IS SEPARATE FROM THE FIRST
#
# Every script gate here already refuses when its subject is absent, and they
# say so in their own words: no schemas found, jsonschema unavailable, a
# registry heading gone, a registry table header gone, a registry that parsed to
# too few rows, the governed field gone from the schema, the example that was to
# be measured carrying nothing. Every one of those sentences was true, every one
# was established by hand once in the session that wrote the script, and nothing
# re-ran them. The list no longer counts itself: it said "three script gates,
# five distinct ways" for as long as there were four gates and more ways, which
# is SPEC 6.2's lesson about a total in prose, met here.
#
# This repository is the contract the rest of the estate implements, so a gate
# here that quietly stops comparing does not break this repo at all. It breaks
# in six other repositories, at whatever pace each of them next reads the SPEC.
#
# HOW IT MUTATES WITHOUT LEAVING A MESS
#
# It edits tracked files in place, so it refuses to start unless the tree is
# clean, restores with `git checkout` after every case, restores again from a
# trap on any exit path including a kill, and asserts the tree is clean before
# reporting success.
#
#
# A GATE THAT IS ALREADY FAILING CANNOT BE JUDGED
#
# No case proves anything if the gate was already failing before the mutation.
# So every case runs the gate on the UNMUTATED tree first and reports
# UNJUDGEABLE. Found on 2026-08-09 in it-rat, where one gate was legitimately
# red and a case against it would have been indistinguishable from a working
# one.
#
# It covered only the fail-cases at first, which left the mirror of the same
# bug: on a red gate a pass-case reports OVEREAGER, "the gate failed on
# something it must not catch", and sends the reader to look at a harmless
# mutation. The verdict was being given without the predicate it depends on.
#
# A MUTATION THAT DID NOT APPLY PROVES NOTHING
#
# Every edit asserts it changed the file. A case whose edit applied nothing is
# a failure here, not a pass. That is not hypothetical: five such mutations
# were caught across idryx and tokenfuse on 2026-08-09, and three of the five
# had been verified BY HAND against the same gate minutes earlier. The hand
# version and the harness version differ only in how many layers of quoting sit
# between the text and python, which is exactly the difference nobody sees.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

if [ -n "$(git status --porcelain)" ]; then
	printf 'this script mutates tracked files, so it needs a clean tree.\n'
	printf 'commit or stash first; it restores with `git checkout` and cannot\n'
	printf 'tell your edits from its own.\n'
	exit 1
fi

# Untracked files too: a mutation may RENAME a tracked file, and `git checkout`
# restores the original while leaving the new name behind. And the INDEX, since
# a gate may read `git ls-files` rather than the disk, so a mutation has to move
# the file in both. Safe because this
# script refuses to start unless the tree is clean, so anything untracked
# during a run was created by the run. `-x` is deliberately absent: ignored
# build output is not ours to delete.
if ! python3 -c 'import jsonschema' 2>/dev/null; then
	printf 'the gates here need jsonschema to validate anything. Without it the\n'
	printf 'validator dies on its import line, and every case below would fail\n'
	printf 'for that reason rather than the one it is about:\n'
	printf '    pip install "jsonschema>=4.18"\n'
	exit 1
fi

restore() {
	git reset -q --hard HEAD 2>/dev/null
	git clean -fdq 2>/dev/null
}
baseline_dir="$(mktemp -d)"

# One trap for both, because a second `trap ... EXIT` REPLACES the first
# rather than adding to it. Writing them separately disarmed `restore` on
# every interrupt path, which would leave a mutated tree behind on Ctrl-C.
cleanup() {
	restore
	rm -rf "$baseline_dir"
}
trap cleanup EXIT INT TERM


failures=0
cases=0

# run_case <name> <expect: fail|pass> <gate> <python edit> [required output]
#
# The needle separates "it failed" from "it failed for the reason this case is
# about". Without it, a case expecting failure is satisfied by any failure,
# including one this harness caused itself.
run_case() {
	local name="$1" expect="$2" gate="$3" edit="$4" needle="${5:-}"
	cases=$((cases + 1))

	# The baseline applies to EVERY case, not only the ones expecting a failure.
	# It was `fail`-only until 2026-08-09, which left the mirror of the bug it was
	# written for: on a gate that is already red, a `pass` case reports OVEREAGER,
	# "the gate failed on something it must not catch", and sends the reader to
	# look at a harmless mutation while the gate was failing without it. Neither
	# verdict means anything on a red gate, so neither is given.
	skip_baseline=0
	if [ "$expect" = fail_env ]; then
		# `fail` with the baseline skipped, for cases whose fault IS the command
		# rather than a mutation: red before and after is the point there.
		expect=fail
		skip_baseline=1
	fi

	if [ "$skip_baseline" = 0 ]; then
		local key base_out
		key="$baseline_dir/$(printf '%s' "$gate" | cksum | tr -d ' ')"
		if [ ! -f "$key" ]; then
			if eval "$gate" >/dev/null 2>&1; then printf 'green' >"$key"; else printf 'red' >"$key"; fi
		fi
		base_out="$(cat "$key")"
		if [ "$base_out" = red ]; then
			printf 'UNJUDGEABLE  %s\n             the gate is already failing on a clean tree, so neither a\n             failure nor a pass after the mutation would prove anything\n' "$name"
			failures=$((failures + 1))
			return
		fi
	fi

	if ! python3 -c "$edit"; then
		printf 'BROKEN  %s\n        its mutation did not apply, so this case proved nothing\n' "$name"
		failures=$((failures + 1))
		restore
		return
	fi

	local out rc
	out=$(eval "$gate" 2>&1)
	rc=$?
	restore

	# Exit code first, then wording. Checking the needle before the expectation
	# turns "it did not fail at all" into "it failed for the wrong reason",
	# which sends the reader to look at prose when the gate is toothless.
	if [ "$expect" = fail ] && [ "$rc" -ne 0 ] && [ -n "$needle" ] &&
		! printf '%s' "$out" | grep -qF -- "$needle"; then
		printf 'WRONG REASON  %s\n              it failed, but not saying: %s\n' "$name" "$needle"
		failures=$((failures + 1))
		return
	fi
	if [ "$expect" = fail ] && [ "$rc" -eq 0 ]; then
		printf 'TOOTHLESS  %s\n           the gate passed on a fault it exists to catch\n' "$name"
		failures=$((failures + 1))
	elif [ "$expect" = pass ] && [ "$rc" -ne 0 ]; then
		printf 'OVEREAGER  %s\n           the gate failed on something it must not catch\n' "$name"
		failures=$((failures + 1))
		printf '%s\n' "$out" | head -4 | sed 's/^/           /'
	else
		printf 'ok  %-58s (%s)\n' "$name" "$expect"
	fi
}

py() { printf 'def edit(p, a, b):\n    s = open(p).read()\n    assert a in s, "pattern not found in " + p\n    open(p, "w").write(s.replace(a, b, 1))\n%s\n' "$1"; }

echo "=== faults each gate must catch ==="

# invariant 3, the three mutations CLAUDE.md says this validator was verified
# against. They were done by hand, once, in the session that wrote it. These
# are the same three, run every time.
run_case "validate-examples: an id that breaks the agent:// pattern" fail \
	'python3 .github/scripts/validate_examples.py' \
	"$(py 'import json
p = "examples/passport.json"
d = json.load(open(p))
d["id"] = "not-an-agent-uri"
json.dump(d, open(p, "w"), indent=2)')" \
	"does not match '^agent://"

run_case "validate-examples: a required field removed from the passport" fail \
	'python3 .github/scripts/validate_examples.py' \
	"$(py 'import json
p = "examples/passport.json"
d = json.load(open(p))
assert "owner" in d, "the example passport carries no owner"
del d["owner"]
json.dump(d, open(p, "w"), indent=2)')" \
	"'owner' is a required property"

run_case "validate-examples: a non-string ts on one event line" fail \
	'python3 .github/scripts/validate_examples.py' \
	"$(py 'import json
p = "examples/events.ndjson"
lines = [l for l in open(p).read().splitlines() if l.strip()]
assert lines, "events.ndjson is empty"
d = json.loads(lines[0])
d["ts"] = 1754700000
lines[0] = json.dumps(d)
open(p, "w").write("\n".join(lines) + "\n")')" \
	"ts"

# SPEC 6.4's compatibility promise: an emitter on v0.1 can move to v0.2 without
# changing what it sends. A newly required field breaks exactly that.
run_case "version-compatibility: v0.2 newly requires a field" fail \
	'./scripts/version-compatibility.sh' \
	"$(py 'import json
p = "schemas/agent-event.v0.2.schema.json"
d = json.load(open(p))
req = d.setdefault("required", [])
cand = [k for k in d.get("properties", {}) if k not in req]
assert cand, "every property is already required"
req.append(cand[0])
json.dump(d, open(p, "w"), indent=2)')" \
	"is required in the newer schema and was not in the older one"

run_case "version-compatibility: a v0.1 field disappears from v0.2" fail \
	'./scripts/version-compatibility.sh' \
	"$(py 'import json
old = json.load(open("schemas/agent-event.schema.json"))
p = "schemas/agent-event.v0.2.schema.json"
d = json.load(open(p))
shared = [k for k in old.get("properties", {}) if k in d.get("properties", {})]
assert shared, "the two versions share no property"
del d["properties"][shared[0]]
json.dump(d, open(p, "w"), indent=2)')" \
	"exists in the older schema and is gone"

# A field in the schema that the prose never mentions: an implementer reading
# the SPEC builds without it, and the two halves of the contract disagree.
run_case "schema-matches-spec: a schema field the prose never mentions" fail \
	'./scripts/schema-matches-spec.sh' \
	"$(py 'import json
p = "schemas/agent-passport.schema.json"
d = json.load(open(p))
d["properties"]["undocumented_knob"] = {"type": "string"}
json.dump(d, open(p, "w"), indent=2)')" \
	"SPEC.md never"

echo
run_case "providers-match-registry: an example passport spells a provider its own way" fail \
	'./scripts/providers-match-registry.sh' \
	"$(py 'edit("examples/passport.json", "\"provider\": \"anthropic\"", "\"provider\": \"Anthropic\"")')" \
	"which SPEC 4.7 does not register"

run_case "providers-match-registry: SPEC 4.5's own example names an unregistered provider" fail \
	'./scripts/providers-match-registry.sh' \
	"$(py 'edit("SPEC.md", "{ \"provider\": \"anthropic\", \"model\": \"claude-sonnet-4-5\"", "{ \"provider\": \"claude\", \"model\": \"claude-sonnet-4-5\"")')" \
	"SPEC 4.5's own example declares provider"

# The schema's description listed six providers by name until 4.7 existed. That
# is the second copy this gate is really for: nobody edits a schema description
# when a registry gains a row.
run_case "providers-match-registry: the schema description lists ids again" fail \
	'./scripts/providers-match-registry.sh' \
	"$(py 'edit("schemas/agent-passport.schema.json", "LLM provider label. SHOULD", "LLM provider label, e.g. anthropic. SHOULD")')" \
	"second copy of the registry"

echo
run_case "runtimes-match-registry: an example passport spells a runtime its own way" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("examples/passport.json", "\"runtime\": \"langgraph\"", "\"runtime\": \"LangGraph\"")')" \
	"which SPEC 4.8 does not register"

# The trailing comma is what makes this pattern unique: 4.8 quotes the same
# declaration in its opening paragraph, without one.
run_case "runtimes-match-registry: SPEC section 4's own example names an unregistered runtime" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("SPEC.md", "\"runtime\": \"langgraph\",", "\"runtime\": \"our-own-loop\",")')" \
	"SPEC section 4's own example declares runtime"

# The schema description read "e.g. langgraph" until 4.8 existed. That is the
# second copy this gate is really for, and it was live on main when the gate
# was written: nobody edits a schema description when a registry moves.
run_case "runtimes-match-registry: the schema description lists ids again" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("schemas/agent-passport.schema.json", "control loop. SHOULD", "control loop, e.g. langgraph. SHOULD")')" \
	"second copy of the registry"

# And the same copy one file further out, in the table most readers reach
# before either the schema or the spec. Also live on main.
run_case "runtimes-match-registry: README's field table lists ids again" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("README.md", "control loop; a declaration", "control loop, e.g. langgraph; a declaration")')" \
	"second copy of the registry"

echo "=== and what they must NOT catch ==="

# An unregistered provider in free prose is not a fault. The field is an open
# string by design, this repo discusses providers it does not register, and a
# gate that fired here would be asking the spec to stop naming things.
run_case "providers-match-registry: prose naming an unregistered provider" pass \
	'./scripts/providers-match-registry.sh' \
	"$(py 'edit("SPEC.md", "### 4.7 Registered provider ids\n", "### 4.7 Registered provider ids\n\nAn operator running deepseek writes that label and is not refused.\n")')"

# A row appended to the registry is the ordinary way this list grows, and the
# only way: 4.7 says ids are appended, never renamed.
run_case "providers-match-registry: a provider appended to the registry" pass \
	'./scripts/providers-match-registry.sh' \
	"$(py 'edit("SPEC.md", "| `ollama` | Ollama, a model server the operator runs |", "| `ollama` | Ollama, a model server the operator runs |\n| `deepseek` | DeepSeek API |")')"

# Same two non-faults one registry over. An unregistered framework in prose is
# not a fault: 4.8 argues at length that the field stays open, so a gate firing
# here would be asking the spec to stop describing the case it exists for.
run_case "runtimes-match-registry: prose naming an unregistered runtime" pass \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("SPEC.md", "### 4.8 `runtime`, and the registered runtime ids\n", "### 4.8 `runtime`, and the registered runtime ids\n\nAn operator running smolagents writes that label and is not refused.\n")')"

run_case "runtimes-match-registry: a runtime appended to the registry" pass \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("SPEC.md", "| `microsoft-agent-framework` | Microsoft Agent Framework, which converges Semantic Kernel and AutoGen |", "| `microsoft-agent-framework` | Microsoft Agent Framework, which converges Semantic Kernel and AutoGen |\n| `llamaindex` | LlamaIndex |")')"


# The gate is deliberately one-directional: prose without a schema field is
# allowed, because free prose is most of a specification.
run_case "schema-matches-spec: prose that names something no schema declares" pass \
	'./scripts/schema-matches-spec.sh' \
	"$(py 'edit("SPEC.md", "### 6.2 Initial event-type registry", "A `hypothetical_future_knob` is discussed here and declared nowhere.\n\n### 6.2 Initial event-type registry")')"

# Widening a bound is compatible in the direction that matters: everything
# v0.1 accepted, v0.2 still accepts. The first version of this case ADDED a
# maxLength where v0.1 had none, and the gate correctly called that a
# narrowing, since v0.1 accepted everything above the new ceiling. Raising an
# existing ceiling is the real widening.
# Raised on the NEWEST schema, and that detail is the case rather than an
# accident of which file was handy. Raising it on a middle version makes the
# version AFTER it look narrowed, so this case failed as OVEREAGER the day v0.3
# arrived: the mutation was fine and the expectation had silently become a claim
# about a two-version world. A widening is only a widening with respect to what
# comes before it.
run_case "version-compatibility: the newest schema raises an existing ceiling" pass \
	'./scripts/version-compatibility.sh' \
	"$(py 'import json
p = "schemas/agent-event.v0.3.schema.json"
d = json.load(open(p))
sch = d["properties"]["agent_id"]
assert "maxLength" in sch, "agent_id carries no maxLength to raise"
sch["maxLength"] = sch["maxLength"] * 2
json.dump(d, open(p, "w"), indent=2)')"

echo
echo "=== and the one this estate learned the hard way ==="
echo "    a gate whose subject is gone must SAY so, not report OK on nothing"

run_case "artifacts-match-registry: SPEC 6.2 loses its heading" fail \
	'./scripts/artifacts-match-registry.sh' \
	"$(py 'edit("SPEC.md", "### 6.2 Initial event-type registry", "### 6.2bis Initial event-type registry")')" \
	"has no '### 6.2' heading"

# The validator prints "N schema(s)" from a glob. With no schemas at all that
# sentence would read as a clean run over nothing, so what it must do instead
# is fail. It does, on the fixed path it reads next.
run_case "validate-examples: no schemas left to validate against" fail \
	'python3 .github/scripts/validate_examples.py' \
	"$(py 'import subprocess, glob
n = 0
for f in glob.glob("schemas/*.json"):
    subprocess.run(["git", "mv", f, f + ".disabled"], check=True)
    n += 1
assert n, "no schemas in this repo"')"

run_case "providers-match-registry: SPEC 4.7 loses its heading" fail \
	'./scripts/providers-match-registry.sh' \
	"$(py 'edit("SPEC.md", "### 4.7 Registered provider ids", "### 4.9 Registered provider ids")')" \
	"has no '### 4.7' heading"

run_case "providers-match-registry: the registry parses to almost nothing" fail \
	'./scripts/providers-match-registry.sh' \
	"$(py 'import re
s = open("SPEC.md").read()
kept = 0
out = []
for line in s.splitlines(keepends=True):
    m = re.match(r"^[|] .([a-z0-9-]+). [|]", line)
    if m and m.group(1) not in ("id",):
        kept += 1
        if kept > 2:
            continue
    out.append(line)
n = "".join(out)
assert n != s, "no registry rows to remove"
open("SPEC.md", "w").write(n)')" \
	"which cannot"

# Renaming the key through json rather than through a text pattern, because the
# pattern needs a quote inside a quote inside a shell string, and the first two
# attempts at that produced a mutation that changed no bytes. This harness
# caught both and called them BROKEN, which is the one thing it must never let
# pass as a gate that worked.
run_case "providers-match-registry: the schema stops declaring provider" fail \
	'./scripts/providers-match-registry.sh' \
	"$(py 'import json
p = "schemas/agent-passport.schema.json"
d = json.load(open(p))
props = d["properties"]["models"]["items"]["properties"]
props["providerx"] = props.pop("provider")
json.dump(d, open(p, "w"), indent=2)')" \
	"declares no models"

run_case "runtimes-match-registry: SPEC 4.8 loses its heading" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'edit("SPEC.md", "### 4.8 `runtime`", "### 4.10 `runtime`")')" \
	"has no '### 4.8' heading"

run_case "runtimes-match-registry: the registry parses to almost nothing" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'import re
s = open("SPEC.md").read()
kept = 0
out = []
for line in s.splitlines(keepends=True):
    m = re.match(r"^[|] .([a-z0-9-]+). [|]", line)
    if m and m.group(1) not in ("id",):
        kept += 1
        if kept > 2:
            continue
    out.append(line)
n = "".join(out)
assert n != s, "no registry rows to remove"
open("SPEC.md", "w").write(n)')" \
	"which cannot"

run_case "runtimes-match-registry: the schema stops declaring runtime" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'import json
p = "schemas/agent-passport.schema.json"
d = json.load(open(p))
props = d["properties"]
props["runtimex"] = props.pop("runtime")
json.dump(d, open(p, "w"), indent=2)')" \
	"declares no top-level"

# The subject that is easiest to lose without noticing: the field is optional,
# so an example dropping it stays valid, keeps validating, and quietly takes
# away the documents this gate measures.
run_case "runtimes-match-registry: no example declares a runtime at all" fail \
	'./scripts/runtimes-match-registry.sh' \
	"$(py 'import json, pathlib
n = 0
for p in sorted(pathlib.Path("examples").glob("*.json")):
    d = json.loads(p.read_text())
    if isinstance(d.get("runtime"), str):
        del d["runtime"]
        p.write_text(json.dumps(d, indent=2) + "\n")
        n += 1
assert n, "no example declared a runtime to remove"')" \
	"measured nothing about them"

run_case "schema-matches-spec: no schemas left to read" fail \
	'./scripts/schema-matches-spec.sh' \
	"$(py 'import subprocess, glob
n = 0
for f in glob.glob("schemas/*.schema.json"):
    subprocess.run(["git", "mv", f, f + ".disabled"], check=True)
    n += 1
assert n, "no schemas in this repo"')" \
	"measured nothing"

echo
if [ -n "$(git status --porcelain)" ]; then
	printf 'FAIL: this script left the tree dirty, so it cannot be trusted about anything above\n'
	git status --porcelain | head -5
	exit 1
fi

if [ "$failures" -gt 0 ]; then
	printf '%d of %d cases failed.\n' "$failures" "$cases"
	printf 'A gate that has quietly stopped catching anything looks exactly like a gate\n'
	printf 'with nothing to catch, and stays that way until the fault it guards ships.\n'
	exit 1
fi

printf 'OK: %d cases. Every gate fails on its own fault, passes on a non-fault,\n' "$cases"
printf '    and refuses to report success when it measured nothing.\n'

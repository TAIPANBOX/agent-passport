# CLAUDE.md, working instructions for agent-passport

These instructions apply to any model working in this repo. Read this file
before changing anything. It holds process and invariants only: **no status.**
Status goes stale, and a stale instruction file is worse than none. For where
things stand, read `VALIDATION.md` and the git tags.

## Read before you change anything

1. **`SPEC.md`, in full.** Not the section you think you need. The sections
   interlock: identity (3), the passport document (4), the delegation chain (5)
   and the event envelope (6) constrain each other, and 6.4 governs how any of
   them may change.
2. `schemas/`. Three files: the passport schema, and the event schema at v0.1
   and v0.2. These are the machine form of `SPEC.md`.
3. `examples/`. `passport.json` and `events.ndjson` are what CI validates.

## What this repo is

The specification, and nothing else. There is no service and no library here.
One agent identifier, one delegation chain, one event envelope, so that
TokenFuse, Engram, Idryx, Qryx, Wardryx, Verdryx, Mockryx, agent-stack-go and
terraform-provider-taipan all speak the same language instead of nine dialects.

**The spec is normative and the implementations are not.** When code in another
repo disagrees with `SPEC.md`, the default resolution is that the code is the
bug. Changing the spec to match an implementation is a decision for the user,
never a convenience fix, because it silently redefines what the other eight
repos are conforming to.

The stack this spec serves is defensive: it exists so an organization can
govern and audit its own agents. Never describe it otherwise.

## Blast radius, read this before calling any change small

Every edit to `SPEC.md` or `schemas/` is an edit to nine repositories at once,
and they adopt on their own schedule. The SPEC 6.5 `prev_hash` chain alone took
seven coordinated pull requests across tokenfuse, engram, verdryx, qryx,
mockryx, wardryx and agent-stack-go.

There is no such thing as a typo fix in a normative sentence. If the wording
changes what an implementer would build, it is a spec change.

## The working loop

1. Branch off `main`, one logical increment per branch.
2. Run the gate below.
3. Commit with Conventional Commits. End the message with the standard
   co-author trailer naming the model that actually did the work.
4. Push the branch, open a PR with `gh`.
5. Wait for CI to go green.
6. **Ask the user before merging.** Do not self-merge.

## Gates

```sh
pip install "jsonschema>=4.18"
python .github/scripts/validate_examples.py
./scripts/schema-matches-spec.sh
./scripts/version-compatibility.sh
./scripts/artifacts-match-registry.sh
./scripts/gates-have-teeth.sh     # invariant 8; needs a clean tree and jsonschema
```

This is what CI runs. It validates every example against the schemas, which is
the only automated tie between the prose and the files.

## Hard invariants

Each one carries how it is held today. Use `(gate: ...)`, `(test: ...)`,
`(partly gated: ...)` or `(not enforced)`, and use the weakest one that is
true. An invariant with no check, written as though it had one, is worse than
an absent invariant.

1. **`SPEC.md` is normative; implementations conform to it.** A disagreement
   between spec and code is resolved in the spec's favour unless the user
   decides otherwise. *(not enforced)*
2. **`schemas/` is the machine form of `SPEC.md` and must not drift from it.**
   A field added to the prose without the schema, or to the schema without the
   prose, means implementers using one of them build the wrong thing.
   *(partly gated: `scripts/schema-matches-spec.sh` catches schema ahead of
   prose, which is half the surface. See below for why only half.)*
3. **Every example validates against its schema.**
   *(gate: `.github/scripts/validate_examples.py`)*

   Verified by breaking it three ways: an `id` violating the `agent://` pattern,
   a missing required `owner`, and a non-string `ts` on one line of
   `events.ndjson`. All three fail loudly with the offending path.

   **Known limit, do not mistake this gate for more than it is.** The passport
   schema leaves `additionalProperties` at its default of true, so an unknown
   key passes silently. Writing `agent_id` where the field is `id` validates
   clean, and the passport simply has no identifier as far as any consumer is
   concerned. The gate catches malformed values, not misspelled field names.
4. **Both event schema versions stay live.** v0.1 and v0.2 are both valid
   input. Retiring v0.1 is a breaking change for every consumer that has not
   migrated, and needs the user. *(partly gated: the validator covers whichever
   versions the examples exercise, not the promise to keep them)*
5. **An optional field never quietly becomes required**, and more generally
   v0.2 is a WIDENING of v0.1. Optionality is a compatibility promise under 6.4:
   a stream written by an older implementation must keep validating. Tightening
   a constraint is a version bump.
   *(gate: `scripts/version-compatibility.sh`)*
6. **Reserved conventions stay reserved.** `labels.version` (4.6) and
   `AGENT_PASSPORT_ID` (3.3) are reserved precisely so nobody redefines them
   locally. Adding a new reserved convention is a spec decision.

   Both are conventions rather than schema changes, and that is the whole
   reason they are cheap: no field enters any document, no validator changes,
   and a Passport is exactly as valid with or without either. The cost of
   getting one wrong is paid elsewhere: a name redefined locally makes two
   products disagree about the same string, and nothing in `schemas/` can see
   it, because there is nothing there to see.

   `AGENT_PASSPORT_ID` carries one extra obligation the other does not, and it
   is the sentence most likely to be lost first: **it is a self-declaration and
   must never be read as attestation.** A process sets its own environment. Any
   consumer that lets an identity learned this way satisfy a control requiring
   an attested one has broken 3.3 and §2 together, and it will look like it is
   working. *(not enforced)*
7. **No artifact in this repo contradicts the 6.2 event-type registry.** The
   registry is the only statement of which product emits which types today, and
   it is invisible to both other gates: `source` and `type` are open strings by
   design (6.1), so an example, a diagram or a second table claiming a producer
   that emits nothing validates clean and matches the prose.
   *(partly gated: `scripts/artifacts-match-registry.sh`, which reads 6.2 as
   the source of truth and measures `examples/*.ndjson`, README's copy of the
   table, the `<text>` nodes of the SVGs and the flowchart's arrows into the
   bus against it. Free prose is deliberately out of scope. See below.)*

8. **A check must be able to tell "did not fail" from "did not run", and every
   gate here has been made to fail on purpose to prove it can.** The three
   script gates already refuse when their subject is absent, in five distinct
   ways: no schemas found, jsonschema unavailable, the 6.2 heading gone, the
   registry table header gone, a registry that parsed to too few sources. And
   invariant 3 says in as many words that the validator was "verified by
   breaking it three ways". Every one of those sentences was true. Every one
   was established by hand, once, in the session that wrote the script, and
   nothing re-ran any of them. The three mutations named in invariant 3 are now
   three cases here, run on every push.

   This repository is where that matters most in the estate, and the reason is
   the blast radius above rather than anything about the scripts. A gate here
   that has quietly stopped comparing breaks nothing in this repo: there is no
   service to break. It breaks in nine other repositories, at whatever pace
   each of them next reads `SPEC.md`, and the symptom is two products
   conforming to different contracts while both report green.

   **It mutates `schemas/` and `SPEC.md` in place and restores them**, which is
   not the change this file's escalation rule is about: nothing is committed,
   the tree is asserted clean before the run reports success, and a run that
   left residue fails instead. A spec change is still a decision for the user.
   *(gate: `scripts/gates-have-teeth.sh`, 11 cases: seven real faults each gate
   must catch, two non-faults they must not, and two subjects taken away
   entirely. The non-faults are the ones worth keeping: prose that names
   something no schema declares is deliberately allowed by invariant 2's
   half-surface, and a raised ceiling is the widening 6.4 promises.)*

   **What it does not cover.** It cannot test itself. It proves each gate
   catches the faults named in it, not every fault of that kind. It found no
   hole in any of the four checks.

   Writing it did find one in ITSELF, and it is the failure mode this whole
   harness exists for. A case asserted the validator fails saying `ts`, and it
   passed on a machine with no jsonschema, because the validator died on its
   import line and the traceback contained the word `scripts`. A three-letter
   needle matched a path. The needles are now specific strings, and the harness
   refuses to start without jsonschema at all.

## Decisions that have no gate yet

This list is debt, and it is here to stay visible rather than to be tidy.

**Held by this file alone: invariants 1 and 6.**

Invariant 2 is now half held by `scripts/schema-matches-spec.sh`, which walks
every property declared anywhere in `schemas/*.json`, including nested ones and
those under `$defs`, and fails when a name appears in no part of `SPEC.md`. It
runs in CI. Thirty-eight declarations across three schemas pass today.

**The half it does not cover is deliberate, not an oversight.** Prose ahead of
schema, a field described in `SPEC.md` that no schema declares, passes this
cleanly. Catching that needs a reader: the prose names things it does not
define, quotes examples, and discusses fields belonging to other documents, so
a script would cry wolf and get disabled. Half the surface, honestly labelled,
beats a guess at the other half.

It also says nothing about whether the prose describing a field is correct. A
name present in both places can still be documented wrongly.

Invariant 5 is now `scripts/version-compatibility.sh`, and it is broader than
the narrow form this paragraph asked for.

The obvious behavioural check does not work and it is worth knowing why:
`schema` is a `const` in each file, so a v0.1 event does not validate against
the v0.2 schema and never will. That is design, not drift. So the check swaps
ONLY the version string and then requires the event to pass, which is the actual
promise in 6.4: everything else about a v0.1 event stays acceptable.

The structural half compares the two schemas and refuses anything that narrows.
Where v0.1 constrains a field to an enum, compatibility is DECIDABLE and the
check decides it: every value v0.1 accepted is validated against v0.2's schema
for that field.

**That last part exists because a heuristic got it wrong on the only field that
actually changed.** Comparing bounds in isolation reported `source` as
"tightened minLength from unset to 1", when v0.1's four enum values are all
non-empty and every one still passes. A bound is not a narrowing if the old
schema was narrower by another means.

**Separately, the `additionalProperties` question is open and is a real hole.**
Today a misspelled field name validates clean (see invariant 3). Setting
`additionalProperties: false` would close it, but it also forbids forward
compatibility: an older validator would then reject a document carrying a field
added in a later version, which is the opposite of what 6.4 promises. The
middle path is to keep the schema permissive and have the validator warn on
unknown keys in `examples/` only, since our own examples have no reason to
carry one. That is a decision for the user, not a fix to apply quietly.

Invariant 7 is `scripts/artifacts-match-registry.sh`, and it exists because the
two checks above cannot see the registry at all. They compare schema with prose
and examples with schema; 6.2 is neither, since `source` and `type` are open
strings. Three artifacts claimed idryx as an emitter from the first commit,
the 2026-08-03 audit corrected only the prose, and each artifact was found by
eye afterwards. The script reads 6.2, fails on a source it does not register,
on a source whose row says it emits nothing, and on a type attributed to a
producer whose row does not list it, in the examples, in README's copy of the
table, in the SVGs' text nodes and in the flowchart's arrows.

**Its limit is prose, and the limit is chosen rather than left.** The example
this paragraph used until 2026-08-10 is itself the argument: it said the
sentence in 6.4 was wrong in exactly the way this gate is meant to catch, and
that no script could judge it, because it would have to be told apart from
6.2's own "idryx emits nothing into this envelope", which was correct.

That second sentence no longer exists. idryx gained an event writer and 6.2's
row stopped saying RESERVED on 2026-08-10, so this file was citing, as the
example of a TRUE statement a gate must not flag, a statement that had been
deleted. An instruction file quoting a line that is gone is worse than one
quoting a line that is wrong, because a reader goes looking and concludes they
are reading the wrong file.

The limit stands and the reason is unchanged: 6.4 talks ABOUT the registry in
prose, the gate reads the registry itself, and no script can judge a sentence
that describes what a table means. In the diagrams the gate judges attribution,
not direction, because nothing in an SVG says which box is a producer.

Invariants 1 and 6 are judgement and stay judgement.

## Standing rule

An approved architecture decision is **not finished** until it is two things: a
numbered invariant in this file, and a gate in a script if it can be checked
structurally. Until then it is a document, and in this repo that is a
particularly thin defence, because documents are all this repo has.

## Escalate, do not push through

Stop and tell the user, then wait, on essentially everything substantive here:

- Any change to `SPEC.md` that a reader could act on differently than before.
- Any change to a file in `schemas/`.
- Any new version of a schema, or any retirement of an old one.
- Cutting a tag.

Routine work without escalation is narrow: fixing a broken link, a spelling
error in non-normative prose, or adding an example that validates as-is.

## Conventions

- **No long dashes** anywhere: not in the spec, schemas, docs, commit messages,
  or PR bodies. Use a comma, a colon, parentheses, or a short hyphen.
- Nothing paid or metered gets enabled without telling the user first.
- Do not delete or revoke keys, tokens, or certificates on your own initiative.

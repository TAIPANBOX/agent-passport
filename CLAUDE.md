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
2. `schemas/`. Six files: the passport schema at v0.1 and v1.0, and the event
   schema at v0.1, v0.2, v0.3 and v1.0. These are the machine form of
   `SPEC.md`. SPEC 10 says which of them are frozen and what a change costs.
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
pip install "jsonschema==4.26.0"
python .github/scripts/validate_examples.py
./scripts/schema-matches-spec.sh
./scripts/version-compatibility.sh
./scripts/artifacts-match-registry.sh
./scripts/providers-match-registry.sh
./scripts/runtimes-match-registry.sh
./scripts/attestation-methods-agree.sh
./scripts/features-are-bound.sh
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

   **Known limit, do not mistake this gate for more than it is.** The v0.1
   passport schema leaves `additionalProperties` at its default of true, so an
   unknown key passes silently there. Writing `agent_id` where the field is
   `id` validates clean under v0.1, and the passport simply has no identifier
   as far as any consumer is concerned. v1.0 closes that (invariant 12); for a
   v0.1 document the gate catches malformed values, not misspelled field names.
4. **Every schema version stays live.** Event v0.1, v0.2, v0.3 and v1.0, and
   Passport v0.1 and v1.0, are all valid input. Retiring one is a breaking
   change for every consumer that has not migrated, and needs the user. From
   1.0 a consumer MUST accept event v0.1, v0.2 and v1.0 and Passport v0.1 and
   v1.0 (SPEC 6.4.1, 7). *(partly gated: the validator covers whichever
   versions the examples exercise, and every version has an example today, not
   the promise to keep them)*

   **Accepting v0.3 is the one asymmetry, and it is deliberate** (SPEC 6.4). A
   consumer MUST accept v0.1 and v0.2; it MAY refuse v0.3, because v0.3 is the
   only version where `agent_id` can hold a claimed subject, and a reader that
   has not decided what a claim means to it is better off refusing than
   guessing. Do not "fix" a consumer that refuses v0.3 by making it accept
   without also deciding what it does with a claim.
5. **An optional field never quietly becomes required**, and more generally
   each version is a WIDENING of the one before it. Optionality is a compatibility promise under 6.4:
   a stream written by an older implementation must keep validating. Tightening
   a constraint is a version bump. **Across a major, exactly one narrowing is
   allowed and SPEC 6.4.1 names it**: the Passport's top level closes. The gate
   knows that one by name, refuses it inside a major, and refuses any other
   narrowing across one; both chains, event and Passport, are walked.
   *(gate: `scripts/version-compatibility.sh`; four cases in
   `gates-have-teeth.sh` for the 1.0 shape: the top level closed inside a major,
   another bound tightened across it, and the two non-faults)*
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

9. **Nothing in this repo names a model provider in a spelling the 4.7 registry
   does not carry.** 4.5 promises a comparison between what an agent declares
   and what two independent observations see, and that comparison is a
   comparison of strings. Until 4.7 nothing said which strings, so the same
   provider was `google` in a source scan, `Google Gemini` in an egress sensor
   and `google` here, and set arithmetic over the three reported drift that was
   orthography.

   **The registry is prose and not a schema enum, and that is forced rather
   than chosen.** `provider` is `type: string, minLength: 1`, and invariant 5
   says each version widens the one before it: an enum would narrow the field
   and refuse every passport naming a provider nobody here thought of. So the
   field stays open, an unregistered value stays legal, and a consumer MUST NOT
   reject one. What the registry fixes is the spelling, and only the spelling.
   It does not claim any plane can detect the provider a row names, which is
   invariant 7's lesson read in the other direction.

   The rule a consumer carries is one line and it is load-bearing: lowercase
   both sides before comparing, and do nothing else. Passports written before
   4.7 carry whatever their author typed. Anything cleverer, stripping
   punctuation or folding an unregistered value onto a registered one, turns a
   spelling into an assertion about which model an agent uses.
   *(gate: `scripts/providers-match-registry.sh`, which reads 4.7 as the source
   of truth and measures every `models[].provider` in `examples/*.json`, 4.5's
   own inline example, and the schema's description of the field, which listed
   six providers by hand until this registry existed. Its limits are declared
   in the file: it says nothing about a passport outside this repo, cannot tell
   a correctly spelled wrong provider from a right one, and does not read free
   prose. Eight cases in `scripts/gates-have-teeth.sh`: three faults, two
   non-faults it must not catch, and three subjects taken away.)*

10. **Nothing in this repo names an agent framework in a spelling the 4.8
    registry does not carry.** This is invariant 9 one field over, and the
    field arrived in a worse state than `provider` did: `runtime` was in the
    schema and in the section 4 example from v0.1 and SPEC.md defined it
    nowhere, so it had a shape and no meaning. 4.8 gives it one and fixes its
    spelling at the same time.

    **A registry and not a schema enum, and here that is doubly forced.**
    Invariant 5's widening rule forbids narrowing an open field, exactly as it
    does for `provider`. On top of that `runtime` has BEEN open since v0.1, so
    an enum would retroactively invalidate passports that were valid when they
    were written, and 6.4 declines to re-version the passport schema at all
    because Idryx hard-codes `requiredSchema =
    "taipanbox.dev/agent-passport/v0.1"`. `attestation.method` is a closed enum
    and is not a counter-example: a consumer ACTS on an attestation method and
    cannot judge one it does not know, while an unregistered `runtime` still
    carries its whole meaning, which is the name of a framework.

    The rule a consumer carries is invariant 9's rule verbatim: lowercase both
    sides before comparing and do nothing else. An unregistered value is legal
    and MUST NOT be rejected.
    *(gate: `scripts/runtimes-match-registry.sh`, which reads 4.8 as the source
    of truth and measures every top-level `runtime` in `examples/*.json`,
    section 4's own passport example, the schema's description of the field and
    README's passport field table. The last two both said "e.g. langgraph" when
    the gate was written, which is the second-copy fault it exists for, live on
    main. Its limits are declared in the file: it says nothing about a passport
    outside this repo, cannot tell `langchain` written where `langgraph` was
    meant from a right answer, reads no free prose, and deliberately does not
    read the SVGs, because README renders a PNG this repo holds no generator
    for and a gate forcing an SVG edit would open a divergence it cannot close.
    Ten cases in `scripts/gates-have-teeth.sh`: four faults, two non-faults it
    must not catch, and four subjects taken away.)*

    **Why a second script rather than two more cases in invariant 9's.** Both
    gates exit on the first "measured nothing" condition, which is the point of
    them; folded together, a missing 4.8 heading would abort before a single
    provider was compared and the run would name the wrong subject as gone. The
    subjects also differ in shape, `provider` being nested in an array under a
    `### 4.5` section and `runtime` a top-level scalar whose example lives
    under `## 4`. The cost is a third copy of the same registry-table parser,
    and it is written down in the script rather than left to be discovered.

8. **A check must be able to tell "did not fail" from "did not run", and every
   gate here has been made to fail on purpose to prove it can.** Every
   script gate already refuses when its subject is absent, each in its own
   words: no schemas found, jsonschema unavailable, a registry heading gone, a
   registry table header gone, a registry that parsed to too few rows, the
   governed field gone from the schema, the example that was to be measured
   carrying nothing. That list deliberately no longer counts itself, for the
   reason SPEC 6.2 gives about its own detector figure: a total in prose ages
   separately from the thing it counts, and this one was still saying "three
   script gates, five distinct ways" after a fourth gate had arrived. And
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
   *(gate: `scripts/gates-have-teeth.sh`, 39 cases: eighteen real faults each
   gate must catch, eight non-faults they must not, and thirteen subjects taken
   away entirely. The non-faults are the ones worth keeping: prose that names
   something no schema declares is deliberately allowed by invariant 2's
   half-surface, and a raised ceiling is the widening 6.4 promises.)*

   **What it does not cover.** It cannot test itself. It proves each gate
   catches the faults named in it, not every fault of that kind. It found no
   hole in any of the five checks.

   Writing it did find one in ITSELF, and it is the failure mode this whole
   harness exists for. A case asserted the validator fails saying `ts`, and it
   passed on a machine with no jsonschema, because the validator died on its
   import line and the traceback contained the word `scripts`. A three-letter
   needle matched a path. The needles are now specific strings, and the harness
   refuses to start without jsonschema at all.

## Decisions that have no gate yet

This list is debt, and it is here to stay visible rather than to be tidy.

**Held by this file alone: invariants 1 and 6.** Invariant 9 is
`scripts/providers-match-registry.sh` and invariant 10 is
`scripts/runtimes-match-registry.sh`.

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

**The `additionalProperties` hole is closed at v1.0 and stays open at v0.1, by
decision (SPEC 8.1, 2026-09-12).** A v1.0 Passport with a key the schema never
named does not validate (invariant 12). v0.1 keeps its default, because every
document written against it was valid when written and 6.4.1 promises they
still are. The forward-compatibility objection this paragraph used to carry
does not survive the `const`: a v1.0 validator already refuses a v1.1 document
by its version string, so closing the top level costs nothing the version did
not already cost.

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

12. **A Passport stamped v1.0 with a key the schema never named does not
    validate.** SPEC 6.4.1's one narrowing, and the reason it exists: `agent_id`
    written where the field is `id` used to validate as a passport with no
    identifier. v0.1 keeps its hole by decision, so the same key on a v0.1
    document is NOT a fault. *(gate: `.github/scripts/validate_examples.py`,
    which validates every `examples/passport*.json` against the schema its own
    `schema` field names; two cases in `gates-have-teeth.sh`, the key planted
    on the v1.0 example must fail and on the v0.1 example must pass)*

13. **Every scenario in `features/` names a gate that exists, and every
    scenario names one at all.** This repository has no test suite to bind a
    scenario to, so the binding is to the gate that holds the promise; the
    scenario is what a reader reads instead of the script. *(gate:
    `scripts/features-are-bound.sh`; three cases in `gates-have-teeth.sh`: a
    scenario with no binding, a binding to a script that does not exist, and
    the directory taken away)*

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

11. **Every list of attestation methods in this repo lists the same ones.**
    `attestation.method` looks like invariants 9 and 10 and is not one of them,
    and the difference decides where its truth lives. Those two govern OPEN
    labels that SPEC registers a spelling for, so SPEC's table is the source
    and the schema points at it. This is a CLOSED enum: the schema does not
    point at a list, the schema IS the list, and 4.8 argues why the two are
    different promises. A consumer ACTS on an attestation method, so a value it
    cannot place leaves it unable to judge the posture 4.3 exists to make
    visible, which is why extending the set is a schema change every time.

    That inversion is also why this is not a fourth copy of the registry-table
    parser the other three share and name as debt. The enum is read as JSON and
    everything else is compared to it.

    **What made it necessary.** `dpop-key` was added to 4.3 and to the schema
    on 2026-08-26 and not to README, whose row went on offering five methods as
    though that were the set. Nothing was wrong in either file alone. The
    schema was right, the spec was right, and the table most readers reach
    first was a quietly short answer to "what may I write here". Five gates
    already ran on every push and none of them read an enum, so it would have
    stayed that way until somebody wrote a passport from README and could not
    work out why it validated fine.
    *(gate: `scripts/attestation-methods-agree.sh`, which reads the schema enum
    as the source and measures 4.3's `One of:` line, README's field table and
    every example against it. Four cases in `gates-have-teeth.sh` for the
    faults, two for what it must not catch, and four for its subjects taken
    away.)*

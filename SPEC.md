# Agent Passport: shared identity & event schema

**Version:** 0.1 · 2026-07-09
**Status:** accepted (design decisions resolved 2026-07-09), adoption in progress across all seven services; see README.md's adoption-status table for current per-repo detail
**Scope:** TokenFuse · Engram · Idryx · Qryx · Wardryx · Verdryx · Mockryx (the TAIPANBOX agent-governance stack)

---

## 1. Why

The four products each govern one plane of an AI agent's existence — money
(TokenFuse), memory (Engram), access (Idryx), cryptography (Qryx) — but they
currently share no technical fabric: no common agent identifier, no common
event format. Each product is complete alone; the *stack* exists only as a
narrative.

This spec is the thinnest possible stitch: **one identifier, one delegation
chain, one event envelope.** No shared runtime, no shared database, no new
service. Adopting it is a naming agreement plus (at most) a few optional
fields per product.

The good news, discovered by reading the code: **the hooks already exist.**

| Product | Existing hook (today, shipped) |
|---|---|
| TokenFuse | `x-fuse-agent-id`, `x-fuse-run-id`, `x-fuse-parent-run-id` headers; `agent_id` dimension in traces; Cloud `/v1/agents` |
| Engram | per-`agent_id` scoping of decay and spreading-activation |
| Idryx | `Identity{Type: IdentityAgent}`, `OnBehalfOf string` (one hop), `IdentityMCPServer` |
| Qryx | signed evidence trails (ed25519/ECDSA); `model.Finding` |

What is missing is only the agreement that these are **the same identifier**,
and a common shape for the events each product emits about it.

## 2. Non-goals

- **Not an authentication protocol.** The Passport names an agent; it does
  not prove possession. Attestation (§4.3) records *how* the binding was
  established, by reference to existing mechanisms (OIDC, SPIFFE SVID,
  Secure Enclave signature) — it does not define a new one.
- **Not a freshness claim.** The delegation chain (§5) records who acted on
  behalf of whom, not when. It carries no expiry, no TTL and no issued-at
  time, and nothing here lets a consumer tell a chain asserted a second ago
  from one lifted off a request captured a year earlier and replayed: the
  event's `ts` (§6.1) times the event, not the delegation it reports. A
  consumer MUST NOT read a chain as evidence that the delegation is still in
  force; a control that needs that must get it from whatever mechanism
  established the delegation. This is a decision rather than an omission. A
  validity window would make every consumer a clock-dependent verifier, and
  this spec issues nothing token-shaped anywhere (§4: the Passport is
  metadata, not a token).
- **Not orchestration.** Nothing here schedules, routes, or runs agents.
- **Not a wire protocol.** Events are plain NDJSON objects; how they move
  (file, webhook, OTLP log body, Parquet column) is each product's business.

## 3. Canonical agent identifier

### 3.1 Format

An agent ID is a URI:

```
agent://<trust-domain>/<path>
```

- `<trust-domain>`: a DNS name the operating organization controls
  (e.g. `acme-bank.example`). Lowercase.
- `<path>`: one or more segments naming the agent within the org
  (e.g. `support/tier1-bot`, `eng/ci-fixer/instance-7`).
- Allowed characters per segment: `[a-z0-9._-]`. Max total length: 255 bytes.

**SPIFFE alignment:** the mapping to a SPIFFE ID is mechanical —
`agent://acme-bank.example/support/tier1-bot` ↔
`spiffe://acme-bank.example/agent/support/tier1-bot`. Organizations already
running SPIRE SHOULD derive the Passport ID from the SVID rather than mint a
parallel namespace. We use our own scheme (`agent://`) so that adopting the
Passport does not *require* SPIFFE infrastructure.

### 3.2 Where it goes, per product

| Product | Binding |
|---|---|
| TokenFuse | the value of `x-fuse-agent-id` (unchanged header, stricter value); `agent_id` column in Parquet traces; budget-hierarchy key |
| Engram | the `agent_id` memory scope; multi-agent ACLs (future) reference these IDs |
| Idryx | `Identity.ID` for `IdentityAgent` nodes ingested from Passport-aware sources |
| Qryx | the `subject` of evidence entries covering agent infrastructure |

Products MUST treat the ID as an opaque string key (no parsing required for
correctness); products MAY parse it for display grouping.

Run-scoped correlation stays exactly as TokenFuse does it today:
`run_id` names one task execution, `parent_run_id` links sub-runs. This spec
adds nothing there — it only standardizes *who* is running.

### 3.3 `AGENT_PASSPORT_ID` (reserved environment-variable convention)

§3.2 says where the identifier goes inside each product. It does not say where
it goes on a **host**, and that gap has a consequence: a host-level observer
sees processes, and a process carries no agent identity anywhere an observer
can read. §4.5 already assigns such an observer a job, comparing declared model
use against "what it is seen reaching on the network (an egress sensor)", while
leaving it no way to say which agent it saw. Today an egress sensor can report
a process name, which the process picks itself and every instance of a binary
shares.

This subsection reserves one environment variable so that a process can carry
its own Passport ID where the operating system will show it.

```
AGENT_PASSPORT_ID=agent://acme-bank.example/support/tier1-bot
```

- The value is a canonical agent ID exactly as §3.1 defines it. A value that
  does not parse MUST be treated as absent rather than repaired or truncated.
- Whoever **launches** the agent sets it: a container spec, a systemd unit, a
  process supervisor, a shell wrapper. The spec does not say which, because
  that is the operator's business and differs per runtime.
- Optional. An absent variable means "not declared", never "not an agent", the
  same reading `filesystem` (§4.4) and `models` (§4.5) already take. A consumer
  that does not model this MUST ignore it.
- Reserved so nobody redefines it locally, exactly as `labels.version` (§4.6)
  is reserved. Like that one, this is a convention rather than a schema change:
  no field is added to any document, and a Passport is unaffected either way.

**This is a self-declaration and MUST NOT be read as attestation.** A process
sets its own environment, so it can set this variable to another agent's ID, or
to an ID that was never issued. That is the same standing this spec already
gives the Passport itself (§2: it names an agent, it does not prove
possession), and proof lives in `attestation.method` (§4.3), which this does not
touch and does not weaken. A consumer MUST record an identity learned this way
as claimed, and MUST NOT let it satisfy a control that requires an attested
one. An observer that reports it SHOULD make the distinction visible in what it
reports, so that an operator reading a finding can tell an identity a process
asserted from one an infrastructure established.

**What it is worth anyway**, since the paragraph above could be read as talking
it out of existence: on a host that is not already compromised, this turns "a
process calling itself python3 reached an LLM API" into "this agent reached an
LLM API", which is the difference between a finding an operator can act on and
one they can only investigate. Against an adversary on the host it proves
nothing, and neither does anything else at this layer.

**Reading it is racy, and a reader must expect to lose.** The environment of a
process is readable while that process lives (`/proc/<pid>/environ` on Linux,
subject to that platform's permissions). A short-lived agent, which is exactly
the one worth attributing, may be gone before an observer looks. A consumer
MUST treat a failed read as "not declared" and MUST NOT retry in a way that
turns an observation into a scan of processes it has no other reason to touch.

**On the wire, a claimed identity is written `claimed:` before the ID**, and
that spelling is normative:

```
claimed:agent://acme-bank.example/support/tier1-bot
```

An observer that reports such an identity in the §6 envelope MUST write it in
this form in `agent_id`, MUST stamp the event `taipanbox.dev/agent-event/v0.3`
(§6.4), and MUST NOT write the bare ID. A consumer MUST NOT strip the prefix to
obtain a subject it then treats as established, and MUST NOT let a value in
this form satisfy a control requiring an attested identity.

**Why the marker is inside the identifier and not beside it.** The paragraph
above says an observer SHOULD make the distinction visible in what it reports,
and a sibling field cannot deliver that. §6.1 obliges consumers to ignore
fields they do not know, so a consumer that has not been updated reads
`agent_id`, finds a bare ID, and presents a self-declaration as an established
one. That is this subsection's own MUST NOT, reached by a consumer doing
exactly what the spec told it to do.

Inside the identifier the burden is the other way round: a consumer cannot
present the claim as established without deliberately removing a prefix nothing
told it to remove. It also costs nothing to read back, since the ID is one
`claimed:` away, and it survives truncation in a subject line or a table
because the marker leads.

**What it is NOT.** It is not a second identity authority: `claimed://` would
read as one, and this is a qualifier on an `agent://` ID rather than a new
scheme. The inner ID keeps §3.1's grammar exactly, so a value that would not be
a valid agent ID is not made valid by being claimed.

## 4. The Passport document

A Passport is a small JSON document describing one agent. It lives wherever
the org keeps config (a git repo, a config service); products consume it
read-only. Nothing at runtime depends on fetching it — it is metadata, not a
token.

```json
{
  "schema": "taipanbox.dev/agent-passport/v0.1",
  "id": "agent://acme-bank.example/support/tier1-bot",
  "display_name": "Tier-1 support bot",
  "owner": "team-support@acme-bank.example",
  "runtime": "langgraph",
  "parent": "agent://acme-bank.example/support/orchestrator",
  "attestation": {
    "method": "spiffe-svid",
    "detail": "spiffe://acme-bank.example/agent/support/tier1-bot"
  },
  "labels": { "env": "prod", "cost_center": "cs-eu", "version": "1.4.2" },
  "created_at": "2026-07-09T00:00:00Z"
}
```

### 4.1 Required fields

`schema`, `id`, `owner`. Everything else is optional.

`owner` is a human or team principal (email or group). This is the field
Idryx maps to `Identity.Owner` and the answer to the auditor's first
question: *whose agent is this?*

### 4.2 `parent`

The agent that provisions/spawns this one, if any — a *static* relationship
(org chart), distinct from the *dynamic* per-request delegation chain (§5).

### 4.3 `attestation.method`

One of: `none` · `oidc` · `spiffe-svid` · `enclave-key` · `mtls-cert`.
Records how the org binds the name to a workload. `none` is legal and
honest (most orgs today); the field exists so the posture is *visible* —
Idryx SHOULD surface `attestation: none` on privileged agents as a finding.

### 4.4 `filesystem`

An optional array declaring the folders an agent is meant to access. Each
entry is `{ "path": <folder>, "mode": "read" | "write" }`:

```json
"filesystem": [
  { "path": "/data/reports", "mode": "read" },
  { "path": "/data/out", "mode": "write" }
]
```

- `path` is a non-empty folder path; `mode` is exactly `read` or `write`.
- A given `path` SHOULD appear at most once: two entries for one folder are
  ambiguous (which mode wins?), and a producer SHOULD refuse to emit a
  duplicate rather than silently pick one.
- This is a *declaration of intent*, carried on the passport, not an
  enforced control. The passport format does not grant, mount, or restrict
  filesystem access; it records what the agent's owner says the agent
  should reach, so an auditor can compare declared scope against observed
  behavior. Whether anything enforces it is a product decision outside this
  spec: as of today no product in the stack enforces filesystem paths (for
  example Wardryx's policy surface is tools, domains, spend ceilings, step
  count, and attestation, with no path rule), so a consumer MUST NOT read
  this field as a live access-control boundary.
- Additive and backward-compatible: an absent `filesystem` means "not
  declared," never "no access." Consumers MUST ignore the field if they do
  not model it.

### 4.5 `models`

An optional array declaring the LLM providers, models, and endpoints an agent
is meant to use. Each entry is
`{ "provider": <label>, "model"?: <name>, "endpoint"?: <host> }`:

```json
"models": [
  { "provider": "anthropic", "model": "claude-sonnet-4-5", "endpoint": "api.anthropic.com" },
  { "provider": "openai" }
]
```

- `provider` is a required, non-empty label. It SHOULD be one of the ids
  registered in 4.7 when one names the provider; it stays an open string, and
  4.7 says what a consumer does with a value that is not registered. `model`
  and `endpoint` are optional: `model` pins a specific model, `endpoint` names
  the API host the agent is declared to reach.
- Like `filesystem`, this is a *declaration of intent* for audit and
  inventory, not an enforced control. The passport format does not grant or
  restrict model access; it records what the agent's owner says the agent is
  meant to call, so an auditor can compare it against two independent
  observations: what the agent's code actually imports and calls (a source
  scan), and what it is seen reaching on the network (an egress sensor). A
  disagreement between declared, coded, and observed model use is the finding
  such an inventory exists to surface. This directly supports code-inventory
  obligations such as the EU AI Act's.
- Additive and backward-compatible: an absent `models` means "not declared,"
  never "no model use." Consumers MUST ignore the field if they do not model
  it.

### 4.6 `labels.version` (reserved label convention)

Fleet inventory and drift views need one agreed place to read "which
version of this agent is running" across products; an unreserved, ad-hoc
label cannot be relied on cross-product. This subsection reserves one key
inside the existing free-form `labels` map for that purpose.

```json
"labels": { "env": "prod", "cost_center": "cs-eu", "version": "1.4.2" }
```

- `labels.version` is the agent's own release version, named by its
  operator: the version of the agent's code or configuration, not the
  Passport schema version (`schema`) and not the model version recorded
  under `models` (§4.5).
- Optional: producers SHOULD set it when the agent has a meaningful
  release identity, and SHOULD use the agent's own semver when one
  exists; the value itself stays free-form.
- Consumers (inventory, drift/360 cards, dashboards) MUST treat a value
  that does not parse as semver as an opaque string - display it, group
  by it, compare it for equality, and nothing more.
- This is a *label convention*, not a schema change: `labels` remains
  exactly the free-form string map it always was, and a passport without
  `labels.version` is exactly as valid as one with it.

### 4.7 Registered provider ids

4.5 says a declaration exists so an auditor can compare it against two
independent observations, a source scan and an egress sensor. That comparison
is a comparison of strings, and until this subsection nothing said which
strings. `provider` was "a required, non-empty label" with six examples beside
it and no agreed spelling, so the three sides of the comparison spelled the
same provider three ways and the disagreements a reader saw were mostly
orthography.

Measured across the estate on 2026-08-25, one provider, three planes:
a source scan naming it `google`, an egress sensor naming it `Google Gemini`,
and this document's own example naming it `google`. Set arithmetic over that
produces a finding about Google being undeclared, on a passport that declares
it.

| id | names |
|---|---|
| `anthropic` | Anthropic's API |
| `openai` | OpenAI's API |
| `google` | Google's generative language API, including Gemini |
| `bedrock` | Amazon Bedrock, whichever model it fronts |
| `mistral` | Mistral AI's API |
| `cohere` | Cohere's API |
| `groq` | Groq's API |
| `together` | Together AI's API |
| `perplexity` | Perplexity's API |
| `replicate` | Replicate's API |
| `openrouter` | OpenRouter, which routes onward to a provider it chooses |
| `huggingface` | Hugging Face's hosted inference |
| `ollama` | Ollama, a model server the operator runs |
| `azure-openai` | Azure OpenAI and Azure AI Foundry |
| `vertex` | Google Cloud Vertex AI |

**What this registry fixes is the spelling, and only the spelling.** It does
not say any plane can currently detect the provider it names, and a row here is
not a claim that one does. That distinction is the lesson 6.2 carries in the
other direction: a registry that lists what a product MEANS to emit beside what
it does emit is a registry nobody can act on. Here the subject is different, a
label a human writes into a declaration, so the useful thing to agree is how it
is written. What each plane recognises is a property of that plane's release
and belongs in that plane's own documentation, where it can be re-measured.

The rules:

- A producer SHOULD use a registered id when one names the provider. An
  unregistered provider is legal and stays legal: `provider` remains the open
  string 4.5 and the schema declare, and a consumer MUST NOT reject a value
  because it is not on this list.
- Ids are lowercase, and use `[a-z0-9-]`. An unregistered value SHOULD be
  written by the same rule, so that a provider registered later needs no
  rewriting of the passports that already named it.
- **A consumer comparing providers MUST lowercase both sides before comparing**,
  and SHOULD do nothing else to them. Passports written before this subsection
  carry whatever their author typed, `Anthropic` as readily as `anthropic`, and
  a comparison that misses those reports drift where there is none. Anything
  further, stripping punctuation, matching prefixes, folding an unregistered
  value onto a registered one, is a guess that turns a spelling into an
  assertion about which model an agent uses.
- Ids are appended, never renamed. A rename would silently redefine what every
  passport already carrying it declares, and unlike a schema field there is no
  version stamp on this list to tell a reader which spelling they are holding.
  A provider that renames itself gets a new id, and the old one stays as what it
  always meant.
- One id names one provider's API surface, not one model and not one endpoint.
  Those are `model` and `endpoint`, which stay free-form: pinning a model is the
  operator's business and the set moves weekly.

**`azure-openai` is not `openai`, and `vertex` is not `google`, for the reason
`bedrock` is its own row rather than a model name.** An id names the API
surface an agent's bytes leave for, and that is what an inventory is asking.
The same model, reached through Azure, goes to Microsoft under a Microsoft
contract, in a region and under a data-residency arrangement the operator
chose; reached through Vertex it goes to Google Cloud rather than to the
generative language API. Folding either onto the provider whose model it
happens to be would put one name on two different answers to "where does our
data go", which is the question the field exists for.

The corollary is a producer's, and it is not always answerable from a
dependency list: an agent using the `openai` package against an Azure endpoint
declares `azure-openai`, because the package is not the destination.

`openrouter` is the row worth reading twice. It is a registered provider
because that is where the operator's bytes go, which is the question an
inventory asks, and it is also the one row where a registered id does not tell
a reader which model ran the prompt. A consumer MUST NOT infer an onward
provider from it.

## 5. Delegation chain

Idryx already models one hop (`OnBehalfOf`). Agents spawn sub-agents, so one
hop is not enough. The chain is an **ordered list, root first**:

```json
"on_behalf_of": [
  "user://acme-bank.example/j.doe",
  "agent://acme-bank.example/support/orchestrator"
]
```

- Entries are `agent://` or `user://` URIs (`user://<trust-domain>/<subject>`).
- The **last** entry is the immediate principal; the **first** is the root
  (usually a human). An empty/absent chain means the agent acts autonomously.
- Wire binding, TokenFuse: a new optional header
  `x-fuse-on-behalf-of: <uri>,<uri>,...` (comma-separated, root first),
  recorded as a trace column. Idryx ingests it from TokenFuse traces (§6)
  and extends its graph edge accordingly (`OnBehalfOf string` →
  `OnBehalfOf []string`, or an edge per hop).
- Products MUST NOT truncate the chain when forwarding; a sub-agent appends
  exactly one entry (its spawner) to the chain it received.

This is the piece nobody else has: *"who acted on behalf of whom, N levels
deep, reconstructable at audit time."*

### 5.1 Cycle safety (normative)

The `on_behalf_of` chain MUST be acyclic. A service appends exactly one
entry (its own principal) to the chain it forwards, and MUST refuse to
forward a chain that already contains its own principal. Maximum chain
depth is 32 entries.

## 6. Event envelope

One JSON object per event, NDJSON when batched. Everything any product says
about an agent fits this envelope:

```json
{
  "schema": "taipanbox.dev/agent-event/v0.1",
  "ts": "2026-07-09T03:12:44.100Z",
  "source": "tokenfuse",
  "type": "budget_exhausted",
  "severity": "critical",
  "agent_id": "agent://acme-bank.example/support/tier1-bot",
  "run_id": "run-8842",
  "on_behalf_of": ["user://acme-bank.example/j.doe"],
  "data": { "budget_usd": 2.00, "spent_usd": 2.00, "action": "blocked_402" },
  "prev_hash": "sha256:..."
}
```

### 6.1 Field rules

- `schema`, `ts` (RFC 3339, UTC), `source`, `type`, `agent_id` — required.

  `agent_id` being required is a boundary, not a formality, and it is worth
  knowing before it surprises somebody. An observation about a whole
  organisation, a tenant or a fleet has no subject here and therefore cannot
  travel in this stream at all. A producer that has one MUST skip the event
  rather than fabricate a subject to make it fit: a fallback id, a "various"
  agent, or the org's own id in this field each makes every downstream count
  wrong and puts a name on an alert that did not do the thing.

  Such facts belong in the producing product's own API and console until this
  envelope grows a subject kind. TokenFuse's `spend_spike` is the live example:
  raised, displayed, and deliberately never exported.

  **This sentence used to end "which would be a change every consumer has to
  make together", and v0.3 is the counter-example.** A subject kind can be
  added without lockstep when two things are true of it: the distinction lives
  INSIDE `agent_id`, so a consumer cannot read the subject without meeting it,
  and the version stamp changes, so the consumers that do gate on a version
  refuse the event instead of guessing. Under those two conditions an
  unupdated consumer is safe by refusal or safe by seeing the truth, and each
  one adopts on its own schedule. A subject kind carried in a SIBLING field
  would still need the lockstep, for the reason §3.3 gives.

  **`agent_id` may carry a claimed subject, and only under v0.3.** The form is
  `claimed:agent://<trust-domain>/<path>` (§3.3), it is written only by an
  observer reporting a self-declaration, and it is the one value in this field
  that is not an established identity. A producer emitting one MUST stamp
  `taipanbox.dev/agent-event/v0.3`; under v0.1 and v0.2 this field is an
  established subject and nothing else, which is what makes the version stamp
  load-bearing rather than decorative.
- `source`: as of schema v0.2, an open string (`type: string, minLength: 1`),
  not a closed enum. Adding a source is additive and does not require a
  schema bump. Consumers MUST ignore events from a `source` they do not
  recognize rather than reject them.
- `severity`: `info` · `low` · `medium` · `high` · `critical`.
- `data`: free-form object, owned by the `source` product. Consumers MUST
  ignore unknown `data` keys.
- `prev_hash`: optional; present when the emitting product maintains a
  tamper-evident chain (TokenFuse audit trail already does sha256 chaining —
  this exposes it in the shared format). Canonicalization is defined
  precisely in §6.5.
- Unknown top-level fields MUST be ignored (forward compatibility).

Registered sources today:

| `source` | Product |
|---|---|
| `tokenfuse` | spend governance |
| `engram` | memory governance |
| `idryx` | identity and access governance |
| `qryx` | cryptographic evidence |
| `wardryx` | policy and approval gating (wave 2) |
| `verdryx` | evaluation and quality drift (wave 2) |
| `mockryx` | simulation and blast-radius testing (wave 2) |
| `console` | the operator console's own privileged actions (Genaryx) |
| `heraldyx` | operator notification (mail out) |
| `scopyx` | web-egress enforcement (agents fetch through it) |

wardryx, verdryx, and mockryx are wave-2 services; like the original four,
this contract governs an operator's own agents, for the operator's own
self-protection, not third-party or adversarial traffic.

### 6.2 Initial event-type registry

| `source` | `type` values |
|---|---|
| `tokenfuse` | `budget_exhausted` · `sustained_loop` · `spend_spike` · `fanout_explosion` · `breaker_tripped` (medium) · `dlp_block` · `taint_block` · `mcp_drift` · `identity_mismatch` (high) · `tool_call` (low) · `budget_threshold` (medium) · `run_killed` (high) · `unit_cap_exceeded` (high) · `policy_deny` (high) · `dependency_failed` (high) · `taint_shadow` (medium) · `taint_raised` (low) · `taint_cleared` (high) |
| `engram` | `memory_written` · `reflection_run` · `contradiction_found` · `memory_forgotten` |
| `idryx` | `identity_finding` (severity per finding) |
| `qryx` | `crypto_finding` · `crypto_drift` · `policy_violation` · `evidence_signed` |
| `wardryx` | `policy_allow` (info) · `policy_deny` (high) · `approval_requested` (medium) · `approval_granted` (info) · `approval_denied` (high) · `approval_timeout` (high) · `approval_unanswered` (high) · `policy_updated` (high) |
| `verdryx` | `eval_run` (info) · `quality_score` (info) · `quality_drift` (high) · `slo_burn` (high) |
| `mockryx` | `sim_run` (info) · `sim_finding` (high) · `blast_radius_measured` (medium) |
| `console` | `console_command` |
| `heraldyx` | `alert_sent` (info) |
| `scopyx` | `web_fetch` (low) · `web_blocked` (high) |


A row here is a CLAIM that the source writes those types into this envelope
today, not a list of what it detects or intends to. Checked against every
producer's code on 2026-08-03, which is when this table stopped being partly
aspirational:

- **`idryx` emitted nothing into this envelope until 2026-08-10**, and the
  seven names reserved for it were wrong in both directions. It shipped 25
  detectors at the moment that was measured; two reserved names
  (`excessive_privilege`, `blast_radius_change`) had no producer anywhere,
  twenty detectors had no reserved name, and `mcp_drift` was reserved for idryx
  while being a live `tokenfuse` type, which would have given a consumer two
  producers for one name.

  **That count is a dated measurement and not a property of idryx**, which is
  the whole reason the reserved list was wrong: a number in this table ages
  separately from the thing it counts. It was 26 within hours of being written
  here. What knows is idryx's own `scripts/detectors-complete.sh`, which reads
  the `Name()` methods; the registry below does not depend on the figure,
  because one type is one row whatever the set does.

  It now emits ONE type, `identity_finding`, with the detector name in
  `data.detector`, under v0.2 when the subject is established and under v0.3
  when it is claimed (§3.3, §6.4). The type does not change with the basis:
  the basis is in the subject, so a consumer routes on one name and reads which
  kind of subject it got from the id in front of it.
  Registering 25 types would have put 25 rows here, 25
  severities beside them, 25 entries in every consumer's render catalogue, and
  would have made each new detector a nine-repository spec change, which is the
  tax that stops detectors being written. One type also settles the collision by
  construction: `mcp_drift` stays tokenfuse's wire string and idryx's detector
  of that name travels in `data`.
- **`verdryx` and `mockryx` were missing** although both have emitted for some
  time. A source absent from this table is worse than a wrong row: nothing
  tells a consumer those events exist at all.

The lesson the table now carries: a registry that lists what a product MEANS to
emit, beside what it does emit, is a registry nobody can act on. If a name is
reserved, say so on the row.

The `console` row is Genaryx, the operator's own console, and it is here
because the console acts on the stack rather than only watching it. Read from
`crates/core/src/command.rs` and its callers rather than from its docs: one
`console_command` is appended per privileged mutation, to the same NDJSON file
the products write, joining the §6.5 hash chain instead of sitting unlinked
beside it. Fixed shape, schema v0.2: `agent_id`
`agent://<trust-domain>/console/<host>`, `on_behalf_of` carrying the
operator's principal when it matches the `(agent|user)://` form, and `data`
holding exactly `action`, `target`, `decision`, `sig_alg`, `sig_fpr`,
`http_status` and `verify_result`. Which action it was lives in `data.action`
(`console.kill_run`, `console.set_budget`, `console.ack_incident`,
`console.grant_approval`, `console.deny_approval`, `console.evidence_built`,
`console.copilot_proposal_approved`, `console.issue_wg_peer`,
`console.revoke_wg_peer`), never in `type`, so the envelope has one shape
whatever the operator did. It sets no `severity`, which is why its row carries
none. Until this row existed the console was emitting an undeclared extension
onto a shared bus: nothing failed conformance, because v0.2's `source` and
`type` are open strings, and no consumer had been told the event exists.

The `heraldyx` row is the mail-out: it reads the shared event log to decide
what is worth a human's attention now, and for every message it sends it
appends one `alert_sent` event to a hash-chained journal of its own. Read
from `internal/record/record.go` rather than from its docs: `source` is
`heraldyx`, `type` is `alert_sent`, severity is always `info`, and `data`
carries exactly `kind` (`alert`, `digest`, or `suppression`), `about` (the
dedup key the message was raised under), `to` (the recipients), `transport`,
and `outcome` (`accepted` or `refused`, with a truncated `error` on refusal);
it never carries a message body or any field copied from another plane's
event. That journal is deliberately not the log the rest of this table's
rows append to: heraldyx mounts the planes' event log read-only, and writing
its own record into that directory would mean mounting it writable, handing
a compromised notifier the ability to corrupt the trail it reads. So the
record lives on heraldyx's own state volume, same envelope, same library,
same verifier, and trailryx's record plane already reads it there directly
(`trailryx-node events --file`), not through this bus. `heraldyx` is
therefore the one row in this table whose events do not travel the shared
log: the registry answers who writes the envelope, not which file it lands
in, and on that question heraldyx belongs here as much as any other row.

The `scopyx` row is the web-egress enforcement point: agents fetch THROUGH it,
and every destination is decided against the policy plane before anything
leaves. Read from `internal/record/record.go` rather than from its docs:
`source` is `scopyx`, and the two types are `web_fetch` for a fetch that
happened and `web_blocked` for one that did not. Severity is fixed per type in
code rather than chosen at the emission site, which is why the row can state it:
a severity a call site can pick drifts between call sites, and every downstream
count of "how many high events" then measures who wrote the call rather than
what happened.

`data` carries `origin` and `url_sha384`, and deliberately NOT the URL. A URL
is personal data: `https://crm.example/customers/12345?email=jane@example.com`
is an address and also a name, an identifier and a contact detail, and the path
and query string are exactly where an identifier or a session token lives. They
are never assembled into the event, so the record cannot leak what it never
held. An operator who needs the full URL sets `SCOPYX_RETAIN=payload`, and the
field is then named `url_unprotected`, because that plane has no subject-keyed
payload store yet and a field called `url` would imply one. A `web_fetch` adds
`backend`, `enforcement` and `content_bytes`; a `web_blocked` adds `verdict` and
`reason`.

`enforcement` is the field a consumer should not skip. It is `per_request` when
every request the fetch made was decided, and `navigation_only` when the
navigation was decided and the page's own subresources were fetched by a service
this plane does not drive. Both are honest states and they are not the same
guarantee, so a consumer counting governed fetches without reading this field is
counting two different things as one.

Like `heraldyx`, and for the same reason one plane further out, scopyx writes
its own hash-chained journal rather than the shared log. It is the one component
in the estate that reaches the public internet on purpose, which makes it the
last one that should be able to rewrite anybody else's record.

A missing `agent_id` is SKIPPED and counted, never fabricated. Section 6.1
forbids inventing one and the reason is not pedantry: a fallback subject, a
"various" agent or an org id in that field makes every downstream count wrong
and puts a name on an alert that did not do the thing.


`approval_timeout` and `approval_unanswered` are two different facts and the
names are worth reading carefully. The first fires when an agent REDEEMS an
approval whose window has closed, which usually means a human did decide and
the agent came back late. The second fires when a hold has simply sat
undecided: nothing decayed, nobody answered. Until 2026-08-03 only the first
existed, so an agent blocked on an unwatched queue produced no event at all,
and the name that sounded like it covered that case did not.

`policy_updated` is the one wardryx type with no governed agent behind it. It
fires from the admin-only policy-as-code routes, `PUT` and `DELETE
/v1/policies/{id}` in `internal/api/api.go` (`evPolicyUpdated`), reporting an
operator changing the rules rather than an agent doing anything, so
`agent_id` carries a synthetic identity instead,
`agent://wardryx.internal/admin/policy-api`, naming the API as its own
well-formed subject rather than leaving the field empty or borrowing an
unrelated agent's id. `data` carries `action` (`put` or `delete`),
`policy_id`, `policy_version`, and `decided_by`; both emission sites set
`severity: high`.

`policy_deny` appears under two sources on purpose. The same fact, an action
refused by policy, is decided in two places: at the policy plane by wardryx,
and inside the gateway by its own evaluator or a wasm module. A consumer that
wants to know WHICH reads `source`, and one that only wants to know what
happened does not have to learn two names for it.

`dependency_failed` is the first type in this registry about the PRODUCER'S
OWN dependency failing, rather than about an agent misbehaving or an agent
being refused. Every other `tokenfuse` type above is one of those two kinds: a
budget crossed, a loop detected, a call blocked, a claimed identity that did
not match. This one says the gateway could not do its job, because something it
depends on stopped answering. Until it existed, an upstream that died produced
a 502 to the caller and nothing at all in this envelope, so the plane whose job
is to record what happened to a run recorded a gap, and an operator reading the
trail could not tell a dead dependency from an agent that went quiet.

Read from `crates/gateway/src/proxy.rs`, where the failure paths are, and
`crates/core/src/agent_event.rs`, which fixes the wire string and the severity,
rather than from its docs. `data` carries four members. `dependency` is which
of TokenFuse's own dependencies died: `provider`, the model API the gateway
proxies to, or `policy_plane`, the evaluator it asks for a decision before the
call. `stage` is how far the attempt had got, `send`, `stream`,
`response_body` or `decide`. `effect` is what the failure did to the call, and
it has its own paragraph below. `detail` is the transport error's own text,
short and capped, and it is there for a person to read rather than for a
consumer to parse: it is written by somebody else's client library and its
wording is not a contract.

**One type carrying the dependency in `data`, rather than one type per
dependency, and the precedent is the `idryx` row above.** idryx registers one
`identity_finding` and puts the detector name in `data.detector`, for the
reason recorded there: 25 types would have meant 25 rows here, 25 severities
beside them, 25 entries in every consumer's render catalogue, and a
nine-repository spec change for each new detector, which is the tax that stops
detectors being written. The same arithmetic holds here in miniature. Two
dependencies can die today and a gateway acquires more of them over time, while
a consumer wanting to route on "the producer lost something it needs" wants one
name for that, with which thing it lost in `data`, where the next one costs
nobody a spec change.

**`effect` is the member a consumer must not skip**, because two of its three
values are not outages at all. `call_failed` is the ordinary one: the call
could not be made, or could not be completed. `allowed_ungoverned` means the
policy plane could not be reached and the default failmode (open) let the call
through, so the trail carries a call that nobody governed: it happened, it was
paid for, and no policy decided it. `denied_unasked` is that same
unreachability under `failmode=closed`, a call refused without anybody having
decided it should be. A consumer that counts all three as ordinary failures is
counting a governance gap as an outage, and the two go to different people: an
outage goes to whoever owns the dependency, an ungoverned call goes to whoever
owns the policy. The `scopyx` row above says the same thing about
`enforcement`, and the mistake available here is the same one: two honest
states that are not the same guarantee, counted as one.

Severity is fixed per type in code rather than chosen at the emission site,
which is why the row can state it, the same sentence the `scopyx` row above
makes and for the same reason: a severity a call site can pick drifts between
call sites, and every downstream count of "how many high events" then measures
who wrote the call rather than what happened. It is `high` whichever `effect`
the event carries, deliberately, because an ungoverned call is not a smaller
fact than a failed one.

`taint_shadow` and `taint_raised` are the first pair in this registry where
one type exists because the OTHER one is not the whole story. `taint_block`
has been here since the beginning and says an action was refused. It was, on
its own, unreadable in two directions.

**Backwards, `taint_raised` (low).** TokenFuse's agent firewall tracks taint
monotonically across a run: once the context has touched the web, an upload or
an unknown tool, the label is carried for the life of that run. So by the time
anything is refused, the tool that carried the label in is many calls back,
and until 2026-08-26 it was recorded nowhere. A consumer reading "refused,
context was [web, file]" had the verdict and no way at all to reach its cause.
`taint_raised` is that cause: `data` carries `added` (only labels NEW to the
run, so a run reading the web on forty turns writes once), `from_tools` naming
which tools carried them, `stage`, and `carrying`, the full set afterwards so a
reader walking a run forward never re-derives the running total. `low`, the
same band as `tool_call` and for the same reason: a run reading the web is
normal, and only what it does next may not be.

**Forwards, `taint_shadow` (medium).** The firewall has three modes and its
documented on-ramp is `shadow`, where a rule that WOULD refuse does not.
Before this type, that produced a response header and no event, so the only
party told that a dangerous action had been permitted was the agent that had
just been talked into it, and a week of shadow left a consumer with nothing to
count. The band is the whole judgement and it is worth stating what it is not.
Not `low`: in shadow the action is PERMITTED, the answer carrying it reaches
the client and the client executes it, so this is a thing that HAPPENED rather
than a refusal that worked. Not `high`, which is `taint_block`'s band: a
consumer paging on a shadow week at the same weight as a real refusal pages
its operator during precisely the week they were told to watch quietly, and an
operator who mutes the sender in week one never reaches week two. `medium`
clears heraldyx's and stack-up's floors, so it is not silence either.

**They share one `data` shape with `taint_block`**, and that is deliberate
rather than lazy: `stage`, `mode`, `rule`, `labels`, `requested`, `denied`,
`tools`. A consumer counting rule hits should be able to read a shadow week and
an enforced week with one code path, which is also what makes the comparison
between them arithmetic instead of a migration. `mode` is on the event even
though the type implies it, so a consumer joining the two families into one
count does not have to know that mapping. `denied` says which capability was
refused; `tools` says which tool the model asked for by name, and that is the
member that makes a row actionable rather than merely true.

This is also the first place in this registry where a `medium` type reports
something a stricter configuration would have made `high`. That is not a
severity chosen at the emission site, which §6.2 forbids everywhere: it is two
types, fixed at `medium` and `high`, for two facts that genuinely differ in
what happened. Naming them one type would have forced one band on both, and
whichever band was picked would have been wrong for the other half.

`taint_cleared` is the first type in this registry that records a control being
LIFTED rather than applied, and the band is the whole of it.

Every other type here is something happening or something being refused.
This one is a human deciding that a refusal no longer applies: TokenFuse's
agent firewall is monotonic, so a taint label lasts the life of a run, and
docs/07 B.4 gate 1 is the only way one comes off. It carries
`{labels, actor, reason, authenticated, still_inherited}`.

**`high`, the same band as `taint_block`**, and a consumer that filed it lower
would have the estate's weights backwards. This is the single event where a
guarantee is deliberately suspended for a run. An estate that pages when a rule
fires and stays quiet when somebody switches it off is telling its operator that
enforcement matters and exemption does not. It is rare by construction, so the
band costs nothing in noise.

**`actor` is a person and `agent_id` is not.** The subject is the run's AGENT,
required and never invented, because §6.1 forbids inventing one and an emitter
that omitted it would produce a clearance that was applied and never recorded.
Who did it travels in `data.actor` as a `user://` principal, which is the
payload plane's side of the line §6.1 draws: `agent_id` is the field this
envelope promises holds no natural person, and a human's identifier belongs
where erasure can reach it.

**`authenticated` is a real field with two values.** It says whether the caller
presented a credential or was trusted by network placement, and a consumer
auditing a clearance needs to tell those apart. A field that was always true
would be worth nothing, which is the same argument §6.2 makes about
`scopyx`'s `enforcement` and `dependency_failed`'s `effect`: two honest states
that are not the same guarantee, and counting them as one loses the difference.

`slo_burn` is the first type in this registry that reports a STANDING
QUANTITY rather than an occurrence. Every type above says that a thing
happened: a run was killed, a call was blocked, a score moved, a dependency
died. This one says how much of an agent's error budget is left against an
objective its operator set, which is a level rather than an event. It exists
because that is the question an enterprise asks before it deploys an agent, and
until this type existed nothing here answered it: verdryx emits `eval_run`,
`quality_score` and `quality_drift`, and none of the three says whether an
agent is reliable ENOUGH, because a score is a number with no denominator and
drift is a change with no threshold.

**Two things called a budget, and they are not the same thing.** TokenFuse's
`budget_exhausted` is money, it fires at the moment a spend ceiling is reached,
and something enforces it: the call is blocked and the caller gets a 402. An
error budget here is reliability, it is computed over a window rather than
reached at an instant, and nothing enforces it at all. The paragraph below on
enforcement is there because the shared word invites the wrong reading.

Read from `verdryx/events.py`, which fixes the wire string and the severity in
its `EVENT_SEVERITY` map, rather than from its docs. `data` carries the
objective, the evidence, the budget and the grouping. `sli` is which service
level indicator the budget is against, one of `task_success`, `quality_floor`,
`containment` or `cost_discipline`. `target` is the objective itself, a
fraction such as 0.95. `observed` is the measured ratio of good runs over
eligible runs, and `window` is the period it was computed over, `28d` for
example.

**`observed` on its own is not evidence, and the three members beside it are
what make it evidence.** `ci_low` and `ci_high` are the Wilson interval at the
configured confidence, and `events` is how many runs the ratio was computed
over. Nine good runs out of ten is an observed 0.90 against a target of 0.95,
and at 95% confidence the interval around it runs from roughly 0.60 to 0.98, so
it still contains the target: the ratio says breach and the interval says not
established yet. A consumer that renders `observed` without reading `events`
puts an operator in front of a number that may rest on three runs, with nothing
on the screen to say so. The interval travels in the event precisely so a
reader can tell a real breach from a small sample without going back to verdryx
to ask.

`budget_remaining` is the fraction of the error budget left, and **it goes
negative, which is not a bug and must not be clamped.** A target of 0.95 allows
5% of the runs in the window to be bad; when 10% have been, the remaining
budget is not zero, it is minus 1.0, and what that says is that twice the
allowance has been spent. The sign is the only place in the event carrying how
far past the line an agent already is, so a consumer that floors it at zero
makes every overspent agent look identically exhausted, and the one that is
twenty times over reads the same as the one that crossed this morning.
`burn_rate` is the same fact against the clock: how many times faster than the
budget allows the failures are arriving.

**It is emitted on `trigger: "exhausted"` and `trigger: "fast_burn"` only, and
a slow burn never reaches this bus at all.** That is a designed hole rather
than a gap. Severity is fixed per type in code rather than chosen at the
emission site, the sentence the `scopyx` and `dependency_failed` paragraphs
above both make and for the same reason, and its consequence here is that one
type is one paging band: everything named `slo_burn` arrives at `high`. A
budget that will be gone by Friday and a budget that is already gone are not
the same fact and must not share a band, and a type that pages for the design
working teaches an operator to filter the sender, which costs the exhausted
case its audience as well. This registry already carries that split one size
down, in `budget_threshold` sitting deliberately one band below the incident it
warns about. Here the warning is given no band at all: the slow-burn figure
stays in verdryx's own report and its JSON output, where a dashboard reads it
and nobody is woken by it.

**This type reports a measurement, and nothing in this stack acts on it.**
verdryx computes the budget and says so. It writes no wardryx policy, it
demotes no agent, and there is no autonomy tier anywhere in this estate for an
agent to be moved down into. Saying that is not pedantry, because the
vocabulary invites the other reading: an error budget in the setting the term
comes from arrives attached to a release freeze, and a consumer that assumes
the same here would build a console showing a consequence that never happened,
which is worse than a console showing nothing. A person decides what an
exhausted budget means for an agent. This type is what they read before
deciding.

`identity_field` says which field the subject was grouped on, `agent_id` or
`key_id`, and it is the member that tells a consumer what the number is worth.
A budget grouped on `agent_id` is grouped on a client-supplied header, and
TokenFuse's own source says so where the alternative is declared
(`crates/gateway/src/sink.rs`): it calls `agent_id` sound for attribution that
a cooperating fleet reports about itself and unsound as the key of a budget,
which a caller could move off simply by sending a different one. `key_id` is
resolved server-side and carries no such weakness, and it is empty on every
deployment that has not configured client keys, so the sound grouping is
frequently not the one available. Both are honest and they do not weigh the
same, and a consumer that counts them as one thing is making the mistake
`scopyx`'s `enforcement` and `dependency_failed`'s `effect` each have a
paragraph about above.

The first four TokenFuse types are its existing incident taxonomy verbatim —
zero renaming. New types may be added freely within a `source`; renames or
semantic changes require a schema version bump. The `wardryx`, `verdryx`,
and `mockryx` rows are wave-2 additions introduced alongside schema v0.2
(§6.4); the parenthesized value after each type is its typical `severity`,
not a schema-enforced mapping.

Every TokenFuse type this registry did not carry when it was first written on
2026-07-09 was added later, under the "added freely within a `source`" rule
above, and each is glossed here so that a reader of this document sees what
that producer actually emits: `identity_mismatch` (its identity gate),
`tool_call` (its MCP broker's per-action audit signal), `budget_threshold` (a
run crossing the configured fraction of its budget, which is the warning that
precedes `budget_exhausted`), `run_killed`, `unit_cap_exceeded`, `policy_deny`
(also a wardryx type, for the reason given above), and `dependency_failed`,
which reports a different kind of fact from every other type on that row and
has its own paragraphs above. Their parenthesized severities are exact rather
than typical:
TokenFuse fixes the severity per type in code, so no emission site can choose
one, and `budget_threshold` sits deliberately one band below the incident it
warns about.

**This paragraph counted, and the count was wrong for three weeks.** It opened
"The last four TokenFuse types" and named four, which was true when it was
written on 2026-08-02 and stopped being true the next day: `unit_cap_exceeded`
and `policy_deny` arrived on 2026-08-03, the row above grew by two, and nobody
came back to the sentence that had counted it. That is the failure the `idryx`
bullet names in as many words ("a number in this table ages separately from the
thing it counts") and the one 6.4 records about itself, met a third time here.
So the wording no longer carries a running total: the row above is where a
reader counts, because the row is the half a gate reads.

### 6.3 The one concrete integration this buys

Idryx gains a `tokenfuse` ingest connector that reads these events (from
Parquet or the Cloud SSE stream) as a behavioral source — the richest record
of what an agent *does* is currently invisible to identity tooling. That
connector plus this envelope is the first real cross-product feature, and it
needs nothing from Engram or Qryx to ship.

### 6.4 Versioning and compatibility

Only the event schema is versioned to v0.2
(`schemas/agent-event.v0.2.schema.json`, `schema` const
`taipanbox.dev/agent-event/v0.2`). The Passport schema stays at v0.1,
unchanged: Idryx hard-codes `requiredSchema =
"taipanbox.dev/agent-passport/v0.1"`, so the Passport schema is not
re-versioned by this change.

Consumers MUST accept events whose `schema` is either
`taipanbox.dev/agent-event/v0.1` or `taipanbox.dev/agent-event/v0.2`.
Emitters already on v0.1 may keep emitting v0.1 events; those remain valid,
and nothing requires them to move. New wave-2 services (wardryx, verdryx,
mockryx) emit v0.2. Those two versions differ only in the `source` field
(closed enum in v0.1, open string in v0.2, §6.1); every other field is
unchanged.

**v0.3 (`schemas/agent-event.v0.3.schema.json`) is different in kind from that
bump, and the difference is the point.** Its only delta from v0.2 is that
`agent_id` also accepts the `claimed:` form (§3.3), which widens the pattern
and raises `maxLength` from 255 to 263, the eight bytes of the marker. Every
v0.2 event validates against v0.3 with its version string swapped, so v0.3 is a
widening exactly as v0.2 was of v0.1.

**Accepting v0.3 is NOT a MUST, and that is deliberate.** A consumer that
accepts only v0.1 and v0.2 refuses a v0.3 event, and refusing is the correct
answer for a consumer that does not know what a claimed subject is: it is the
one version where `agent_id` can hold something that is not an established
identity, so a reader that has not been told MUST NOT be handed it. A consumer
adopts v0.3 when it has decided what a claim means to it, and until then it
loses only events it could not have read safely.

The cost of that choice is stated rather than left to be discovered: an
operator running a v0.2-only consumer sees no claimed-subject events at all,
and the consumer SHOULD count what it refused rather than dropping it in
silence, so the gap is visible as a number rather than as an absence.

**A producer MUST NOT stamp v0.3 on an event whose subject is established.**
The version is how a reader knows a claim is possible; stamping it on ordinary
traffic would take that signal away from every consumer at once and force the
lockstep this design exists to avoid.

That v0.1 enum is a closed list of four names, `tokenfuse`, `engram`,
`idryx` and `qryx`, and a list of permitted values is not a list of
emitters. As of 2026-08-10 all four of them do emit, so the distinction has
no live example here, and saying that is better than keeping one that has
stopped being true.

**This paragraph has now been wrong twice, for the same reason both times.**
It named all four as emitters until 2026-08-06, three days after the audit
that corrected 6.2, because that audit read the registry and never came back
here. It then used `idryx` as the counter-example until 2026-08-10, when
idryx gained an event writer and 6.2's row stopped saying RESERVED, and
whoever made that change had to be reminded to come back here again. The
registry is gated; this sentence is prose about the registry, and prose about
a gated thing is the part that drifts.

### 6.5 `prev_hash` canonicalization

Where present, `prev_hash` MUST be computed as:

```
prev_hash = "sha256:" + hex(sha256(C))
```

where `C` is the RFC 8785 (JSON Canonicalization Scheme, JCS) canonical
serialization of the event object with the `prev_hash` field itself
removed. Format: `^sha256:[0-9a-f]{64}$`.

## 7. Conformance (v0.1)

A product is Passport-aware when it:

1. Accepts an `agent://` URI wherever it takes an agent identifier today,
   treating it as an opaque key.
2. Emits its agent-relevant events in the §6 envelope (natively or via an
   exporter).
3. Propagates `on_behalf_of` without truncation where it forwards requests.

Deliberately *not* required: reading Passport documents (§4) — a consumer of
IDs and events alone is already useful.

## 8. Resolved design decisions (2026-07-09)

1. **Scheme string: `agent://`** (own scheme, mechanical SPIFFE mapping per
   §3.1). Raw SPIFFE was rejected: it drags in trust-domain semantics this
   spec does not enforce.
2. **Humans in the chain: `user://`** — symmetric with `agent://`, parsed by
   the same rules. `mailto:` rejected.
3. **Home: its own repo, `TAIPANBOX/agent-passport`** — SPEC.md + JSON
   Schemas + examples, publicly referenceable ("naming the category" needs a
   public URL).
4. **Namespace: `taipanbox.dev`** — the `schema` strings
   `taipanbox.dev/agent-passport/v0.1` and `taipanbox.dev/agent-event/v0.1`
   are final for v0.1.

## 9. Adoption cost estimate (per repo)

| Repo | Work | Size | Status (2026-07-09) |
|---|---|---|---|
| tokenfuse | accept/record `x-fuse-on-behalf-of`; NDJSON event exporter mapping existing incidents to the envelope | small — trace column + serializer | shipped on main, not yet in a tagged release: `x-fuse-agent-id` carried; exporter and `x-fuse-on-behalf-of` capture shipped |
| Idryx | `OnBehalfOf` one-hop → chain; `ingest/tokenfuse` connector (§6.3); `attestation_missing` detector | medium — the connector is the real feature | shipped |
| Engram | document `agent_id` = Passport ID; emit §6 events from reflection/contradiction paths (optional exporter) | small | shipped: `agent_id` scope and the event exporter are both built |
| Qryx | accept `agent_id` as evidence subject; emit findings in envelope (exporter) | small | shipped: `agent_id`-as-evidence-subject (`qryx agents`, `internal/agentstack`) and the emitter (`internal/exporter`, `crypto_finding`/`crypto_drift`/`policy_violation`/`evidence_signed`, `--events` flag) both built |

No step blocks any other; TokenFuse exporter + Idryx connector is the pair
that proves the whole idea.

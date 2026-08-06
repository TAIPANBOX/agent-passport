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

- `provider` is a required, non-empty label (e.g. `anthropic`, `openai`,
  `bedrock`, `google`, `mistral`, `cohere`). `model` and `endpoint` are
  optional: `model` pins a specific model, `endpoint` names the API host the
  agent is declared to reach.
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
  envelope grows a subject kind, which would be a change every consumer has to
  make together. TokenFuse's `spend_spike` is the live example: raised,
  displayed, and deliberately never exported.
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

wardryx, verdryx, and mockryx are wave-2 services; like the original four,
this contract governs an operator's own agents, for the operator's own
self-protection, not third-party or adversarial traffic.

### 6.2 Initial event-type registry

| `source` | `type` values |
|---|---|
| `tokenfuse` | `budget_exhausted` · `sustained_loop` · `spend_spike` · `fanout_explosion` · `breaker_tripped` (medium) · `dlp_block` · `taint_block` · `mcp_drift` · `identity_mismatch` (high) · `tool_call` (low) · `budget_threshold` (medium) · `run_killed` (high) · `unit_cap_exceeded` (high) · `policy_deny` (high) |
| `engram` | `memory_written` · `reflection_run` · `contradiction_found` · `memory_forgotten` |
| `idryx` | RESERVED, not emitted today: `excessive_privilege` · `behavior_anomaly` · `impossible_travel` · `mfa_fatigue` · `new_device` · `blast_radius_change` · `attestation_missing` |
| `qryx` | `crypto_finding` · `crypto_drift` · `policy_violation` · `evidence_signed` |
| `wardryx` | `policy_allow` (info) · `policy_deny` (high) · `approval_requested` (medium) · `approval_granted` (info) · `approval_denied` (high) · `approval_timeout` (high) · `approval_unanswered` (high) · `policy_updated` (high) |
| `verdryx` | `eval_run` (info) · `quality_score` (info) · `quality_drift` (high) |
| `mockryx` | `sim_run` (info) · `sim_finding` (high) · `blast_radius_measured` (medium) |
| `console` | `console_command` |
| `heraldyx` | `alert_sent` (info) |


A row here is a CLAIM that the source writes those types into this envelope
today, not a list of what it detects or intends to. Checked against every
producer's code on 2026-08-03, which is when this table stopped being partly
aspirational:

- **`idryx` emits nothing into this envelope.** Its detections leave by OTLP
  and by Slack, so all seven names above are reserved rather than live. Four of
  them are its internal detector names, and `attestation_missing` had never had
  a producer anywhere. A consumer that built a handler for one of these would
  have waited forever, and one downstream product had already written the
  operator-facing description for two of them.
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

The first four TokenFuse types are its existing incident taxonomy verbatim —
zero renaming. New types may be added freely within a `source`; renames or
semantic changes require a schema version bump. The `wardryx`, `verdryx`,
and `mockryx` rows are wave-2 additions introduced alongside schema v0.2
(§6.4); the parenthesized value after each type is its typical `severity`,
not a schema-enforced mapping.

The last four TokenFuse types were added after this registry was first
written, under the "added freely within a `source`" rule above, and are listed
here so that a reader of this document sees what that producer actually emits:
`identity_mismatch` (its identity gate), `tool_call` (its MCP broker's
per-action audit signal), `budget_threshold` (a run crossing the configured
fraction of its budget, which is the warning that precedes
`budget_exhausted`), and `run_killed`. Their parenthesized severities are
exact rather than typical: TokenFuse fixes the severity per type in code, so
no emission site can choose one, and `budget_threshold` sits deliberately one
band below the incident it warns about.

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
mockryx) emit v0.2. The two versions differ only in the `source` field
(closed enum in v0.1, open string in v0.2, §6.1); every other field is
unchanged.

That v0.1 enum is a closed list of four names, `tokenfuse`, `engram`,
`idryx` and `qryx`, and a list of permitted values is not a list of
emitters: `idryx` is in the enum and emits nothing into this envelope
(§6.2). This paragraph named all four as emitters until 2026-08-06, three
days after the audit that corrected 6.2, because that audit read the
registry and never came back here.

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

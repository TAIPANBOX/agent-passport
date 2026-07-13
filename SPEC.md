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
  "labels": { "env": "prod", "cost_center": "cs-eu" },
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

wardryx, verdryx, and mockryx are wave-2 services; like the original four,
this contract governs an operator's own agents, for the operator's own
self-protection, not third-party or adversarial traffic.

### 6.2 Initial event-type registry

| `source` | `type` values |
|---|---|
| `tokenfuse` | `budget_exhausted` · `sustained_loop` · `spend_spike` · `fanout_explosion` · `breaker_tripped` · `dlp_block` · `taint_block` · `mcp_drift` |
| `engram` | `memory_written` · `reflection_run` · `contradiction_found` · `memory_forgotten` |
| `idryx` | `excessive_privilege` · `behavior_anomaly` · `impossible_travel` · `mfa_fatigue` · `new_device` · `blast_radius_change` · `attestation_missing` |
| `qryx` | `crypto_finding` · `crypto_drift` · `policy_violation` · `evidence_signed` |
| `wardryx` | `policy_allow` (info) · `policy_deny` (high) · `approval_requested` (medium) · `approval_granted` (info) · `approval_denied` (high) · `approval_timeout` (high) |
| `verdryx` | `eval_run` (info) · `quality_score` (info) · `quality_drift` (high) |
| `mockryx` | `sim_run` (info) · `sim_finding` (high) · `blast_radius_measured` (medium) |

The first four TokenFuse types are its existing incident taxonomy verbatim —
zero renaming. New types may be added freely within a `source`; renames or
semantic changes require a schema version bump. The `wardryx`, `verdryx`,
and `mockryx` rows are wave-2 additions introduced alongside schema v0.2
(§6.4); the parenthesized value after each type is its typical `severity`,
not a schema-enforced mapping.

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
Existing emitters (tokenfuse, engram, idryx, qryx) may keep emitting v0.1
events; those remain valid, and nothing requires them to move. New wave-2
services (wardryx, verdryx, mockryx) emit v0.2. The two versions differ
only in the `source` field (closed enum in v0.1, open string in v0.2,
§6.1); every other field is unchanged.

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

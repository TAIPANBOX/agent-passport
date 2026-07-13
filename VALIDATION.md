# Live infrastructure validation

Agent Passport doesn't run as its own service, so it has no dashboard of its own - but its envelope and
delegation-chain format is what every other service's live validation runs were built on, and it was
exercised end to end in every one of them, on disposable Hetzner infrastructure before any public launch.

## What was actually validated

- **Schema-valid NDJSON with an intact delegation chain**, emitted natively by TokenFuse
  (`TOKENFUSE_EVENTS_PATH`) on every real Claude call across every campaign, validated against the
  `taipanbox.dev/agent-event/v0.1` schema.
- **Root-first delegation-chain resolution** (`OnBehalfOf`, cycle-safe) consumed correctly by Idryx's
  detectors off real event streams, including in the real-Postgres runs.
- **The `on_behalf_of` header** (captured via `x-fuse-on-behalf-of`) carried correctly end to end through
  the raft-replicated gateway under concurrent multi-agent load (34 agents at once) without chain
  corruption.
- **Attestation status** (attested / unattested) as part of the identity envelope, correctly read and
  enforced by Wardryx's PEP under the same concurrent load.

In short: the envelope format was the thread every other service's live validation numbers ran through -
it was proven correct by being load-bearing in all of them at once, under real concurrent traffic, rather
than tested in isolation against a fixture.

## Method

Disposable Hetzner VPS boxes (deleted after each run); code delivered as a `git archive` tarball (no
secrets, no `.git`, no token); every service bound to `127.0.0.1` only, reached exclusively via SSH
tunnel. Nothing from these runs was ever exposed publicly, and no infrastructure or secret from the
campaign persists today.

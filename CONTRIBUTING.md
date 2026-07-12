# Contributing to agent-passport

This is a specification repo, not a running service: there is no build or
test suite here, only the `agent://` identifier grammar, the delegation-chain
rules, and the event-envelope schema in [SPEC.md](SPEC.md), plus a
conformance test suite that lives in each consuming service's own repo
(TokenFuse, Engram, Idryx, Qryx, Wardryx, Verdryx, Mockryx).

## Proposing a spec change

1. Open an issue describing the problem before proposing a change - a schema
   change has to work for all seven consuming services, so the discussion
   matters more than the diff.
2. State whether the change is backward-compatible (a new optional field) or
   breaking (anything a v0.1 consumer would reject or misinterpret). Breaking
   changes need a version bump and a migration note.
3. Update [SPEC.md](SPEC.md) and the adoption-status table in
   [README.md](README.md) together - they must not drift.
4. If the change affects the JSON Schema, update it and re-run each
   consumer's conformance test against the new schema before merging.

## Conventions

- Conventional Commits: `feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, `test:`.
- One logical change per commit.
- The spec is versioned (`SPEC.md`'s `Version:` header); every change updates
  it and records the date.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities privately.

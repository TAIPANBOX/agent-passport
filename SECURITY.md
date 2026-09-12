# Security Policy

agent-passport is a specification, not a running service, but a flaw in the
spec itself (a weak delegation-chain rule, an ambiguous envelope field, a
signature scheme gap) becomes a security bug in every one of the seven
services that implement it. This document covers how to report one.

## Reporting a vulnerability

Please report security issues privately, not in public issues or PRs:

- Open a **GitHub private security advisory**:
  <https://github.com/TAIPANBOX/agent-passport/security/advisories/new>

Include the affected spec version, a description, and, where possible, a
concrete scenario showing how a conforming implementation could be misled.
We aim to acknowledge within a few days and to fix high-severity issues
before any public disclosure. There is no bug-bounty program; we credit
reporters in the advisory unless you prefer otherwise.

## Supported versions

The newest minor gets every fix; the previous minor gets security-relevant
fixes for 90 days after the newer one is tagged (SPEC 10 / the support
sentence decided 2026-09-12).

## Scope

In scope: the `agent://` identifier grammar, delegation-chain validation
rules (including `MaxDepth` and acyclic/root-first requirements), and the
event-envelope schema. Out of scope: bugs in a specific consuming service's
*implementation* of the spec - report those in that service's own repo (see
[CONTRIBUTING.md](CONTRIBUTING.md) for the list).

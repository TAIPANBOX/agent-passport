Feature: Release 1.0 marks a surface that has run, and keeps what 0.x accepted

  @decided 2026-09-12: a release version marks a contract that has been run on
  real infrastructure and is now frozen; it is not a quality certificate. What
  0.x accepted, 1.0 still accepts, with one narrowing a reader can see by name
  (SPEC 6.4.1), and a gate holds each promise below. Every scenario names the
  gate that holds it; scripts/features-are-bound.sh refuses a scenario that
  names none, or one that names a gate this repository does not have.

  Scenario: a v0.1 event moves to v1.0 by changing only its version string
    Given an event stamped taipanbox.dev/agent-event/v0.1 in examples/events.ndjson
    When its schema string is replaced by the next version's, pair by pair, up to v1.0
    Then it validates against every newer schema with nothing else changed
    # @gate: scripts/version-compatibility.sh

  Scenario: a v0.3 event and a v1.0 event have the same shape
    Given schemas/agent-event.v0.3.schema.json and schemas/agent-event.v1.0.schema.json
    When the two are compared field by field, bound by bound
    Then nothing is newly required, removed, or tightened between them
    # @gate: scripts/version-compatibility.sh

  Scenario: a v0.1 passport moves to v1.0 by changing only its version string
    Given examples/passport.json, stamped taipanbox.dev/agent-passport/v0.1
    When its schema string is replaced by taipanbox.dev/agent-passport/v1.0
    Then it validates against schemas/agent-passport.v1.0.schema.json
    # @gate: scripts/version-compatibility.sh

  Scenario: the one narrowing a major may make is the Passport's top level, and only that
    Given the Passport schema at v0.1 and at v1.0
    When v1.0 closes its top level and changes nothing else
    Then the compatibility gate passes, and it fails on any other narrowing across the major
    # @gate: scripts/version-compatibility.sh

  Scenario: a key the v1.0 Passport schema never named does not validate
    Given examples/passport.v1.0.json
    When a top-level key the schema does not declare is added to it
    Then the validator refuses the document and names the key
    # @gate: python3 .github/scripts/validate_examples.py

  Scenario: the same unknown key is still tolerated under v0.1
    Given examples/passport.json, stamped v0.1
    When the same undeclared key is added to it
    Then the validator accepts it, because v0.1's hole stays open by design
    # @gate: python3 .github/scripts/validate_examples.py

  Scenario: every passport schema version closes the attestation set the same way
    Given every schemas/agent-passport*.schema.json
    When their attestation.method enums are compared in order
    Then they are identical, and a version with an open set is refused outright
    # @gate: scripts/attestation-methods-agree.sh

  Scenario: an event stamped with a version this repository does not carry is refused
    Given a line in examples/events.ndjson
    When its schema string names a version no file in schemas/ declares
    Then the validator refuses the line and names the versions it knows
    # @gate: python3 .github/scripts/validate_examples.py

  Scenario: every property a v1.0 schema declares is named in the prose
    Given schemas/agent-passport.v1.0.schema.json and schemas/agent-event.v1.0.schema.json
    When every declared property name is looked up in SPEC.md
    Then each one appears there
    # @gate: scripts/schema-matches-spec.sh

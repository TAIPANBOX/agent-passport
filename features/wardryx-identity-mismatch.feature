Feature: A token that names another agent is refused under wardryx's own subject, and the registry says wardryx writes it

  @decided 2026-10-19: the policy decision point verifies the agent's token itself and
  reports a contradiction when the token names a different agent than the request does.
  The registry lists the pair (wardryx, identity_mismatch) beside tokenfuse's own row for
  the same type, so a consumer knows wardryx can write it too (SPEC 6.2, the wardryx row
  and its bullet). Each scenario below names the gate that holds it.
  scripts/features-are-bound.sh refuses a scenario that names none.

  Scenario: the registry accepts identity_mismatch when wardryx writes it
    Given an event line with source "wardryx" and type "identity_mismatch", as wardryx writes it when a verified token names another agent
    When the registry check reads that line against SPEC 6.2
    Then the check passes, because SPEC 6.2 lists identity_mismatch under wardryx
    # @gate: scripts/artifacts-match-registry.sh

  Scenario: identity_mismatch attributed to another source is refused
    Given an event line with source "idryx" and type "identity_mismatch"
    When the registry check reads that line against SPEC 6.2
    Then the check fails, because the idryx row does not list that type
    # @gate: scripts/artifacts-match-registry.sh

  Scenario: README's copy of the wardryx row lists the same pair as SPEC 6.2
    Given README's registry table and SPEC 6.2's registry table
    When the registry check compares the two copies of the wardryx row
    Then they agree, and a README copy that drops identity_mismatch fails
    # @gate: scripts/artifacts-match-registry.sh

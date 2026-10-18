Feature: A producer's checkpoint says what its stream held, and no more

  @decided 2026-10-18: a producer signs a checkpoint over its stream, and the record
  is fixed to the byte so two writers in two languages agree. A v1 checkpoint binds the
  bytes of the stream through its count (the prefix member), so a rewritten earlier line
  is refused by every later record that covers it, even when the chain still passes
  (SPEC 6.5.1, "What a v1 checkpoint binds"). Each scenario below names the gate that
  holds it. scripts/features-are-bound.sh refuses a scenario that names none.

  Scenario: every signed checkpoint verifies under the key its record names
    Given examples/checkpoint-vectors.json, whose records carry signatures and a public key
    When each signature is checked over its signing input with that key
    Then every signature verifies, and a record whose signing input changed does not
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: a checkpoint record is accepted only in its canonical bytes
    Given each record line in the vector file
    When it is serialized again with the RFC 8785 rules
    Then the bytes are unchanged, and a record whose members are reordered is refused
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: the head of a checkpoint is the chain hash of the line it counts
    Given the stream in the vector file and the count of each record
    When the 6.5 chain hash of line count is computed for each record
    Then it equals the head the record carries, for the checkpoint, the resume and the close alike
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: the records of one file chain from the genesis value to the last one
    Given the records in the order they were written
    When each prev is compared with the SHA-256 of the record before it
    Then the first prev is the genesis value, every later one matches, and a re-linked record is refused
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: a record written after its key expired says so and is not counted as signed
    Given the unsigned record in the vector file, which carries unsigned_reason key_expired
    When it is read beside the signed records
    Then it has no alg, kid or sig, it stays in the chain, and it is reported as unsigned
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: the record SPEC 6.5.1 quotes is the first vector, byte for byte
    Given the first checkpoint record in the vector file
    When the text of SPEC 6.5.1 is searched for it
    Then it is found, so the quoted record cannot drift from the vector it shows
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: a forged earlier line is refused by every record that covers it, though the chain passes
    Given the forged prefix stream, whose first line is rewritten and whose second line is re-linked
    When every checkpoint is checked against it
    Then the chain verifies on its own, and every record is refused because its prefix names other bytes
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: a whitespace-only change to an earlier line is refused by the prefix alone
    Given the prefix-only stream, whose first line differs from the honest one by one space
    When every checkpoint is checked against it
    Then every chain hash is unchanged, and every record is still refused by its prefix
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: a truncated stream is refused by the records that count past its end, and accepted by the rest
    Given the truncated stream, which has lost its third line
    When each record is checked against it
    Then the record that counts two lines is accepted, and the three that count three are refused as truncations
    # @gate: scripts/checkpoint-vectors.sh

  Scenario: the keyryx rows agree in SPEC 6.2 and README, and no example claims a keyryx event
    Given the keyryx row and the agent-conform row in SPEC 6.2 and in README
    When both copies are compared, and every example event is read against the registry
    Then the copies agree, keyryx is an emitting source with the seven witness types, and no example attributes an event to it
    # @gate: scripts/artifacts-match-registry.sh

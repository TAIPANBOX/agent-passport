#!/usr/bin/env python3
"""Validate agent-passport's JSON Schemas and example documents.

Checks, in order:
  1. Every schemas/*.json file is syntactically valid JSON and is itself a
     valid JSON Schema (draft 2020-12).
  2. Every examples/passport*.json validates against the Passport schema its
     own "schema" field names (v0.1 or v1.0). Under v1.0 a key the schema never
     named is a failure, which is SPEC 6.4.1's one narrowing.
  3. Every line of examples/events.ndjson validates against the agent-event
     schema matching its own "schema" field (v0.1, v0.2, v0.3 or v1.0).

Exits non-zero with a diagnostic on the first class of failure so CI fails
loudly rather than silently drifting.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError

ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMAS = ROOT / "schemas"
EXAMPLES = ROOT / "examples"

EVENT_SCHEMA_BY_ID = {
    "taipanbox.dev/agent-event/v0.1": SCHEMAS / "agent-event.schema.json",
    "taipanbox.dev/agent-event/v0.2": SCHEMAS / "agent-event.v0.2.schema.json",
    "taipanbox.dev/agent-event/v0.3": SCHEMAS / "agent-event.v0.3.schema.json",
    "taipanbox.dev/agent-event/v1.0": SCHEMAS / "agent-event.v1.0.schema.json",
}

PASSPORT_SCHEMA_BY_ID = {
    "taipanbox.dev/agent-passport/v0.1": SCHEMAS / "agent-passport.schema.json",
    "taipanbox.dev/agent-passport/v1.0": SCHEMAS / "agent-passport.v1.0.schema.json",
}


def load_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def check_schema_files() -> list[str]:
    errors = []
    for path in sorted(SCHEMAS.glob("*.json")):
        try:
            schema = load_json(path)
        except json.JSONDecodeError as e:
            errors.append(f"{path}: invalid JSON ({e})")
            continue
        try:
            Draft202012Validator.check_schema(schema)
        except SchemaError as e:
            errors.append(f"{path}: not a valid draft 2020-12 schema ({e.message})")
    return errors


def passport_examples() -> list[Path]:
    return sorted(EXAMPLES.glob("passport*.json"))


def check_passport_example() -> list[str]:
    errors = []
    examples = passport_examples()
    if not examples:
        return [f"{EXAMPLES}: no passport*.json example to validate, so this check measured nothing"]
    validators: dict[str, Draft202012Validator] = {}
    for schema_id, schema_path in PASSPORT_SCHEMA_BY_ID.items():
        validators[schema_id] = Draft202012Validator(load_json(schema_path))
    for example_path in examples:
        example = load_json(example_path)
        schema_id = example.get("schema") if isinstance(example, dict) else None
        validator = validators.get(schema_id)
        if validator is None:
            errors.append(
                f"{example_path}: unrecognized \"schema\" value {schema_id!r} "
                f"(expected one of {sorted(PASSPORT_SCHEMA_BY_ID)})"
            )
            continue
        for err in sorted(validator.iter_errors(example), key=str):
            errors.append(f"{example_path}: {err.message} (at {'/'.join(map(str, err.path))})")
    return errors


def check_events_example() -> list[str]:
    errors = []
    events_path = EXAMPLES / "events.ndjson"
    validators: dict[str, Draft202012Validator] = {}
    for schema_id, schema_path in EVENT_SCHEMA_BY_ID.items():
        validators[schema_id] = Draft202012Validator(load_json(schema_path))

    with events_path.open("r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                errors.append(f"{events_path}:{lineno}: invalid JSON ({e})")
                continue
            schema_id = event.get("schema")
            validator = validators.get(schema_id)
            if validator is None:
                errors.append(
                    f"{events_path}:{lineno}: unrecognized \"schema\" value {schema_id!r} "
                    f"(expected one of {sorted(EVENT_SCHEMA_BY_ID)})"
                )
                continue
            for err in sorted(validator.iter_errors(event), key=str):
                errors.append(
                    f"{events_path}:{lineno}: {err.message} (at {'/'.join(map(str, err.path))})"
                )
    return errors


def main() -> int:
    all_errors = []
    all_errors += check_schema_files()
    all_errors += check_passport_example()
    all_errors += check_events_example()

    if all_errors:
        print("agent-passport schema/example validation FAILED:\n", file=sys.stderr)
        for e in all_errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print("agent-passport schema/example validation OK: "
          f"{len(list(SCHEMAS.glob('*.json')))} schema(s), "
          f"{len(passport_examples())} passport example(s), events.ndjson all validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

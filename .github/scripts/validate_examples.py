#!/usr/bin/env python3
"""Validate agent-passport's JSON Schemas and example documents.

Checks, in order:
  1. Every schemas/*.json file is syntactically valid JSON and is itself a
     valid JSON Schema (draft 2020-12).
  2. examples/passport.json validates against schemas/agent-passport.schema.json.
  3. Every line of examples/events.ndjson validates against the agent-event
     schema matching its own "schema" field (v0.1 or v0.2).

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


def check_passport_example() -> list[str]:
    errors = []
    schema_path = SCHEMAS / "agent-passport.schema.json"
    example_path = EXAMPLES / "passport.json"
    schema = load_json(schema_path)
    example = load_json(example_path)
    validator = Draft202012Validator(schema)
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
          "1 passport example, events.ndjson all validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

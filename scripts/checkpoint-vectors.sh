#!/usr/bin/env bash
# Enforces invariant 14 of CLAUDE.md: every checkpoint record in
# examples/checkpoint-vectors.json is the canonical serialization of its object,
# every signature verifies under the key its `kid` names, every `prev` chains from
# the genesis value, every `head` is the SPEC 6.5 chain hash of the stream line it
# counts, and the record SPEC 6.5.1 quotes is the first vector.
#
# WHY THIS EXISTS
#
# SPEC 6.5.1 promises that a Go writer and a Rust writer produce the same bytes.
# Prose cannot hold that promise: two implementations agree only where they have
# been run against the same bytes. The vectors are those bytes, and this gate is
# the one place that re-derives every one of them from the stream and the key, so
# a vector that stops reproducing turns CI red here before any writer reads it.
#
# WHAT IT READS
#
# examples/checkpoint-vectors.json is the source of truth. SPEC.md is read for two
# things only: the 6.5.1 heading, and that the first signed record appears in it
# verbatim (the quote a reader sees must be the vector, not a copy that drifted).
#
# WHAT IT CANNOT DO
#
# It does not prove the signing key was honest; it proves the signatures verify
# under the public key the vectors carry. It canonicalizes only the subset these
# vectors use (ASCII strings, integers, objects, arrays), and it refuses anything
# outside that subset rather than guessing at RFC 8785's number rules. It does not
# check that a key statement certifies the key: that statement belongs to the
# service that certifies keys, and no vector in this repository contains one.
#
# THE KNOWN LIMIT IS CHECKED, NOT ASSUMED
#
# known_limit_forged_prefix is a stream whose first line was rewritten and whose
# second line was re-linked to it. Every checkpoint still verifies against it,
# because a line's hash does not cover its own prev_hash. This gate asserts that
# fact. If a later format closes the gap, this assertion fails and forces SPEC
# 6.5.1 to be rewritten with it, rather than leaving the limit described in prose
# that nothing measures.
#
# It refuses to report success when it measured nothing: no vector file, no 6.5.1
# heading, no stream line, no record, no signed record verified, or no openssl to
# verify a signature with. OPENSSL may name another binary (the teeth harness
# uses that to prove the refusal).

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

OPENSSL_BIN="${OPENSSL:-openssl}"

python3 - "$OPENSSL_BIN" <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

OPENSSL = sys.argv[1]
VECTORS = pathlib.Path("examples/checkpoint-vectors.json")
SPEC = pathlib.Path("SPEC.md")
GENESIS = "sha256:" + "0" * 64
KINDS = {"checkpoint", "close", "resume"}
COMMON = {"v", "kind", "stream", "count", "head", "at", "prev"}
SIGNED = {"alg", "kid", "sig"}
UNSIGNED = {"unsigned_reason"}
STREAM_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.ndjson$")
AT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
HASH = re.compile(r"^sha256:[0-9a-f]{64}$")

problems = []


def fail(msg):
    problems.append(msg)


def measured_nothing(msg):
    print(f"FAIL: {msg}, so this check measured nothing.")
    sys.exit(1)


# ------------------------------------------------------------------ subjects

if not VECTORS.is_file():
    measured_nothing("examples/checkpoint-vectors.json is not there")
if not SPEC.is_file():
    measured_nothing("SPEC.md is not there")
spec = SPEC.read_text()
if not re.search(r"^### 6\.5\.1 ", spec, re.M):
    measured_nothing("SPEC.md has no '### 6.5.1' heading")

try:
    vec = json.loads(VECTORS.read_text())
except json.JSONDecodeError as e:
    print(f"FAIL: examples/checkpoint-vectors.json is not valid JSON ({e})")
    sys.exit(1)


# ------------------------------------------------------------- canonical JSON

def check_subset(value, where):
    if isinstance(value, bool) or value is None:
        return
    if isinstance(value, int):
        return
    if isinstance(value, float):
        raise ValueError(f"{where}: a float, outside the subset this gate canonicalizes")
    if isinstance(value, str):
        if not value.isascii():
            raise ValueError(f"{where}: non-ASCII text, outside the subset this gate canonicalizes")
        return
    if isinstance(value, list):
        for i, v in enumerate(value):
            check_subset(v, f"{where}[{i}]")
        return
    if isinstance(value, dict):
        for k, v in value.items():
            check_subset(v, f"{where}.{k}")
        return
    raise ValueError(f"{where}: unexpected type {type(value).__name__}")


def jcs(obj, where="object"):
    # RFC 8785 for the subset check_subset admits: sorted members, no whitespace.
    check_subset(obj, where)
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def chain_hash(line_obj):
    # SPEC 6.5: sha256 over the JCS of the line with its own prev_hash removed.
    body = {k: v for k, v in line_obj.items() if k != "prev_hash"}
    return "sha256:" + hashlib.sha256(jcs(body)).hexdigest()


def b64u_encode(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64u_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# -------------------------------------------------------------- the public key

key = vec.get("key") if isinstance(vec, dict) else None
if not isinstance(key, dict):
    measured_nothing("the vector file carries no key")
if key.get("crv") != "P-256" or key.get("kty") != "EC":
    fail("key is not an EC P-256 key (crv and kty must say P-256 and EC)")
try:
    x = b64u_decode(key["x"])
    y = b64u_decode(key["y"])
except (KeyError, ValueError) as e:
    measured_nothing(f"the key's x and y do not decode ({e})")
if len(x) != 32 or len(y) != 32:
    fail("key x and y are not 32 bytes each")
thumb = b64u_encode(hashlib.sha256(jcs({"crv": "P-256", "kty": "EC", "x": key["x"], "y": key["y"]})).digest())
if key.get("kid") != thumb:
    fail(f"key kid {key.get('kid')!r} is not the RFC 7638 thumbprint of its own x and y ({thumb})")
SPKI_P256 = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")


def public_pem(tmp):
    der = os.path.join(tmp, "pub.der")
    pem = os.path.join(tmp, "pub.pem")
    open(der, "wb").write(SPKI_P256 + b"\x04" + x + y)
    subprocess.run([OPENSSL, "pkey", "-pubin", "-inform", "DER", "-in", der, "-out", pem],
                   check=True, capture_output=True)
    return pem


def raw_to_der(raw):
    r = raw[:32].lstrip(b"\x00")
    s = raw[32:].lstrip(b"\x00")
    if r[:1] and r[0] & 0x80:
        r = b"\x00" + r
    if s[:1] and s[0] & 0x80:
        s = b"\x00" + s
    seq = b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
    return b"\x30" + bytes([len(seq)]) + seq


def verifies(message, raw_sig, pem, tmp):
    inp = os.path.join(tmp, "msg")
    sig = os.path.join(tmp, "sig.der")
    open(inp, "wb").write(message)
    open(sig, "wb").write(raw_to_der(raw_sig))
    res = subprocess.run([OPENSSL, "dgst", "-sha256", "-verify", pem, "-signature", sig, inp],
                         capture_output=True, text=True)
    return res.returncode == 0


# Lives for the whole run: every signature below is checked against this file.
PEM_DIR = tempfile.TemporaryDirectory(prefix="checkpoint-vectors-")
try:
    PEM = public_pem(PEM_DIR.name)
except FileNotFoundError:
    measured_nothing(f"{OPENSSL!r} is not on this machine, so no signature can be verified")
except subprocess.CalledProcessError as e:
    measured_nothing(f"{OPENSSL!r} could not load the vector public key ({e.stderr.decode(errors='replace').strip()[:120]})")


# ----------------------------------------------------------------- the stream

stream = vec.get("stream") if isinstance(vec, dict) else None
if not isinstance(stream, dict) or not isinstance(stream.get("lines"), list) or not stream["lines"]:
    measured_nothing("the vector file carries no stream lines")
STREAM = stream.get("name")
if not isinstance(STREAM, str) or not STREAM_NAME.match(STREAM):
    fail(f"stream name {STREAM!r} is not a plain *.ndjson file name")
heads = []
prev_obj = None
for i, line in enumerate(stream["lines"]):
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as e:
        fail(f"stream line {i + 1} is not JSON ({e})")
        heads.append(None)
        continue
    if i == 0:
        if "prev_hash" in obj:
            fail("stream line 1 carries a prev_hash, so it is not the head of its chain")
    elif obj.get("prev_hash") != chain_hash(prev_obj):
        fail(f"stream line {i + 1} prev_hash does not chain from line {i}")
    heads.append(chain_hash(obj))
    prev_obj = obj


# ---------------------------------------------------------------- the records

records = vec.get("checkpoints")
if not isinstance(records, list) or not records:
    measured_nothing("the vector file carries no checkpoint records")

signed_verified = 0
unsigned = 0
prev_bytes = None
with tempfile.TemporaryDirectory() as tmp:
    for i, c in enumerate(records):
        where = f"checkpoint record {i + 1}"
        record = c.get("record") if isinstance(c, dict) else None
        if not isinstance(record, str):
            fail(f"{where} has no record text")
            continue
        try:
            obj = json.loads(record)
        except json.JSONDecodeError as e:
            fail(f"{where} is not JSON ({e})")
            continue
        if not isinstance(obj, dict):
            fail(f"{where} is not a JSON object")
            continue
        try:
            canonical = jcs(obj, where)
        except ValueError as e:
            fail(str(e))
            continue
        if canonical.decode() != record:
            fail(f"{where} is not the canonical serialization of its object (RFC 8785 order and whitespace)")

        members = set(obj)
        if members == COMMON | SIGNED:
            is_signed = True
        elif members == COMMON | UNSIGNED:
            is_signed = False
        else:
            extra = sorted(members - COMMON - SIGNED - UNSIGNED)
            missing = sorted(COMMON - members)
            fail(f"{where} has members outside format v1 (extra {extra}, missing {missing}); "
                 "a signed record has alg, kid and sig, an unsigned one has unsigned_reason")
            continue

        if obj.get("v") != 1 or isinstance(obj.get("v"), bool):
            fail(f"{where} has v other than 1")
        if obj.get("kind") not in KINDS:
            fail(f"{where} has kind {obj.get('kind')!r}, which is not checkpoint, close or resume")
        if obj.get("stream") != STREAM:
            fail(f"{where} names stream {obj.get('stream')!r}, not {STREAM!r}")
        count = obj.get("count")
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            fail(f"{where} has count {count!r}, which is not an integer of at least 1")
        elif count > len(stream["lines"]):
            fail(f"{where} counts {count} lines, but the stream holds {len(stream['lines'])}")
        elif heads[count - 1] is None:
            pass
        elif obj.get("head") != heads[count - 1]:
            fail(f"{where} head does not equal the chain hash of line {count} under 6.5")
        if not isinstance(obj.get("head"), str) or not HASH.match(obj["head"]):
            fail(f"{where} head is not sha256 followed by 64 lowercase hex digits")
        if not isinstance(obj.get("at"), str) or not AT.match(obj["at"]):
            fail(f"{where} at is not in the form YYYY-MM-DDTHH:MM:SS.sssZ")

        expected_prev = GENESIS if prev_bytes is None else "sha256:" + hashlib.sha256(prev_bytes).hexdigest()
        if obj.get("prev") != expected_prev:
            fail(f"{where} prev does not chain from the record before it")
        prev_bytes = record.encode()

        if is_signed:
            if obj.get("alg") != "ES256":
                fail(f"{where} alg is not ES256")
            if obj.get("kid") != key.get("kid"):
                fail(f"{where} kid is not the vector key's kid")
            try:
                raw = b64u_decode(obj["sig"])
            except (ValueError, TypeError):
                fail(f"{where} sig is not base64url")
                continue
            if len(raw) != 64:
                fail(f"{where} sig is {len(raw)} bytes, not 64 (r and s, 32 bytes each)")
                continue
            signing = jcs({k: v for k, v in obj.items() if k != "sig"}, where)
            if "signing_input" in c and c["signing_input"] != signing.decode():
                fail(f"{where} signing_input is not the JCS of the record without sig")
            if verifies(signing, raw, PEM, tmp):
                signed_verified += 1
            else:
                fail(f"{where} signature does not verify under the key its kid names")
        else:
            unsigned += 1
            if obj.get("unsigned_reason") != "key_expired":
                fail(f"{where} unsigned_reason {obj.get('unsigned_reason')!r} is not key_expired, the only v1 value")
            if "signing_input" in c:
                fail(f"{where} is unsigned but carries a signing_input")

if signed_verified == 0:
    measured_nothing("no signed checkpoint record verified, so no signature was checked")

# The quote SPEC 6.5.1 carries must be the first vector, byte for byte.
first = records[0].get("record") if isinstance(records[0], dict) else None
if not first or first not in spec:
    fail("SPEC 6.5.1 does not quote the first checkpoint record of examples/checkpoint-vectors.json")
if "examples/checkpoint-vectors.json" not in spec:
    fail("SPEC 6.5.1 does not name examples/checkpoint-vectors.json as its vector file")

# The known limit: the forged prefix must still verify, and must differ from the honest stream.
limit = vec.get("known_limit_forged_prefix")
forged = limit.get("lines") if isinstance(limit, dict) else None
if not isinstance(forged, list) or not forged:
    measured_nothing("the vector file carries no known_limit_forged_prefix")
if forged == stream["lines"]:
    fail("known_limit_forged_prefix equals the honest stream, so it forges nothing")
else:
    forged_heads = []
    fprev = None
    chain_ok = True
    for i, line in enumerate(forged):
        fobj = json.loads(line)
        if i > 0 and fobj.get("prev_hash") != chain_hash(fprev):
            chain_ok = False
        forged_heads.append(chain_hash(fobj))
        fprev = fobj
    if not chain_ok:
        fail("known_limit_forged_prefix does not chain, so it is not the limit SPEC 6.5.1 describes")
    for i, c in enumerate(records):
        if not isinstance(c, dict) or "record" not in c:
            continue
        robj = json.loads(c["record"])
        if isinstance(robj.get("count"), int) and 1 <= robj["count"] <= len(forged):
            if robj.get("head") != forged_heads[robj["count"] - 1]:
                fail(f"KNOWN LIMIT no longer holds: checkpoint record {i + 1} rejects the forged prefix, "
                     "so SPEC 6.5.1 and this check must be rewritten together")
                break
    if not any("KNOWN LIMIT" in p for p in problems):
        print("known limit reproduced: every checkpoint verifies against the forged prefix (SPEC 6.5.1)")

if problems:
    print(f"FAIL: {len(problems)} checkpoint vector problem(s):")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)

print(f"OK: {len(records)} checkpoint records ({signed_verified} signed and verified with openssl, "
      f"{unsigned} unsigned) over a {len(stream['lines'])}-line stream; every head, prev and "
      f"canonical form reproduces, and SPEC 6.5.1 quotes the first record.")
PY

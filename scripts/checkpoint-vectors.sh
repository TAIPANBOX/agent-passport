#!/usr/bin/env bash
# Enforces invariant 14 of CLAUDE.md: every checkpoint record in
# examples/checkpoint-vectors.json is the canonical serialization of its object,
# every signature verifies under the key its `kid` names, every `prev` chains from
# the genesis value, every `head` is the SPEC 6.5 chain hash of the stream line it
# counts, every `prefix` is the SHA-256 of the stream's bytes through that line,
# and the record SPEC 6.5.1 quotes is the first vector.
#
# THE NEGATIVE VARIANTS ARE PART OF THE CONTRACT
#
# negative_variants holds three streams that SPEC 6.5.1 says v1 must refuse: a
# forged earlier line with its successor re-linked, a whitespace-only change to an
# earlier line, and a truncated stream. Each one is a stream that passes the 6.5
# chain on its own, so the chain cannot be what refuses it. The gate requires that
# the stream chains, and that exactly the records named for it are refused, with
# the reason named, and every other record is accepted. A v1 verifier that accepted
# any of them would be wrong, and so would a gate that stopped checking.
#
# WHY THIS EXISTS
#
# SPEC 6.5.1 promises that a Go writer and a Rust writer produce the same bytes.
# Prose cannot hold that promise: two implementations agree only where they have
# been run against the same bytes. The vectors are those bytes, and this gate is
# the one place that re-derives every one of them from the stream and the key.
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
# vectors use (ASCII strings, integers, objects, arrays) and refuses anything
# outside that subset rather than guessing at RFC 8785's number rules. It does not
# check that a key statement certifies the key: that belongs to the service that
# certifies keys, and no vector here contains one. It does not check consistency
# across records written by different producers; it checks each record against the
# stream it is given.
#
# It refuses to report success when it measured nothing: no vector file, no 6.5.1
# heading, no stream line, no record, no signed record verified, no negative
# variant, or no openssl to verify a signature with. OPENSSL may name another
# binary (the teeth harness uses that to prove the refusal).

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
COMMON = {"v", "kind", "stream", "count", "head", "prefix", "at", "prev"}
SIGNED = {"alg", "kid", "sig"}
UNSIGNED = {"unsigned_reason"}
STREAM_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.ndjson$")
AT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
HASH = re.compile(r"^sha256:[0-9a-f]{64}$")


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
if not isinstance(vec, dict):
    measured_nothing("the vector file is not a JSON object")


# ------------------------------------------------------------- canonical JSON

def check_subset(value, where):
    if isinstance(value, bool) or value is None or isinstance(value, int):
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


def prefix_of(lines, count):
    # SPEC 6.5.1 prefix: SHA-256 of the stream file's bytes through line `count`,
    # each line followed by its LF. The file is exactly these lines, in order.
    data = "".join(line + "\n" for line in lines[:count]).encode()
    return "sha256:" + hashlib.sha256(data).hexdigest()


def b64u_encode(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64u_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# -------------------------------------------------------------- the public key

key = vec.get("key")
if not isinstance(key, dict):
    measured_nothing("the vector file carries no key")
if key.get("crv") != "P-256" or key.get("kty") != "EC":
    print("FAIL: key is not an EC P-256 key (crv and kty must say P-256 and EC)")
    sys.exit(1)
try:
    x = b64u_decode(key["x"])
    y = b64u_decode(key["y"])
except (KeyError, ValueError, TypeError) as e:
    measured_nothing(f"the key's x and y do not decode ({e})")
if len(x) != 32 or len(y) != 32:
    print("FAIL: key x and y are not 32 bytes each")
    sys.exit(1)
thumb = b64u_encode(hashlib.sha256(jcs({"crv": "P-256", "kty": "EC", "x": key["x"], "y": key["y"]})).digest())
if key.get("kid") != thumb:
    print(f"FAIL: key kid {key.get('kid')!r} is not the RFC 7638 thumbprint of its own x and y ({thumb})")
    sys.exit(1)
SPKI_P256 = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")

# Lives for the whole run: every signature below is checked against this file.
PEM_DIR = tempfile.TemporaryDirectory(prefix="checkpoint-vectors-")


def public_pem():
    der = os.path.join(PEM_DIR.name, "pub.der")
    pem = os.path.join(PEM_DIR.name, "pub.pem")
    open(der, "wb").write(SPKI_P256 + b"\x04" + x + y)
    subprocess.run([OPENSSL, "pkey", "-pubin", "-inform", "DER", "-in", der, "-out", pem],
                   check=True, capture_output=True)
    return pem


try:
    PEM = public_pem()
except FileNotFoundError:
    measured_nothing(f"{OPENSSL!r} is not on this machine, so no signature can be verified")
except subprocess.CalledProcessError as e:
    measured_nothing(f"{OPENSSL!r} could not load the vector public key "
                     f"({e.stderr.decode(errors='replace').strip()[:120]})")


def raw_to_der(raw):
    r = raw[:32].lstrip(b"\x00")
    s = raw[32:].lstrip(b"\x00")
    if r[:1] and r[0] & 0x80:
        r = b"\x00" + r
    if s[:1] and s[0] & 0x80:
        s = b"\x00" + s
    seq = b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
    return b"\x30" + bytes([len(seq)]) + seq


def verifies(message, raw_sig):
    inp = os.path.join(PEM_DIR.name, "msg")
    sig = os.path.join(PEM_DIR.name, "sig.der")
    open(inp, "wb").write(message)
    open(sig, "wb").write(raw_to_der(raw_sig))
    res = subprocess.run([OPENSSL, "dgst", "-sha256", "-verify", PEM, "-signature", sig, inp],
                         capture_output=True, text=True)
    return res.returncode == 0


# ------------------------------------------------------- stream and records

def stream_problems(name, lines):
    """The stream's own SPEC 6.5 chain. Returns (problems, heads)."""
    problems = []
    heads = []
    prev_obj = None
    for i, line in enumerate(lines):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as e:
            problems.append(f"{name} line {i + 1} is not JSON ({e})")
            heads.append(None)
            prev_obj = None
            continue
        if not isinstance(obj, dict):
            problems.append(f"{name} line {i + 1} is not a JSON object")
            heads.append(None)
            prev_obj = None
            continue
        if i == 0:
            if "prev_hash" in obj:
                problems.append(f"{name} line 1 carries a prev_hash, so it is not the head of its chain")
        elif prev_obj is None or obj.get("prev_hash") != chain_hash(prev_obj):
            problems.append(f"{name} line {i + 1} prev_hash does not chain from line {i}")
        heads.append(chain_hash(obj))
        prev_obj = obj
    return problems, heads


def record_problems(lines, heads, STREAM):
    """Every record checked against one stream. Returns {index: [problem, ...]}."""
    out = {}
    records = vec["checkpoints"]
    prev_bytes = None
    for i, c in enumerate(records):
        probs = out.setdefault(i, [])
        where = f"checkpoint record {i + 1}"
        record = c.get("record") if isinstance(c, dict) else None
        if not isinstance(record, str):
            probs.append(f"{where} has no record text")
            prev_bytes = None
            continue
        try:
            obj = json.loads(record)
        except json.JSONDecodeError as e:
            probs.append(f"{where} is not JSON ({e})")
            prev_bytes = record.encode()
            continue
        if not isinstance(obj, dict):
            probs.append(f"{where} is not a JSON object")
            prev_bytes = record.encode()
            continue
        try:
            canonical = jcs(obj, where)
        except ValueError as e:
            probs.append(str(e))
            prev_bytes = record.encode()
            continue
        if canonical.decode() != record:
            probs.append(f"{where} is not the canonical serialization of its object (RFC 8785 order and whitespace)")

        members = set(obj)
        if members == COMMON | SIGNED:
            is_signed = True
        elif members == COMMON | UNSIGNED:
            is_signed = False
        else:
            extra = sorted(members - COMMON - SIGNED - UNSIGNED)
            missing = sorted(COMMON - members)
            probs.append(f"{where} has members outside format v1 (extra {extra}, missing {missing}); "
                         "a signed record has alg, kid and sig, an unsigned one has unsigned_reason")
            is_signed = None

        if obj.get("v") != 1 or isinstance(obj.get("v"), bool):
            probs.append(f"{where} has v other than 1")
        if obj.get("kind") not in KINDS:
            probs.append(f"{where} has kind {obj.get('kind')!r}, which is not checkpoint, close or resume")
        if obj.get("stream") != STREAM:
            probs.append(f"{where} names stream {obj.get('stream')!r}, not {STREAM!r}")

        count = obj.get("count")
        count_ok = isinstance(count, int) and not isinstance(count, bool) and count >= 1
        if not count_ok:
            probs.append(f"{where} has count {count!r}, which is not an integer of at least 1")
        elif count > len(lines):
            probs.append(f"{where} is refused: the stream is shorter than the record's N bytes "
                         f"(it holds {len(lines)} lines, the record counts {count}), so the record is a truncation")
        else:
            if heads[count - 1] is not None and obj.get("head") != heads[count - 1]:
                probs.append(f"{where} head does not equal the chain hash of line {count} under 6.5")
            if obj.get("prefix") != prefix_of(lines, count):
                probs.append(f"{where} prefix does not match the SHA-256 of the first N bytes of the stream "
                             f"(N is the offset after line {count}'s LF)")

        if not isinstance(obj.get("head"), str) or not HASH.match(obj["head"]):
            probs.append(f"{where} head is not sha256 followed by 64 lowercase hex digits")
        if not isinstance(obj.get("prefix"), str) or not HASH.match(obj["prefix"]):
            probs.append(f"{where} prefix is not sha256 followed by 64 lowercase hex digits")
        if not isinstance(obj.get("at"), str) or not AT.match(obj["at"]):
            probs.append(f"{where} at is not in the form YYYY-MM-DDTHH:MM:SS.sssZ")

        expected_prev = GENESIS if prev_bytes is None else "sha256:" + hashlib.sha256(prev_bytes).hexdigest()
        if obj.get("prev") != expected_prev:
            probs.append(f"{where} prev does not chain from the record before it")
        prev_bytes = record.encode()

        if is_signed is True:
            if obj.get("alg") != "ES256":
                probs.append(f"{where} alg is not ES256")
            if obj.get("kid") != key.get("kid"):
                probs.append(f"{where} kid is not the vector key's kid")
            try:
                raw = b64u_decode(obj["sig"])
            except (ValueError, TypeError, KeyError):
                probs.append(f"{where} sig is not base64url")
                continue
            if len(raw) != 64:
                probs.append(f"{where} sig is {len(raw)} bytes, not 64 (r and s, 32 bytes each)")
                continue
            signing = jcs({k: v for k, v in obj.items() if k != "sig"}, where)
            if "signing_input" in c and c["signing_input"] != signing.decode():
                probs.append(f"{where} signing_input is not the JCS of the record without sig")
            if not verifies(signing, raw):
                probs.append(f"{where} signature does not verify under the key its kid names")
        elif is_signed is False:
            if obj.get("unsigned_reason") != "key_expired":
                probs.append(f"{where} unsigned_reason {obj.get('unsigned_reason')!r} is not key_expired, "
                             "the only v1 value")
            if "signing_input" in c:
                probs.append(f"{where} is unsigned but carries a signing_input")
    return out


problems = []
STREAM_BLOCK = vec.get("stream")
if not isinstance(STREAM_BLOCK, dict) or not isinstance(STREAM_BLOCK.get("lines"), list) \
        or not STREAM_BLOCK["lines"]:
    measured_nothing("the vector file carries no stream lines")
STREAM = STREAM_BLOCK.get("name")
if not isinstance(STREAM, str) or not STREAM_NAME.match(STREAM):
    problems.append(f"stream name {STREAM!r} is not a plain *.ndjson file name")
honest = STREAM_BLOCK["lines"]

records = vec.get("checkpoints")
if not isinstance(records, list) or not records:
    measured_nothing("the vector file carries no checkpoint records")
signed_count = sum(1 for c in records if isinstance(c, dict) and "signing_input" in c)

stream_probs, heads = stream_problems("the stream", honest)
problems.extend(stream_probs)
per_record = record_problems(honest, heads, STREAM)
for i, probs in per_record.items():
    problems.extend(probs)
if signed_count == 0:
    measured_nothing("no signed checkpoint record to verify a signature with")

# The quote SPEC 6.5.1 carries must be the first vector, byte for byte.
first = records[0].get("record") if isinstance(records[0], dict) else None
if not first or first not in spec:
    problems.append("SPEC 6.5.1 does not quote the first checkpoint record of examples/checkpoint-vectors.json")
if "examples/checkpoint-vectors.json" not in spec:
    problems.append("SPEC 6.5.1 does not name examples/checkpoint-vectors.json as its vector file")

# The negative variants: each stream chains on its own, and v1 refuses exactly the
# records named for it, for the reason named, and accepts the rest.
variants = vec.get("negative_variants")
if not isinstance(variants, dict) or not variants:
    measured_nothing("the vector file carries no negative_variants")
variant_checks = 0
for vname, v in sorted(variants.items()):
    vlines = v.get("lines") if isinstance(v, dict) else None
    refused = v.get("refused") if isinstance(v, dict) else None
    accepted = v.get("accepted") if isinstance(v, dict) else None
    if not isinstance(vlines, list) or not vlines or not isinstance(refused, dict) or not isinstance(accepted, list):
        problems.append(f"negative variant {vname!r} is malformed")
        continue
    if vlines == honest:
        problems.append(f"negative variant {vname!r} equals the honest stream, so it tests nothing")
        continue
    chain_probs, vheads = stream_problems(f"variant {vname!r}", vlines)
    if chain_probs:
        problems.append(f"negative variant {vname!r} does not pass the SPEC 6.5 chain on its own, "
                        f"so it does not isolate what it is meant to: {chain_probs[0]}")
        continue
    got = record_problems(vlines, vheads, STREAM)
    named = set(refused) | {str(a) for a in accepted}
    if named != {str(i) for i in range(len(records))}:
        problems.append(f"negative variant {vname!r} does not name every record exactly once")
        continue
    for idx_s, reason in sorted(refused.items()):
        idx = int(idx_s)
        msgs = got.get(idx, [])
        if not any(reason in m for m in msgs):
            problems.append(f"negative variant {vname!r}: record {idx + 1} was not refused with {reason!r} "
                            f"(v1 must refuse it; got {msgs[:1] or 'no problem at all'})")
        variant_checks += 1
    for idx in accepted:
        msgs = got.get(int(idx), [])
        if msgs:
            problems.append(f"negative variant {vname!r}: record {int(idx) + 1} was expected to be accepted "
                            f"and was refused: {msgs[0]}")
        variant_checks += 1
if variant_checks == 0:
    measured_nothing("no negative variant was checked")

if problems:
    print(f"FAIL: {len(problems)} checkpoint vector problem(s):")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)

print(f"OK: {len(records)} checkpoint records ({signed_count} signed and verified with openssl) over a "
      f"{len(honest)}-line stream; every head, prefix, prev and canonical form reproduces; "
      f"{len(variants)} negative variant(s) refused exactly as named; SPEC 6.5.1 quotes the first record.")
PY

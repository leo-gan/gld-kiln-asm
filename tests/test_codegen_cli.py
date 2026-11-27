#!/usr/bin/env python3
"""CLI negative validation & cross-language ctypes smoke tests for gld-kilngen-asm."""

import ctypes
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODEGEN = os.path.join(ROOT, "codegen", "gld-kilngen-asm")


def expect_reject(name: str, schema: dict, expect_substr: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        sp = os.path.join(td, f"{name}.json")
        out = os.path.join(td, "out")
        with open(sp, "w", encoding="utf-8") as f:
            json.dump(schema, f)
        proc = subprocess.run(
            [CODEGEN, "--schema", sp, "--out", out],
            capture_output=True, text=True, check=False,
        )
        assert proc.returncode != 0, f"{name}: expected nonzero exit, got 0"
        assert "SCHEMA:" in proc.stderr and expect_substr in proc.stderr, (
            f"{name}: expected '{expect_substr}' in stderr, got: {proc.stderr!r}"
        )


def test_negative_schemas() -> None:
    expect_reject("cyclic_ref", {
        "title": "Node",
        "$defs": {
            "A": {"type": "object", "properties": {"b": {"$ref": "#/$defs/B"}}},
            "B": {"type": "object", "properties": {"a": {"$ref": "#/$defs/A"}}},
        },
        "type": "object",
        "properties": {"a": {"$ref": "#/$defs/A"}},
    }, "cyclic $ref")

    expect_reject("missing_ref", {
        "title": "BadRef",
        "type": "object",
        "properties": {"x": {"$ref": "#/$defs/DoesNotExist"}},
    }, "missing $ref")

    expect_reject("remote_ref", {
        "title": "RemoteRef",
        "type": "object",
        "properties": {"x": {"$ref": "other.json#/$defs/X"}},
    }, "only local")

    expect_reject("unsupported_oneof", {
        "title": "Union",
        "type": "object",
        "properties": {"x": {"oneOf": [{"type": "integer"}, {"type": "string"}]}},
    }, "oneOf")

    expect_reject("missing_title", {
        "type": "object",
        "properties": {"x": {"type": "integer"}},
    }, "title")

    expect_reject("bad_int_format", {
        "title": "BadInt",
        "type": "object",
        "properties": {"x": {"type": "integer", "format": "int128"}},
    }, "integer format")

    expect_reject("keyword_field", {
        "title": "KwField",
        "type": "object",
        "properties": {"return": {"type": "integer"}},
    }, "valid C identifier")


def test_ctypes_so(so_path: str) -> None:
    lib = ctypes.CDLL(so_path)

    class Point(ctypes.Structure):
        _fields_ = [("x", ctypes.c_int32), ("y", ctypes.c_int32)]

    class Result(ctypes.Structure):
        _fields_ = [("bytes", ctypes.c_uint64), ("hash", ctypes.c_uint64)]

    buf = ctypes.create_string_buffer(64)
    res = Result()
    rc = lib.kiln_asm_encode_gen_point_framed(ctypes.byref(Point(9, -4)), buf, 64, None, ctypes.byref(res))
    assert rc == 0 and res.bytes == 24, f"encode failed rc={rc} bytes={res.bytes}"

    out = Point()
    rc = lib.kiln_asm_decode_gen_point_framed(buf, 24, ctypes.byref(out), None, None, ctypes.byref(res))
    assert rc == 0 and out.x == 9 and out.y == -4 and res.hash == 0xE66AC0386103C72F, (
        f"decode mismatch rc={rc} x={out.x} y={out.y} hash={res.hash:#x}"
    )


def main() -> int:
    test_negative_schemas()
    if len(sys.argv) > 1:
        test_ctypes_so(sys.argv[1])
    print("ALL gld-kilngen-asm CLI negative & ctypes FFI tests PASSED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

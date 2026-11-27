#!/usr/bin/env python3
"""gld-kilngen-asm: AOT Kiln Wire Format v2 JSON Schema -> x86-64 GAS Assembly + C11 header compiler.

Reads the normative Kiln v2 JSON Schema subset (§8 of kiln-wire-v2.md) plus
optional embedded `tensors` fields (`"format": "kiln-tensors"` or `"x-kiln": "tensors"`),
and emits:
  - <out>/<stem>.h : C11 struct definitions (with compile-time _Static_assert layout
                     checks), FNV-1a-64 schema hash macro, and C-ABI declarations.
  - <out>/<stem>.s : Self-contained Intel-syntax x86-64 GNU Assembly kernels and
                     System V AMD64 C-ABI wrappers linking against libkiln_asm.a.
  - <out>/<stem>.map (optional --emit-map): Linker version script exporting kiln_asm_*.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import sys
from typing import Dict, List, Optional, Set, Tuple

FNV1A_OFFSET = 0xCBF29CE484222325
FNV1A_PRIME = 0x00000100000001B3
MASK64 = 0xFFFFFFFFFFFFFFFF

C_KEYWORDS = {
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if",
    "inline", "int", "long", "register", "restrict", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
    "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof",
    "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn",
    "_Static_assert", "_Thread_local",
}

UNSUPPORTED_KEYWORDS = {
    "oneOf", "anyOf", "allOf", "not", "pattern", "patternProperties",
    "prefixItems", "enum", "const", "if", "then", "else", "dependentSchemas",
}

# kind -> (c_type, size, align, wire_width, hash_token)
SCALAR_INFO: Dict[str, Tuple[str, int, int, int, str]] = {
    "bool": ("uint8_t",  1, 1, 1, "bool"),
    "i8":   ("int8_t",   1, 1, 1, "i8"),
    "u8":   ("uint8_t",  1, 1, 1, "u8"),
    "i16":  ("int16_t",  2, 2, 2, "i16"),
    "u16":  ("uint16_t", 2, 2, 2, "u16"),
    "i32":  ("int32_t",  4, 4, 4, "i32"),
    "u32":  ("uint32_t", 4, 4, 4, "u32"),
    "f32":  ("float",    4, 4, 4, "f32"),
    "i64":  ("int64_t",  8, 8, 8, "i64"),
    "u64":  ("uint64_t", 8, 8, 8, "u64"),
    "int":  ("int64_t",  8, 8, 8, "int"),
    "uint": ("uint64_t", 8, 8, 8, "uint"),
    "f64":  ("double",   8, 8, 8, "f64"),
}

INT_FORMAT_MAP = {
    None:     "i64",
    "int8":   "i8",
    "int16":  "i16",
    "int32":  "i32",
    "int64":  "i64",
    "int":    "int",
    "uint8":  "u8",
    "uint16": "u16",
    "uint32": "u32",
    "uint64": "u64",
    "uint":   "uint",
}


class SchemaError(Exception):
    pass


def align_up(offset: int, align: int) -> int:
    return (offset + align - 1) & ~(align - 1)


def is_valid_ident(name: str) -> bool:
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name)) and name not in C_KEYWORDS


def to_snake(name: str) -> str:
    s1 = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    s2 = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s1)
    s3 = re.sub(r"[^A-Za-z0-9_]+", "_", s2).strip("_").lower()
    if not s3 or s3[0].isdigit():
        s3 = "t_" + s3
    return s3


def fnv1a_mix_token(h: int, tok: bytes) -> int:
    for b in tok:
        h = ((h ^ b) * FNV1A_PRIME) & MASK64
    return (h * FNV1A_PRIME) & MASK64


def fnv1a_hash_tokens(tokens: List[bytes]) -> int:
    h = FNV1A_OFFSET
    for t in tokens:
        h = fnv1a_mix_token(h, t)
    return h


# ------------------------------------------------------------------------------
# Type IR
# ------------------------------------------------------------------------------
@dataclasses.dataclass
class FieldSpec:
    name: str
    wire_name: str
    type_ir: "TypeIR"
    offset: int = 0


@dataclasses.dataclass
class TypeIR:
    kind: str  # scalar kind | "str" | "bytes" | "tensors" | "struct" | "opt" | "list" | "dict"
    name: str = ""
    c_type: str = ""
    sym: str = ""  # unique internal assembly suffix
    size: int = 0
    align: int = 1
    elem: Optional["TypeIR"] = None
    fields: List[FieldSpec] = dataclasses.field(default_factory=list)
    # For opt: offset of value field; for dict: entry_c_type, entry_size, entry_align, entry_val_off
    val_off: int = 0
    entry_c_type: str = ""
    entry_size: int = 0
    entry_align: int = 8

    def is_scalar(self) -> bool:
        return self.kind in SCALAR_INFO

    def is_pod_list(self) -> bool:
        return self.kind == "list" and self.elem is not None and self.elem.is_scalar() and self.elem.kind != "bool"

    def is_bool_list(self) -> bool:
        return self.kind == "list" and self.elem is not None and self.elem.kind == "bool"

    def min_wire_size(self) -> int:
        if self.kind in SCALAR_INFO:
            return SCALAR_INFO[self.kind][3]
        if self.kind in ("str", "bytes", "list", "dict"):
            return 4
        if self.kind == "opt":
            return 1
        if self.kind == "tensors":
            return 64
        if self.kind == "struct":
            return sum(f.type_ir.min_wire_size() for f in self.fields)
        raise SchemaError(f"unknown kind {self.kind}")

    def schema_tokens(self) -> List[bytes]:
        if self.kind in SCALAR_INFO:
            return [SCALAR_INFO[self.kind][4].encode("ascii")]
        if self.kind == "str":
            return [b"str"]
        if self.kind == "bytes":
            return [b"list<", b"u8", b">"]
        if self.kind == "tensors":
            return [b"tensors"]
        if self.kind == "list":
            assert self.elem is not None
            return [b"list<"] + self.elem.schema_tokens() + [b">"]
        if self.kind == "opt":
            assert self.elem is not None
            return [b"opt<"] + self.elem.schema_tokens() + [b">"]
        if self.kind == "dict":
            assert self.elem is not None
            return [b"dict<str,"] + self.elem.schema_tokens() + [b">"]
        if self.kind == "struct":
            toks: List[bytes] = [b"struct{"]
            for f in self.fields:
                toks.append(f.wire_name.encode("utf-8"))
                toks.append(b":")
                toks.extend(f.type_ir.schema_tokens())
                toks.append(b",")
            toks.append(b"}")
            return toks
        raise SchemaError(f"unknown kind {self.kind}")

    def schema_hash(self) -> int:
        return fnv1a_hash_tokens(self.schema_tokens())

    def is_leaf_struct(self) -> bool:
        if self.kind != "struct":
            return False
        for f in self.fields:
            if f.type_ir.kind in ("struct", "opt", "list", "dict", "tensors", "str", "bytes"):
                return False
        return True


# ------------------------------------------------------------------------------
# Schema Parser & Layout Engine
# ------------------------------------------------------------------------------
class SchemaCompiler:
    def __init__(self, root_json: dict, stem: str, prefix: Optional[str]):
        self.root_json = root_json
        self.stem = to_snake(stem)
        self.prefix = to_snake(prefix) if prefix else ""
        self.ns = f"{self.prefix}_{self.stem}" if self.prefix else self.stem
        self.defs_json: Dict[str, dict] = {}
        self.named_types: Dict[str, TypeIR] = {}
        self.visiting: Set[str] = set()
        self.ordered_defs: List[TypeIR] = []  # topological order of all typedefs to emit
        self.container_cache: Dict[Tuple[str, str, str], TypeIR] = {}
        self.used_names: Set[str] = set()
        self.root_struct: Optional[TypeIR] = None

    def _c_type_name(self, base: str, is_root: bool = False) -> str:
        s = to_snake(base)
        if self.prefix:
            cand = f"{self.prefix}_{s}_t" if is_root else f"{self.prefix}_{self.stem}_{s}_t"
        else:
            cand = f"kiln_{s}_t" if is_root else f"kiln_{self.stem}_{s}_t"
        if cand in self.used_names:
            idx = 2
            while f"{cand[:-2]}_{idx}_t" in self.used_names:
                idx += 1
            cand = f"{cand[:-2]}_{idx}_t"
        self.used_names.add(cand)
        return cand

    def _public_fn_suffix(self, base: str) -> str:
        s = to_snake(base)
        return f"{self.prefix}_{s}" if self.prefix else s

    def _check_unsupported(self, node: dict) -> None:
        for k in UNSUPPORTED_KEYWORDS:
            if k in node:
                raise SchemaError(f"SCHEMA: unsupported JSON Schema keyword '{k}'")

    def compile(self) -> TypeIR:
        if not isinstance(self.root_json, dict):
            raise SchemaError("SCHEMA: root schema must be a JSON object")
        title = self.root_json.get("title")
        if not isinstance(title, str) or not title.strip():
            raise SchemaError("SCHEMA: root schema must specify a non-empty string 'title'")
        if not is_valid_ident(title):
            raise SchemaError(f"SCHEMA: root title '{title}' is not a valid C identifier")

        defs = self.root_json.get("$defs")
        if defs is not None:
            if not isinstance(defs, dict):
                raise SchemaError("SCHEMA: '$defs' must be a JSON object")
            for k, v in defs.items():
                if not is_valid_ident(k):
                    raise SchemaError(f"SCHEMA: $defs key '{k}' is not a valid C identifier")
                if not isinstance(v, dict):
                    raise SchemaError(f"SCHEMA: $defs['{k}'] must be a JSON object")
                self.defs_json[k] = v

        # Compile root struct (resolving referenced $defs lazily with cycle detection)
        root = self._parse_node(self.root_json, title, is_root=True)
        if root.kind != "struct":
            raise SchemaError("SCHEMA: root schema must be an object with 'properties'")
        self.root_struct = root
        return root

    def _make_scalar(self, kind: str) -> TypeIR:
        ctype, sz, al, _, _ = SCALAR_INFO[kind]
        return TypeIR(kind=kind, name=kind, c_type=ctype, sym=kind, size=sz, align=al)

    def _make_opt(self, elem: TypeIR) -> TypeIR:
        key = ("opt", elem.kind, elem.c_type)
        if key in self.container_cache:
            return self.container_cache[key]
        short = to_snake(elem.name)
        c_type = self._c_type_name(f"opt_{short}")
        val_off = align_up(1, elem.align)
        size = align_up(val_off + elem.size, elem.align)
        t = TypeIR(
            kind="opt",
            name=f"opt_{short}",
            c_type=c_type,
            sym=f"{self.ns}_{c_type[:-2]}",
            size=size,
            align=elem.align,
            elem=elem,
            val_off=val_off,
        )
        self.container_cache[key] = t
        self.ordered_defs.append(t)
        return t

    def _make_list(self, elem: TypeIR) -> TypeIR:
        key = ("list", elem.kind, elem.c_type)
        if key in self.container_cache:
            return self.container_cache[key]
        short = to_snake(elem.name)
        c_type = self._c_type_name(f"list_{short}")
        t = TypeIR(
            kind="list",
            name=f"list_{short}",
            c_type=c_type,
            sym=f"{self.ns}_{c_type[:-2]}",
            size=16,
            align=8,
            elem=elem,
        )
        self.container_cache[key] = t
        self.ordered_defs.append(t)
        return t

    def _make_dict(self, val_ir: TypeIR) -> TypeIR:
        key = ("dict", val_ir.kind, val_ir.c_type)
        if key in self.container_cache:
            return self.container_cache[key]
        short = to_snake(val_ir.name)
        entry_c_type = self._c_type_name(f"dict_{short}_entry")
        c_type = self._c_type_name(f"dict_{short}")
        # Entry layout: { kiln_str_t key (16 B, align 8); V val; }
        val_off = align_up(16, val_ir.align)
        entry_align = max(8, val_ir.align)
        entry_size = align_up(val_off + val_ir.size, entry_align)
        t = TypeIR(
            kind="dict",
            name=f"dict_{short}",
            c_type=c_type,
            sym=f"{self.ns}_{c_type[:-2]}",
            size=16,
            align=8,
            elem=val_ir,
            val_off=val_off,
            entry_c_type=entry_c_type,
            entry_size=entry_size,
            entry_align=entry_align,
        )
        self.container_cache[key] = t
        self.ordered_defs.append(t)
        return t

    def _parse_struct(self, node: dict, name: str, is_root: bool) -> TypeIR:
        props = node.get("properties")
        if not isinstance(props, dict):
            raise SchemaError(f"SCHEMA: struct '{name}' missing 'properties' object")

        req_raw = node.get("required")
        if req_raw is None:
            req_set: Optional[Set[str]] = None
        else:
            if not isinstance(req_raw, list) or not all(isinstance(x, str) for x in req_raw):
                raise SchemaError(f"SCHEMA: struct '{name}' 'required' must be an array of strings")
            req_set = set(req_raw)

        fields: List[FieldSpec] = []
        offset = 0
        max_align = 1
        for fname, fschema in props.items():
            if not is_valid_ident(fname):
                raise SchemaError(f"SCHEMA: field '{fname}' in '{name}' is not a valid C identifier")
            ft = self._parse_node(fschema, f"{name}_{fname}", is_root=False)
            is_req = True if req_set is None else (fname in req_set)
            if not is_req:
                ft = self._make_opt(ft)
            offset = align_up(offset, ft.align)
            fields.append(FieldSpec(name=fname, wire_name=fname, type_ir=ft, offset=offset))
            offset += ft.size
            if ft.align > max_align:
                max_align = ft.align

        if not fields:
            # Standard ISO C11 prohibits 0-size structs; emit 1-byte dummy field.
            size = 1
            max_align = 1
        else:
            size = align_up(offset, max_align)

        c_type = self._c_type_name(name, is_root=is_root)
        sym = f"{self.ns}_{c_type[:-2]}"
        st = TypeIR(
            kind="struct",
            name=name,
            c_type=c_type,
            sym=sym,
            size=size,
            align=max_align,
            fields=fields,
        )
        self.ordered_defs.append(st)
        return st

    def _parse_node(self, node: dict, hint_name: str, is_root: bool) -> TypeIR:
        if not isinstance(node, dict):
            raise SchemaError(f"SCHEMA: node '{hint_name}' must be a JSON object")
        self._check_unsupported(node)

        if "$ref" in node:
            ref = node["$ref"]
            prefix = "#/$defs/"
            if not isinstance(ref, str) or not ref.startswith(prefix):
                raise SchemaError(f"SCHEMA: only local '#/$defs/Name' $ref is supported (got '{ref}')")
            def_name = ref[len(prefix):]
            if def_name not in self.defs_json:
                raise SchemaError(f"SCHEMA: missing $ref target '{ref}'")
            if def_name in self.visiting:
                raise SchemaError(f"SCHEMA: cyclic $ref detected at '{ref}'")
            if def_name in self.named_types:
                return self.named_types[def_name]
            self.visiting.add(def_name)
            resolved = self._parse_node(self.defs_json[def_name], def_name, is_root=False)
            self.visiting.remove(def_name)
            self.named_types[def_name] = resolved
            return resolved

        if node.get("x-kiln") == "tensors" or node.get("format") == "kiln-tensors":
            return TypeIR(
                kind="tensors", name="tensors", c_type="kiln_tensor_dir_t",
                sym="tensors", size=32, align=8,
            )

        typ = node.get("type")
        if not isinstance(typ, str):
            raise SchemaError(f"SCHEMA: node '{hint_name}' is missing string 'type'")
        fmt = node.get("format")
        if fmt is not None and not isinstance(fmt, str):
            raise SchemaError(f"SCHEMA: node '{hint_name}' 'format' must be a string")

        if typ == "boolean":
            if fmt is not None:
                raise SchemaError(f"SCHEMA: unsupported boolean format '{fmt}'")
            return self._make_scalar("bool")

        if typ == "integer":
            if fmt not in INT_FORMAT_MAP:
                raise SchemaError(f"SCHEMA: unsupported integer format '{fmt}'")
            return self._make_scalar(INT_FORMAT_MAP[fmt])

        if typ == "number":
            if fmt in (None, "double"):
                return self._make_scalar("f64")
            if fmt == "float":
                return self._make_scalar("f32")
            raise SchemaError(f"SCHEMA: unsupported number format '{fmt}'")

        if typ == "string":
            if fmt is None:
                return TypeIR(kind="str", name="str", c_type="kiln_str_t", sym="str", size=16, align=8)
            if fmt == "binary":
                return TypeIR(kind="bytes", name="bytes", c_type="kiln_bytes_t", sym="bytes", size=16, align=8)
            raise SchemaError(f"SCHEMA: unsupported string format '{fmt}'")

        if typ == "array":
            items = node.get("items")
            if not isinstance(items, dict):
                raise SchemaError(f"SCHEMA: array '{hint_name}' missing 'items' schema")
            elem = self._parse_node(items, f"{hint_name}_item", is_root=False)
            return self._make_list(elem)

        if typ == "object":
            has_props = "properties" in node
            has_extra = "additionalProperties" in node
            if has_props:
                return self._parse_struct(node, hint_name, is_root=is_root)
            if has_extra:
                extra = node["additionalProperties"]
                if not isinstance(extra, dict):
                    raise SchemaError(f"SCHEMA: dict '{hint_name}' 'additionalProperties' must be a schema object")
                val_ir = self._parse_node(extra, f"{hint_name}_val", is_root=False)
                return self._make_dict(val_ir)
            raise SchemaError(f"SCHEMA: object '{hint_name}' needs 'properties' or 'additionalProperties'")

        raise SchemaError(f"SCHEMA: unsupported JSON Schema type '{typ}'")


# ------------------------------------------------------------------------------
# C11 Header Emitter
# ------------------------------------------------------------------------------
def emit_header(comp: SchemaCompiler, stem: str) -> str:
    assert comp.root_struct is not None
    root = comp.root_struct
    guard = re.sub(r"[^A-Z0-9_]", "_", f"KILN_GEN_{comp.ns}_H".upper())
    pub_suffix = comp._public_fn_suffix(root.name)
    hash_macro = (
        f"{comp.prefix.upper()}_HASH_{to_snake(root.name).upper()}"
        if comp.prefix
        else f"KILN_HASH_{to_snake(root.name).upper()}"
    )
    hval = root.schema_hash()

    out: List[str] = [
        f"/* Generated by gld-kilngen-asm from {stem}.json. Do not edit. */",
        f"#ifndef {guard}",
        f"#define {guard}",
        "",
        '#include "kiln_asm.h"',
        "#include <stddef.h>",
        "#include <stdint.h>",
        "",
        "#ifdef __cplusplus",
        'extern "C" {',
        "#endif",
        "",
        f"#define {hash_macro} 0x{hval:016X}ULL",
        "",
    ]

    for t in comp.ordered_defs:
        if t.kind == "opt":
            assert t.elem is not None
            out.append(f"typedef struct {t.c_type} {{")
            out.append("    uint8_t present;")
            out.append(f"    {t.elem.c_type} value;")
            out.append(f"}} {t.c_type};")
            out.append(f'_Static_assert(offsetof({t.c_type}, present) == 0, "{t.c_type}.present");')
            out.append(f'_Static_assert(offsetof({t.c_type}, value) == {t.val_off}, "{t.c_type}.value");')
            out.append(f'_Static_assert(sizeof({t.c_type}) == {t.size}, "sizeof({t.c_type})");')
            out.append("")
        elif t.kind == "list":
            assert t.elem is not None
            out.append(f"typedef struct {t.c_type} {{")
            out.append(f"    {t.elem.c_type} *items;")
            out.append("    uint64_t count;")
            out.append(f"}} {t.c_type};")
            out.append(f'_Static_assert(offsetof({t.c_type}, items) == 0, "{t.c_type}.items");')
            out.append(f'_Static_assert(offsetof({t.c_type}, count) == 8, "{t.c_type}.count");')
            out.append(f'_Static_assert(sizeof({t.c_type}) == 16, "sizeof({t.c_type})");')
            out.append("")
        elif t.kind == "dict":
            assert t.elem is not None
            out.append(f"typedef struct {t.entry_c_type} {{")
            out.append("    kiln_str_t key;")
            out.append(f"    {t.elem.c_type} val;")
            out.append(f"}} {t.entry_c_type};")
            out.append(f'_Static_assert(offsetof({t.entry_c_type}, key) == 0, "{t.entry_c_type}.key");')
            out.append(f'_Static_assert(offsetof({t.entry_c_type}, val) == {t.val_off}, "{t.entry_c_type}.val");')
            out.append(f'_Static_assert(sizeof({t.entry_c_type}) == {t.entry_size}, "sizeof({t.entry_c_type})");')
            out.append("")
            out.append(f"typedef struct {t.c_type} {{")
            out.append(f"    {t.entry_c_type} *entries;")
            out.append("    uint64_t count;")
            out.append(f"}} {t.c_type};")
            out.append(f'_Static_assert(offsetof({t.c_type}, entries) == 0, "{t.c_type}.entries");')
            out.append(f'_Static_assert(offsetof({t.c_type}, count) == 8, "{t.c_type}.count");')
            out.append(f'_Static_assert(sizeof({t.c_type}) == 16, "sizeof({t.c_type})");')
            out.append("")
        elif t.kind == "struct":
            out.append(f"typedef struct {t.c_type} {{")
            if not t.fields:
                out.append("    uint8_t _empty;")
            else:
                for f in t.fields:
                    out.append(f"    {f.type_ir.c_type} {f.name};")
            out.append(f"}} {t.c_type};")
            for f in t.fields:
                out.append(f'_Static_assert(offsetof({t.c_type}, {f.name}) == {f.offset}, "{t.c_type}.{f.name}");')
            out.append(f'_Static_assert(sizeof({t.c_type}) == {t.size}, "sizeof({t.c_type})");')
            out.append("")

    # Public C-ABI function declarations for root struct (+ framed + batch)
    out.extend([
        f"kiln_err_t kiln_asm_encode_{pub_suffix}(",
        f"    const {root.c_type} *in, uint8_t *dst, size_t cap,",
        "    const kiln_read_opts_t *opts, kiln_result_t *res);",
        "",
        f"kiln_err_t kiln_asm_decode_{pub_suffix}(",
        f"    const uint8_t *src, size_t len, {root.c_type} *out,",
        "    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);",
        "",
        f"kiln_err_t kiln_asm_encode_{pub_suffix}_framed(",
        f"    const {root.c_type} *in, uint8_t *dst, size_t cap,",
        "    const kiln_read_opts_t *opts, kiln_result_t *res);",
        "",
        f"kiln_err_t kiln_asm_decode_{pub_suffix}_framed(",
        f"    const uint8_t *src, size_t len, {root.c_type} *out,",
        "    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);",
        "",
        f"kiln_err_t kiln_asm_encode_{pub_suffix}_batch(",
        f"    const {root.c_type} *items, size_t count, uint8_t *dst, size_t cap,",
        "    const kiln_read_opts_t *opts, kiln_result_t *res);",
        "",
        f"kiln_err_t kiln_asm_decode_{pub_suffix}_batch(",
        f"    const uint8_t *src, size_t len, {root.c_type} **out_items, size_t *out_count,",
        "    kiln_arena_t *arena, const kiln_read_opts_t *opts, kiln_result_t *res);",
        "",
        "#ifdef __cplusplus",
        "}",
        "#endif",
        "",
        f"#endif /* {guard} */",
        "",
    ])
    return "\n".join(out)


# ------------------------------------------------------------------------------
# x86-64 GAS Assembly Emitter
# ------------------------------------------------------------------------------
ASM_PREAMBLE = """\
.intel_syntax noprefix

# Self-contained Kiln v2 ABI constants (mirrors arch/x86_64/defs.inc)
.equ KILN_OK,            0
.equ KILN_ERR_FRAME,     1
.equ KILN_ERR_SCHEMA,    2
.equ KILN_ERR_LIMIT,     3
.equ KILN_ERR_EOF,       4
.equ KILN_ERR_TYPE,      5
.equ KILN_ERR_UTF8,      6
.equ KILN_ERR_TRAILING,  7
.equ KILN_ERR_DEPTH,     8

.equ KILN_CAP_DEFAULT,   16777216
.equ KILN_DEPTH_DEFAULT, 64

.equ FLAG_CHECK_UTF8,    0x100
.equ FLAG_SLOP32,        0x200
.equ FLAG_OWNED,         0x400
.equ FLAG_EMBEDDED,      0x800
.equ FLAG_COPY_AVX2,     0x1000
.equ FLAG_COPY_NT,       0x2000

.equ KILN_OPT_TRUSTED,   0x01
.equ KILN_OPT_OWNED,     0x02
.equ KILN_OPT_SLOP32,    0x04
.equ KILN_OPT_EMBEDDED,  0x08
.equ KILN_OPT_COPY_AVX2, 0x10
.equ KILN_OPT_COPY_NT,   0x20

.equ CTX_BASE_PTR,       0
.equ CTX_ARENA_END,      8
.equ CTX_MAX_COUNT,      16
.equ CTX_MAX_BYTES,      24
.equ CTX_MAX_DEPTH,      32

.equ ARENA_CUR,          8
.equ ARENA_END,          16

.equ OPTS_MAX_COUNT,     0
.equ OPTS_MAX_BYTES,     8
.equ OPTS_MAX_DEPTH,     16
.equ OPTS_FLAGS,         20

.equ RES_BYTES,          0
.equ RES_HASH,           8

.macro KILN_FAIL code
    mov     eax, \\code
    mov     rdx, r12
    sub     rdx, QWORD PTR [rbx + CTX_BASE_PTR]
    stc
    ret
.endm

.macro KILN_OK_RET
    xor     eax, eax
    ret
.endm

.macro ABI_PROLOGUE
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72
    lea     rbx, [rbp - 80]
.endm

.macro ABI_EPILOGUE
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
.endm

.text

# File-local C-ABI context setup & result helpers
.p2align 4
.Lgen_setup_ctx:
    mov     r12, rdi
    lea     r13, [rdi + rsi]
    mov     QWORD PTR [rbx + CTX_BASE_PTR], rdi
    xor     r14, r14
    mov     QWORD PTR [rbx + CTX_ARENA_END], r14
    test    rdx, rdx
    jz      .Lgsc_no_arena
    mov     r14, QWORD PTR [rdx + ARENA_CUR]
    mov     rax, QWORD PTR [rdx + ARENA_END]
    mov     QWORD PTR [rbx + CTX_ARENA_END], rax
.Lgsc_no_arena:
    mov     rax, KILN_CAP_DEFAULT
    mov     QWORD PTR [rbx + CTX_MAX_COUNT], rax
    mov     QWORD PTR [rbx + CTX_MAX_BYTES], rax
    mov     QWORD PTR [rbx + CTX_MAX_DEPTH], KILN_DEPTH_DEFAULT
    mov     r15, FLAG_CHECK_UTF8
    test    rcx, rcx
    jz      .Lgsc_done
    mov     rax, QWORD PTR [rcx + OPTS_MAX_COUNT]
    test    rax, rax
    jz      .Lgsc_mc
    mov     QWORD PTR [rbx + CTX_MAX_COUNT], rax
.Lgsc_mc:
    mov     rax, QWORD PTR [rcx + OPTS_MAX_BYTES]
    test    rax, rax
    jz      .Lgsc_mb
    mov     QWORD PTR [rbx + CTX_MAX_BYTES], rax
.Lgsc_mb:
    mov     eax, DWORD PTR [rcx + OPTS_MAX_DEPTH]
    test    eax, eax
    jz      .Lgsc_md
    cmp     eax, 255
    jbe     .Lgsc_md_ok
    mov     eax, 255
.Lgsc_md_ok:
    mov     QWORD PTR [rbx + CTX_MAX_DEPTH], rax
.Lgsc_md:
    mov     eax, DWORD PTR [rcx + OPTS_FLAGS]
    test    eax, KILN_OPT_TRUSTED
    jz      .Lgsc_f1
    and     r15, ~FLAG_CHECK_UTF8
.Lgsc_f1:
    test    eax, KILN_OPT_OWNED
    jz      .Lgsc_f2
    or      r15, FLAG_OWNED
.Lgsc_f2:
    test    eax, KILN_OPT_SLOP32
    jz      .Lgsc_f3
    or      r15, FLAG_SLOP32
.Lgsc_f3:
    test    eax, KILN_OPT_EMBEDDED
    jz      .Lgsc_f4
    or      r15, FLAG_EMBEDDED
.Lgsc_f4:
    test    eax, KILN_OPT_COPY_AVX2
    jz      .Lgsc_f5
    or      r15, FLAG_COPY_AVX2
.Lgsc_f5:
    test    eax, KILN_OPT_COPY_NT
    jz      .Lgsc_done
    or      r15, FLAG_COPY_NT
.Lgsc_done:
    ret

.p2align 4
.Lgen_finish_nohash:
    mov     esi, 0
.Lgen_finish:
    jc      .Lgf_err
    test    rdi, rdi
    jz      .Lgf_ok
    mov     rcx, r12
    sub     rcx, QWORD PTR [rbx + CTX_BASE_PTR]
    mov     QWORD PTR [rdi + RES_BYTES], rcx
    mov     QWORD PTR [rdi + RES_HASH], rsi
.Lgf_ok:
    xor     eax, eax
    ret
.Lgf_err:
    test    rdi, rdi
    jz      .Lgf_err_ret
    mov     QWORD PTR [rdi + RES_BYTES], rdx
    mov     QWORD PTR [rdi + RES_HASH], 0
.Lgf_err_ret:
    ret

# Inlined short-string fast-path macros (0..8 B overlapping GPR/SWAR; >8 B or non-ASCII falls back)
.macro GEN_ENC_STR_INLINE ptr_off, len_off, err_limit, err_prop
    mov     r8, QWORD PTR [rdi + \\len_off]
    cmp     r8, QWORD PTR [rbx + CTX_MAX_BYTES]
    ja      \\err_limit
    mov     eax, 0xFFFFFFFF
    cmp     r8, rax
    ja      \\err_limit
    lea     rcx, [r8 + 4]
    mov     rax, r13
    sub     rax, r12
    cmp     rax, rcx
    jb      \\err_limit
    mov     DWORD PTR [r12], r8d
    add     r12, 4
    test    r8, r8
    jz      9f
    mov     rsi, QWORD PTR [rdi + \\ptr_off]
    cmp     r8, 8
    ja      7f
    cmp     r8, 4
    jb      5f
    mov     eax, DWORD PTR [rsi]
    mov     ecx, DWORD PTR [rsi + r8 - 4]
    mov     DWORD PTR [r12], eax
    mov     DWORD PTR [r12 + r8 - 4], ecx
    add     r12, r8
    jmp     9f
5:
    cmp     r8, 2
    jb      6f
    movzx   eax, WORD PTR [rsi]
    movzx   ecx, WORD PTR [rsi + r8 - 2]
    mov     WORD PTR [r12], ax
    mov     WORD PTR [r12 + r8 - 2], cx
    add     r12, r8
    jmp     9f
6:
    movzx   eax, BYTE PTR [rsi]
    mov     BYTE PTR [r12], al
    inc     r12
    jmp     9f
7:
    mov     rdx, r8
    mov     rdi, r12
    add     r12, r8
    call    kiln_core_memcpy_fast
    mov     rdi, QWORD PTR [rbp - 8]
9:
.endm

.macro GEN_DEC_STR_INLINE ptr_off, len_off, err_eof, err_limit, err_prop
    mov     rcx, r13
    sub     rcx, r12
    cmp     rcx, 4
    jb      \\err_eof
    mov     edx, DWORD PTR [r12]
    cmp     rdx, QWORD PTR [rbx + CTX_MAX_BYTES]
    ja      \\err_limit
    sub     rcx, 4
    cmp     rdx, rcx
    ja      \\err_eof
    cmp     rdx, 8
    ja      8f
    cmp     rdx, 4
    jb      1f
    mov     eax, DWORD PTR [r12 + 4]
    mov     ecx, DWORD PTR [r12 + rdx]
    test    r15, FLAG_CHECK_UTF8
    jz      2f
    mov     r8d, eax
    or      r8d, ecx
    test    r8d, 0x80808080
    jnz     8f
2:
    test    r15, FLAG_OWNED
    jnz     3f
    lea     r8, [r12 + 4]
    mov     QWORD PTR [rdi + \\ptr_off], r8
    mov     QWORD PTR [rdi + \\len_off], rdx
    lea     r12, [r8 + rdx]
    jmp     9f
3:
    mov     r9, QWORD PTR [rbx + CTX_ARENA_END]
    sub     r9, r14
    cmp     r9, rdx
    jb      \\err_limit
    mov     DWORD PTR [r14], eax
    mov     DWORD PTR [r14 + rdx - 4], ecx
    mov     QWORD PTR [rdi + \\ptr_off], r14
    mov     QWORD PTR [rdi + \\len_off], rdx
    add     r14, rdx
    lea     r12, [r12 + rdx + 4]
    jmp     9f
1:
    test    rdx, rdx
    jnz     4f
    add     r12, 4
    mov     rax, r12
    test    r15, FLAG_OWNED
    cmovnz  rax, r14
    mov     QWORD PTR [rdi + \\ptr_off], rax
    mov     QWORD PTR [rdi + \\len_off], 0
    jmp     9f
4:
    cmp     rdx, 2
    jb      6f
    movzx   eax, WORD PTR [r12 + 4]
    movzx   ecx, WORD PTR [r12 + rdx + 2]
    test    r15, FLAG_CHECK_UTF8
    jz      5f
    mov     r8d, eax
    or      r8d, ecx
    test    r8d, 0x8080
    jnz     8f
5:
    test    r15, FLAG_OWNED
    jnz     7f
    lea     r8, [r12 + 4]
    mov     QWORD PTR [rdi + \\ptr_off], r8
    mov     QWORD PTR [rdi + \\len_off], rdx
    lea     r12, [r8 + rdx]
    jmp     9f
7:
    mov     r9, QWORD PTR [rbx + CTX_ARENA_END]
    sub     r9, r14
    cmp     r9, rdx
    jb      \\err_limit
    mov     WORD PTR [r14], ax
    mov     WORD PTR [r14 + rdx - 2], cx
    mov     QWORD PTR [rdi + \\ptr_off], r14
    mov     QWORD PTR [rdi + \\len_off], rdx
    add     r14, rdx
    lea     r12, [r12 + rdx + 4]
    jmp     9f
6:
    movzx   eax, BYTE PTR [r12 + 4]
    test    r15, FLAG_CHECK_UTF8
    jz      10f
    test    al, 0x80
    jnz     8f
10:
    test    r15, FLAG_OWNED
    jnz     11f
    lea     r8, [r12 + 4]
    mov     QWORD PTR [rdi + \\ptr_off], r8
    mov     QWORD PTR [rdi + \\len_off], 1
    add     r12, 5
    jmp     9f
11:
    cmp     r14, QWORD PTR [rbx + CTX_ARENA_END]
    jae     \\err_limit
    mov     BYTE PTR [r14], al
    mov     QWORD PTR [rdi + \\ptr_off], r14
    mov     QWORD PTR [rdi + \\len_off], 1
    inc     r14
    add     r12, 5
    jmp     9f
8:
    call    kiln_core_dec_str
    jc      \\err_prop
    mov     rdi, QWORD PTR [rbp - 8]
    mov     QWORD PTR [rdi + \\ptr_off], rax
    mov     QWORD PTR [rdi + \\len_off], rdx
9:
.endm
"""


class AsmEmitter:
    def __init__(self, comp: SchemaCompiler, stem: str):
        self.comp = comp
        self.stem = stem
        self.lines: List[str] = [
            f"# Generated by gld-kilngen-asm from {stem}.json. Do not edit.",
            ASM_PREAMBLE,
        ]
        self.lbl_seq = 0

    def new_lbl(self, tag: str) -> str:
        self.lbl_seq += 1
        return f".L_{tag}_{self.lbl_seq}"

    def emit(self, line: str = "") -> None:
        self.lines.append(line)

    # Emit inline scalar store from [src_reg + src_off] -> [r12 + wire_off]
    def emit_scalar_store(self, kind: str, src_reg: str, src_off: int, wire_off: int) -> None:
        w = SCALAR_INFO[kind][3]
        if kind == "bool":
            self.emit(f"    movzx   eax, BYTE PTR [{src_reg} + {src_off}]")
            self.emit("    test    al, al")
            self.emit("    setne   al")
            self.emit(f"    mov     BYTE PTR [r12 + {wire_off}], al")
        elif w == 1:
            self.emit(f"    movzx   eax, BYTE PTR [{src_reg} + {src_off}]")
            self.emit(f"    mov     BYTE PTR [r12 + {wire_off}], al")
        elif w == 2:
            self.emit(f"    movzx   eax, WORD PTR [{src_reg} + {src_off}]")
            self.emit(f"    mov     WORD PTR [r12 + {wire_off}], ax")
        elif w == 4:
            self.emit(f"    mov     eax, DWORD PTR [{src_reg} + {src_off}]")
            self.emit(f"    mov     DWORD PTR [r12 + {wire_off}], eax")
        elif w == 8:
            self.emit(f"    mov     rax, QWORD PTR [{src_reg} + {src_off}]")
            self.emit(f"    mov     QWORD PTR [r12 + {wire_off}], rax")

    # Emit inline non-bool scalar load from [r12 + wire_off] -> [dst_reg + dst_off]
    def emit_scalar_load(self, kind: str, dst_reg: str, dst_off: int, wire_off: int) -> None:
        w = SCALAR_INFO[kind][3]
        if w == 1:
            self.emit(f"    movzx   eax, BYTE PTR [r12 + {wire_off}]")
            self.emit(f"    mov     BYTE PTR [{dst_reg} + {dst_off}], al")
        elif w == 2:
            self.emit(f"    movzx   eax, WORD PTR [r12 + {wire_off}]")
            self.emit(f"    mov     WORD PTR [{dst_reg} + {dst_off}], ax")
        elif w == 4:
            self.emit(f"    mov     eax, DWORD PTR [r12 + {wire_off}]")
            self.emit(f"    mov     DWORD PTR [{dst_reg} + {dst_off}], eax")
        elif w == 8:
            self.emit(f"    mov     rax, QWORD PTR [r12 + {wire_off}]")
            self.emit(f"    mov     QWORD PTR [{dst_reg} + {dst_off}], rax")

    # Emit encoding of any single value located at [base_reg + off], preserving [rbp - 8] -> rdi
    def emit_enc_value(
        self, t: TypeIR, base_reg: str, off: int,
        err_limit: str, err_prop: str, reload_slot: str = "[rbp - 8]",
    ) -> None:
        if t.is_scalar():
            w = SCALAR_INFO[t.kind][3]
            self.emit("    mov     rax, r13")
            self.emit("    sub     rax, r12")
            self.emit(f"    cmp     rax, {w}")
            self.emit(f"    jb      {err_limit}")
            self.emit_scalar_store(t.kind, base_reg, off, 0)
            self.emit(f"    add     r12, {w}")
        elif t.kind == "str":
            if base_reg != "rdi":
                self.emit(f"    mov     rdi, {base_reg}")
            self.emit(f"    GEN_ENC_STR_INLINE {off}, {off + 8}, {err_limit}, {err_prop}")
            if reload_slot != "[rbp - 8]":
                self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")
        elif t.kind == "bytes":
            self.emit(f"    mov     rsi, QWORD PTR [{base_reg} + {off + 8}]")
            self.emit(f"    mov     rdi, QWORD PTR [{base_reg} + {off}]")
            self.emit("    call    kiln_core_enc_str")
            self.emit(f"    jc      {err_prop}")
            self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")
        elif t.kind == "tensors":
            self.emit(f"    lea     rdi, [{base_reg} + {off}]")
            self.emit("    call    kiln_core_enc_tensors")
            self.emit(f"    jc      {err_prop}")
            self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")
        else:
            # struct, opt, list, dict -> dedicated generated helper
            self.emit(f"    lea     rdi, [{base_reg} + {off}]")
            self.emit(f"    call    kiln_core_enc_{t.sym}")
            self.emit(f"    jc      {err_prop}")
            self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")

    # Emit decoding of any single value into [base_reg + off]
    def emit_dec_value(
        self, t: TypeIR, base_reg: str, off: int,
        err_eof: str, err_limit: str, err_type: str, err_prop: str,
        reload_slot: str = "[rbp - 8]",
    ) -> None:
        if t.kind == "bool":
            self.emit("    cmp     r12, r13")
            self.emit(f"    jae     {err_eof}")
            self.emit("    movzx   eax, BYTE PTR [r12]")
            self.emit("    cmp     al, 1")
            self.emit(f"    ja      {err_type}")
            self.emit(f"    mov     BYTE PTR [{base_reg} + {off}], al")
            self.emit("    inc     r12")
        elif t.is_scalar():
            w = SCALAR_INFO[t.kind][3]
            self.emit("    mov     rax, r13")
            self.emit("    sub     rax, r12")
            self.emit(f"    cmp     rax, {w}")
            self.emit(f"    jb      {err_eof}")
            self.emit_scalar_load(t.kind, base_reg, off, 0)
            self.emit(f"    add     r12, {w}")
        elif t.kind == "str":
            if base_reg != "rdi":
                self.emit(f"    mov     rdi, {base_reg}")
            if reload_slot == "[rbp - 8]":
                self.emit(f"    GEN_DEC_STR_INLINE {off}, {off + 8}, {err_eof}, {err_limit}, {err_prop}")
            else:
                self.emit("    call    kiln_core_dec_str")
                self.emit(f"    jc      {err_prop}")
                self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")
                self.emit(f"    mov     QWORD PTR [{base_reg} + {off}], rax")
                self.emit(f"    mov     QWORD PTR [{base_reg} + {off + 8}], rdx")
        elif t.kind == "bytes":
            self.emit("    call    kiln_core_dec_bytes")
            self.emit(f"    jc      {err_prop}")
            self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")
            self.emit(f"    mov     QWORD PTR [{base_reg} + {off}], rax")
            self.emit(f"    mov     QWORD PTR [{base_reg} + {off + 8}], rdx")
        elif t.kind == "tensors":
            self.emit(f"    lea     rdi, [{base_reg} + {off}]")
            self.emit("    call    kiln_core_dec_tensors")
            self.emit(f"    jc      {err_prop}")
            self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")
        else:
            self.emit(f"    lea     rdi, [{base_reg} + {off}]")
            self.emit(f"    call    kiln_core_dec_{t.sym}")
            self.emit(f"    jc      {err_prop}")
            self.emit(f"    mov     {base_reg}, QWORD PTR {reload_slot}")

    # --------------------------------------------------------------------------
    # Emit opt<T> encoder & decoder
    # --------------------------------------------------------------------------
    def emit_opt_codecs(self, t: TypeIR) -> None:
        assert t.elem is not None
        sym = t.sym
        # Encoder
        l_none = self.new_lbl("opt_enone")
        l_ok = self.new_lbl("opt_eok")
        l_lim = self.new_lbl("opt_elim")
        l_err = self.new_lbl("opt_eerr")
        l_ret = self.new_lbl("opt_eret")
        self.emit(f".p2align 4")
        self.emit(f".globl kiln_core_enc_{sym}")
        self.emit(f".type kiln_core_enc_{sym}, @function")
        self.emit(f"kiln_core_enc_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 16")
        self.emit("    mov     QWORD PTR [rbp - 8], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_ret}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    cmp     r12, r13")
        self.emit(f"    jae     {l_lim}")
        self.emit("    cmp     BYTE PTR [rdi], 0")
        self.emit(f"    je      {l_none}")
        self.emit("    mov     BYTE PTR [r12], 1")
        self.emit("    inc     r12")
        self.emit_enc_value(t.elem, "rdi", t.val_off, l_lim, l_err)
        self.emit(f"{l_ok}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_none}:")
        self.emit("    mov     BYTE PTR [r12], 0")
        self.emit("    inc     r12")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_lim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_err}:")
        self.emit("    dec     r15")
        self.emit(f"{l_ret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_enc_{sym}, .-kiln_core_enc_{sym}\n")

        # Decoder
        l_dnone = self.new_lbl("opt_dnone")
        l_dok = self.new_lbl("opt_dok")
        l_deof = self.new_lbl("opt_deof")
        l_dlim = self.new_lbl("opt_dlim")
        l_dtype = self.new_lbl("opt_dtype")
        l_derr = self.new_lbl("opt_derr")
        l_dret = self.new_lbl("opt_dret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_dec_{sym}")
        self.emit(f".type kiln_core_dec_{sym}, @function")
        self.emit(f"kiln_core_dec_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 16")
        self.emit("    mov     QWORD PTR [rbp - 8], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_dret}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    cmp     r12, r13")
        self.emit(f"    jae     {l_deof}")
        self.emit("    movzx   eax, BYTE PTR [r12]")
        self.emit("    cmp     al, 1")
        self.emit(f"    ja      {l_dtype}")
        self.emit("    mov     BYTE PTR [rdi], al")
        self.emit("    inc     r12")
        self.emit("    test    al, al")
        self.emit(f"    jz      {l_dnone}")
        self.emit_dec_value(t.elem, "rdi", t.val_off, l_deof, l_dlim, l_dtype, l_derr)
        self.emit(f"{l_dok}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_dnone}:")
        # Zero-init value payload when absent for clean deterministic structs
        self.emit(f"    lea     rdi, [rdi + {t.val_off}]")
        self.emit("    xor     eax, eax")
        self.emit(f"    mov     rcx, {t.elem.size}")
        self.emit("    rep stosb")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_deof}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_EOF")
        self.emit(f"{l_dlim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_dtype}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_TYPE")
        self.emit(f"{l_derr}:")
        self.emit("    dec     r15")
        self.emit(f"{l_dret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_dec_{sym}, .-kiln_core_dec_{sym}\n")

    # --------------------------------------------------------------------------
    # Emit list<E> encoder & decoder (POD fast path, bool AVX2 path, general loop)
    # --------------------------------------------------------------------------
    def emit_list_codecs(self, t: TypeIR) -> None:
        assert t.elem is not None
        elem = t.elem
        sym = t.sym

        if t.is_pod_list():
            w = SCALAR_INFO[elem.kind][3]
            shift = {1: 0, 2: 1, 4: 2, 8: 3}[w]
            self._emit_pod_list_codecs(sym, w, shift, elem.align)
            return

        if t.is_bool_list():
            self._emit_bool_list_codecs(sym)
            return

        # General list<E> encoder
        l_loop = self.new_lbl("list_eloop")
        l_ok = self.new_lbl("list_eok")
        l_lim = self.new_lbl("list_elim")
        l_err = self.new_lbl("list_eerr")
        l_ret = self.new_lbl("list_eret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_enc_{sym}")
        self.emit(f".type kiln_core_enc_{sym}, @function")
        self.emit(f"kiln_core_enc_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 32")  # -8: cur_ptr, -16: end_ptr, -24: count, -32: items
        self.emit("    mov     rax, QWORD PTR [rdi]")
        self.emit("    mov     rcx, QWORD PTR [rdi + 8]")
        self.emit("    mov     QWORD PTR [rbp - 32], rax")
        self.emit("    mov     QWORD PTR [rbp - 24], rcx")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_ret}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 24]")
        self.emit("    call    kiln_core_enc_count")
        self.emit(f"    jc      {l_err}")
        self.emit("    mov     rax, QWORD PTR [rbp - 24]")
        self.emit(f"    imul    rax, rax, {elem.size}")
        self.emit("    mov     rcx, QWORD PTR [rbp - 32]")
        self.emit("    mov     QWORD PTR [rbp - 8], rcx")
        self.emit("    add     rax, rcx")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")
        self.emit(".p2align 4")
        self.emit(f"{l_loop}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    cmp     rdi, QWORD PTR [rbp - 16]")
        self.emit(f"    jae     {l_ok}")
        self.emit_enc_value(elem, "rdi", 0, l_lim, l_err, reload_slot="[rbp - 8]")
        self.emit(f"    add     QWORD PTR [rbp - 8], {elem.size}")
        self.emit(f"    jmp     {l_loop}")
        self.emit(f"{l_ok}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_lim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_err}:")
        self.emit("    dec     r15")
        self.emit(f"{l_ret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_enc_{sym}, .-kiln_core_enc_{sym}\n")

        # General list<E> decoder (normative §4.2 pre-allocation guard!)
        l_dloop = self.new_lbl("list_dloop")
        l_demp = self.new_lbl("list_demp")
        l_dok = self.new_lbl("list_dok")
        l_deof = self.new_lbl("list_deof")
        l_dlim = self.new_lbl("list_dlim")
        l_dtype = self.new_lbl("list_dtype")
        l_derr = self.new_lbl("list_derr")
        l_dret = self.new_lbl("list_dret")
        min_e = elem.min_wire_size()
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_dec_{sym}")
        self.emit(f".type kiln_core_dec_{sym}, @function")
        self.emit(f"kiln_core_dec_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        # -8: cur_ptr (matches GEN_DEC_STR_INLINE reload!), -16: end_ptr, -24: out_list*, -32: arr*, -40: count
        self.emit("    sub     rsp, 48")
        self.emit("    mov     QWORD PTR [rbp - 24], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_dret}")
        self.emit(f"    mov     rdi, {min_e}")
        self.emit("    call    kiln_core_dec_count")
        self.emit(f"    jc      {l_derr}")
        self.emit("    mov     QWORD PTR [rbp - 40], rax")
        self.emit("    test    rax, rax")
        self.emit(f"    jz      {l_demp}")
        self.emit(f"    mov     rcx, {elem.size}")
        self.emit("    mul     rcx")
        self.emit("    test    rdx, rdx")
        self.emit(f"    jnz     {l_dlim}")
        self.emit("    mov     rdi, rax")
        self.emit(f"    mov     rsi, {elem.align}")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")  # temporarily store byte size
        self.emit("    call    kiln_core_arena_alloc")
        self.emit(f"    jc      {l_derr}")
        self.emit("    mov     QWORD PTR [rbp - 32], rax")  # arr*
        self.emit("    mov     QWORD PTR [rbp - 8], rax")   # cur_ptr
        self.emit("    add     rax, QWORD PTR [rbp - 16]")  # end_ptr
        self.emit("    mov     QWORD PTR [rbp - 16], rax")
        self.emit(".p2align 4")
        self.emit(f"{l_dloop}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    cmp     rdi, QWORD PTR [rbp - 16]")
        self.emit(f"    jae     {l_dok}")
        self.emit_dec_value(elem, "rdi", 0, l_deof, l_dlim, l_dtype, l_derr, reload_slot="[rbp - 8]")
        self.emit(f"    add     QWORD PTR [rbp - 8], {elem.size}")
        self.emit(f"    jmp     {l_dloop}")
        self.emit(f"{l_demp}:")
        self.emit("    mov     QWORD PTR [rbp - 32], 0")
        self.emit(f"{l_dok}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 24]")
        self.emit("    mov     rax, QWORD PTR [rbp - 32]")
        self.emit("    mov     rdx, QWORD PTR [rbp - 40]")
        self.emit("    mov     QWORD PTR [rdi], rax")
        self.emit("    mov     QWORD PTR [rdi + 8], rdx")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_deof}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_EOF")
        self.emit(f"{l_dlim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_dtype}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_TYPE")
        self.emit(f"{l_derr}:")
        self.emit("    dec     r15")
        self.emit(f"{l_dret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_dec_{sym}, .-kiln_core_dec_{sym}\n")

    def _emit_pod_list_codecs(self, sym: str, w: int, shift: int, align: int) -> None:
        # Fast bulk-copy POD scalar list encoder
        l_ok = self.new_lbl("pod_eok")
        l_lim = self.new_lbl("pod_elim")
        l_ret = self.new_lbl("pod_eret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_enc_{sym}")
        self.emit(f".type kiln_core_enc_{sym}, @function")
        self.emit(f"kiln_core_enc_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 16")
        self.emit("    mov     QWORD PTR [rbp - 8], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_ret}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     rsi, QWORD PTR [rdi + 8]")  # count
        self.emit("    cmp     rsi, QWORD PTR [rbx + CTX_MAX_COUNT]")
        self.emit(f"    ja      {l_lim}")
        self.emit("    mov     eax, 0xFFFFFFFF")
        self.emit("    cmp     rsi, rax")
        self.emit(f"    ja      {l_lim}")
        self.emit("    mov     rdx, rsi")
        if shift:
            self.emit(f"    shl     rdx, {shift}")
        self.emit("    lea     rcx, [rdx + 4]")
        self.emit("    mov     rax, r13")
        self.emit("    sub     rax, r12")
        self.emit("    cmp     rax, rcx")
        self.emit(f"    jb      {l_lim}")
        self.emit("    mov     DWORD PTR [r12], esi")
        self.emit("    add     r12, 4")
        self.emit("    test    rdx, rdx")
        self.emit(f"    jz      {l_ok}")
        self.emit("    mov     rsi, QWORD PTR [rdi]")      # src ptr
        self.emit("    mov     rdi, r12")                  # dst ptr
        self.emit("    add     r12, rdx")
        self.emit("    call    kiln_core_memcpy_bulk")
        self.emit(f"{l_ok}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_lim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_ret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_enc_{sym}, .-kiln_core_enc_{sym}\n")

        # Fast zero-copy / bulk-copy POD scalar list decoder
        l_own = self.new_lbl("pod_down")
        l_emp = self.new_lbl("pod_demp")
        l_err = self.new_lbl("pod_derr")
        l_dret = self.new_lbl("pod_dret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_dec_{sym}")
        self.emit(f".type kiln_core_dec_{sym}, @function")
        self.emit(f"kiln_core_dec_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 32")  # -8: out_list*, -16: count, -24: nbytes
        self.emit("    mov     QWORD PTR [rbp - 8], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_dret}")
        self.emit(f"    mov     rdi, {w}")
        self.emit("    call    kiln_core_dec_count")
        self.emit(f"    jc      {l_err}")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")
        self.emit("    test    rax, rax")
        self.emit(f"    jz      {l_emp}")
        if shift:
            self.emit(f"    shl     rax, {shift}")
        self.emit("    mov     QWORD PTR [rbp - 24], rax")
        self.emit("    test    r15, FLAG_OWNED")
        self.emit(f"    jnz     {l_own}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     QWORD PTR [rdi], r12")
        self.emit("    mov     rcx, QWORD PTR [rbp - 16]")
        self.emit("    mov     QWORD PTR [rdi + 8], rcx")
        self.emit("    add     r12, rax")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_own}:")
        self.emit("    mov     rdi, rax")
        self.emit(f"    mov     rsi, {align}")
        self.emit("    call    kiln_core_arena_alloc")
        self.emit(f"    jc      {l_err}")
        self.emit("    mov     QWORD PTR [rbp - 32], rax")
        self.emit("    mov     rdi, rax")
        self.emit("    mov     rsi, r12")
        self.emit("    mov     rdx, QWORD PTR [rbp - 24]")
        self.emit("    add     r12, rdx")
        self.emit("    call    kiln_core_memcpy_bulk")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     rax, QWORD PTR [rbp - 32]")
        self.emit("    mov     rcx, QWORD PTR [rbp - 16]")
        self.emit("    mov     QWORD PTR [rdi], rax")
        self.emit("    mov     QWORD PTR [rdi + 8], rcx")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_emp}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     QWORD PTR [rdi], 0")
        self.emit("    mov     QWORD PTR [rdi + 8], 0")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_err}:")
        self.emit("    dec     r15")
        self.emit(f"{l_dret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_dec_{sym}, .-kiln_core_dec_{sym}\n")

    def _emit_bool_list_codecs(self, sym: str) -> None:
        # Bool list encoder (normalizes each element to 0x00 / 0x01)
        l_loop = self.new_lbl("blist_eloop")
        l_ok = self.new_lbl("blist_eok")
        l_lim = self.new_lbl("blist_elim")
        l_ret = self.new_lbl("blist_eret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_enc_{sym}")
        self.emit(f".type kiln_core_enc_{sym}, @function")
        self.emit(f"kiln_core_enc_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 16")
        self.emit("    mov     QWORD PTR [rbp - 8], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_ret}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     rcx, QWORD PTR [rdi + 8]")
        self.emit("    cmp     rcx, QWORD PTR [rbx + CTX_MAX_COUNT]")
        self.emit(f"    ja      {l_lim}")
        self.emit("    mov     eax, 0xFFFFFFFF")
        self.emit("    cmp     rcx, rax")
        self.emit(f"    ja      {l_lim}")
        self.emit("    lea     rdx, [rcx + 4]")
        self.emit("    mov     rax, r13")
        self.emit("    sub     rax, r12")
        self.emit("    cmp     rax, rdx")
        self.emit(f"    jb      {l_lim}")
        self.emit("    mov     DWORD PTR [r12], ecx")
        self.emit("    add     r12, 4")
        self.emit("    test    rcx, rcx")
        self.emit(f"    jz      {l_ok}")
        self.emit("    mov     rsi, QWORD PTR [rdi]")
        self.emit(f"{l_loop}:")
        self.emit("    movzx   eax, BYTE PTR [rsi]")
        self.emit("    test    al, al")
        self.emit("    setne   al")
        self.emit("    mov     BYTE PTR [r12], al")
        self.emit("    inc     rsi")
        self.emit("    inc     r12")
        self.emit("    dec     rcx")
        self.emit(f"    jnz     {l_loop}")
        self.emit(f"{l_ok}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_lim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_ret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_enc_{sym}, .-kiln_core_enc_{sym}\n")

        # Bool list decoder (AVX2 kiln_core_check_bool_bytes BEFORE any arena alloc!)
        l_own = self.new_lbl("blist_down")
        l_emp = self.new_lbl("blist_demp")
        l_type = self.new_lbl("blist_dtype")
        l_err = self.new_lbl("blist_derr")
        l_dret = self.new_lbl("blist_dret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_dec_{sym}")
        self.emit(f".type kiln_core_dec_{sym}, @function")
        self.emit(f"kiln_core_dec_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        self.emit("    sub     rsp, 32")
        self.emit("    mov     QWORD PTR [rbp - 8], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_dret}")
        self.emit("    mov     rdi, 1")
        self.emit("    call    kiln_core_dec_count")
        self.emit(f"    jc      {l_err}")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")
        self.emit("    test    rax, rax")
        self.emit(f"    jz      {l_emp}")
        self.emit("    mov     rdi, r12")
        self.emit("    mov     rsi, rax")
        self.emit("    call    kiln_core_check_bool_bytes")
        self.emit(f"    jc      {l_type}")
        self.emit("    mov     rax, QWORD PTR [rbp - 16]")
        self.emit("    test    r15, FLAG_OWNED")
        self.emit(f"    jnz     {l_own}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     QWORD PTR [rdi], r12")
        self.emit("    mov     QWORD PTR [rdi + 8], rax")
        self.emit("    add     r12, rax")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_own}:")
        self.emit("    mov     rdi, rax")
        self.emit("    mov     rsi, 1")
        self.emit("    call    kiln_core_arena_alloc")
        self.emit(f"    jc      {l_err}")
        self.emit("    mov     QWORD PTR [rbp - 24], rax")
        self.emit("    mov     rdi, rax")
        self.emit("    mov     rsi, r12")
        self.emit("    mov     rdx, QWORD PTR [rbp - 16]")
        self.emit("    add     r12, rdx")
        self.emit("    call    kiln_core_memcpy_fast")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     rax, QWORD PTR [rbp - 24]")
        self.emit("    mov     rcx, QWORD PTR [rbp - 16]")
        self.emit("    mov     QWORD PTR [rdi], rax")
        self.emit("    mov     QWORD PTR [rdi + 8], rcx")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_emp}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    mov     QWORD PTR [rdi], 0")
        self.emit("    mov     QWORD PTR [rdi + 8], 0")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_type}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_TYPE")
        self.emit(f"{l_err}:")
        self.emit("    dec     r15")
        self.emit(f"{l_dret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_dec_{sym}, .-kiln_core_dec_{sym}\n")

    # --------------------------------------------------------------------------
    # Emit dict<str, V> encoder & decoder (strict ascending UTF-8 keys!)
    # --------------------------------------------------------------------------
    def emit_dict_codecs(self, t: TypeIR) -> None:
        assert t.elem is not None
        val_ir = t.elem
        sym = t.sym
        esz = t.entry_size
        voff = t.val_off

        # Encoder
        l_chk = self.new_lbl("dict_echk")
        l_wcnt = self.new_lbl("dict_ewcnt")
        l_wloop = self.new_lbl("dict_ewloop")
        l_ok = self.new_lbl("dict_eok")
        l_lim = self.new_lbl("dict_elim")
        l_type = self.new_lbl("dict_etype")
        l_err = self.new_lbl("dict_eerr")
        l_ret = self.new_lbl("dict_eret")
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_enc_{sym}")
        self.emit(f".type kiln_core_enc_{sym}, @function")
        self.emit(f"kiln_core_enc_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        # -8: cur_ptr, -16: end_ptr, -24: count, -32: entries
        self.emit("    sub     rsp, 32")
        self.emit("    mov     rax, QWORD PTR [rdi]")
        self.emit("    mov     rcx, QWORD PTR [rdi + 8]")
        self.emit("    mov     QWORD PTR [rbp - 32], rax")
        self.emit("    mov     QWORD PTR [rbp - 24], rcx")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_ret}")
        self.emit("    mov     rax, QWORD PTR [rbp - 24]")
        self.emit("    cmp     rax, QWORD PTR [rbx + CTX_MAX_COUNT]")
        self.emit(f"    ja      {l_lim}")
        self.emit("    mov     ecx, 0xFFFFFFFF")
        self.emit("    cmp     rax, rcx")
        self.emit(f"    ja      {l_lim}")
        self.emit(f"    imul    rax, rax, {esz}")
        self.emit("    add     rax, QWORD PTR [rbp - 32]")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")  # end_ptr
        self.emit("    cmp     QWORD PTR [rbp - 24], 2")
        self.emit(f"    jb      {l_wcnt}")
        self.emit("    mov     rax, QWORD PTR [rbp - 32]")
        self.emit(f"    add     rax, {esz}")
        self.emit("    mov     QWORD PTR [rbp - 8], rax")   # cur = &entries[1]
        self.emit(f"{l_chk}:")
        self.emit("    mov     r9, QWORD PTR [rbp - 8]")
        self.emit("    cmp     r9, QWORD PTR [rbp - 16]")
        self.emit(f"    jae     {l_wcnt}")
        self.emit(f"    lea     r10, [r9 - {esz}]")
        self.emit("    mov     rdi, QWORD PTR [r10]")
        self.emit("    mov     rsi, QWORD PTR [r10 + 8]")
        self.emit("    mov     rdx, QWORD PTR [r9]")
        self.emit("    mov     rcx, QWORD PTR [r9 + 8]")
        self.emit("    call    kiln_core_cmp_bytes")
        self.emit("    test    eax, eax")
        self.emit(f"    jns     {l_type}")
        self.emit(f"    add     QWORD PTR [rbp - 8], {esz}")
        self.emit(f"    jmp     {l_chk}")
        self.emit(f"{l_wcnt}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 24]")
        self.emit("    call    kiln_core_enc_count")
        self.emit(f"    jc      {l_err}")
        self.emit("    mov     rax, QWORD PTR [rbp - 32]")
        self.emit("    mov     QWORD PTR [rbp - 8], rax")
        self.emit(f"{l_wloop}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    cmp     rdi, QWORD PTR [rbp - 16]")
        self.emit(f"    jae     {l_ok}")
        self.emit(f"    GEN_ENC_STR_INLINE 0, 8, {l_lim}, {l_err}")
        self.emit_enc_value(val_ir, "rdi", voff, l_lim, l_err, reload_slot="[rbp - 8]")
        self.emit(f"    add     QWORD PTR [rbp - 8], {esz}")
        self.emit(f"    jmp     {l_wloop}")
        self.emit(f"{l_ok}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_lim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_type}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_TYPE")
        self.emit(f"{l_err}:")
        self.emit("    dec     r15")
        self.emit(f"{l_ret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_enc_{sym}, .-kiln_core_enc_{sym}\n")

        # Decoder
        l_dloop = self.new_lbl("dict_dloop")
        l_dsave = self.new_lbl("dict_dsave")
        l_demp = self.new_lbl("dict_demp")
        l_dok = self.new_lbl("dict_dok")
        l_deof = self.new_lbl("dict_deof")
        l_dlim = self.new_lbl("dict_dlim")
        l_dtype = self.new_lbl("dict_dtype")
        l_derr = self.new_lbl("dict_derr")
        l_dret = self.new_lbl("dict_dret")
        min_entry = 4 + val_ir.min_wire_size()
        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_dec_{sym}")
        self.emit(f".type kiln_core_dec_{sym}, @function")
        self.emit(f"kiln_core_dec_{sym}:")
        self.emit("    push    rbp")
        self.emit("    mov     rbp, rsp")
        # -8: cur_ptr, -16: end_ptr, -24: out_dict*, -32: arr*, -40: count, -48: prev_ptr, -56: prev_len
        self.emit("    sub     rsp, 64")
        self.emit("    mov     QWORD PTR [rbp - 24], rdi")
        self.emit("    call    kiln_core_depth_enter")
        self.emit(f"    jc      {l_dret}")
        self.emit(f"    mov     rdi, {min_entry}")
        self.emit("    call    kiln_core_dec_count")
        self.emit(f"    jc      {l_derr}")
        self.emit("    mov     QWORD PTR [rbp - 40], rax")
        self.emit("    test    rax, rax")
        self.emit(f"    jz      {l_demp}")
        self.emit(f"    mov     rcx, {esz}")
        self.emit("    mul     rcx")
        self.emit("    test    rdx, rdx")
        self.emit(f"    jnz     {l_dlim}")
        self.emit("    mov     rdi, rax")
        self.emit(f"    mov     rsi, {t.entry_align}")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")
        self.emit("    call    kiln_core_arena_alloc")
        self.emit(f"    jc      {l_derr}")
        self.emit("    mov     QWORD PTR [rbp - 32], rax")
        self.emit("    mov     QWORD PTR [rbp - 8], rax")
        self.emit("    add     rax, QWORD PTR [rbp - 16]")
        self.emit("    mov     QWORD PTR [rbp - 16], rax")
        self.emit(f"{l_dloop}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit("    cmp     rdi, QWORD PTR [rbp - 16]")
        self.emit(f"    jae     {l_dok}")
        self.emit(f"    GEN_DEC_STR_INLINE 0, 8, {l_deof}, {l_dlim}, {l_derr}")
        # Enforce strict ascending order against previous key
        self.emit("    cmp     rdi, QWORD PTR [rbp - 32]")
        self.emit(f"    je      {l_dsave}")
        self.emit("    mov     rdx, QWORD PTR [rdi]")
        self.emit("    mov     rcx, QWORD PTR [rdi + 8]")
        self.emit("    mov     rdi, QWORD PTR [rbp - 48]")
        self.emit("    mov     rsi, QWORD PTR [rbp - 56]")
        self.emit("    call    kiln_core_cmp_bytes")
        self.emit("    test    eax, eax")
        self.emit(f"    jns     {l_dtype}")
        self.emit("    mov     rdi, QWORD PTR [rbp - 8]")
        self.emit(f"{l_dsave}:")
        self.emit("    mov     rax, QWORD PTR [rdi]")
        self.emit("    mov     rdx, QWORD PTR [rdi + 8]")
        self.emit("    mov     QWORD PTR [rbp - 48], rax")
        self.emit("    mov     QWORD PTR [rbp - 56], rdx")
        self.emit_dec_value(val_ir, "rdi", voff, l_deof, l_dlim, l_dtype, l_derr, reload_slot="[rbp - 8]")
        self.emit(f"    add     QWORD PTR [rbp - 8], {esz}")
        self.emit(f"    jmp     {l_dloop}")
        self.emit(f"{l_demp}:")
        self.emit("    mov     QWORD PTR [rbp - 32], 0")
        self.emit(f"{l_dok}:")
        self.emit("    mov     rdi, QWORD PTR [rbp - 24]")
        self.emit("    mov     rax, QWORD PTR [rbp - 32]")
        self.emit("    mov     rdx, QWORD PTR [rbp - 40]")
        self.emit("    mov     QWORD PTR [rdi], rax")
        self.emit("    mov     QWORD PTR [rdi + 8], rdx")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_OK_RET")
        self.emit(f"{l_deof}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_EOF")
        self.emit(f"{l_dlim}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        self.emit(f"{l_dtype}:")
        self.emit("    dec     r15")
        self.emit("    leave")
        self.emit("    KILN_FAIL KILN_ERR_TYPE")
        self.emit(f"{l_derr}:")
        self.emit("    dec     r15")
        self.emit(f"{l_dret}:")
        self.emit("    leave")
        self.emit("    stc")
        self.emit("    ret")
        self.emit(f".size kiln_core_dec_{sym}, .-kiln_core_dec_{sym}\n")

    # --------------------------------------------------------------------------
    # Emit struct encoder & decoder (with coalesced fixed-scalar runs!)
    # --------------------------------------------------------------------------
    def emit_struct_codecs(self, st: TypeIR) -> None:
        sym = st.sym
        is_leaf = st.is_leaf_struct()

        # --- Encoder ---
        l_dep = self.new_lbl("st_edep")
        l_lim = self.new_lbl("st_elim")
        l_err = self.new_lbl("st_eerr")
        l_ret = self.new_lbl("st_eret")

        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_enc_{sym}")
        self.emit(f".type kiln_core_enc_{sym}, @function")
        self.emit(f"kiln_core_enc_{sym}:")
        if is_leaf:
            self.emit("    movzx   eax, r15b")
            self.emit("    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]")
            self.emit(f"    jae     {l_dep}")
        else:
            self.emit("    push    rbp")
            self.emit("    mov     rbp, rsp")
            self.emit("    sub     rsp, 16")
            self.emit("    mov     QWORD PTR [rbp - 8], rdi")
            self.emit("    movzx   eax, r15b")
            self.emit("    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]")
            self.emit(f"    jae     {l_dep}")
            self.emit("    inc     r15")

        # Group consecutive required scalars into single-check runs!
        i = 0
        nf = len(st.fields)
        while i < nf:
            if st.fields[i].type_ir.is_scalar():
                run: List[FieldSpec] = []
                run_bytes = 0
                while i < nf and st.fields[i].type_ir.is_scalar():
                    run.append(st.fields[i])
                    run_bytes += SCALAR_INFO[st.fields[i].type_ir.kind][3]
                    i += 1
                self.emit("    mov     rax, r13")
                self.emit("    sub     rax, r12")
                self.emit(f"    cmp     rax, {run_bytes}")
                self.emit(f"    jb      {l_lim}")
                woff = 0
                for f in run:
                    self.emit_scalar_store(f.type_ir.kind, "rdi", f.offset, woff)
                    woff += SCALAR_INFO[f.type_ir.kind][3]
                self.emit(f"    add     r12, {run_bytes}")
            else:
                f = st.fields[i]
                self.emit_enc_value(f.type_ir, "rdi", f.offset, l_lim, l_err)
                i += 1

        if is_leaf:
            self.emit("    KILN_OK_RET")
            self.emit(f"{l_dep}:")
            self.emit("    KILN_FAIL KILN_ERR_DEPTH")
            self.emit(f"{l_lim}:")
            self.emit("    KILN_FAIL KILN_ERR_LIMIT")
        else:
            self.emit("    dec     r15")
            self.emit("    leave")
            self.emit("    KILN_OK_RET")
            self.emit(f"{l_dep}:")
            self.emit("    leave")
            self.emit("    KILN_FAIL KILN_ERR_DEPTH")
            self.emit(f"{l_lim}:")
            self.emit("    dec     r15")
            self.emit("    leave")
            self.emit("    KILN_FAIL KILN_ERR_LIMIT")
            self.emit(f"{l_err}:")
            self.emit("    dec     r15")
            self.emit(f"{l_ret}:")
            self.emit("    leave")
            self.emit("    stc")
            self.emit("    ret")
        self.emit(f".size kiln_core_enc_{sym}, .-kiln_core_enc_{sym}\n")

        # --- Decoder ---
        l_ddep = self.new_lbl("st_ddep")
        l_deof = self.new_lbl("st_deof")
        l_dlim = self.new_lbl("st_dlim")
        l_dtype = self.new_lbl("st_dtype")
        l_derr = self.new_lbl("st_derr")
        l_dret = self.new_lbl("st_dret")

        self.emit(".p2align 4")
        self.emit(f".globl kiln_core_dec_{sym}")
        self.emit(f".type kiln_core_dec_{sym}, @function")
        self.emit(f"kiln_core_dec_{sym}:")
        if is_leaf:
            self.emit("    movzx   eax, r15b")
            self.emit("    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]")
            self.emit(f"    jae     {l_ddep}")
        else:
            self.emit("    push    rbp")
            self.emit("    mov     rbp, rsp")
            self.emit("    sub     rsp, 16")
            self.emit("    mov     QWORD PTR [rbp - 8], rdi")
            self.emit("    movzx   eax, r15b")
            self.emit("    cmp     rax, QWORD PTR [rbx + CTX_MAX_DEPTH]")
            self.emit(f"    jae     {l_ddep}")
            self.emit("    inc     r15")

        # Coalesce runs of consecutive non-bool scalars (exact field-order EOF/TYPE on bool!)
        i = 0
        while i < nf:
            ft = st.fields[i].type_ir
            if ft.is_scalar() and ft.kind != "bool":
                run = []
                run_bytes = 0
                while i < nf and st.fields[i].type_ir.is_scalar() and st.fields[i].type_ir.kind != "bool":
                    run.append(st.fields[i])
                    run_bytes += SCALAR_INFO[st.fields[i].type_ir.kind][3]
                    i += 1
                self.emit("    mov     rax, r13")
                self.emit("    sub     rax, r12")
                self.emit(f"    cmp     rax, {run_bytes}")
                self.emit(f"    jb      {l_deof}")
                woff = 0
                for f in run:
                    self.emit_scalar_load(f.type_ir.kind, "rdi", f.offset, woff)
                    woff += SCALAR_INFO[f.type_ir.kind][3]
                self.emit(f"    add     r12, {run_bytes}")
            else:
                f = st.fields[i]
                self.emit_dec_value(f.type_ir, "rdi", f.offset, l_deof, l_dlim, l_dtype, l_derr)
                i += 1

        if is_leaf:
            self.emit("    KILN_OK_RET")
            self.emit(f"{l_ddep}:")
            self.emit("    KILN_FAIL KILN_ERR_DEPTH")
            self.emit(f"{l_deof}:")
            self.emit("    KILN_FAIL KILN_ERR_EOF")
            self.emit(f"{l_dtype}:")
            self.emit("    KILN_FAIL KILN_ERR_TYPE")
        else:
            self.emit("    dec     r15")
            self.emit("    leave")
            self.emit("    KILN_OK_RET")
            self.emit(f"{l_ddep}:")
            self.emit("    leave")
            self.emit("    KILN_FAIL KILN_ERR_DEPTH")
            self.emit(f"{l_deof}:")
            self.emit("    dec     r15")
            self.emit("    leave")
            self.emit("    KILN_FAIL KILN_ERR_EOF")
            self.emit(f"{l_dlim}:")
            self.emit("    dec     r15")
            self.emit("    leave")
            self.emit("    KILN_FAIL KILN_ERR_LIMIT")
            self.emit(f"{l_dtype}:")
            self.emit("    dec     r15")
            self.emit("    leave")
            self.emit("    KILN_FAIL KILN_ERR_TYPE")
            self.emit(f"{l_derr}:")
            self.emit("    dec     r15")
            self.emit(f"{l_dret}:")
            self.emit("    leave")
            self.emit("    stc")
            self.emit("    ret")
        self.emit(f".size kiln_core_dec_{sym}, .-kiln_core_dec_{sym}\n")

    # --------------------------------------------------------------------------
    # Emit Public System V AMD64 C-ABI Wrappers for Root Struct (+ Framed + Batch)
    # --------------------------------------------------------------------------
    def emit_root_cabi_wrappers(self, root: TypeIR) -> None:
        pub = self.comp._public_fn_suffix(root.name)
        sym = root.sym
        hval = root.schema_hash()
        min_sz = root.min_wire_size()

        # 1. kiln_asm_encode_<pub>(in, dst, cap, opts, res)
        self.emit(f""".p2align 4
.globl kiln_asm_encode_{pub}
.type kiln_asm_encode_{pub}, @function
kiln_asm_encode_{pub}:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], r8
    mov     rdi, rsi
    mov     rsi, rdx
    xor     rdx, rdx
    call    .Lgen_setup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_{sym}
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lgen_finish_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_{pub}, .-kiln_asm_encode_{pub}
""")

        # 2. kiln_asm_decode_<pub>(src, len, out, arena, opts, res)
        self.emit(f""".p2align 4
.globl kiln_asm_decode_{pub}
.type kiln_asm_decode_{pub}, @function
kiln_asm_decode_{pub}:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx
    mov     QWORD PTR [rbp - 96], rcx
    mov     QWORD PTR [rbp - 104], r9
    mov     rdx, rcx
    mov     rcx, r8
    call    .Lgen_setup_ctx
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_{sym}
    jc      .Ldec_{pub}_err
    call    kiln_core_check_trailing
    jc      .Ldec_{pub}_err
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldec_{pub}_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldec_{pub}_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    clc
    call    .Lgen_finish
    ABI_EPILOGUE
.Ldec_{pub}_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldec_{pub}_efin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldec_{pub}_efin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lgen_finish
    ABI_EPILOGUE
.size kiln_asm_decode_{pub}, .-kiln_asm_decode_{pub}
""")

        # 3. kiln_asm_encode_<pub>_framed(in, dst, cap, opts, res)
        self.emit(f""".p2align 4
.globl kiln_asm_encode_{pub}_framed
.type kiln_asm_encode_{pub}_framed, @function
kiln_asm_encode_{pub}_framed:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi
    mov     QWORD PTR [rbp - 96], r8
    mov     rdi, rsi
    mov     rsi, rdx
    xor     rdx, rdx
    call    .Lgen_setup_ctx
    movabs  rdi, 0x{hval:016X}
    call    kiln_core_enc_frame_hdr
    jc      .Lef_{pub}_fin
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_enc_{sym}
.Lef_{pub}_fin:
    mov     rdi, QWORD PTR [rbp - 96]
    call    .Lgen_finish_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_{pub}_framed, .-kiln_asm_encode_{pub}_framed
""")

        # 4. kiln_asm_decode_<pub>_framed(src, len, out, arena, opts, res)
        self.emit(f""".p2align 4
.globl kiln_asm_decode_{pub}_framed
.type kiln_asm_decode_{pub}_framed, @function
kiln_asm_decode_{pub}_framed:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdx
    mov     QWORD PTR [rbp - 96], rcx
    mov     QWORD PTR [rbp - 104], r9
    mov     rdx, rcx
    mov     rcx, r8
    call    .Lgen_setup_ctx
    movabs  rdi, 0x{hval:016X}
    call    kiln_core_dec_frame_hdr
    jc      .Ldf_{pub}_err
    mov     QWORD PTR [rbp - 112], rax
    mov     rdi, QWORD PTR [rbp - 88]
    call    kiln_core_dec_{sym}
    jc      .Ldf_{pub}_err
    call    kiln_core_check_trailing
    jc      .Ldf_{pub}_err
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldf_{pub}_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldf_{pub}_ok:
    mov     rdi, QWORD PTR [rbp - 104]
    mov     rsi, QWORD PTR [rbp - 112]
    clc
    call    .Lgen_finish
    ABI_EPILOGUE
.Ldf_{pub}_err:
    mov     rcx, QWORD PTR [rbp - 96]
    test    rcx, rcx
    jz      .Ldf_{pub}_efin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldf_{pub}_efin:
    mov     rdi, QWORD PTR [rbp - 104]
    xor     esi, esi
    stc
    call    .Lgen_finish
    ABI_EPILOGUE
.size kiln_asm_decode_{pub}_framed, .-kiln_asm_decode_{pub}_framed
""")

        # 5. kiln_asm_encode_<pub>_batch(items, count, dst, cap, opts, res)
        self.emit(f""".p2align 4
.globl kiln_asm_encode_{pub}_batch
.type kiln_asm_encode_{pub}_batch, @function
kiln_asm_encode_{pub}_batch:
    ABI_PROLOGUE
    mov     QWORD PTR [rbp - 88], rdi   # items
    mov     QWORD PTR [rbp - 96], rsi   # count
    mov     QWORD PTR [rbp - 104], r9   # res
    mov     rdi, rdx                    # dst
    mov     rsi, rcx                    # cap
    xor     rdx, rdx
    mov     rcx, r8                     # opts
    call    .Lgen_setup_ctx
    call    kiln_core_depth_enter
    jc      .Leb_{pub}_fin
    mov     rdi, QWORD PTR [rbp - 96]
    call    kiln_core_enc_count
    jc      .Leb_{pub}_lerr
    mov     rax, QWORD PTR [rbp - 96]
    imul    rax, rax, {root.size}
    add     rax, QWORD PTR [rbp - 88]
    mov     QWORD PTR [rbp - 112], rax  # end_ptr
.p2align 4
.Leb_{pub}_loop:
    mov     rdi, QWORD PTR [rbp - 88]
    cmp     rdi, QWORD PTR [rbp - 112]
    jae     .Leb_{pub}_ok
    add     QWORD PTR [rbp - 88], {root.size}
    call    kiln_core_enc_{sym}
    jc      .Leb_{pub}_lerr
    jmp     .Leb_{pub}_loop
.Leb_{pub}_ok:
    dec     r15
    clc
    jmp     .Leb_{pub}_fin
.Leb_{pub}_lerr:
    dec     r15
    stc
.Leb_{pub}_fin:
    mov     rdi, QWORD PTR [rbp - 104]
    call    .Lgen_finish_nohash
    ABI_EPILOGUE
.size kiln_asm_encode_{pub}_batch, .-kiln_asm_encode_{pub}_batch
""")

        # 6. kiln_asm_decode_<pub>_batch(src, len, out_items, out_count, arena, opts, res=[rbp+16])
        self.emit(f""".p2align 4
.globl kiln_asm_decode_{pub}_batch
.type kiln_asm_decode_{pub}_batch, @function
kiln_asm_decode_{pub}_batch:
    ABI_PROLOGUE
    sub     rsp, 32                     # extra locals: -120:arr, -128:count, -136:cur, -144:end
    mov     QWORD PTR [rbp - 88], rdx   # out_items
    mov     QWORD PTR [rbp - 96], rcx   # out_count
    mov     QWORD PTR [rbp - 104], r8   # arena
    mov     rdx, r8
    mov     rcx, r9
    call    .Lgen_setup_ctx
    call    kiln_core_depth_enter
    jc      .Ldb_{pub}_err_nodec
    mov     rdi, {min_sz}
    call    kiln_core_dec_count
    jc      .Ldb_{pub}_err
    mov     QWORD PTR [rbp - 128], rax  # count
    test    rax, rax
    jz      .Ldb_{pub}_emp
    mov     rcx, {root.size}
    mul     rcx
    test    rdx, rdx
    jnz     .Ldb_{pub}_lim
    mov     rdi, rax
    mov     rsi, {root.align}
    mov     QWORD PTR [rbp - 144], rax
    call    kiln_core_arena_alloc
    jc      .Ldb_{pub}_err
    mov     QWORD PTR [rbp - 120], rax  # arr
    mov     QWORD PTR [rbp - 136], rax  # cur
    add     rax, QWORD PTR [rbp - 144]
    mov     QWORD PTR [rbp - 144], rax  # end
.p2align 4
.Ldb_{pub}_loop:
    mov     rdi, QWORD PTR [rbp - 136]
    cmp     rdi, QWORD PTR [rbp - 144]
    jae     .Ldb_{pub}_after
    add     QWORD PTR [rbp - 136], {root.size}
    call    kiln_core_dec_{sym}
    jc      .Ldb_{pub}_err
    jmp     .Ldb_{pub}_loop
.Ldb_{pub}_emp:
    mov     QWORD PTR [rbp - 120], 0
.Ldb_{pub}_after:
    dec     r15
    call    kiln_core_check_trailing
    jc      .Ldb_{pub}_err_nodec
    mov     rcx, QWORD PTR [rbp - 88]
    mov     rax, QWORD PTR [rbp - 120]
    mov     QWORD PTR [rcx], rax
    mov     rcx, QWORD PTR [rbp - 96]
    mov     rdx, QWORD PTR [rbp - 128]
    mov     QWORD PTR [rcx], rdx
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      .Ldb_{pub}_ok
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldb_{pub}_ok:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    clc
    call    .Lgen_finish
    add     rsp, 32
    ABI_EPILOGUE
.Ldb_{pub}_lim:
    mov     eax, KILN_ERR_LIMIT
    mov     rdx, r12
    sub     rdx, QWORD PTR [rbx + CTX_BASE_PTR]
.Ldb_{pub}_err:
    dec     r15
.Ldb_{pub}_err_nodec:
    mov     rcx, QWORD PTR [rbp - 104]
    test    rcx, rcx
    jz      .Ldb_{pub}_efin
    mov     QWORD PTR [rcx + ARENA_CUR], r14
.Ldb_{pub}_efin:
    mov     rdi, QWORD PTR [rbp + 16]
    xor     esi, esi
    stc
    call    .Lgen_finish
    add     rsp, 32
    ABI_EPILOGUE
.size kiln_asm_decode_{pub}_batch, .-kiln_asm_decode_{pub}_batch
""")

    def build(self) -> str:
        assert self.comp.root_struct is not None
        for t in self.comp.ordered_defs:
            if t.kind == "opt":
                self.emit_opt_codecs(t)
            elif t.kind == "list":
                self.emit_list_codecs(t)
            elif t.kind == "dict":
                self.emit_dict_codecs(t)
            elif t.kind == "struct":
                self.emit_struct_codecs(t)
        self.emit_root_cabi_wrappers(self.comp.root_struct)
        self.emit('.section .note.GNU-stack,"",@progbits')
        return "\n".join(self.lines) + "\n"


def emit_version_script() -> str:
    return "{\n    global:\n        kiln_asm_*;\n    local:\n        *;\n};\n"


def compile_schema_file(schema_path: str, out_dir: str, prefix: Optional[str], emit_map: bool) -> Tuple[str, str]:
    with open(schema_path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            raise SchemaError(f"SCHEMA: JSON parse error in {schema_path}: {e}") from e

    base = os.path.basename(schema_path)
    stem = os.path.splitext(base)[0]
    if not stem:
        raise SchemaError(f"SCHEMA: invalid schema filename '{schema_path}'")

    comp = SchemaCompiler(data, stem, prefix)
    comp.compile()

    os.makedirs(out_dir, exist_ok=True)
    h_path = os.path.join(out_dir, f"{stem}.h")
    s_path = os.path.join(out_dir, f"{stem}.s")

    with open(h_path, "w", encoding="utf-8") as hf:
        hf.write(emit_header(comp, stem))
    with open(s_path, "w", encoding="utf-8") as sf:
        sf.write(AsmEmitter(comp, stem).build())

    if emit_map:
        m_path = os.path.join(out_dir, f"{stem}.map")
        with open(m_path, "w", encoding="utf-8") as mf:
            mf.write(emit_version_script())

    return h_path, s_path


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="gld-kilngen-asm",
        description="AOT compiler: Kiln v2 JSON Schema -> x86-64 GAS Assembly (.s) + C11 header (.h)",
    )
    ap.add_argument(
        "--schema", required=True, action="append",
        help="Path to a Kiln JSON Schema file (may be passed multiple times)",
    )
    ap.add_argument("--out", required=True, help="Output directory for generated .h and .s files")
    ap.add_argument("--prefix", default=None, help="Optional symbol/type prefix (e.g. 'bench')")
    ap.add_argument("--emit-map", action="store_true", help="Also emit linker version script (.map) exporting kiln_asm_*")
    args = ap.parse_args(argv)

    try:
        for sp in args.schema:
            compile_schema_file(sp, args.out, args.prefix, args.emit_map)
    except SchemaError as e:
        print(f"gld-kilngen-asm: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"gld-kilngen-asm: I/O error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

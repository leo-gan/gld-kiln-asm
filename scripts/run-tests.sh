#!/usr/bin/env bash
set -euo pipefail

# Unified local & CI verification gate for gld-kiln-asm.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "=== 1. Version consistency check ==="
VER="$(tr -d ' \t\r\n' < VERSION)"
grep -Fq "#define KILN_ASM_VERSION      \"${VER}\"" include/kiln_asm.h
grep -Fq ".asciz \"${VER}\"" arch/x86_64/abi_c.s
echo "VERSION=${VER} matches include/kiln_asm.h and arch/x86_64/abi_c.s"

echo ""
echo "=== 2. Build & test MODE=cabi (libkiln_asm.a + libkiln_asm.so + 46/46 conformance + golden) ==="
make --no-print-directory MODE=cabi test

echo ""
echo "=== 3. Build & run examples/roundtrip.c ==="
make --no-print-directory MODE=cabi example
./bin/example_roundtrip

echo ""
echo "=== 4. Build & test MODE=nolibc (zero NEEDED libs + --self-test) ==="
make --no-print-directory MODE=nolibc test

echo ""
echo "=== 5. Build apples-to-apples C reference baseline (c_ref) ==="
make --no-print-directory c_ref
echo "Built bin/kiln_bench_cref cleanly (-Wall -Wextra -Werror)"

echo ""
echo "=== 6. AOT schema codegen (gld-kilngen-asm: static, shared .so, negative CLI, ctypes FFI) ==="
make --no-print-directory MODE=cabi test-codegen

echo ""
echo "ALL gld-kiln-asm checks PASSED."
